#!/usr/bin/env python3
"""Banner + button art for the sample pack (stdlib only)."""
import struct, zlib, os, math, sys

def write_png(path, w, h, fn):
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            rows += bytes(fn(x, y))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    hdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", hdr) +
                          chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))

def deep_sea(x, y, w, h):
    # vertical gradient + light shafts + a few bubbles
    t = y / h
    r = int(6 + 26 * (1 - t)); g = int(30 + 70 * (1 - t)); b = int(58 + 110 * (1 - t))
    for k in range(3):                      # light shafts from the surface
        cx = w * (0.25 + 0.25 * k)
        dx = abs(x - cx + (y * 0.35))
        if dx < w * 0.045:
            f = (1 - dx / (w * 0.045)) * (1 - t) * 0.5
            r = int(r + 90 * f); g = int(g + 120 * f); b = int(b + 130 * f)
    for (bx, by, br) in ((0.18, 0.72, 0.012), (0.30, 0.55, 0.008), (0.74, 0.66, 0.010),
                         (0.62, 0.40, 0.006), (0.86, 0.80, 0.009)):
        dx = (x / w - bx); dy = (y / h - by)
        if dx * dx + dy * dy < (br * h / w) ** 2 * 0 + br * br:
            r, g, b = min(255, r + 120), min(255, g + 140), min(255, b + 150)
    return (min(255, r), min(255, g), min(255, b), 255)

def button(x, y, w, h):
    dx, dy = x - w / 2, y - h / 2
    d = math.sqrt(dx * dx + dy * dy)
    R = w * 0.46
    if d > R: return (0, 0, 0, 0)
    edge = 1.0 if d < R - 4 else (R - d) / 4.0
    t = (x + y) / (w + h)
    r, g, b = int(40 + 60 * t), int(150 + 70 * t), int(210 + 40 * t)
    if R * 0.34 < d < R * 0.44: r, g, b = 235, 250, 255          # sonar ring
    if d < R * 0.16: r, g, b = 200, 245, 255                     # sonar centre
    return (r, g, b, int(255 * edge))

out = sys.argv[1] if len(sys.argv) > 1 else "CustomEvents/SamplePack"
write_png(os.path.join(out, "banner.png"), 1024, 384,
          lambda x, y: deep_sea(x, y, 1024, 384))
write_png(os.path.join(out, "button.png"), 256, 256,
          lambda x, y: button(x, y, 256, 256))
print("wrote banner.png (1024x384) button.png (256x256) ->", out)
