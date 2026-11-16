#!/usr/bin/env python3
"""Draws the folder state icons of the Disk and writes app/launcher/icons/<Kind>.ico (standard library only).

A state icon is a folder with a badge that says what is going on with it, as in Yandex Disk. The file names are the members of
DiskExplorerKind (DiskShellModel.cs); Explorer shows a folder of the Disk with the icon of its state.

    Synced        folder + green check             all copies are equal
    Syncing       folder + blue circular arrows    files are being sent or received
    ServerOnly    translucent folder + cloud       the folder exists on the server only (right click: download)
    Error         folder + red cross               synchronisation failed
    Offline       grey folder + crossed-out cloud  no connection to the server
    Unavailable   the same: the local Syncthing does not answer, so nothing is known
    Paused        folder + grey pause bars         paused on purpose
    Pending       folder + grey clock              waiting for Syncthing to confirm
    LocalChanges  folder + orange arrow up         changes to upload before the space can be freed
    ServerRemoved folder + crossed-out grey cloud  the server no longer has the folder; the local copy is kept (not an error)
    LocalCopy     plain folder, no badge; existing copy awaiting explicit merge
    Local         plain folder, no badge

Frames: 16, 20, 24, 32, 48 and 256 px, all PNG (the container of the icons generated before, which Explorer displayed).
Every size is drawn on its own: below 32 px the round badge is snapped to the pixel grid and the glyphs are simpler.
The program embeds these files (RemoteAgents.Icons.<Kind>.ico) and writes them to %LOCALAPPDATA%\\RemoteDisk\\explorer-icons.

    python3 build/make-state-icons.py [output directory]
    python3 build/make-state-icons.py --preview sheet.png     # all states at 16, 24, 32 and 48 px on a light and a dark ground
"""
import math
import sys
from pathlib import Path

from icon_art import Layer, compose, ico, lerp, png_frame, png_image

KINDS = ('Local', 'ServerOnly', 'Pending', 'Syncing', 'Synced', 'Paused', 'Error', 'Offline', 'Unavailable', 'LocalChanges', 'ServerRemoved', 'LocalCopy')
SIZES = (16, 20, 24, 32, 48, 256)

WHITE = (255, 255, 255)
BADGE = {'Synced': (40, 160, 70), 'Syncing': (40, 120, 235), 'Error': (215, 45, 35),
         'Paused': (105, 114, 126), 'Pending': (105, 114, 126), 'LocalChanges': (240, 140, 20)}
CLOUD = {'ServerOnly': (84, 136, 206), 'Offline': (128, 136, 148), 'Unavailable': (128, 136, 148), 'ServerRemoved': (128, 136, 148)}
SLASH = (70, 76, 84)             # the cut across the cloud of a folder that cannot sync now
GREY_KINDS = ('Offline', 'Unavailable')
FADED = 0.5                      # opacity of the folder that exists only on the server
YELLOW = dict(back=(222, 160, 38), top=(255, 226, 132), bottom=(251, 196, 68))
GREY = dict(back=(141, 148, 156), top=(218, 222, 227), bottom=(186, 192, 199))


def folder(layer, s, grey):
    c = GREY if grey else YELLOW
    y0, y1 = 0.30 * s, 0.88 * s
    layer.rrect(0.05 * s, 0.12 * s, 0.46 * s, 0.34 * s, 0.05 * s, c['back'])      # tab
    layer.rrect(0.05 * s, 0.20 * s, 0.95 * s, 0.86 * s, 0.06 * s, c['back'])      # back panel
    layer.rrect(0.05 * s, y0, 0.95 * s, y1, 0.06 * s, lambda y: lerp(c['top'], c['bottom'], min(1.0, max(0.0, (y - y0) / (y1 - y0)))))


def cloud(layer, s, color, grow=0.0):
    """The cloud; grow > 0 paints it fatter, for the white outline. Returns its box."""
    x0, y0, w, h = 0.40 * s, 0.50 * s, 0.58 * s, 0.42 * s
    layer.rrect(x0 + 0.03 * w - grow, y0 + 0.52 * h - grow, x0 + 0.97 * w + grow, y0 + h + grow, 0.24 * h + grow, color)
    layer.circle(x0 + 0.27 * w, y0 + 0.62 * h, 0.27 * h + grow, color)
    layer.circle(x0 + 0.52 * w, y0 + 0.42 * h, 0.40 * h + grow, color)
    layer.circle(x0 + 0.77 * w, y0 + 0.64 * h, 0.25 * h + grow, color)
    return x0, y0, w, h


def badge_circle(s):
    """Centre and radius of the round badge; below 32 px they sit on the pixel grid, so that the glyphs are crisp."""
    if s <= 24:
        return round(0.69 * s - 0.5) + 0.5, round(0.29 * s - 0.5) + 0.5
    return 0.69 * s, 0.29 * s


