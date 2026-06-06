#!/usr/bin/env python3
"""
Affine / warp read-engine feasibility GATE (behavioral model — no HDL, pure stdlib).

Question: can an arbitrary-geometry read engine (rotation / keystone / pincushion / warp)
run REAL-TIME on the Zynq-7020? The line-ring fetch can't do rotated access, so the general
fetch is a TILE CACHE backed by DDR. The gate measures, per transform + tile/cache config:

  - tile MISSES per frame  -> DDR read bandwidth (misses * tile_bytes * fps)
  - max misses in a single output row -> burst / prefetch-FIFO depth needed
  - verdict vs a conservative DDR read budget

The source-coordinate function is pluggable, so the SAME cache sim covers affine (scale/rot),
projective keystone (homography), and radial pincushion — the whole correction family, since
they differ only in the addrgen, not the fetch.

Inverse map: for each OUTPUT pixel we compute the SOURCE coord it reads (what the HW does),
then the bilinear 2x2 neighborhood -> up to 4 tiles -> LRU cache hit/miss.
"""
import math
from collections import OrderedDict

OUT_W, OUT_H = 1280, 720      # output raster
IN_W,  IN_H  = 1920, 1080     # source master in DDR (1080p input, worst case)
FPS          = 60
BYTES_PP     = 3

# DDR on Zybo Z7-20: ~1.3 GB/s usable total, shared with the VDMA source-write
# (~373 MB/s @1080p60) and the FRC genlock read. Leave ~700 MB/s for the tile-cache read.
DDR_TOTAL_MBPS = 1300
DDR_READ_BUDGET_MBPS = 700


def make_coord_fn(kind, scale=1.0, deg=0.0, k=0.0, keyst=0.0):
    """Return f(dx,dy)->(sx,sy): inverse-map output-offset -> source coord."""
    cxs, cys = IN_W / 2.0, IN_H / 2.0
    if kind == "affine":
        th = math.radians(deg); inv = 1.0 / scale
        c, s = math.cos(th), math.sin(th)
        def f(dx, dy):
            return cxs + inv * (c * dx + s * dy), cys + inv * (-s * dx + c * dy)
    elif kind == "keystone":            # projective: top edge squeezed (perspective)
        cyo = OUT_H / 2.0
        def f(dx, dy):
            ny = (dy + cyo) / OUT_H
            w = 1.0 + keyst * (1.0 - ny)
            return cxs + dx * w, cys + dy
    elif kind == "pincushion":          # radial non-linear
        cxo, cyo = OUT_W / 2.0, OUT_H / 2.0
        nrm = cxo * cxo + cyo * cyo
        sxr, syr = IN_W / OUT_W, IN_H / OUT_H
        def f(dx, dy):
            r2 = (dx * dx + dy * dy) / nrm
            g = 1.0 + k * r2
            return cxs + dx * g * sxr, cys + dy * g * syr
    else:
        raise ValueError(kind)
    return f


def simulate(coord_fn, TILE, CACHE_TILES):
    TX = (IN_W + TILE - 1) // TILE
    cxo, cyo = OUT_W / 2.0, OUT_H / 2.0
    cache = OrderedDict(); cap = CACHE_TILES
    mte = cache.move_to_end
    misses = 0; touched = 0; maxrow = 0
    floor = math.floor
    for oy in range(OUT_H):
        dy = oy - cyo
        rowmiss = 0
        for ox in range(OUT_W):
            sx, sy = coord_fn(ox - cxo, dy)
            if sx < 0.0 or sy < 0.0 or sx >= IN_W - 1 or sy >= IN_H - 1:
                continue                                   # out of frame -> matte, no fetch
            x0 = int(sx); y0 = int(sy)
            tx0 = x0 // TILE; ty0 = y0 // TILE
            tx1 = (x0 + 1) // TILE; ty1 = (y0 + 1) // TILE
            base0 = ty0 * TX; base1 = ty1 * TX
            tiles = (base0 + tx0,)
            if tx1 != tx0:
                tiles = (base0 + tx0, base0 + tx1)
            if ty1 != ty0:
                tiles = tiles + ((base1 + tx0,) if tx1 == tx0 else (base1 + tx0, base1 + tx1))
            for t in tiles:
                touched += 1
                if t in cache:
                    mte(t)
                else:
                    misses += 1; rowmiss += 1
                    cache[t] = 1
                    if len(cache) > cap:
                        cache.popitem(last=False)
        if rowmiss > maxrow:
            maxrow = rowmiss
    return misses, touched, maxrow


def run():
    TILE = 32
    tile_bytes = TILE * TILE * BYTES_PP
    cases = [
        ("identity (1:1)",         dict(kind="affine", scale=1.0, deg=0)),
        ("zoom 200%",              dict(kind="affine", scale=2.0, deg=0)),
        ("zoom 50% (shrink)",      dict(kind="affine", scale=0.5, deg=0)),
        ("rotate 30deg",           dict(kind="affine", scale=1.0, deg=30)),
        ("rotate 45deg",           dict(kind="affine", scale=1.0, deg=45)),
        ("rotate 90deg",           dict(kind="affine", scale=1.0, deg=90)),
        ("zoom2x + rotate 30",     dict(kind="affine", scale=2.0, deg=30)),
        ("keystone (perspective)", dict(kind="keystone", keyst=0.25)),
        ("pincushion (radial)",    dict(kind="pincushion", k=0.15)),
    ]
    caches = [64, 128, 256]
    print(f"# Affine/warp tile-cache GATE | out {OUT_W}x{OUT_H} src {IN_W}x{IN_H} "
          f"tile {TILE}x{TILE}({tile_bytes}B) @{FPS}fps")
    print(f"# DDR read budget ~{DDR_READ_BUDGET_MBPS} MB/s (of ~{DDR_TOTAL_MBPS} total) | "
          f"cache: " + ", ".join(f"{n}={n*tile_bytes//1024}KB" for n in caches))
    hdr = f"{'transform':<24}{'cache':>6}{'miss/frm':>11}{'missrt':>8}{'MB/s@60':>9}{'maxrow':>8}  verdict"
    print(hdr); print("-" * len(hdr))
    for name, p in cases:
        f = make_coord_fn(**p)
        for n in caches:
            miss, touched, maxrow = simulate(f, TILE, n)
            mbps = miss * tile_bytes * FPS / 1e6
            mr = (miss / touched * 100) if touched else 0.0
            verdict = "OK" if mbps < DDR_READ_BUDGET_MBPS else "OVER"
            print(f"{name:<24}{n:>6}{miss:>11,}{mr:>7.1f}%{mbps:>9.0f}{maxrow:>8}  {verdict}")
        print()


if __name__ == "__main__":
    run()
