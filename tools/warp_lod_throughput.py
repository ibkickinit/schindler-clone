#!/usr/bin/env python3
"""!! MODEL UNRELIABLE FOR LEAD TUNING (2026-06-24). Silicon opix/frame sweep (live 'L' override) REFUTED
this model's lead predictions: it claimed a SHORTER lead (8192) fixes downscale, but on hardware 8192
STARVES even fit 1.5x (344k/921600) while 24576 is full at fit; and 3x (50%) starves at EVERY lead
(~83% max) = a real cache-CAPACITY wall this LRU model doesn't capture. KEEP using this only for the
qualitative point (downscale is capacity/throughput-bound, not set-conflict, and a half-res mip fixes it);
do NOT trust its absolute lead/underrun numbers. The truth source is on-silicon opix/frame, not this gate.

LOD throughput gate. The set-conflict gate (warp_lod_gate.py) showed the deployed (1,33)&127 hash
does NOT thrash on centered downscale -> the bench "breaks up below Scale X 1260" is a FETCH-THROUGHPUT
(miss-burst starvation) limit, not a cache-conflict. This reuses the cycle-accurate realtime gate to:
  (1) reproduce starvation at downscale S with the REAL hardware params, and
  (2) show that fetching from a half-res/quarter-res mip (LOD) removes it.

LOD model: at level L the source buffer is IN_W/2^L x IN_H/2^L; the output->source map has effective
shrink S/2^L, so each output pixel steps fewer mip-px -> fewer tiles/row -> lower miss burst, and the
whole mip is 1/4^L the tiles. We pick the smallest L with S/2^L <= 1.0 (fetch at >=1:1 from the mip).
"""
import math
from tilecache_realtime_gate import simulate, H_ACT, V_ACT

IN_W, IN_H = 1920, 1080

# Real-hardware params (scout-confirmed): TILE=16, NTILE=512, option-b DataMover 64-bit @143MHz.
# DDR bytes/pixelclk: 143.0/74.25 * 8 ~= 15.4 -> 16 B/cyc. Deployed prefetch lead = 24576 output px.
TILE, NTILE, BPC, LEAD = 16, 512, 16, 24576
DDR_LAT = 40
XFER = max(1, (TILE * TILE * 3) // BPC)        # cycles to move one tile over the DataMover


def need_downscale(S, L, deg=0.0):
    """Per-active-output-pixel tile set when downscaling by S, fetching from mip level L.
       Mip dims = IN_W>>L, IN_H>>L; effective shrink at the mip = S/2^L."""
    f = float(1 << L)
    mw, mh = IN_W / f, IN_H / f
    TX = int((mw + TILE - 1) // TILE)
    cxo, cyo = H_ACT / 2.0, V_ACT / 2.0
    cxs, cys = mw / 2.0, mh / 2.0
    th = math.radians(deg); c, s = math.cos(th), math.sin(th)
    out = [None] * (H_ACT * V_ACT)
    for ay in range(V_ACT):
        dy = ay - cyo; base = ay * H_ACT
        for ax in range(H_ACT):
            dx = ax - cxo
            sx = cxs + (c * dx + s * dy) * S / f
            sy = cys + (-s * dx + c * dy) * S / f
            if sx < 0 or sy < 0 or sx >= mw - 1 or sy >= mh - 1:
                out[base + ax] = (); continue
            x0 = int(sx); y0 = int(sy)
            tx0 = x0 // TILE; ty0 = y0 // TILE; tx1 = (x0 + 1) // TILE; ty1 = (y0 + 1) // TILE
            if tx0 == tx1 and ty0 == ty1:
                out[base + ax] = (ty0 * TX + tx0,)
            else:
                out[base + ax] = tuple({ty0 * TX + tx0, ty0 * TX + tx1, ty1 * TX + tx0, ty1 * TX + tx1})
    return out


def lod_for(S):
    L = 0
    while S / (1 << L) > 1.0:
        L += 1
    return L


if __name__ == "__main__":
    print(f"# LOD throughput gate | tile{TILE} x{NTILE} ddr{BPC}B/cyc lead{LEAD} (option-b) | "
          f"underruns must be 0\n")
    # Scale-slider mapping: 100% (whole-frame fit) = 1.5x shrink. Slider below 100% = MORE shrink.
    # Test the band the operator hits: 1.5x (fit) down through 4x.
    print(f"  {'shrink S':>9}{'(slider~)':>10}   {'L=0 underrun':>14}   {'LOD L':>6}{'eff':>6}{'LOD underrun':>14}")
    for S in (1.5, 1.6, 1.75, 2.0, 2.5, 3.0, 4.0):
        slider = int(round(1280 * 1.5 / S))    # approx Scale-X slider value for this shrink
        need0 = need_downscale(S, 0)
        ur0, _, _ = simulate(need0, CACHE=NTILE, LEAD=LEAD, FIFO=2048, DDR_LAT=DDR_LAT, DDR_XFER=XFER)
        L = lod_for(S); eff = S / (1 << L)
        needL = need_downscale(S, L)
        urL, _, fminL = simulate(needL, CACHE=NTILE, LEAD=LEAD, FIFO=2048, DDR_LAT=DDR_LAT, DDR_XFER=XFER)
        v0 = "OK" if ur0 == 0 else f"UNDERRUN x{ur0}"
        vL = "OK" if urL == 0 else f"UNDERRUN x{urL}"
        print(f"  {S:>9.2f}{slider:>10}   {v0:>14}   {L:>6}{eff:>6.2f}{vL:>14}")
