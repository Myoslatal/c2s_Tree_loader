#!/usr/bin/env python3
"""Generate simple RGBA PNG icons for the sample pack (stdlib only)."""
import struct, zlib, os, math, sys

def png(path, size, fn):
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            r, g, b, a = fn(x, y)
            rows += bytes((r, g, b, a))
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    hdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    out = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", hdr) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)

NODES = [
    ("deepsea_sonar", ( 60, 170, 230), "G"),
    ("deepsea_rov",   ( 40, 120, 210), "G"),
    ("deepsea_vent",  (230, 110,  60), "R"),
    ("deepsea_chem",  ( 60, 190, 140), "G"),
    ("deepsea_tube",  (200,  80, 160), "R"),
    ("deepsea_whale", ( 90, 130, 190), "G"),
    ("deepsea_abyss", (120,  90, 220), "T"),
]
out = sys.argv[1] if len(sys.argv) > 1 else "CustomEvents/SamplePack/icons"
os.makedirs(out, exist_ok=True)
S = 256
for uid, (cr, cg, cb), kind in NODES:
    def fn(x, y, cr=cr, cg=cg, cb=cb, kind=kind):
        dx, dy = x - 128, y - 128
        d = math.sqrt(dx * dx + dy * dy)
        if d > 120:
            return (0, 0, 0, 0)
        edge = 1.0 if d < 112 else (120 - d) / 8.0
        t = (x + y) / (2.0 * S)
        r = int(cr * (0.55 + 0.45 * t)); g = int(cg * (0.55 + 0.45 * t)); b = int(cb * (0.55 + 0.45 * t))
        # inner ring marks research/trophy variants
        if 84 < d < 92:
            if kind == "R": r, g, b = 255, 235, 150
            elif kind == "T": r, g, b = 255, 255, 255
            else: r, g, b = int(r * 0.6), int(g * 0.6), int(b * 0.6)
        return (r, g, b, int(255 * edge))
    png(os.path.join(out, uid + ".png"), S, fn)
print("generated", len(NODES), "icons ->", out)
