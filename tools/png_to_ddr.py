#!/usr/bin/env python3
"""PNG -> raw DDR framebuffer bytes for Schindler image-playback.
The TSG writes vid_data = {R[23:16], B[15:8], G[7:0]} and looks correct on HDMI; the S2MM stores
that 24-bit beat little-endian -> DDR pixel bytes (low..high addr) = [G, B, R], 3 bytes/pixel packed,
STRIDE = W*3, no padding within the frame. Usage: png_to_ddr.py <in.png> <out.bin> [--order gbr|rgb|bgr]
"""
import sys, argparse
from PIL import Image
ap = argparse.ArgumentParser()
ap.add_argument("png"); ap.add_argument("out")
ap.add_argument("--order", default="gbr", help="DDR byte order per pixel (default gbr = TSG-matched)")
ap.add_argument("--w", type=int, default=1920); ap.add_argument("--h", type=int, default=1080)
a = ap.parse_args()
im = Image.open(a.png).convert("RGB").resize((a.w, a.h))
px = im.load()
idx = {"r":0,"g":1,"b":2}
perm = [idx[c] for c in a.order.lower()]
buf = bytearray(a.w*a.h*3)
o = 0
for y in range(a.h):
    for x in range(a.w):
        rgb = px[x,y]
        buf[o]=rgb[perm[0]]; buf[o+1]=rgb[perm[1]]; buf[o+2]=rgb[perm[2]]; o+=3
open(a.out,"wb").write(buf)
print(f"wrote {a.out}: {a.w}x{a.h} order={a.order} -> {len(buf)} bytes")
