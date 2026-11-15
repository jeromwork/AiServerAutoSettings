#!/usr/bin/env python3
"""The program's icon, the tray dot: app.ico is what build/make-app-icon.py draws, and the built EXE carries exactly it.

    python3 test_app_icon.py                  # the file only
    python3 test_app_icon.py RemoteAgents.exe # the file, and the application icon inside the EXE built from it

The EXE had no icon at all before app.ico: Explorer showed the stock "window" icon for it and for the Disk menu items.
"""
import importlib.util
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ICON = ROOT / 'app/launcher/app.ico'
spec = importlib.util.spec_from_file_location('make_app_icon', ROOT / 'build/make-app-icon.py')
maker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maker)


def parse_ico(data):
    reserved, kind, count = struct.unpack_from('<HHH', data, 0)
    assert (reserved, kind) == (0, 1), 'not an icon file'
    frames = []
    for i in range(count):
        width, height, _, _, planes, bits, length, offset = struct.unpack_from('<BBBBHHII', data, 6 + 16 * i)
        assert offset + length <= len(data), 'frame outside the file'
        frames.append(dict(side=width or 256, height=height or 256, planes=planes, bits=bits, data=data[offset:offset + length]))
    return frames


def decode(frame):
    """(kind, side, RGBA rows top to bottom) of a 32-bit BMP or PNG icon frame."""
    data = frame['data']
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        position, idat = 8, b''
        while position < len(data):
            length, kind = struct.unpack_from('>I4s', data, position)
            body = data[position + 8:position + 8 + length]
            assert struct.unpack_from('>I', data, position + 8 + length)[0] == zlib.crc32(kind + body) & 0xffffffff, 'PNG chunk CRC'
            if kind == b'IHDR':
                side, height, depth, colour, _, _, interlace = struct.unpack('>IIBBBBB', body)
                assert (side, height, depth, colour, interlace) == (frame['side'], frame['side'], 8, 6, 0), 'PNG must be 8-bit RGBA'
            elif kind == b'IDAT':
                idat += body
            position += 12 + length
        raw, stride = zlib.decompress(idat), 1 + side * 4
        assert all(raw[y * stride] == 0 for y in range(side)), 'unfiltered PNG rows expected'
        return 'png', side, [[tuple(raw[y * stride + 1 + x * 4:y * stride + 5 + x * 4]) for x in range(side)] for y in range(side)]
    size, side, double, planes, bits, compression = struct.unpack_from('<IiiHHI', data, 0)
    assert (size, side, double, planes, bits, compression) == (40, frame['side'], frame['side'] * 2, 1, 32, 0), '32-bit BMP expected'
    pixels, mask = data[40:40 + side * side * 4], data[40 + side * side * 4:]
    assert len(mask) == ((side + 31) // 32) * 4 * side and not any(mask), 'AND mask must be clear: alpha carries the shape'
    def rgba(x, y):
        at = ((side - 1 - y) * side + x) * 4   # rows are stored bottom-up, as B G R A
        return pixels[at + 2], pixels[at + 1], pixels[at], pixels[at + 3]
    return 'bmp', side, [[rgba(x, y) for x in range(side)] for y in range(side)]


def resources(path):
    """{resource type: {id: bytes}} of a PE file (numeric types and ids only)."""
    data = Path(path).read_bytes()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    assert data[pe:pe + 4] == b'PE\0\0', 'not a PE file'
    sections, optional = struct.unpack_from('<H', data, pe + 6)[0], struct.unpack_from('<H', data, pe + 20)[0]
    start = pe + 24
    directory = start + (96 if struct.unpack_from('<H', data, start)[0] == 0x10b else 112)
    rva = struct.unpack_from('<I', data, directory + 16)[0]
    spans = [struct.unpack_from('<4I', data, start + optional + i * 40 + 8) for i in range(sections)]   # vsize, vaddr, rsize, rptr
    def offset(address):
        for vsize, vaddr, rsize, rptr in spans:
            if vaddr <= address < vaddr + max(vsize, rsize):
                return rptr + address - vaddr
        raise AssertionError('resource outside the sections')
    if rva == 0:
        return {}
    base = offset(rva)
    def entries(at):
        named, ids = struct.unpack_from('<HH', data, at + 12)
        return [struct.unpack_from('<II', data, at + 16 + i * 8) for i in range(named + ids)]
    found = {}
    for kind, kind_at in entries(base):
        for ident, ident_at in entries(base + (kind_at & 0x7fffffff)):
            for _, leaf in entries(base + (ident_at & 0x7fffffff)):
                address, length, _, _ = struct.unpack_from('<IIII', data, base + leaf)
                found.setdefault(kind, {})[ident] = data[offset(address):offset(address) + length]
    return found


def check_file():
    frames = parse_ico(ICON.read_bytes())
    drawn = maker.frames()
    assert [f['side'] for f in frames] == list(maker.SIZES) == [16, 20, 24, 32, 48, 256], 'frame sizes'
    assert all(f['bits'] == 32 and f['planes'] == 1 and f['side'] == f['height'] for f in frames), '32-bit square frames'
    for frame, (side, alpha, raw) in zip(frames, drawn):
        kind, _, rows = decode(frame)
        assert kind == ('png' if side >= maker.PNG_FROM else 'bmp'), 'BMP below 256 px, PNG at 256 px'
        assert all(p[:3] == maker.GREEN for row in rows for p in row), 'ForestGreen everywhere, only alpha varies'
        assert [[p[3] for p in row] for row in rows] == alpha, 'app.ico is not what build/make-app-icon.py draws; run it'
        if kind == 'bmp':
            assert frame['data'] == raw, 'BMP frame differs from the generator output'
        # The picture itself, independent of the generator: the tray dot, a disc with a margin of 1/16 of the side.
        mid = side // 2
        assert rows[mid][mid][3] == 255 and rows[0][0][3] == 0 and rows[0][side - 1][3] == 0 and rows[side - 1][0][3] == 0, 'opaque centre, transparent corners'
        assert all(rows[y][x][3] == rows[side - 1 - y][x][3] == rows[y][side - 1 - x][3] for y in range(side) for x in range(side)), 'symmetric disc'
        edge = next(x for x, p in enumerate(rows[mid]) if p[3] > 127)
        assert abs(edge - side / 16) <= 1, 'margin of 1/16 of the side'
    print('PASS: app.ico is the tray dot as build/make-app-icon.py draws it: %s px frames, ForestGreen, margin 1/16' % ', '.join(str(f['side']) for f in frames))


def check_exe(path):
    found = resources(path)
    groups = found.get(14, {})
    assert groups, '%s has no application icon (no RT_GROUP_ICON): Explorer would show the stock window icon' % path
    group = groups[min(groups)]
    count = struct.unpack_from('<H', group, 4)[0]
    wanted = parse_ico(ICON.read_bytes())
    assert count == len(wanted), 'the EXE icon has %d frames, app.ico has %d' % (count, len(wanted))
    for i, frame in enumerate(wanted):
        width, height, _, _, planes, bits, length, ident = struct.unpack_from('<BBBBHHIH', group, 6 + 14 * i)
        assert (width or 256, height or 256, planes, bits) == (frame['side'], frame['side'], 1, 32), 'frame %d header' % i
        assert found.get(3, {}).get(ident) == frame['data'], 'the EXE frame %d is not the frame of app.ico' % frame['side']
    print('PASS: %s carries app.ico as its application icon (%d frames, byte for byte)' % (Path(path).name, count))


if __name__ == '__main__':
    check_file()
    for path in sys.argv[1:]:
        check_exe(path)
