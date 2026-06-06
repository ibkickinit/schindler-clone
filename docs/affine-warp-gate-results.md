# Affine / Warp read-engine feasibility gate — results

**Date:** 2026-06-06 · **Model:** `tools/affine_tilecache_gate.py` (behavioral, no HDL) ·
**Verdict: ✅ FEASIBLE on Zynq-7020 with a 128-tile (384 KB) tile cache.**

## Question

A general geometry/warp read engine (arbitrary rotation, keystone, pincushion, mesh warp) needs
*arbitrary* source access. The current line-ring fetch can't do rotated access (an output row maps
to a diagonal/column across the source). The general fetch is a **tile cache** backed by DDR: tile
the source frame, keep an LRU BRAM cache, miss → DMA the tile. The gate measures whether the
resulting DDR read bandwidth is real-time-sustainable.

The fetch is identical for affine / projective / radial — they differ only in the addrgen — so this
one gate de-risks the **whole geometric-correction family** (rotation, keystone, pincushion, warp).

## Setup

- Output 1280×720, source 1920×1080 in DDR, 32×32 tiles (3 KB), 60 fps, bilinear (2×2 → up to 4 tiles).
- Inverse-mapped (output→source) per pixel; LRU cache **cold each frame** (realistic for FRC).
- DDR read budget ~700 MB/s (of ~1.3 GB/s usable, after VDMA source-write + FRC genlock read).

## Results (128-tile cache = 384 KB)

| transform | miss/frame | MB/s@60 | maxrow | verdict |
|---|---|---|---|---|
| identity 1:1 | 984 | 181 | 41 | ✅ |
| zoom 200% | 252 | 46 | 21 | ✅ |
| zoom 50% shrink | 2,040 | 376 | 60 | ✅ |
| rotate 30° | 952 | 175 | 48 | ✅ |
| rotate 45° | 925 | 170 | 70 | ✅ |
| rotate 90° | 816 | 150 | 34 | ✅ |
| zoom2× + rot 30° | 269 | 50 | 29 | ✅ |
| keystone (projective) | 1,108 | 204 | 50 | ✅ |
| pincushion (radial) | 2,040 | 376 | 60 | ✅ |

## Findings

1. **Rotation (incl. 90°) is cheap** — 150–175 MB/s. Tiles make the transpose the line-ring can't do
   nearly free. The whole rotation family is feasible.
2. **128 tiles is the knee.** 64 tiles thrashes on pincushion (1890 MB/s, OVER) and strains
   rotate-45/keystone; 128 fixes all; 256 = no gain (128 holds the working set). Design target =
   **384 KB tile cache** (fits the 7020 BRAM budget, shared with VDMA/scaler — verify at integration).
3. **Burst is the real-time care-point, not average.** Worst per-row miss burst ~60–115 tiles
   (pincushion); average (376 MB/s) is well under 700, so a **prefetch engine ~1–2 rows ahead + a
   ~128-tile FIFO** absorbs bursts. This is the key HDL-phase design point.

## Decision

The "one affine+warp engine does all geometry" is **real-time-feasible on existing hardware**
(rotation, keystone, pincushion). **HDL deferred** (owner's call) — this gate just proves the path
before committing. When built: `pg_affine` addrgen (2×3 / 3×3 / radial map) + `pg_tilecache` fetch
(replaces `pg_linefetch`); reuse the existing bilinear/Mackin/compose tail. Roadmap priority for the
corrections: **pincushion → warp → keystone** (per owner).
