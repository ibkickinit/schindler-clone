# LOD mipmap for downscale-below-fit — design + plan

**Date:** 2026-06-24 · **Task #28** · **Status:** designed + golden-proven, HDL pending review

## Problem

Operator chose 100% = whole-frame fit = a 1.5× downscale of the 1080p master into the 720p output.
The Scale-X slider below ~1260 (shrink > ~1.6×) **breaks up** on the monitor. We need clean downscale
below fit.

## Root cause (NOT what we first assumed)

Two candidate failure modes; the goldens decide between them:

1. **Set-conflict** (like the rotation clamp) — REFUTED for downscale. `tools/warp_lod_gate.py` runs the
   *deployed* hash `(tx + 33·ty)&127` (NSET=128, 4-way) on centered downscale and finds worst-set-live ≤ 2
   even at 4×. The deployed hash is shrink-friendly; downscale does **not** overflow sets.

2. **Fetch-throughput / miss-burst starvation** — CONFIRMED. `tools/warp_lod_throughput.py` (cycle-accurate,
   built on `tilecache_realtime_gate.py`, real params: tile16 ×512, option-b DataMover ~16 B/cyc, lead 24576):

   | shrink S | slider≈ | L=0 result |
   |---|---|---|
   | 1.50 (fit) | 1280 | OK |
   | 1.60 | 1200 | OK |
   | 1.75 | 1097 | **UNDERRUN** |
   | 2.00 | 960 | **UNDERRUN** |
   | 3.00 | 640 | **UNDERRUN** |

   At shrink S each output pixel steps S source-px, so a single output row crosses ~S× more tile-columns →
   the per-row miss burst exceeds what the DataMover refills in a row time → the genlocked consumer starves
   mid-frame → break-up. The starvation threshold (slider ~1100–1280) matches the bench's "below 1260".
   Deeper prefetch lead can't fix it: the lead's in-flight tiles would exceed the 512-tile cache.

## Fix: LOD mipmap

Keep half-res (L1) and quarter-res (L2) box-averaged copies of the master in DDR. For shrink S, fetch from
the level whose **effective** shrink stays in the proven-clean band, so the cache always sees a near-1:1
(or gentle) fetch. `warp_lod_throughput.py` with LOD → **0 underruns through 4×**:

| shrink S | LOD L | eff = S/2^L | LOD result |
|---|---|---|---|
| 1.75 | 1 | 0.88 | OK |
| 2.00 | 1 | 1.00 | OK |
| 3.00 | 2 | 0.75 | OK |
| 4.00 | 2 | 1.00 | OK |

**LOD selection (firmware, per geometry):** `L = max(0, ceil(log2(S / 1.5)))`, where S = max(invx,invy)/4096
is the shrink factor (4096 = 1:1). Threshold 1.5 = the proven-clean fit point, so L=0 stays for S ≤ 1.5
(sharpest, no mip), L=1 for 1.5 < S ≤ 3.0, L=2 for 3.0 < S ≤ 6.0. Two mip levels cover to 6× (≈17% scale);
beyond that is out of the operating range.

## DDR layout (confirmed: ring base 0x1000_0000, 7 frames, R-B-G, row stride W·3)

- L0 (full): base 0x1000_0000, 1920×1080×3, slot stride 6,226,560 B, 7 slots → ends 0x12999E80.
- L1 (half): 960×540×3 = 1,555,200 B/frame; 7-slot ring placed after L0. (32-bit safe — the scout's
  overflow note was an arithmetic slip; 0x1000_0000 + 7·6,226,560 = 0x12999E80, well inside the 1 GB PS DDR.)
- L2 (quarter): 480×270×3 = 388,800 B/frame; 7-slot ring after L1.
- Each mip ring uses the SAME gray-coded frame_ptr as L0 (written in lock-step), so genlock slot-follow is
  identical — the read engine indexes the mip ring with the same `rd_slot`.

## Read-path changes (well-specified, low risk)

One LOD register (firmware-set via AXI GPIO, latched at sof like the lead). Apply the shift at the **affine/
projective output** so the cache + DMA are LOD-agnostic except for the base/stride select:

