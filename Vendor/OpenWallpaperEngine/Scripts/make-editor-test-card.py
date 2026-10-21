# Draws the editor's effect-preview test card: a hue sweep with a light ramp, colour bars, a
# checker strip, circles, a triangle, a grid and fine lines, so colour, blur, distortion and motion
# all show. 512x320, 4x supersampled.
import colorsys, struct, sys, zlib

W, H, S = 512, 320, 4


def hsv(h, s, v):
    return colorsys.hsv_to_rgb(h % 1.0, s, v)


def in_circle(x, y, cx, cy, r):
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def in_triangle(x, y, a, b, c):
    def side(p1, p2, p3):
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])
    d1, d2, d3 = side((x, y), a, b), side((x, y), b, c), side((x, y), c, a)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))


BARS = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1), (0.08, 0.08, 0.08)]


def colour(x, y):
    if y >= H - 48:
        if y < H - 40:
            return (0.1, 0.1, 0.1)
        return BARS[min(int(x / (W / len(BARS))), len(BARS) - 1)]
    if y < 32:
        return (0.95, 0.95, 0.95) if (int(x // 16) + int(y // 16)) % 2 else (0.15, 0.15, 0.15)
    if x > 400 and 52 < y < 252 and int((x + y) / 6) % 2 == 0:
        return (0.98, 0.98, 0.98)
    if in_circle(x, y, 120, 150, 70):
        return hsv(0.08, 0.9, 1.0) if in_circle(x, y, 120, 150, 40) else (0.97, 0.97, 0.97)
    if in_triangle(x, y, (260, 70), (340, 230), (180, 230)):
        return hsv(0.55, 0.85, 0.35)
    if in_circle(x, y, 330, 110, 26):
        return hsv(0.92, 0.8, 1.0)
    if int(x) % 64 == 0 or int(y) % 64 == 0:
        return (0.2, 0.2, 0.2)
    return hsv(x / W, 0.75, 0.55 + 0.4 * (1 - y / H))


rows = []
for y in range(H):
    row = bytearray([0])
    for x in range(W):
        r = g = b = 0.0
        for sy in range(S):
            for sx in range(S):
                c = colour(x + (sx + 0.5) / S, y + (sy + 0.5) / S)
                r, g, b = r + c[0], g + c[1], b + c[2]
        n = S * S
        row += bytes([round(255 * r / n), round(255 * g / n), round(255 * b / n)])
    rows.append(bytes(row))


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
with open(sys.argv[1], "wb") as out:
    out.write(png)
