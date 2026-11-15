#!/usr/bin/env python3
"""Draws the program's icon and writes app/launcher/app.ico (standard library only).

The picture is the tray dot: a filled circle, ForestGreen (#228B22), with a margin of 1/16 of the side
(2 px of 32), edges smoothed by 8x8 supersampling. Frames: 16, 20, 24, 32 and 48 px as 32-bit BMP (understood
by every Windows version), 256 px as PNG (Windows Vista and later).

    python3 build/make-app-icon.py [output.ico]
"""
import sys
from pathlib import Path

from icon_art import bmp_frame, ico, png_frame

GREEN = (34, 139, 34)          # System.Drawing.Color.ForestGreen, the colour of the "all works" tray dot
SIZES = (16, 20, 24, 32, 48, 256)
PNG_FROM = 256                 # frames of this size and larger are PNG
SAMPLES = 8                    # supersampling grid per pixel side


def alpha_rows(size):
    """Alpha 0..255 of every pixel, top row first, for the circle inscribed with a margin of size/16."""
    radius, centre = size * 7 / 16, size / 2
    limit = radius * radius
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            inside = 0
            for sy in range(SAMPLES):
                dy = y + (sy + .5) / SAMPLES - centre
                for sx in range(SAMPLES):
                    dx = x + (sx + .5) / SAMPLES - centre
                    if dx * dx + dy * dy <= limit:
                        inside += 1
            row.append((255 * inside + SAMPLES * SAMPLES // 2) // (SAMPLES * SAMPLES))
        rows.append(row)
    return rows


def frames():
    """[(size, alpha rows, frame bytes)] in ascending size."""
    result = []
    for size in SIZES:
        alpha = alpha_rows(size)
        rows = [[GREEN + (a,) for a in row] for row in alpha]
        result.append((size, alpha, (png_frame if size >= PNG_FROM else bmp_frame)(size, rows)))
    return result


def build():
    return ico([(size, data) for size, _, data in frames()])


if __name__ == '__main__':
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'app/launcher/app.ico'
    target.write_bytes(build())
    print('wrote', target, target.stat().st_size, 'bytes')
