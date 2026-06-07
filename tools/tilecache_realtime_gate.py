#!/usr/bin/env python3
"""
M2 real-time gate (cycle-accurate, pure stdlib) for pg_tilecache.

The bandwidth gate (affine_tilecache_gate.py) proved AVERAGE DDR fits. This proves the TIMING:
with a prefetch walker + real DDR latency/throughput + an output FIFO, does the genlocked output
ever STARVE (underrun) on the worst transforms? Models the full 720p60 output timing including
blanking (the prefetch's slack), an LRU tile cache, a single-channel DDR, and the output FIFO.

Output underrun cycles must be 0 for real-time. Reports the prefetch-lead / FIFO / DDR-rate that
achieves it — those become the HDL params for M3.
"""
import math
from collections import OrderedDict

# 720p60 timing
H_ACT, H_TOT = 1280, 1650
V_ACT, V_TOT = 720, 750
IN_W, IN_H = 1920, 1080


def tiles_per_active(kind, TILE, scale=1.0, deg=0.0, k=0.0):
    """Precompute, per active output pixel, the set of source tiles its bilinear 2x2 touches."""
    TX = (IN_W + TILE - 1)//TILE
    cxo, cyo = H_ACT/2.0, V_ACT/2.0
    cxs, cys = IN_W/2.0, IN_H/2.0
    th = math.radians(deg); c, s = math.cos(th), math.sin(th); inv = 1.0/scale
    nrm = cxo*cxo + cyo*cyo
    out = [None]*(H_ACT*V_ACT)
    for ay in range(V_ACT):
        dy = ay - cyo
        base = ay*H_ACT
        for ax in range(H_ACT):
            dx = ax - cxo
            if kind == "affine":
                sx = cxs + inv*(c*dx + s*dy); sy = cys + inv*(-s*dx + c*dy)
            else:  # pincushion
                g = 1.0 + k*(dx*dx+dy*dy)/nrm
                sx = cxs + dx*g*(IN_W/H_ACT); sy = cys + dy*g*(IN_H/V_ACT)
            if sx < 0 or sy < 0 or sx >= IN_W-1 or sy >= IN_H-1:
                out[base+ax] = ()
                continue
            x0 = int(sx); y0 = int(sy)
            tx0 = x0//TILE; ty0 = y0//TILE; tx1 = (x0+1)//TILE; ty1 = (y0+1)//TILE
            if tx0==tx1 and ty0==ty1:
                out[base+ax] = (ty0*TX+tx0,)
            else:
                out[base+ax] = tuple({ty0*TX+tx0, ty0*TX+tx1, ty1*TX+tx0, ty1*TX+tx1})
    return out


def simulate(need, CACHE, LEAD, FIFO, DDR_LAT, DDR_XFER):
    """Cycle-accurate. Returns (underruns, max_ddr_inflight, fifo_min)."""
    resident = OrderedDict()           # tile -> 1 (LRU)
    pending = {}                       # tile -> completion cycle
    issue_q = []                       # tiles awaiting DDR
    ddr_free = 0
    pf = 0                             # prefetch pixel ptr (active-pixel index)
    prod = 0                           # producer pixel ptr (active-pixel index)
    fifo = 0; underruns = 0; fifo_min = FIFO
    NA = H_ACT*V_ACT
    cyc = 0
    # active-pixel index as a function of timing position
    for vy in range(V_TOT):
        for hx in range(H_TOT):
            active = (vy < V_ACT) and (hx < H_ACT)
            # ---- DDR completions ----
            done = [t for t,c in pending.items() if c <= cyc]
            for t in done:
                del pending[t]
                resident[t] = 1
                if len(resident) > CACHE:
                    resident.popitem(last=False)
            # ---- DDR issue ----
            if ddr_free <= cyc and issue_q:
                t = issue_q.pop(0)
                if t not in resident and t not in pending:
                    pending[t] = cyc + DDR_LAT + DDR_XFER
                    ddr_free = cyc + DDR_XFER
            # ---- prefetch one pixel ahead (1px/cycle DDA) ----
            if pf < NA and pf < prod + LEAD:
                for t in need[pf]:
                    if t not in resident and t not in pending and t not in issue_q:
                        issue_q.append(t)
                pf += 1
            # ---- produce (gather) one pixel if its tiles resident + FIFO room ----
            if prod < NA and fifo < FIFO:
                ts = need[prod]
                if all(t in resident for t in ts):
                    if ts:
                        for t in ts: resident.move_to_end(t)
                    fifo += 1; prod += 1
            # ---- consume on active cycles ----
            if active:
                if fifo > 0:
                    fifo -= 1
                    if fifo < fifo_min: fifo_min = fifo
                else:
                    underruns += 1
            cyc += 1
    return underruns, len(pending), fifo_min


def run():
    print(f"# M2 real-time gate | 720p60 (act {H_ACT}x{V_ACT}, tot {H_TOT}x{V_TOT}) | "
          f"~384KB cache, DDR 16 B/cyc @ pixelclk, lat 40")
    cases = [("pincushion k=0.15", dict(kind="pincushion", k=0.15)),
             ("rotate 90 (orthog)", dict(kind="affine", deg=90.0)),
             ("rotate 30 (moderate)", dict(kind="affine", deg=30.0)),
             ("rotate 45 (worst)", dict(kind="affine", deg=45.0)),
             ("zoom 50% shrink", dict(kind="affine", scale=0.5))]
    # tile-size sweep at constant ~384KB BRAM: ntiles = 131072 / (tile^2)
    # DDR_XFER = tile_bytes / 16 B/cyc (16 = 1 HP port at a faster AXI clock, or 2 ports @ pixelclk)
    # (TILE, ntiles@384KB, DDR B/cyc, lead). 16=1 HP port faster-clk; 32=2 HP ports.
    configs = [(16, 512, 16, 4096), (16, 512, 32, 8192), (8, 2048, 32, 8192)]
    for name, p in cases:
        for TILE, NT, BPC, lead in configs:
            need = tiles_per_active(TILE=TILE, **p)
            xfer = max(1, (TILE*TILE*3)//BPC)
            ur, infl, fmin = simulate(need, CACHE=NT, LEAD=lead, FIFO=2048, DDR_LAT=40, DDR_XFER=xfer)
            tag = f"tile{TILE} x{NT} ddr{BPC}B/cyc lead{lead}"
            verd = "OK (no underrun)" if ur == 0 else f"UNDERRUN x{ur}"
            print(f"  {name:<18} {tag:<34} fifo_min={fmin:<5} {verd}")
        print()


if __name__ == "__main__":
    run()
