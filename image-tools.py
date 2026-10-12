"""Image helper for the DSH computer-use MCP server.

Subcommands (all print one line of JSON on success):

  resize  <src> <dst> <scale>
  analyze <src> <grid> <maxColorsPerCell>
  crop    <src> <dst> <x> <y> <w> <h>

Uses Pillow from the DSH bundled Python runtime.
"""

import json
import sys
import warnings
from collections import Counter
from pathlib import Path

from PIL import Image

# Pillow deprecations are noise here: this helper's stdout is a protocol channel
# and its stderr is reported to the model as a failure.
warnings.filterwarnings("ignore", category=DeprecationWarning)


def pixels(image):
    """All pixels as a flat list, across Pillow versions."""
    getter = getattr(image, "get_flattened_data", None)
    if getter is not None:
        return list(getter())
    return list(image.getdata())


def hex_of(rgb):
    return "#%02x%02x%02x" % (rgb[0], rgb[1], rgb[2])


def nearest_of(rgb, palette):
    """Index of the palette entry closest to rgb (squared distance)."""
    best_index, best_distance = 0, None
    for index, entry in enumerate(palette):
        distance = (
            (rgb[0] - entry[0]) ** 2
            + (rgb[1] - entry[1]) ** 2
            + (rgb[2] - entry[2]) ** 2
        )
        if best_distance is None or distance < best_distance:
            best_index, best_distance = index, distance
    return best_index


def cmd_resize(src, dst, scale):
    image = Image.open(src).convert("RGB")
    new_size = (max(1, int(image.width * scale)), max(1, int(image.height * scale)))
    image.resize(new_size, Image.LANCZOS).save(dst, "PNG", optimize=True)
    return {"width": new_size[0], "height": new_size[1], "scale": scale}


def cmd_analyze(src, grid, max_colors):
    image = Image.open(src).convert("RGB")
    width, height = image.size
    cell_w = max(1, width // grid)
    cell_h = max(1, height // grid)

    # One global palette keeps cell colours comparable between cells and keeps
    # the reported names short.
    small = image.resize((min(width, 320), min(height, 320)), Image.LANCZOS)
    global_palette = small.quantize(colors=12, method=Image.MEDIANCUT).getpalette()
    palette = [
        (global_palette[i * 3], global_palette[i * 3 + 1], global_palette[i * 3 + 2])
        for i in range(12)
    ]

    counts = Counter()
    for pixel in pixels(small):
        counts[nearest_of(pixel, palette)] += 1
    total = sum(counts.values()) or 1
    dominant = [
        {"color": hex_of(palette[index]), "share": round(count / total, 3)}
        for index, count in counts.most_common(6)
    ]

    grid_cells = []
    for row in range(grid):
        row_cells = []
        for column in range(grid):
            left = column * cell_w
            upper = row * cell_h
            right = width if column == grid - 1 else left + cell_w
            lower = height if row == grid - 1 else upper + cell_h
            cell = image.crop((left, upper, right, lower)).resize(
                (min(64, max(8, right - left)), min(64, max(8, lower - upper))),
                Image.LANCZOS,
            )
            cell_counts = Counter(
                nearest_of(pixel, palette) for pixel in pixels(cell)
            )
            cell_total = sum(cell_counts.values()) or 1
            top = [
                {
                    "color": hex_of(palette[index]),
                    "share": round(count / cell_total, 2),
                }
                for index, count in cell_counts.most_common(max_colors)
            ]
            # How colourful the cell is: number of palette entries covering >4%.
            variety = sum(1 for c in cell_counts.values() if c / cell_total > 0.04)
            row_cells.append(
                {
                    "x": left,
                    "y": upper,
                    "width": right - left,
                    "height": lower - upper,
                    "main": top[0]["color"] if top else None,
                    "colors": top,
                    "variety": variety,
                }
            )
        grid_cells.append(row_cells)

    average = image.resize((1, 1), Image.LANCZOS).getpixel((0, 0))
    return {
        "width": width,
        "height": height,
        "grid": grid,
        "cellWidth": cell_w,
        "cellHeight": cell_h,
        "avgColor": hex_of(average),
        "dominantColors": dominant,
        "cells": grid_cells,
    }


def cmd_crop(src, dst, x, y, w, h):
    image = Image.open(src).convert("RGB")
    box = (int(x), int(y), int(x) + int(w), int(y) + int(h))
    image.crop(box).save(dst, "PNG", optimize=True)
    return {"path": dst, "box": {"x": int(x), "y": int(y), "width": int(w), "height": int(h)}}


def main(argv):
    if len(argv) < 2:
        raise SystemExit(json.dumps({"error": "missing subcommand"}))
    command, *rest = argv[1:]
    if command == "resize":
        result = cmd_resize(rest[0], rest[1], float(rest[2]))
    elif command == "analyze":
        result = cmd_analyze(rest[0], int(rest[1]), int(rest[2]))
    elif command == "crop":
        result = cmd_crop(rest[0], rest[1], rest[2], rest[3], rest[4], rest[5])
    else:
        raise SystemExit(json.dumps({"error": "unknown subcommand: %s" % command}))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv)