1. `pg_warp_engine` / `pg_affine` / `pg_projective`: after the integer source coord (sx_int, sy_int), emit
   `sx_m = sx_int >> L`, `sy_m = sy_int >> L` (and shift the bilinear fraction window correspondingly so the
   sub-pixel weight is taken in mip space). These mip coords drive the cache tiling, set hash, and gather —
   all unchanged.
2. `pg_tile_dma`: select per-L base + row stride:
   `frame_base_L = FRAME_BUF_BASE + lod_off[L]`, `stride_L = (1920 >> L)·3`, and the mip slot stride.
   `fetch_addr = frame_base_L + rd_slot·slotstride_L + (ty·16 + row)·stride_L + tx·16·3`.
   (tx,ty,row already in mip space from step 1.)
3. `pg_warp_top`: new LOD GPIO + CDC, fan it to engine + tile_dma; include in the soft-reset domain.

## Write-path changes (the heavy part — hardware mip generator)

To keep the mips live for moving video, generate them each frame from the source stream:

- A streaming **2×2 box-average** module taps the source AXIS (broadcast before the L0 S2MM): 1 source-line
  buffer (1920×3 ≈ 1.5 RAMB36), average horizontal pairs + vertical pairs → half-res stream → its own S2MM/
  DataMover into the L1 ring. Chain a second box L1→L2.
- BD: `axis_broadcaster` to fork the source; 2 box-average IPs; 2 write DataMovers into the mip rings; share
  the L0 frame_ptr so all three rings advance together.
- Budget: extra write BW ≈ 93 (L1) + 23 (L2) = ~116 MB/s; extra BRAM ≈ 3 RAMB36 (line buffers) — both fit
  (~30 RAMB36 spare; DDR HP headroom per affine_tilecache_gate). Port balancing is the integration care-point.

## Phased build (de-risks the read path before the heavy write path)

- **Phase 1 — read-path LOD + CPU static mip (cheap, bench-testable):** implement the read-path changes
  (coord shift + base/stride select + LOD GPIO) and have the FIRMWARE one-shot box-average the master into
  the L1/L2 DDR rings ONCE (for a STATIC source — the Osee SMPTE bars, known static). Proves coord shift,
  addressing, LOD select, and that downscale-below-fit is clean on a static image — without any new
  DataMover/BD write path. Pure HDL (read side) + firmware mip-fill + GPIO.
- **Phase 2 — hardware streaming mip generator (live video):** the box-average IPs + mip S2MM rings + BD
  broadcast, so the mips track motion. This is the bitstream/BD-heavy phase.
- **Phase 3 — firmware LOD selection + trilinear (optional):** auto-set L from invx/invy at sof; optional
  LOD0↔L1 blend (trilinear) to avoid a visible pop at the L-switch boundary.

## Goldens (committed)

- `tools/warp_lod_gate.py` — set-conflict gate: deployed hash is shrink-friendly (refutes set-conflict).
- `tools/warp_lod_throughput.py` — throughput gate: reproduces the bench starvation threshold and proves LOD
  removes it (0 underruns to 4×). This is the operative proof.

## CORRECTION (2026-06-24, on-silicon) — lead can't fix 50%; the mip is genuinely required

Attempted a lead-only shortcut (the throughput model suggested a shorter lead would fix downscale). SILICON
opix/frame sweep (live 'L' override) REFUTED the model:

| downscale | best lead (silicon) | opix/frame | clean? |
|---|---|---|---|
| 1.5× (fit / 100%) | ≥24576 | 921600 | ✅ full |
| 2.0× (75%) | 32768 | 866622 | ~94% marginal |
| 3.0× (50%) | 16384 | 769743 | ❌ ~83% max — starves at EVERY lead |

So: (a) fit needs the DEEP 24576 lead (a shorter lead starves fit — the model had it backwards), reverted to
24576; (b) 50% (3×) is a hard cache-CAPACITY wall — no lead makes it a full frame. The half-res mip (LOD1
alone, effective 1.5× at 50%) is genuinely required for clean 50%. The model is fine for the qualitative
conclusion (capacity-bound, mip fixes it) but its absolute lead/underrun numbers are NOT trustworthy —
on-silicon opix/frame is the source of truth. NOTE: a SINGLE half-res level covers down to ~3× (50%);
quarter-res only matters below ~25%.
