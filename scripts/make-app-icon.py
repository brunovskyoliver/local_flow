#!/usr/bin/env python3
"""Draws the LocalFlow app icon and writes apps/desktop/resources/AppIcon.icns.

A teal rounded square (the app's accent, #247872) on Apple's 1024 px icon grid, with a white
waveform: the menu bar glyph, large. Needs Pillow (`python3 -m pip install pillow`) and iconutil.
"""
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE, SCALE = 1024, 4  # drawn at 4x, then downsampled, for smooth edges
OUT = Path(__file__).resolve().parent.parent / "apps/desktop/resources/AppIcon.icns"


def hex_rgb(value):
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


def icon():
    s = SIZE * SCALE
    inset, radius = 100 * SCALE, 185 * SCALE  # Apple's macOS grid: 824 px tile, ~22.5% corners
    box = (inset, inset, s - inset, s - inset)
    # Soft shadow under the tile.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0], box[1] + 12 * SCALE, box[2], box[3] + 12 * SCALE), radius, fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SCALE))
    # Vertical gradient from a lighter to a deeper teal.
    top, bottom = hex_rgb("37A096"), hex_rgb("1B5C57")
    gradient = Image.new("RGBA", (1, s))
    for y in range(s):
        t = y / (s - 1)
        gradient.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    gradient = gradient.resize((s, s))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    tile = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    tile.paste(gradient, (0, 0), mask)
    # The waveform: seven rounded bars, symmetric, centred.
    heights = [0.20, 0.42, 0.66, 0.86, 0.66, 0.42, 0.20]
    bar, gap = 58 * SCALE, 40 * SCALE
    width = len(heights) * bar + (len(heights) - 1) * gap
    left, mid, span = (s - width) // 2, s // 2, 470 * SCALE
    draw = ImageDraw.Draw(tile)
    for i, h in enumerate(heights):
        x = left + i * (bar + gap)
        half = h * span / 2
        draw.rounded_rectangle((x, mid - half, x + bar, mid + half), bar // 2, fill=(255, 255, 255, 255))
    canvas = Image.alpha_composite(shadow, tile)
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    master = icon()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for factor in (1, 2):
                pixels = points * factor
                name = f"icon_{points}x{points}{'@2x' if factor == 2 else ''}.png"
                master.resize((pixels, pixels), Image.LANCZOS).save(iconset / name)
        OUT.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
