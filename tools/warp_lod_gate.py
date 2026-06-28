# LOD-mip gate: prove that fetching downscale-below-100% from a pre-shrunk mip level keeps the
# 4-way set-associative tile cache out of thrash (worst-set-live <= ways), the way the rotation
# clamp proof did for angle. Builds on warp_workingset.max_overlap_per_set.
#
# Failure mode (bench 2026-06-24): at downscale S the cache thrashes once S exceeds ~1.4-1.5x, NOT
# because of bandwidth (affine_tilecache_gate showed 50% shrink = 376 MB/s, fine) but because the
# strided downscale access overflows specific sets > ways (a set-CONFLICT, same class as rotation).
#
# Fix: keep mip levels L=0(full),1(half),2(quarter),... in DDR. For downscale S, fetch from level
# L so the EFFECTIVE downscale seen by the cache, S/2^L, stays in the clean band. This gate (a) finds
# the clean band (max effective downscale with worst-set-live <= ways), (b) shows the LOD selection
# keeps every S in that band.
import sys; sys.path.insert(0, 'tools')
import math
from tilecache_realtime_gate import H_ACT, V_ACT, IN_W, IN_H
from warp_workingset import max_overlap_per_set

TILE = 16          # source tile edge in px (confirm vs pg_tilecache_rt2)
WAYS = 4           # set associativity (confirm)
# Deployed set-index hash. main.c comment + rotation-clamp memory: setf=(tx*1 + ty*33) & 127 (128 sets).
NSET = 128
def setf_133(t):
    tx, ty = t
    return (tx * 1 + ty * 33) & (NSET - 1)

def need_tiles_lod(TILE, S, L, deg=0.0):
    """Tile-set sequence (consumer-pixel order) when downscaling by S while fetching from mip level L
       (a copy of the source pre-shrunk by 2^L). Effective downscale at the mip = S / 2^L; mip dims =
       IN_W>>L, IN_H>>L. L=0 reduces to the plain full-res fetch."""
    f = float(1 << L)
    mw, mh = IN_W / f, IN_H / f                 # mip dimensions
    cxo, cyo = H_ACT / 2., V_ACT / 2.           # output center
    cxs, cys = mw / 2., mh / 2.                 # source center IN MIP COORDS
    th = math.radians(deg); c, s = math.cos(th), math.sin(th)
    seq = []
    for ay in range(V_ACT):
        dy = ay - cyo
        for ax in range(H_ACT):
            dx = ax - cxo
            rx = c * dx + s * dy; ry = -s * dx + c * dy
            sx = cxs + (rx * S) / f             # full-res source = center + rx*S; /f -> mip coords
            sy = cys + (ry * S) / f
            if sx < 0 or sy < 0 or sx >= mw - 1 or sy >= mh - 1:
                seq.append(()); continue
            x0 = int(sx); y0 = int(sy); ts = set()
            for xx, yy in ((x0, y0), (x0 + 1, y0), (x0, y0 + 1), (x0 + 1, y0 + 1)):
                ts.add((xx // TILE, yy // TILE))
            seq.append(tuple(ts))
    return seq

def worst(S, L, deg=0.0):
    seq = need_tiles_lod(TILE, S, L, deg)
    w, active, top = max_overlap_per_set(seq, setf_133, NSET)
    return w, active

def lod_for(S, clean_max):
    """Smallest L such that effective downscale S/2^L <= clean_max."""
    L = 0
    while S / (1 << L) > clean_max:
        L += 1
    return L

if __name__ == "__main__":
    print(f"cache model: TILE={TILE}  hash=(tx + 33*ty)&{NSET-1}  NSET={NSET}  WAYS={WAYS}\n")

    print("(1) No LOD (L=0) — reproduce the downscale thrash. worst-set-live > WAYS = thrash:")
    print(f"    {'downscale S':>12}{'worst-live':>11}{'verdict':>10}")
    clean_max = 0.0
    for S in (1.0, 1.1, 1.25, 1.4, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0):
        w, _ = worst(S, 0)
        ok = w <= WAYS
        if ok and S > clean_max:
            clean_max = S
        print(f"    {S:>12.2f}{w:>11}{'  OK' if ok else '  THRASH':>10}")
    print(f"\n    -> clean band (L=0): downscale <= {clean_max:.2f} keeps worst-live <= {WAYS}")

    print(f"\n(2) With LOD selection (pick L so effective downscale <= {clean_max:.2f}):")
    print(f"    {'downscale S':>12}{'L':>4}{'eff S/2^L':>11}{'worst-live':>11}{'verdict':>10}")
    allok = True
    for S in (1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 6.0, 8.0):
        L = lod_for(S, clean_max if clean_max >= 1.0 else 1.4)
        eff = S / (1 << L)
        w, _ = worst(S, L)
        ok = w <= WAYS
        allok = allok and ok
        print(f"    {S:>12.2f}{L:>4}{eff:>11.2f}{w:>11}{'  OK' if ok else '  THRASH':>10}")
    print(f"\n    -> LOD selection holds worst-live <= {WAYS} for all tested downscales: {allok}")
    print(f"    -> mip levels needed up to 8x downscale: L=0,1,2,3 (full/half/quarter/eighth)")