def badge(layer, s, kind):
    if kind in CLOUD:
        outline = max(0.8, 0.045 * s)
        x0, y0, w, h = cloud(layer, s, WHITE, outline)
        cloud(layer, s, CLOUD[kind])
        if kind in GREY_KINDS or kind == 'ServerRemoved':         # the connection is cut / the folder is gone from the server: a slash across the cloud
            width = max(1.5, 0.06 * s)
            a, b = (x0 + 0.14 * w, y0 + 0.10 * h), (x0 + 0.90 * w, y0 + 1.00 * h)
            layer.line(a, b, width + 2 * outline, WHITE)
            layer.line(a, b, width, SLASH)
        return
    centre, radius = badge_circle(s)
    layer.circle(centre, centre, radius + max(0.6, 0.035 * s), WHITE)
    layer.circle(centre, centre, radius, BADGE[kind])
    stroke = max(0.30 * radius, 1.25)
    p = lambda x, y: (centre + x * radius, centre + y * radius)
    if kind == 'Synced':
        layer.polyline([p(-0.50, 0.04), p(-0.14, 0.42), p(0.52, -0.38)], stroke, WHITE)
    elif kind == 'Error':
        arm, thin = 0.38, max(0.26 * radius, 1.15)
        layer.line(p(-arm, -arm), p(arm, arm), thin, WHITE)
        layer.line(p(arm, -arm), p(-arm, arm), thin, WHITE)
    elif kind == 'Paused':
        bar = max(0.26 * radius, 1.2)
        for x in (-0.28, 0.28):
            layer.rrect(centre + x * radius - bar / 2, centre - 0.46 * radius, centre + x * radius + bar / 2, centre + 0.46 * radius, bar / 3, WHITE)
    elif kind == 'Pending':                                        # a clock: the badge is the face
        big = radius >= 7
        if big:
            layer.circle(centre, centre, 0.72 * radius, WHITE)
            layer.circle(centre, centre, 0.54 * radius, BADGE[kind])
        hand = max(0.2 * radius, 1.1)
        layer.line(p(0, 0), p(0, -0.40 if big else -0.56), hand, WHITE)
        layer.line(p(0, 0), p(0.30 if big else 0.44, 0.18 if big else 0.26), hand, WHITE)
    elif kind == 'LocalChanges':                                   # something to upload: an arrow up
        layer.line(p(0, 0.46), p(0, -0.10), stroke, WHITE)
        layer.polygon([p(-0.46, -0.04), p(0, -0.58), p(0.46, -0.04)], WHITE)
    elif kind == 'Syncing':
        if radius >= 7:                                            # two arrows chasing each other
            ring, width, spans, head, half = 0.56 * radius, max(0.24 * radius, 1.2), [(205, 330), (25, 150)], 0.50 * radius, 0.36 * radius
        else:                                                      # too small for two: one circular arrow
            ring, width, spans, head, half = 0.58 * radius, max(0.22 * radius, 1.0), [(60, 320)], 0.50 * radius, 0.32 * radius
        for a0, a1 in spans:
            layer.arc(centre, centre, ring, a0, a1, width, WHITE, step=8)
            t = math.radians(a1)
            tip = (centre + ring * math.cos(t), centre + ring * math.sin(t))
            tangent, normal = (-math.sin(t), math.cos(t)), (math.cos(t), math.sin(t))
            layer.polygon([(tip[0] + normal[0] * half, tip[1] + normal[1] * half), (tip[0] - normal[0] * half, tip[1] - normal[1] * half),
                           (tip[0] + tangent[0] * head, tip[1] + tangent[1] * head)], WHITE)


def draw(kind, size):
    """Rows of (r, g, b, a) of one frame."""
    scale = 8 if size <= 48 else 4
    base = Layer(size, scale)
    folder(base, size, kind in GREY_KINDS)
    layers = [(base.image(), FADED if kind == 'ServerOnly' else 1.0)]
    if kind not in ('Local', 'LocalCopy'):
        top = Layer(size, scale)
        badge(top, size, kind)
        layers.append((top.image(), 1.0))
    return compose(size, layers)


def build(kind, sizes=SIZES):
    return ico([(size, png_frame(size, draw(kind, size))) for size in sizes])


def preview(path, zoom=((16, 6), (24, 4), (32, 3), (48, 2)), grounds=((255, 255, 255), (32, 32, 32))):
    """A contact sheet for a look without Windows: a row per state, every size magnified, on light and on dark ground."""
    gap = 8
    rows = []
    for kind in KINDS:
        frames = [(draw(kind, size), size * factor, factor) for size, factor in zoom]
        height = max(side for _, side, _ in frames)
        sheet = [[] for _ in range(height + gap)]
        for ground in grounds:
            for image, side, factor in frames:
                for y in range(height + gap):
                    for x in range(side + gap):
                        r, g, b, a = image[y // factor][x // factor] if y < side and x < side else (0, 0, 0, 0)
                        sheet[y].append(tuple((c * a + bc * (255 - a)) // 255 for c, bc in zip((r, g, b), ground)) + (255,))
        rows.extend(sheet)
    Path(path).write_bytes(png_image(len(rows[0]), len(rows), rows))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--preview':
        preview(sys.argv[2])
        sys.exit(0)
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'app/launcher/icons'
    target.mkdir(parents=True, exist_ok=True)
    for kind in KINDS:
        data = build(kind)
        (target / (kind + '.ico')).write_bytes(data)
        print('wrote', target / (kind + '.ico'), len(data), 'bytes')
