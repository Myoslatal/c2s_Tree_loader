#!/usr/bin/env python3
"""Event backdrop for the sample pack (stdlib only)."""
import struct, zlib, sys, os, math
def write_png(path, w, h, fn):
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w): rows += bytes(fn(x, y))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))
W = H = 1024
def bg(x, y):
    t = y / H
    r, g, b = int(4 + 18 * (1 - t)), int(22 + 54 * (1 - t)), int(46 + 92 * (1 - t))
    # faint vertical light shafts
    for k in range(4):
        dx = abs(x - W * (0.15 + 0.23 * k) + y * 0.25)
        if dx < W * 0.035:
            f = (1 - dx / (W * 0.035)) * (1 - t) * 0.42
            r = int(r + 70 * f); g = int(g + 100 * f); b = int(b + 115 * f)
    # soft drifting particles
    for (px, py, pr) in ((0.2,0.7,0.010),(0.33,0.52,0.007),(0.72,0.64,0.009),
                         (0.6,0.38,0.005),(0.85,0.78,0.008),(0.45,0.85,0.006)):
        d2 = (x / W - px) ** 2 + (y / H - py) ** 2
        if d2 < pr * pr:
            r = min(255, r + 110); g = min(255, g + 130); b = min(255, b + 145)
    return (min(255, r), min(255, g), min(255, b), 255)
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
write_png(os.path.join(out, "deepsea_bg.png"), W, H, bg)
print("wrote", os.path.join(out, "deepsea_bg.png"))
