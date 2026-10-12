<#
dsh-computer-use.ps1 — 桌面操控 MCP 服务器（stdio）

给 agent 提供「看屏幕 + 动鼠标键盘」的能力，底层全部用 Windows 自带 API：
  · 屏幕截图 / 缩放        System.Drawing
  · 鼠标移动与点击          user32!SetCursorPos / mouse_event
  · 键盘输入                user32!keybd_event + VkKeyScan
  · 滚动                    user32!mouse_event(MOUSEEVENTF_WHEEL)
  · 窗口列表                user32!EnumWindows + GetWindowRect
不安装任何第三方二进制，不写系统目录，全部可审计。

用法（由 DSH 的 MCP 客户端按 stdio 拉起）：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File dsh-computer-use.ps1
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('DshComputerUse.Native' -as [type])) {
	Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace DshComputerUse {
	public static class Native {
		[DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
		[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
		[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
		[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
		[DllImport("user32.dll")] public static extern short VkKeyScan(char ch);
		[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
		[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
		[DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
		[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
		[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
		[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
		[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
		[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
		[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
		[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
		[DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
		[DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int index);
		[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);

		public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
		public const uint MOUSEEVENTF_LEFTUP = 0x0004;
		public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
		public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
		public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
		public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
		public const uint MOUSEEVENTF_WHEEL = 0x0800;
		public const uint MOUSEEVENTF_HWHEEL = 0x01000;
		public const uint KEYEVENTF_KEYUP = 0x0002;
		public const int SM_CXSCREEN = 0;
		public const int SM_CYSCREEN = 1;

		[StructLayout(LayoutKind.Sequential)]
		public struct POINT { public int X; public int Y; }

		[StructLayout(LayoutKind.Sequential)]
		public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

		public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

		public static List<IntPtr> TopLevelWindows() {
			var list = new List<IntPtr>();
			EnumWindows(delegate(IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
			return list;
		}

		[DllImport("user32.dll")]
		private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);

		public static string WindowText(IntPtr hWnd) {
			int len = GetWindowTextLength(hWnd);
			if (len <= 0) return string.Empty;
			var sb = new StringBuilder(len + 2);
			GetWindowText(hWnd, sb, sb.Capacity);
			return sb.ToString();
		}
	}
}
'@
}

# DPI 感知：必须在取屏幕尺寸之前设置，否则坐标会被系统缩放。
try { [void][DshComputerUse.Native]::SetProcessDPIAware() } catch { }

# ── 常量 ──────────────────────────────────────────────────────────────────────
$script:ShotDir = Join-Path $env:TEMP 'dsh-computer-use'
$script:PyHelper = Join-Path $PSScriptRoot 'image-tools.py'
$script:ServerInfo = @{ name = 'computer-use'; version = '1.0.0' }
$script:Protocol = '2025-06-18'
$script:Screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

# Python 解释器来源，按优先级探测（不同机器 DSH 运行时路径不一样，写死不可移植）：
#   1) 环境变量 DSH_COMPUTER_USE_PYTHON
#   2) $DSH_HOME 下主运行时的 python.exe
#   3) $DSH_HOME 下任意 dsh-runtimes\*\dependencies\python\python.exe
#   4) PATH 上的 python / py
function Resolve-PythonExe {
	if ($env:DSH_COMPUTER_USE_PYTHON -and (Test-Path $env:DSH_COMPUTER_USE_PYTHON)) {
		return $env:DSH_COMPUTER_USE_PYTHON
	}
	$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
	$primary = Join-Path $dshHome 'dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
	if (Test-Path $primary) { return $primary }
	$runtimes = Join-Path $dshHome 'dsh-runtimes'
	if (Test-Path $runtimes) {
		$found = Get-ChildItem $runtimes -Directory -ErrorAction SilentlyContinue |
			ForEach-Object { Join-Path $_.FullName 'dependencies\python\python.exe' } |
			Where-Object { Test-Path $_ } |
			Select-Object -First 1
		if ($found) { return $found }
	}
	foreach ($name in 'python.exe', 'python3.exe', 'py.exe') {
		$cmd = Get-Command $name -ErrorAction SilentlyContinue
		if ($cmd) { return $cmd.Source }
	}
	return $null
}
$script:PythonExe = Resolve-PythonExe

New-Item -ItemType Directory -Force -Path $script:ShotDir | Out-Null

# ── 小工具 ────────────────────────────────────────────────────────────────────
function Get-Cursor {
	$p = New-Object DshComputerUse.Native+POINT
	[void][DshComputerUse.Native]::GetCursorPos([ref]$p)
	return @{ x = $p.X; y = $p.Y }
}

function Get-ScreenSize {
	return @{ width = $script:Screen.Width; height = $script:Screen.Height }
}

function Save-Screenshot([string]$Path, [int]$X, [int]$Y, [int]$W, [int]$H) {
	$bmp = New-Object System.Drawing.Bitmap $W, $H
	$g = [System.Drawing.Graphics]::FromImage($bmp)
	try {
		$g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size $W, $H))
		$bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
	} finally {
		$g.Dispose(); $bmp.Dispose()
	}
	return $Path
}

function Invoke-Python([string[]]$PyArgs) {
	if (-not (Test-Path $script:PythonExe)) { throw "找不到 Python：$script:PythonExe" }
	if (-not (Test-Path $script:PyHelper)) { throw "找不到图像助手脚本：$script:PyHelper" }
	$out = & $script:PythonExe $script:PyHelper @PyArgs 2>&1
	$text = ($out | Out-String).Trim()
	if ($LASTEXITCODE -ne 0) { throw "图像处理失败：$text" }
	return $text
}

function Assert-ScreenPoint([int]$X, [int]$Y) {
	$s = Get-ScreenSize
	if ($X -lt 0 -or $Y -lt 0 -or $X -ge $s.width -or $Y -ge $s.height) {
		throw "坐标 ($X,$Y) 超出屏幕范围 0..$($s.width - 1) x 0..$($s.height - 1)"
	}
}

function Move-Cursor([int]$X, [int]$Y) {
	Assert-ScreenPoint $X $Y
	[void][DshComputerUse.Native]::SetCursorPos($X, $Y)
	Start-Sleep -Milliseconds 60
}

function Invoke-Click([string]$Button, [int]$Count) {
	$down = switch ($Button) {
		'right' { [DshComputerUse.Native]::MOUSEEVENTF_RIGHTDOWN }
		'middle' { [DshComputerUse.Native]::MOUSEEVENTF_MIDDLEDOWN }
		default { [DshComputerUse.Native]::MOUSEEVENTF_LEFTDOWN }
	}
	$up = switch ($Button) {
		'right' { [DshComputerUse.Native]::MOUSEEVENTF_RIGHTUP }
		'middle' { [DshComputerUse.Native]::MOUSEEVENTF_MIDDLEUP }
		default { [DshComputerUse.Native]::MOUSEEVENTF_LEFTUP }
	}
	for ($i = 0; $i -lt $Count; $i++) {
		[DshComputerUse.Native]::mouse_event($down, 0, 0, 0, [IntPtr]::Zero)
		Start-Sleep -Milliseconds 40
		[DshComputerUse.Native]::mouse_event($up, 0, 0, 0, [IntPtr]::Zero)
		if ($i -lt $Count - 1) { Start-Sleep -Milliseconds 90 }
	}
}

function Send-KeyCombo([string]$Combo) {
	$parts = $Combo -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
	if ($parts.Count -eq 0) { throw '组合键为空' }
	$mods = @()
	$main = $null
	foreach ($part in $parts) {
		switch ($part.ToUpperInvariant()) {
			'CTRL' { $mods += 0x11 }
			'CONTROL' { $mods += 0x11 }
			'ALT' { $mods += 0x12 }
			'SHIFT' { $mods += 0x10 }
			'WIN' { $mods += 0x5B }
			default { $main = $part }
		}
	}
	if ($null -eq $main) { throw "组合键缺少主键：$Combo" }
	$vk = ConvertTo-VirtualKey $main
	foreach ($m in $mods) { [DshComputerUse.Native]::keybd_event($m, 0, 0, [IntPtr]::Zero) }
	Start-Sleep -Milliseconds 30
	[DshComputerUse.Native]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
	Start-Sleep -Milliseconds 40
	[DshComputerUse.Native]::keybd_event($vk, 0, [DshComputerUse.Native]::KEYEVENTF_KEYUP, [IntPtr]::Zero)
	foreach ($m in ($mods | Sort-Object -Descending)) {
		[DshComputerUse.Native]::keybd_event($m, 0, [DshComputerUse.Native]::KEYEVENTF_KEYUP, [IntPtr]::Zero)
	}
}

function ConvertTo-VirtualKey([string]$Name) {
	$named = @{
		'ENTER' = 0x0D; 'RETURN' = 0x0D; 'TAB' = 0x09; 'ESC' = 0x1B; 'ESCAPE' = 0x1B
		'SPACE' = 0x20; 'BACKSPACE' = 0x08; 'DELETE' = 0x2E; 'DEL' = 0x2E
		'HOME' = 0x24; 'END' = 0x23; 'PAGEUP' = 0x21; 'PAGEDOWN' = 0x22
		'UP' = 0x26; 'DOWN' = 0x28; 'LEFT' = 0x25; 'RIGHT' = 0x27
		'CAPSLOCK' = 0x14; 'PRINTSCREEN' = 0x2C; 'INSERT' = 0x2D
		'F1' = 0x70; 'F2' = 0x71; 'F3' = 0x72; 'F4' = 0x73; 'F5' = 0x74; 'F6' = 0x75
		'F7' = 0x76; 'F8' = 0x77; 'F9' = 0x78; 'F10' = 0x79; 'F11' = 0x7A; 'F12' = 0x7B
	}
	$key = $Name.ToUpperInvariant()
	if ($named.ContainsKey($key)) { return [byte]$named[$key] }
	if ($key.Length -eq 1) {
		$scan = [DshComputerUse.Native]::VkKeyScan($key[0])
		if ($scan -eq -1) { throw "无法映射按键：$Name" }
		return [byte]($scan -band 0xFF)
	}
	throw "不认识的按键名：$Name"
}

function Send-Text([string]$Text) {
	foreach ($ch in $Text.ToCharArray()) {
		$scan = [DshComputerUse.Native]::VkKeyScan($ch)
		if ($scan -eq -1) { continue }   # 当前键盘布局打不出的字符直接跳过
		$vk = [byte]($scan -band 0xFF)
		$shift = ($scan -shr 8) -band 0x01
		if ($shift) { [DshComputerUse.Native]::keybd_event(0x10, 0, 0, [IntPtr]::Zero) }
		[DshComputerUse.Native]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
		Start-Sleep -Milliseconds 12
		[DshComputerUse.Native]::keybd_event($vk, 0, [DshComputerUse.Native]::KEYEVENTF_KEYUP, [IntPtr]::Zero)
		if ($shift) { [DshComputerUse.Native]::keybd_event(0x10, 0, [DshComputerUse.Native]::KEYEVENTF_KEYUP, [IntPtr]::Zero) }
		Start-Sleep -Milliseconds 12
	}
	return $Text.Length
}

function Get-Windows {
	$fg = [DshComputerUse.Native]::GetForegroundWindow()
	$list = @()
	foreach ($h in [DshComputerUse.Native]::TopLevelWindows()) {
		if (-not [DshComputerUse.Native]::IsWindowVisible($h)) { continue }
		$title = [DshComputerUse.Native]::WindowText($h)
		if ([string]::IsNullOrWhiteSpace($title)) { continue }
		$rect = New-Object DshComputerUse.Native+RECT
		if (-not [DshComputerUse.Native]::GetWindowRect($h, [ref]$rect)) { continue }
		# $pid 是 PowerShell 只读自动变量，这里必须换名。
		$owner = 0
		[void][DshComputerUse.Native]::GetWindowThreadProcessId($h, [ref]$owner)
		$proc = ''
		try { $proc = (Get-Process -Id $owner -ErrorAction Stop).ProcessName } catch { }
		$list += [ordered]@{
			title = $title
			process = $proc
			x = $rect.Left; y = $rect.Top
			width = $rect.Right - $rect.Left
			height = $rect.Bottom - $rect.Top
			minimized = [bool][DshComputerUse.Native]::IsIconic($h)
			foreground = ($h -eq $fg)
		}
	}
	return , @($list | Sort-Object { -not $_.foreground }, { $_.title })
}

# ── 工具定义 ──────────────────────────────────────────────────────────────────
$script:Tools = @(
	@{
		name = 'desktop_doctor'
		description = '自检：报告服务器运行目录、脚本位置、Python 解释器是否可用、Pillow 是否就绪、屏幕尺寸、DPI 感知状态、截图目录。装完先用它确认环境没问题。'
		inputSchema = @{ type = 'object'; properties = @{}; additionalProperties = $false }
		handler = {
			$pythonOk = $false
			$pillowOk = $false
			$pythonVersion = $null
			if ($script:PythonExe) {
				try {
					$out = & $script:PythonExe -c "import sys; print(sys.version.split()[0])" 2>&1
					if ($LASTEXITCODE -eq 0) { $pythonOk = $true; $pythonVersion = ($out | Out-String).Trim() }
				} catch { }
				if ($pythonOk) {
					try {
						$null = & $script:PythonExe -c "import PIL" 2>&1
						$pillowOk = ($LASTEXITCODE -eq 0)
					} catch { }
				}
			}
			return @{
				server = $script:ServerInfo
				scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
				packageRoot = $PSScriptRoot
				workingDirectory = (Get-Location).Path
				python = @{
					configuredPath = $script:PythonExe
					available = $pythonOk
					version = $pythonVersion
					pillow = $pillowOk
					helperScript = $script:PyHelper
					helperExists = (Test-Path $script:PyHelper)
				}
				screen = Get-ScreenSize
				dpiAware = $true
				screenshotDir = $script:ShotDir
				powershell = $PSVersionTable.PSVersion.ToString()
				note = 'python 不可用时，screen_capture 仍可按 scale=1 原图返回，只有缩放与 screen_describe 需要 Pillow。'
			}
		}
	},
	@{
		name = 'desktop_info'
		description = '报告桌面环境：屏幕尺寸、当前鼠标坐标、鼠标所在位置最上层的窗口。做任何点击/输入前先用它确认坐标系。'
		inputSchema = @{ type = 'object'; properties = @{}; additionalProperties = $false }
		handler = {
			$cur = Get-Cursor
			$s = Get-ScreenSize
			$under = $null
			$pt = New-Object DshComputerUse.Native+POINT
			try {
				[void][DshComputerUse.Native]::GetCursorPos([ref]$pt)
				$h = [DshComputerUse.Native]::WindowFromPoint($pt)
				if ($h -ne [IntPtr]::Zero) { $under = [DshComputerUse.Native]::WindowText($h) }
			} catch { }
			return @{
				screen = $s
				cursor = $cur
				windowUnderCursor = $under
				screenshotDir = $script:ShotDir
			}
		}
	},
	@{
		name = 'desktop_observe'
		description = '观察当前桌面：屏幕尺寸、前台/可见窗口清单（标题、进程、矩形），以及鼠标位置。用来「看清楚现在桌面上有什么」，比截图更省 token。'
		inputSchema = @{
			type = 'object'
			properties = @{ limit = @{ type = 'number'; description = '最多返回多少个窗口，默认 25。' } }
			additionalProperties = $false
		}
		handler = {
			param($a)
			$limit = 25
			if ($a.limit) { $limit = [int]$a.limit }
			$wins = Get-Windows
			$fg = $wins | Where-Object { $_.foreground } | Select-Object -First 1
			return @{
				screen = Get-ScreenSize
				cursor = Get-Cursor
				foregroundWindow = $fg
				windowCount = $wins.Count
				windows = @($wins | Select-Object -First $limit)
			}
		}
	},
	@{
		name = 'screen_capture'
		description = '截屏并作为图片返回（可用 read_image 查看）。可只截一块区域。返回的图片即模型看到的内容；区域坐标以屏幕左上角为原点。'
		inputSchema = @{
			type = 'object'
			properties = @{
				x = @{ type = 'number'; description = '区域左上角 X，省略则整屏。' }
				y = @{ type = 'number'; description = '区域左上角 Y，省略则整屏。' }
				width = @{ type = 'number'; description = '区域宽度。' }
				height = @{ type = 'number'; description = '区域高度。' }
				scale = @{ type = 'number'; description = '缩放系数 0.1–1，默认 0.6（省 token；要看细节再用 1）。' }
				filename = @{ type = 'string'; description = '可选文件名（不含目录）。' }
			}
			additionalProperties = $false
		}
		handler = {
			param($a)
			$s = Get-ScreenSize
			$x = 0; $y = 0; $w = $s.width; $h = $s.height
			if ($null -ne $a.x) { $x = [int]$a.x }
			if ($null -ne $a.y) { $y = [int]$a.y }
			if ($a.width) { $w = [int]$a.width }
			if ($a.height) { $h = [int]$a.height }
			if ($w -le 0 -or $h -le 0) { throw '宽高必须为正数' }
			if ($x -lt 0 -or $y -lt 0 -or ($x + $w) -gt $s.width -or ($y + $h) -gt $s.height) {
				throw "区域 ($x,$y,${w}x${h}) 超出屏幕 $($s.width)x$($s.height)"
			}
			$name = if ($a.filename) { [IO.Path]::GetFileName([string]$a.filename) } else { "shot-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').png" }
			if (-not $name.EndsWith('.png')) { $name = "$name.png" }
			$full = Join-Path $script:ShotDir $name
			$scaled = Join-Path $script:ShotDir ([IO.Path]::GetFileNameWithoutExtension($name) + '.view.png')
			[void](Save-Screenshot $full $x $y $w $h)

			$scale = 0.6
			if ($null -ne $a.scale) { $scale = [double]$a.scale }
			if ($scale -gt 1) { $scale = 1 }
			if ($scale -lt 0.1) { $scale = 0.1 }
			$viewPath = $full
			$viewSize = @{ width = $w; height = $h }
			if ($scale -lt 1) {
				$json = Invoke-Python @('resize', $full, $scaled, "$scale")
				$viewSize = $json | ConvertFrom-Json
				$viewPath = $scaled
			}
			$bytes = [IO.File]::ReadAllBytes($viewPath)
			$b64 = [Convert]::ToBase64String($bytes)
			return @{
				text = (@{
					captured = $full
					region = @{ x = $x; y = $y; width = $w; height = $h }
					viewSize = $viewSize
					scale = $scale
					screen = $s
				} | ConvertTo-Json -Depth 5)
				images = @(@{ data = $b64; mimeType = 'image/png' })
			}
		}
	},
	@{
		name = 'screen_describe'
		description = '不给模型看像素，而是用程序分析屏幕：把画面切成 NxN 网格，报告每格的主色与整体配色，并附带鼠标位置和窗口信息。适合「现在屏幕大概是什么状态」这种判断。'
		inputSchema = @{
			type = 'object'
			properties = @{
				grid = @{ type = 'number'; description = '网格边长，2–6，默认 3。' }
				maxColors = @{ type = 'number'; description = '每格报告的主色数，1–4，默认 2。' }
			}
			additionalProperties = $false
		}
		handler = {
			param($a)
			$grid = if ($a.grid) { [int]$a.grid } else { 3 }
			$maxColors = if ($a.maxColors) { [int]$a.maxColors } else { 2 }
			if ($grid -lt 2) { $grid = 2 }
			if ($grid -gt 6) { $grid = 6 }
			if ($maxColors -lt 1) { $maxColors = 1 }
			if ($maxColors -gt 4) { $maxColors = 4 }
			$s = Get-ScreenSize
			$full = Join-Path $script:ShotDir 'describe.png'
			[void](Save-Screenshot $full 0 0 $s.width $s.height)
			$json = Invoke-Python @('analyze', $full, "$grid", "$maxColors")
			$analysis = $json | ConvertFrom-Json
			$wins = (Get-Windows | Select-Object -First 8)
			return @{
				screen = $s
				cursor = Get-Cursor
				grid = $analysis.grid
				cellWidth = $analysis.cellWidth
				cellHeight = $analysis.cellHeight
				avgColor = $analysis.avgColor
				dominantColors = $analysis.dominantColors
				topWindows = $wins
			}
		}
	},
	@{
		name = 'mouse_move'
		description = '把鼠标移动到屏幕坐标 (x,y)。坐标以屏幕左上角 (0,0) 为原点。'
		inputSchema = @{
			type = 'object'
			properties = @{
				x = @{ type = 'number'; description = '目标 X（像素）。' }
				y = @{ type = 'number'; description = '目标 Y（像素）。' }
				durationMs = @{ type = 'number'; description = '可选：用多少毫秒平滑移动过去（默认 0，瞬移）。' }
			}
			required = @('x', 'y')
			additionalProperties = $false
		}
		handler = {
			param($a)
			$x = [int]$a.x; $y = [int]$a.y
			Assert-ScreenPoint $x $y
			$from = Get-Cursor
			$dur = if ($a.durationMs) { [int]$a.durationMs } else { 0 }
			if ($dur -gt 0) {
				$steps = [Math]::Max(2, [Math]::Min(60, [int]($dur / 16)))
				for ($i = 1; $i -le $steps; $i++) {
					$nx = [int]($from.x + ($x - $from.x) * $i / $steps)
					$ny = [int]($from.y + ($y - $from.y) * $i / $steps)
					[void][DshComputerUse.Native]::SetCursorPos($nx, $ny)
					Start-Sleep -Milliseconds ([Math]::Max(1, [int]($dur / $steps)))
				}
			} else {
				[void][DshComputerUse.Native]::SetCursorPos($x, $y)
			}
			Start-Sleep -Milliseconds 60
			return @{ movedTo = @{ x = $x; y = $y }; from = $from; cursor = Get-Cursor }
		}
	},
	@{
		name = 'mouse_click'
		description = '在指定坐标点击鼠标（会先移动过去）。button 可选 left/right/middle，count 为点击次数（2=双击）。这个动作会真实作用到桌面，请先确认坐标。'
		inputSchema = @{
			type = 'object'
			properties = @{
				x = @{ type = 'number'; description = '点击位置 X。' }
				y = @{ type = 'number'; description = '点击位置 Y。' }
				button = @{ type = 'string'; enum = @('left', 'right', 'middle'); description = '默认 left。' }
				count = @{ type = 'number'; description = '点击次数，默认 1。' }
			}
			required = @('x', 'y')
			additionalProperties = $false
		}
		handler = {
			param($a)
			$x = [int]$a.x; $y = [int]$a.y
			$button = if ($a.button) { [string]$a.button } else { 'left' }
			$count = if ($a.count) { [int]$a.count } else { 1 }
			if ($count -lt 1) { $count = 1 }
			if ($count -gt 3) { $count = 3 }
			Move-Cursor $x $y
			Invoke-Click $button $count
			return @{ clicked = @{ x = $x; y = $y; button = $button; count = $count }; cursor = Get-Cursor }
		}
	},
	@{
		name = 'mouse_scroll'
		description = '滚动鼠标滚轮。delta 为正向上、负向下；一格通常是 120。会在当前鼠标位置滚动，可先指定坐标。'
		inputSchema = @{
			type = 'object'
			properties = @{
				delta = @{ type = 'number'; description = '滚动量，正数向上、负数向下（一格 120）。' }
				x = @{ type = 'number'; description = '可选：先移动到该 X 再滚。' }
				y = @{ type = 'number'; description = '可选：先移动到该 Y 再滚。' }
				horizontal = @{ type = 'boolean'; description = 'true 表示横向滚动。' }
			}
			required = @('delta')
			additionalProperties = $false
		}
		handler = {
			param($a)
			if ($null -ne $a.x -and $null -ne $a.y) { Move-Cursor ([int]$a.x) ([int]$a.y) }
			$delta = [int]$a.delta
			$flag = if ($a.horizontal) { [DshComputerUse.Native]::MOUSEEVENTF_HWHEEL } else { [DshComputerUse.Native]::MOUSEEVENTF_WHEEL }
			$remaining = [Math]::Abs($delta)
			$step = if ($delta -lt 0) { -120 } else { 120 }
			while ($remaining -gt 0) {
				$chunk = [Math]::Min(120, $remaining)
				$value = if ($step -lt 0) { -$chunk } else { $chunk }
				# mouse_event 的数据参数是无符号 32 位，负数（向下滚）要按二进制补码传，
				# 不能直接强转 UInt32（会抛溢出）。BitConverter 走的是原始字节。
				$unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$value), 0)
				[DshComputerUse.Native]::mouse_event($flag, 0, 0, $unsigned, [IntPtr]::Zero)
				$remaining -= $chunk
				Start-Sleep -Milliseconds 30
			}
			return @{ scrolled = $delta; horizontal = [bool]$a.horizontal; cursor = Get-Cursor }
		}
	},
	@{
		name = 'key_press'
		description = '按下组合键或单个键，例如 "enter"、"esc"、"tab"、"ctrl+c"、"alt+tab"、"win"、"f5"。'
		inputSchema = @{
			type = 'object'
			properties = @{ keys = @{ type = 'string'; description = '键名，可用 + 组合，如 ctrl+shift+t。' } }
			required = @('keys')
			additionalProperties = $false
		}
		handler = {
			param($a)
			Send-KeyCombo ([string]$a.keys)
			return @{ pressed = [string]$a.keys }
		}
	},
	@{
		name = 'text_type'
		description = '把一段文本敲进当前焦点控件（模拟真实按键）。只能输入当前键盘布局能打出的字符；中文等需要输入法的字符请改用剪贴板方案。'
		inputSchema = @{
			type = 'object'
			properties = @{ text = @{ type = 'string'; description = '要输入的文本。' } }
			required = @('text')
			additionalProperties = $false
		}
		handler = {
			param($a)
			$text = [string]$a.text
			$sent = Send-Text $text
			return @{ charactersSent = $sent; note = '字符数按键盘布局映射，打不出的字符会被跳过。' }
		}
	},
	@{
		name = 'mouse_drag'
		description = '从 (fromX,fromY) 按住拖到 (toX,toY)，用于拖拽窗口、框选、拖放。'
		inputSchema = @{
			type = 'object'
			properties = @{
				fromX = @{ type = 'number' }; fromY = @{ type = 'number' }
				toX = @{ type = 'number' }; toY = @{ type = 'number' }
				button = @{ type = 'string'; enum = @('left', 'right', 'middle'); description = '默认 left。' }
				durationMs = @{ type = 'number'; description = '拖动过程时长，默认 500ms。' }
			}
			required = @('fromX', 'fromY', 'toX', 'toY')
			additionalProperties = $false
		}
		handler = {
			param($a)
			$fx = [int]$a.fromX; $fy = [int]$a.fromY
			$tx = [int]$a.toX; $ty = [int]$a.toY
			$button = if ($a.button) { [string]$a.button } else { 'left' }
			$dur = if ($a.durationMs) { [int]$a.durationMs } else { 500 }
			Assert-ScreenPoint $fx $fy
			Assert-ScreenPoint $tx $ty
			$down = switch ($button) {
				'right' { [DshComputerUse.Native]::MOUSEEVENTF_RIGHTDOWN }
				'middle' { [DshComputerUse.Native]::MOUSEEVENTF_MIDDLEDOWN }
				default { [DshComputerUse.Native]::MOUSEEVENTF_LEFTDOWN }
			}
			$up = switch ($button) {
				'right' { [DshComputerUse.Native]::MOUSEEVENTF_RIGHTUP }
				'middle' { [DshComputerUse.Native]::MOUSEEVENTF_MIDDLEUP }
				default { [DshComputerUse.Native]::MOUSEEVENTF_LEFTUP }
			}
			Move-Cursor $fx $fy
			[DshComputerUse.Native]::mouse_event($down, 0, 0, 0, [IntPtr]::Zero)
			Start-Sleep -Milliseconds 90
			$steps = [Math]::Max(4, [Math]::Min(60, [int]($dur / 16)))
			for ($i = 1; $i -le $steps; $i++) {
				$nx = [int]($fx + ($tx - $fx) * $i / $steps)
				$ny = [int]($fy + ($ty - $fy) * $i / $steps)
				[void][DshComputerUse.Native]::SetCursorPos($nx, $ny)
				Start-Sleep -Milliseconds ([Math]::Max(1, [int]($dur / $steps)))
			}
			Start-Sleep -Milliseconds 90
			[DshComputerUse.Native]::mouse_event($up, 0, 0, 0, [IntPtr]::Zero)
			return @{ dragged = @{ from = @{ x = $fx; y = $fy }; to = @{ x = $tx; y = $ty }; button = $button } }
		}
	},
	@{
		name = 'window_focus'
		description = '按标题关键字把某个窗口切到前台。先 desktop_observe 拿到标题，再用它聚焦，然后才能可靠地输入。'
		inputSchema = @{
			type = 'object'
			properties = @{ title = @{ type = 'string'; description = '窗口标题的一部分（不区分大小写）。' } }
			required = @('title')
			additionalProperties = $false
		}
		handler = {
			param($a)
			$needle = [string]$a.title
			$fg = [DshComputerUse.Native]::GetForegroundWindow()
			$match = $null
			$handles = New-Object 'System.Collections.Generic.List[System.IntPtr]'
			$titles = New-Object 'System.Collections.Generic.List[string]'
			foreach ($h in [DshComputerUse.Native]::TopLevelWindows()) {
				if (-not [DshComputerUse.Native]::IsWindowVisible($h)) { continue }
				$t = [DshComputerUse.Native]::WindowText($h)
				if ([string]::IsNullOrWhiteSpace($t)) { continue }
				$handles.Add($h)
				$titles.Add($t)
			}
			for ($i = 0; $i -lt $titles.Count; $i++) {
				# 大小写不敏感，匹配标题的一部分；找不到时再用模糊回退。
				if ($titles[$i].ToLowerInvariant().Contains($needle.ToLowerInvariant())) {
					$match = @{ handle = $handles[$i]; title = $titles[$i] }
					break
				}
			}
			if ($null -eq $match) {
				# 回退一：忽略空格与连字符再比一次（"Paint" vs "MS Paint"）
				$flatNeedle = ($needle -replace '[\s\-_]', '').ToLowerInvariant()
				if ($flatNeedle.Length -ge 3) {
					for ($i = 0; $i -lt $titles.Count; $i++) {
						$flatTitle = ($titles[$i] -replace '[\s\-_]', '').ToLowerInvariant()
						if ($flatTitle.Contains($flatNeedle)) {
							$match = @{ handle = $handles[$i]; title = $titles[$i] }
							break
						}
					}
				}
			}
			if ($null -eq $match) {
				$shown = ($titles | Select-Object -First 15) -join ' | '
				throw "没有找到标题包含「$needle」的可见窗口。当前可见窗口：$shown"
			}
			[void][DshComputerUse.Native]::SetForegroundWindow($match.handle)
			Start-Sleep -Milliseconds 250
			return @{ focused = $match.title; wasForeground = ($match.handle -eq $fg) }
		}
	}
)

# ── JSON-RPC / MCP 主循环 ─────────────────────────────────────────────────────
function Write-Message($object) {
	$json = $object | ConvertTo-Json -Depth 12 -Compress
	[Console]::Out.WriteLine($json)
	[Console]::Out.Flush()
}

function Write-Result($id, $result) {
	Write-Message @{ jsonrpc = '2.0'; id = $id; result = $result }
}

function Write-Error($id, $code, $message) {
	Write-Message @{ jsonrpc = '2.0'; id = $id; error = @{ code = $code; message = $message } }
}

function Invoke-Tool([string]$name, $arguments) {
	$tool = $script:Tools | Where-Object { $_.name -eq $name } | Select-Object -First 1
	if ($null -eq $tool) { throw "未知工具：$name" }
	$result = & $tool.handler $arguments
	if ($result -is [hashtable] -and $result.ContainsKey('text')) {
		$content = @(@{ type = 'text'; text = [string]$result.text })
		foreach ($img in @($result.images)) {
			$content += @{ type = 'image'; data = $img.data; mimeType = $img.mimeType }
		}
		return @{ content = $content }
	}
	$json = $result | ConvertTo-Json -Depth 10
	return @{ content = @(@{ type = 'text'; text = $json }) }
}

$stdin = [Console]::In
while ($true) {
	$line = $stdin.ReadLine()
	if ($null -eq $line) { break }
	$line = $line.Trim()
	if ($line -eq '') { continue }
	$msg = $null
	try { $msg = $line | ConvertFrom-Json } catch { continue }
	if ($null -eq $msg) { continue }

	switch ($msg.method) {
		'initialize' {
			Write-Result $msg.id @{
				protocolVersion = if ($msg.params.protocolVersion) { $msg.params.protocolVersion } else { $script:Protocol }
				capabilities = @{ tools = @{ listChanged = $false } }
				serverInfo = $script:ServerInfo
				instructions = '桌面操控：先用 desktop_info 或 desktop_observe 看清屏幕与窗口，再 mouse_move / mouse_click / text_type / key_press。坐标以屏幕左上角为原点，点击会真实作用到你的桌面。'
			}
		}
		'notifications/initialized' { }
		'notifications/cancelled' { }
		'ping' { Write-Result $msg.id @{} }
		'tools/list' {
			$defs = @()
			foreach ($t in $script:Tools) {
				$defs += @{ name = $t.name; description = $t.description; inputSchema = $t.inputSchema }
			}
			Write-Result $msg.id @{ tools = $defs }
		}
		'tools/call' {
			$name = [string]$msg.params.name
			$args = $msg.params.arguments
			try {
				$result = Invoke-Tool $name $args
				Write-Result $msg.id $result
			} catch {
				Write-Result $msg.id @{
					content = @(@{ type = 'text'; text = "Error: $($_.Exception.Message)" })
					isError = $true
				}
			}
		}
		default {
			if ($null -ne $msg.id) { Write-Error $msg.id -32601 "Method not found: $($msg.method)" }
		}
	}
}
