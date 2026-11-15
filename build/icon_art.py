"""Tiny vector painter and icon file writers for the program's icons (make-app-icon.py, make-state-icons.py).

Standard library only. Shapes are painted opaque on a supersampled layer (one span per row, no per-pixel tests), a layer is
box-filtered down to RGBA and layers are composed with "over". Coordinates are pixels of the final image, y grows downwards.
"""
import math
import struct
import zlib


class Layer:
    def __init__(self, size, scale):
        self.size, self.scale = size, scale
        n = self.n = size * scale
        self.r, self.g, self.b, self.a = (bytearray(n * n) for _ in range(4))

    # --- painting ---------------------------------------------------------------------------------------------------
    def _rows(self, y0, y1):
        s = self.scale
        return range(max(0, math.ceil(y0 * s - 0.5)), min(self.n, math.ceil(y1 * s - 0.5)))

    def _centre(self, j):
        return (j + 0.5) / self.scale

    def _span(self, j, xa, xb, color):
        s, n = self.scale, self.n
        i0, i1 = max(0, math.ceil(xa * s - 0.5)), min(n, math.ceil(xb * s - 0.5))
        if i1 <= i0:
            return
        if callable(color):
            color = color(self._centre(j))
        at, count = j * n, i1 - i0
        self.r[at + i0:at + i1] = bytes((color[0],)) * count
        self.g[at + i0:at + i1] = bytes((color[1],)) * count
        self.b[at + i0:at + i1] = bytes((color[2],)) * count
        self.a[at + i0:at + i1] = b'\xff' * count

    def circle(self, cx, cy, r, color):
        for j in self._rows(cy - r, cy + r):
            dy = self._centre(j) - cy
            h2 = r * r - dy * dy
            if h2 > 0:
                h = math.sqrt(h2)
                self._span(j, cx - h, cx + h, color)

    def rect(self, x0, y0, x1, y1, color):
        for j in self._rows(y0, y1):
            self._span(j, x0, x1, color)

    def rrect(self, x0, y0, x1, y1, rad, color):
        rad = min(rad, (x1 - x0) / 2, (y1 - y0) / 2)
        for j in self._rows(y0, y1):
            y = self._centre(j)
            edge = min(y - y0, y1 - y)
            inset = 0.0 if edge >= rad else rad - math.sqrt(max(0.0, rad * rad - (rad - edge) ** 2))
            self._span(j, x0 + inset, x1 - inset, color)

    def polygon(self, pts, color):
        ys = [p[1] for p in pts]
        count = len(pts)
        for j in self._rows(min(ys), max(ys)):
            y = self._centre(j)
            xs = []
            for k in range(count):
                (xa, ya), (xb, yb) = pts[k], pts[(k + 1) % count]
                if (ya <= y < yb) or (yb <= y < ya):
                    xs.append(xa + (y - ya) * (xb - xa) / (yb - ya))
            xs.sort()
            for k in range(0, len(xs) - 1, 2):
                self._span(j, xs[k], xs[k + 1], color)

    def line(self, p, q, width, color):
        """A thick segment with round ends."""
        half = width / 2
        dx, dy = q[0] - p[0], q[1] - p[1]
        length = math.hypot(dx, dy)
        if length > 0:
            nx, ny = -dy / length * half, dx / length * half
            self.polygon([(p[0] + nx, p[1] + ny), (q[0] + nx, q[1] + ny), (q[0] - nx, q[1] - ny), (p[0] - nx, p[1] - ny)], color)
        self.circle(p[0], p[1], half, color)
        self.circle(q[0], q[1], half, color)

    def polyline(self, pts, width, color):
        for a, b in zip(pts, pts[1:]):
            self.line(a, b, width, color)

    def arc(self, cx, cy, r, a0, a1, width, color, step=12):
        """Degrees, 0 = right, growing clockwise on screen."""
        steps = max(2, int(abs(a1 - a0) / step) + 1)
        pts = [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / steps)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / steps))) for i in range(steps + 1)]
        self.polyline(pts, width, color)

    # --- result -----------------------------------------------------------------------------------------------------
    def image(self):
        """Rows of (r, g, b, a), straight alpha; the colour is the mean over covered samples only (no dark fringes)."""
        s, n, size = self.scale, self.n, self.size
        area = s * s
        rows = []
        for y in range(size):
            row = []
            for x in range(size):
                covered = red = green = blue = 0
                for k in range(s):
                    at = (y * s + k) * n + x * s
                    covered += sum(self.a[at:at + s])
                    red += sum(self.r[at:at + s])
                    green += sum(self.g[at:at + s])
                    blue += sum(self.b[at:at + s])
                covered //= 255
                if covered == 0:
                    row.append((0, 0, 0, 0))
                else:
                    row.append((round(red / covered), round(green / covered), round(blue / covered), round(255 * covered / area)))
            rows.append(row)
        return rows


def compose(size, layers):
    """layers: [(image, opacity)] bottom to top -> rows of (r, g, b, a) with straight alpha."""
    out = []
    for y in range(size):
        row = []
        for x in range(size):
            red = green = blue = alpha = 0.0
            for image, opacity in layers:
                r, g, b, a = image[y][x]
                top = a / 255 * opacity
                if top <= 0:
                    continue
                keep = 1 - top
                red, green, blue = r * top + red * keep, g * top + green * keep, b * top + blue * keep
                alpha = top + alpha * keep
            if alpha <= 0:
                row.append((0, 0, 0, 0))
            else:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha), round(alpha * 255)))
        out.append(row)
    return out


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


# --- containers -------------------------------------------------------------------------------------------------------
def png_image(width, height, rows):
    """8-bit RGBA PNG without filtering."""
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    raw = b''.join(b'\x00' + b''.join(bytes(p) for p in row) for row in rows)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def png_frame(size, rows):
    return png_image(size, size, rows)


def bmp_frame(size, rows):
    """DIB for an icon: BITMAPINFOHEADER (height doubled), bottom-up BGRA pixels, then the 1-bit AND mask (clear)."""
    header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0, size * size * 4, 0, 0, 0, 0)
    pixels = b''.join(bytes((p[2], p[1], p[0], p[3])) for row in reversed(rows) for p in row)
    return header + pixels + bytes(((size + 31) // 32) * 4 * size)


def ico(frames):
    """frames: [(size, bytes)] ascending -> .ico file bytes."""
    out = struct.pack('<HHH', 0, 1, len(frames))
    offset = 6 + 16 * len(frames)
    for size, data in frames:
        out += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    return out + b''.join(data for _, data in frames)
