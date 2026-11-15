#!/usr/bin/env python3
"""The program's icon, the tray dot: app.ico is what build/make-app-icon.py draws, and the built EXE carries exactly it.

    python3 test_app_icon.py                  # the file only
    python3 test_app_icon.py RemoteAgents.exe # the file, and the application icon inside the EXE built from it

The EXE had no icon at all before app.ico: Explorer showed the stock "window" icon for it and for the Disk menu items.
"""
import importlib.util
import struct
import sys
from pathlib import Path

from icon_files import decode, parse_ico, resources

ROOT = Path(__file__).resolve().parents[3]
ICON = ROOT / 'app/launcher/app.ico'
sys.path.insert(0, str(ROOT / 'build'))          # the drawing scripts import icon_art
spec = importlib.util.spec_from_file_location('make_app_icon', ROOT / 'build/make-app-icon.py')
maker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maker)


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
