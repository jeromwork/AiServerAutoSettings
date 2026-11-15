#!/usr/bin/env python3
"""Draws the program's icon and writes app/launcher/app.ico (standard library only).

The picture is the tray dot: a filled circle, ForestGreen (#228B22), with a margin of 1/16 of the side
(2 px of 32), edges smoothed by 8x8 supersampling. Frames: 16, 20, 24, 32 and 48 px as 32-bit BMP (understood
by every Windows version), 256 px as PNG (Windows Vista and later).

    python3 build/make-app-icon.py [output.ico]
"""
import struct
import sys
import zlib
from pathlib import Path

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


def bmp_frame(size, alpha):
    """DIB for an icon: BITMAPINFOHEADER (height doubled), bottom-up BGRA pixels, then the 1-bit AND mask."""
    r, g, b = GREEN
    header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0, size * size * 4, 0, 0, 0, 0)
    pixels = b''.join(bytes((b, g, r, a)) for row in reversed(alpha) for a in row)
    mask = bytes(((size + 31) // 32) * 4 * size)       # alpha carries the shape; the AND mask stays clear
    return header + pixels + mask


def png_frame(size, alpha):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    r, g, b = GREEN
    raw = b''.join(b'\x00' + b''.join(bytes((r, g, b, a)) for a in row) for row in alpha)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def frames():
    """[(size, alpha rows, frame bytes)] in ascending size."""
    result = []
    for size in SIZES:
        alpha = alpha_rows(size)
        result.append((size, alpha, (png_frame if size >= PNG_FROM else bmp_frame)(size, alpha)))
    return result


def build():
    items = frames()
    out = struct.pack('<HHH', 0, 1, len(items))
    offset = 6 + 16 * len(items)
    for size, _, data in items:
        out += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    return out + b''.join(data for _, _, data in items)


if __name__ == '__main__':
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'app/launcher/app.ico'
    target.write_bytes(build())
    print('wrote', target, target.stat().st_size, 'bytes')
