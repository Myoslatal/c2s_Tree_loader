#!/usr/bin/env python3
"""Extra icons for the sample pack: two currencies + a tap-hint resource."""
import struct, zlib, os, math, sys

def png(path, size, fn):
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            rows += bytes(fn(x, y))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    hdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", hdr) +
                          chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))

def disc(cr, cg, cb, glyph=None):
    def fn(x, y):
        dx, dy = x - 128, y - 128
        d = math.sqrt(dx * dx + dy * dy)
        if d > 118: return (0, 0, 0, 0)
        edge = 1.0 if d < 108 else (118 - d) / 10.0
        t = (x + y) / 512.0
        r, g, b = int(cr * (0.6 + 0.4 * t)), int(cg * (0.6 + 0.4 * t)), int(cb * (0.6 + 0.4 * t))
        if glyph == "shell" and 40 < d < 100:
            ang = math.atan2(dy, dx)
            if math.sin(ang * 5) > 0.55: r, g, b = 255, 255, 255
        if glyph == "crystal" and d < 70:
            if abs(dx) + abs(dy) < 90: r, g, b = 230, 255, 255
        return (r, g, b, int(255 * edge))
    return fn

out = sys.argv[1] if len(sys.argv) > 1 else "CustomEvents/SamplePack"
os.makedirs(out, exist_ok=True)
S = 256
png(os.path.join(out, "currency1.png"), S, disc(60, 170, 230, "shell"))
png(os.path.join(out, "currency2.png"), S, disc(230, 140, 60, "crystal"))
png(os.path.join(out, "resource.png"), S, disc(90, 210, 190, "crystal"))
print("wrote currency1.png currency2.png resource.png ->", out)
