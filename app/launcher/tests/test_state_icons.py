#!/usr/bin/env python3
"""The folder state icons, app/launcher/icons/<Kind>.ico: Yandex-style badges that read at 16 and 32 px, built into the EXE.

    python3 test_state_icons.py                   # the files
    python3 test_state_icons.py RemoteAgents.exe  # and their presence in the EXE built from them

Green check = synced, blue arrows = syncing, translucent folder with a cloud = only on the server, red cross = error,
grey folder with a crossed-out cloud = offline, grey pause = paused, grey clock = waiting, orange arrow = changes to upload.
"""
import importlib.util
import itertools
import math
import re
import struct
import sys
import tempfile
from pathlib import Path

from icon_files import decode, parse_ico

ROOT = Path(__file__).resolve().parents[3]
ICONS = ROOT / 'app/launcher/icons'
sys.path.insert(0, str(ROOT / 'build'))          # the drawing scripts import icon_art
spec = importlib.util.spec_from_file_location('make_state_icons', ROOT / 'build/make-state-icons.py')
maker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maker)

SIDES = (16, 20, 24, 32, 48, 256)


def load():
    images = {}
    for kind in maker.KINDS:
        data = (ICONS / (kind + '.ico')).read_bytes()
        frames = parse_ico(data)
        assert [f['side'] for f in frames] == list(SIDES), '%s: frame sizes' % kind
        for frame in frames:
            assert frame['bits'] == 32 and frame['planes'] == 1 and frame['side'] == frame['height'], '%s: 32-bit square frames' % kind
            assert frame['data'][:8] == b'\x89PNG\r\n\x1a\n', '%s: PNG frames (the container Explorer already showed)' % kind
        images[kind] = {f['side']: decode(f)[2] for f in frames}
    return images


def pixel(rows, x, y):
    return rows[min(len(rows) - 1, max(0, int(math.floor(y))))][min(len(rows) - 1, max(0, int(math.floor(x))))]


def spread(p):
    return max(p[:3]) - min(p[:3])


def check_set():
    enum = re.search(r'enum DiskExplorerKind \{([^}]*)\}', (ROOT / 'app/launcher/DiskShellModel.cs').read_text(encoding='utf-8')).group(1)
    states = [name.strip() for name in enum.split(',')]
    assert sorted(states) == sorted(maker.KINDS), 'icons and DiskExplorerKind differ: %s' % states
    assert sorted(p.stem for p in ICONS.glob('*.ico')) == sorted(maker.KINDS), 'unexpected files in app/launcher/icons'
    print('PASS: an icon file for each of the %d folder states, none besides' % len(states))


def check_art(images):
    for kind, sizes in images.items():
        for side, rows in sizes.items():
            if side <= 48 or kind in ('Synced', 'Error'):       # the 256 px frames take long to draw: two of them stand for all
                assert rows == maker.draw(kind, side), '%s %d px is not what build/make-state-icons.py draws; run it' % (kind, side)
    print('PASS: the files are what build/make-state-icons.py draws (every frame up to 48 px, the 256 px frames of Synced and Error)')


def check_meaning(images):
    colour = {'Synced': lambda p: p[1] > p[0] + 60 and p[1] > p[2] + 60,                         # green
              'Syncing': lambda p: p[2] > p[0] + 100 and p[2] > p[1] + 40,                       # blue
              'Error': lambda p: p[0] > p[1] + 100 and p[0] > p[2] + 100,                        # red
              'Paused': lambda p: spread(p) < 40 and 80 <= p[0] <= 140,                          # grey
              'Pending': lambda p: spread(p) < 40 and 80 <= p[0] <= 140,
              'LocalChanges': lambda p: p[0] >= 220 and 110 <= p[1] <= 170 and p[2] <= 60}       # orange
    for kind, sizes in images.items():
        for side, rows in sizes.items():
            tag = '%s %d px' % (kind, side)
            assert rows[0][0][3] == 0 and rows[0][-1][3] == 0 and rows[-1][0][3] == 0, tag + ': transparent corners'
            folder = pixel(rows, 0.20 * side, 0.60 * side)                                       # left of the badge
            if kind in ('Offline', 'Unavailable'):
                assert folder[3] == 255 and spread(folder) <= 16, tag + ': a grey folder'
            elif kind == 'ServerOnly':
                assert abs(folder[3] - 127) <= 8 and folder[0] >= 240, tag + ': a translucent folder (half opaque)'
            else:
                assert folder[3] == 255 and folder[0] >= 240 and 185 <= folder[1] <= 235 and folder[2] <= 140, tag + ': a yellow folder'
            if kind in colour:
                centre, radius = maker.badge_circle(side)
                sample = pixel(rows, centre - 0.85 * radius, centre)                             # on the disc, clear of the glyph
                assert sample[3] >= 250 and colour[kind](sample), '%s: badge colour %s' % (tag, sample)
            if kind == 'ServerOnly':
                cloud = pixel(rows, 0.69 * side, 0.82 * side)
                assert cloud[3] == 255 and cloud[2] > cloud[0] + 80, tag + ': a blue cloud'
            if kind in ('Offline', 'Unavailable'):
                cloud = pixel(rows, 0.50 * side, 0.84 * side)
                assert cloud[3] == 255 and spread(cloud) <= 30 and cloud[0] < 170, tag + ': a grey cloud'
            if kind in ('Local', 'LocalCopy'):
                assert pixel(rows, 0.69 * side, 0.69 * side) == pixel(rows, 0.60 * side, 0.69 * side), tag + ': plain folder, no badge'
    assert images['Local'] == images['LocalCopy'], 'local copies use a neutral plain folder'
    assert images['Offline'] == images['Unavailable'], 'no connection and no local Syncthing look the same'
    print('PASS: every state reads as its meaning at all sizes: colours of the folder and the badge, clouds, transparent corners')


def check_distinct(images):
    for side, least in ((16, 12), (32, 80)):
        for a, b in itertools.combinations([k for k in maker.KINDS if k not in ('Unavailable', 'LocalCopy')], 2):
            different = sum(1 for y in range(side) for x in range(side) if max(abs(p - q) for p, q in zip(images[a][side][y][x], images[b][side][y][x])) > 40)
            assert different >= least, '%s and %s look alike at %d px (%d pixels differ)' % (a, b, side, different)
    print('PASS: distinct states look different at 16 and 32 px (LocalCopy intentionally uses the plain Local icon)')


def check_preview():
    with tempfile.TemporaryDirectory() as folder:
        sheet = Path(folder) / 'sheet.png'
        maker.preview(sheet)
        data = sheet.read_bytes()
        width, height = struct.unpack('>II', data[16:24])
        assert data[:8] == b'\x89PNG\r\n\x1a\n' and width > 700 and height > 800, 'contact sheet of all states'
    print('PASS: build/make-state-icons.py --preview draws a contact sheet of all states (%dx%d)' % (width, height))


def check_exe(path):
    data = Path(path).read_bytes()
    for kind in maker.KINDS:
        assert data.find(('RemoteAgents.Icons.%s.ico' % kind).encode()) >= 0, '%s: resource name missing in %s' % (kind, path)
        assert data.find((ICONS / (kind + '.ico')).read_bytes()) >= 0, '%s: icon bytes missing in %s' % (kind, path)
    print('PASS: %s has the %d state icons built in, byte for byte' % (Path(path).name, len(maker.KINDS)))


if __name__ == '__main__':
    check_set()
    pictures = load()
    check_art(pictures)
    check_meaning(pictures)
    check_distinct(pictures)
    check_preview()
    for exe in sys.argv[1:]:
        check_exe(exe)
