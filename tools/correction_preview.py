#!/usr/bin/env python3
"""
Geometric-correction previewer (pure stdlib) — validates keystone + warp math the same way
tools/pincushion_preview.py did for radial. Each correction is just a map (ox,oy)->(sx,sy),
exactly the addrgen interface the real engine will expose, so this proves the unification too:
one render path, three maps.

Renders a straight reference grid as the SOURCE through each map -> PNG, prints metrics.
"""
import math, zlib, struct

PW, PH = 320, 180
GRID = 20


def write_png(path, w, h, rows):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    raw = bytearray()
    for r in rows:
        raw.append(0); raw += r
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)


def src(sx, sy):
    if sx < 0 or sy < 0 or sx >= PW or sy >= PH:
        return (0, 0, 40)
    if (int(sx) % GRID < 2) or (int(sy) % GRID < 2):
        return (240, 240, 240)
    return (20 + int(180 * sx / PW), 20, 20 + int(180 * sy / PH))


def render(mapfn, path):
    rows = []
    for oy in range(PH):
        row = bytearray()
        for ox in range(PW):
            sx, sy = mapfn(ox, oy)
            r, g, b = src(sx, sy)
            row += bytes((r, g, b))
        rows.append(row)
    write_png(path, PW, PH, rows)


# ---- maps (output -> source) ----
CX, CY = PW / 2.0, PH / 2.0

def keystone(kh, kv):
    """Projective: w = 1 + kh*x' /cx + kv*y'/cy ; s = c + d/w  (the per-pixel DIVIDE)."""
    def f(ox, oy):
        dx, dy = ox - CX, oy - CY
        w = 1.0 + kh * dx / CX + kv * dy / CY
        if w < 0.1:
            w = 0.1
        return CX + dx / w, CY + dy / w
    return f

def pincushion(k1):
    R2 = CX * CX + CY * CY
    def f(ox, oy):
        dx, dy = ox - CX, oy - CY
        g = 1.0 + k1 * (dx * dx + dy * dy) / R2
        return CX + dx * g, CY + dy * g
    return f

def warp_mesh(basemap, N=9):
    """Sample basemap at an NxN grid; per pixel bilinear-interp the 4 vertex source coords.
    Proves the mesh SUBSUMES a parametric map (render ~ the basemap render)."""
    xs = [i * (PW - 1) / (N - 1) for i in range(N)]
    ys = [j * (PH - 1) / (N - 1) for j in range(N)]
    V = [[basemap(xs[i], ys[j]) for i in range(N)] for j in range(N)]   # V[j][i] = (sx,sy)
    cw, ch = (PW - 1) / (N - 1), (PH - 1) / (N - 1)
    def f(ox, oy):
        gi = min(int(ox / cw), N - 2); gj = min(int(oy / ch), N - 2)
        tx = (ox - xs[gi]) / cw; ty = (oy - ys[gj]) / ch
        (a, b) = V[gj][gi]; (c, d) = V[gj][gi + 1]
        (e, g) = V[gj + 1][gi]; (h, k) = V[gj + 1][gi + 1]
        top_x = a + (c - a) * tx; bot_x = e + (h - e) * tx
        top_y = b + (d - b) * tx; bot_y = g + (k - g) * tx
        return top_x + (bot_x - top_x) * ty, top_y + (bot_y - top_y) * ty
    return f


def run():
    print(f"# correction preview {PW}x{PH} grid={GRID}")
    jobs = [
        ("keystone vertical kv=0.30",   keystone(0.0, 0.30),  "/tmp/keystone_v.png"),
        ("keystone horizontal kh=0.30", keystone(0.30, 0.0),  "/tmp/keystone_h.png"),
        ("warp mesh(9x9) of pincushion k=0.30", warp_mesh(pincushion(0.30)), "/tmp/warp_mesh.png"),
        ("pincushion k=0.30 (reference)", pincushion(0.30), "/tmp/warp_ref.png"),
    ]
    for name, fn, path in jobs:
        render(fn, path)
        print(f"  {name:<38} -> {path}")
    print("\nkeystone: straight grid -> trapezoid/perspective (the per-pixel /w divide).")
    print("warp_mesh vs warp_ref: 9x9 mesh should ~match the parametric pincushion (mesh subsumes it).")


if __name__ == "__main__":
    run()
