# dsh-computer-use-ps

**Give your [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) agent eyes and hands on your Windows desktop.**

Screen capture, window inspection, virtual mouse and keyboard — as a DSH MCP server, built **only on Windows APIs**. No third-party binaries, no installer script, no driver-level input, nothing written outside your temp folder.

![tools](https://img.shields.io/badge/tools-12-blue) ![platform](https://img.shields.io/badge/platform-windows-lightgrey) ![license](https://img.shields.io/badge/license-MIT-green)

---

## What it looks like

Ask in plain language and the agent picks the right tool:

- 「截个图看看我屏幕现在什么样」 → `screen_capture`
- 「现在桌面上都开着什么窗口」 → `desktop_observe`
- 「把鼠标移到 (1200,400)」 → `mouse_move`
- 「在那个搜索框里输入 xxx 然后回车」 → `window_focus` → `mouse_click` → `text_type` → `key_press`

## Tools (12)

| Tool | What it does |
|---|---|
| `desktop_doctor` | Self-check: script root, Python/Pillow availability, screen size, DPI state. **Run this first after installing.** |
| `desktop_info` | Screen size, cursor position, topmost window under the cursor. |
| `desktop_observe` | Foreground + visible window list (title, process, rect, minimized) and cursor. Cheaper than a screenshot. |
| `screen_capture` | Capture the screen (or a region) and return it **as an image**, with optional scaling (default 0.6). |
| `screen_describe` | No pixels: splits the screen into an N×N grid and reports each cell's dominant colours, the overall palette, cursor and windows. |
| `mouse_move` | Move the cursor, optionally with a smooth duration. |
| `mouse_click` | Click at a coordinate (left / right / middle, single or double). |
| `mouse_scroll` | Wheel scroll, vertical or horizontal. |
| `mouse_drag` | Press, drag from A to B, release. |
| `key_press` | Key combos: `ctrl+c`, `alt+tab`, `f5`, `win`, … |
| `text_type` | Type text into the focused control. |
| `window_focus` | Bring a window to the foreground by (partial, case-insensitive) title. |

## Why this exists

Two similarly named plugins were evaluated and rejected:

| Candidate | Why not |
|---|---|
| `jiumengya/dsh-computer-use` | 0 stars, no license, and its installer assumes a **completely different runtime layout** (`%LOCALAPPDATA%\DshNative\`, a `farm` junction) that does not exist on a stock DSH install. The `pkg\lib\index.js` it copies is not even in the repository. |
| npm `dsh-computer-use` | A different author's package that merely shares the name. Not used, to keep the dependency chain auditable. |

This implementation therefore has **zero third-party dependencies**:

| Capability | Built on |
|---|---|
| Screen capture | `System.Drawing` |
| Mouse move / click / scroll / drag | `user32!SetCursorPos`, `user32!mouse_event` |
| Keyboard keys and text | `user32!keybd_event`, `user32!VkKeyScan` |
| Window enumeration and focus | `user32!EnumWindows`, `GetWindowRect`, `SetForegroundWindow` |
| Image scaling and colour analysis | DSH's bundled Python + Pillow |

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (the one that ships with Windows)
- DeepSeek Harness with a profile you can add an MCP row to
- Python 3 + Pillow **only** for `screen_capture` scaling and `screen_describe`.
  DSH's bundled runtime already provides it; the script auto-detects it. Without Python,
  `screen_capture` still works at `scale: 1`.

## Install

### 1. Get the files

```powershell
git clone https://github.com/<you>/dsh-computer-use-ps.git
```

### 2. Point your profile at it

Add this row to `~/.dsh/profiles/<profile>/cordis.patch.yml`:

```yaml
- id: mcp-computer-use
  name: "@deepseek-ai/dsh-mcp-client"
  config:
    serverName: desktop
    transport: stdio
    command: C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
    args:
      - -NoProfile
      - -ExecutionPolicy
      - Bypass
      - -File
      - <ABSOLUTE PATH TO>/dsh-computer-use.ps1
    toolCallTimeoutMs: 120000
```

> **The path must be absolute.** The MCP client spawns the server with the *harness's*
> working directory, not the package directory, so a relative script path resolves to
> the wrong place and the server never starts.

### 3. Restart DeepSeek Harness

MCP rows are loaded at startup. After restarting, the tools appear as
`mcp__desktop__desktop_observe`, `mcp__desktop__mouse_click`, and so on.

### 4. Verify

Ask the agent to run `desktop_doctor`, or call it yourself. It should report
`python.available: true`, `python.pillow: true`, and your real screen size.

## Coordinate system

**DPI awareness is enabled at startup**, so the reported size is in *physical* pixels
(2560×1440 on the machine this was developed against). Without it you would see a
scaled-down size like 1707×960 and every click would land in the wrong place — the most
common bug in this class of tool.

## ⚠️ Safety

These tools **really operate your desktop**:

- the cursor really moves, clicks really land, typing really goes into the focused window
- there is **no built-in confirmation step** — if the agent decides to act, it acts
- an agent that is unsure of the coordinates can click something destructive

Recommended habits:

- let the agent `screen_capture` (or `desktop_observe`) first, and say out loud what it is about to do
- keep a scratch app (Paint, Notepad) in front when you want input tested
- to disable everything: add `disabled: true` to the row above and restart DSH

The author is not responsible for what an agent clicks.

## Known limitations

- **`text_type` cannot type CJK.** It synthesises keystrokes via `VkKeyScan`, which cannot
  produce IME characters. Use a clipboard-based tool for Chinese/Japanese/Korean input.
- **Non-ASCII arguments do not survive a CLI round trip.** Passing a Chinese window title
  through `cmd.exe` → `powershell.exe` mangles it (GBK decoding). Over MCP the arguments
  arrive as UTF-8 JSON on stdin, so this only affects hand-run command-line tests.
- **`desktop_doctor` requires `$PSCommandPath`** for its own path; when run via `-Command`
  instead of `-File`, that field is `null` (harmless).
- Single monitor only: the screen size comes from the primary display.
- Only the topmost window under the cursor is reported by `desktop_info`; use
  `desktop_observe` for the full list.

## Development notes

**The script must be saved as UTF-8 *with* BOM.** Windows PowerShell 5.1 decodes a
BOM-less script using the machine's ANSI codepage, which turns Chinese comments into
mojibake whose stray bytes swallow string quotes and produce a wall of
`Unexpected token` parse errors. This bit the author once; do not remove the BOM.

Test the server without DSH:

```powershell
# MCP handshake + tool list (needs Node)
node -e "..." # or reuse any MCP stdio probe
```

## License

MIT — see [LICENSE](LICENSE).

---

## 中文说明

给 DeepSeek Harness 的 agent 加上「看屏幕 + 动鼠标键盘」的能力。底层**全部是 Windows
自带 API**，不装任何第三方二进制、不写系统目录、不申请驱动级权限。

- **12 个工具**：自检、屏幕信息、窗口清单、截屏、配色分析、鼠标移动/点击/滚动/拖拽、
  按键、文本输入、窗口聚焦
- **必须绝对路径**：MCP 客户端用宿主的工作目录启动服务器，相对路径会找错地方
- **已开启 DPI 感知**：报的是物理像素（本机 2560×1440），否则点击会整体错位
- **安全提示**：这些工具会真实操作桌面，没有确认环节；不放心就先让它截图确认，或者
  在配置行加 `disabled: true` 关掉
- **已知限制**：`text_type` 打不出中文（模拟按键无法产生输入法字符）；只支持主显示器
- **开发注意**：脚本必须存为 **UTF-8 带 BOM**，否则 PowerShell 5.1 按 GBK 解码会报语法错误
