# Warp engine — real-geometry findings (the TB green does NOT mean real-time at 1080p)

**Date:** 2026-06-07. **Re:** confirming the real-time LEAD at the production geometry before sizing
cache ways (the "confirm the real lead first" decision).

**TL;DR:** I built a full real-geometry gate (`sim/pg_warp_real_tb.v`, 1280×720 ← 1920×1080, 720p60
raster) and ran shrink 1.5× (the fill/lead driver). **It is NOT real-time** as architected — and the
reason is not the fill rate. The TB (`pg_warp_dma_tb`, 1/5 scale) passes 4/4 because its small frame
fits the cache entirely and gets a disproportionate V-blank warmup head-start; **neither holds at full
scale.** Two real bottlenecks the TB masked: **(1) no LRU eviction**, and **(2) prefetch feed depth.**

## The measurements (real geometry, shrink 1.5×, collected of 921600)

| cache | PD / DREQ | LEAD | collected | note |
|---|---|---|---|---|
| 4-way / 512   | 16 / 16  | 8k–49k | **5%** | LEAD has no effect; capacity-bound |
| 16-way / 2048 | 16 / 16  | 16k–131k | **25%** | LEAD still no effect; PD-bound |
| 16-way / 2048 | 64 / 64  | 65k | 23% | deeper PD *worse* — still evicting |
| 16-way / **16384** (no eviction) | 16 / 16 | 65k–262k | **62%** | eviction removed → big jump |
| 16-way / 16384 | 64 / 64  | 131k | **85%** | now PD/lead start working |
| 16-way / 16384 | **128 / 128** | **262k** | **94%** | trending to real-time, impractical cost |

Fill-path health at the stalling point (16-way/2048, PD16, LEAD65k): **clk/tile = 96 (= the target 2.67
px/clk — the gap-free fill is at its design rate), but beat_duty = 0.20, work_frac = 0.34** (the DMA has
a pending fetch only 34% of the time). So the DMA is *starved*, not slow.

## Why — two coupled bottlenecks the small TB hid

1. **No LRU eviction.** My victim is free-way-first with a round-robin fallback only when a set is
   *full*. That never *proactively* recycles dead tiles — they sit valid until the set fills, then RR
   evicts arbitrarily (sometimes a still-live tile). The TB never hit this (its frame fits the cache, so
   eviction never happens). At 1080p, shrink touches ~8100 tiles while its *live* working set is only a
   few hundred; with LRU + worst-set-live ≤ ways, a modest cache would hold the live set indefinitely
   and never evict a live tile. Without it, the cache fills with dead tiles and thrashes — which is why
   "no eviction" (NTILE=16384) jumped shrink 25%→62%, and why more ways = more rows-before-stall.

2. **Prefetch feed depth.** Even with eviction removed, PD=16 caps shrink at 62%; PD=128 + a very deep
   lead reaches 94%. The fill is serial (tile_dma fills one tile at ~96 clk), so covering shrink's
   ~120-tile tile-row-crossing burst needs many fills queued and a deep lead to pre-fill it. The TB's
   24-tile burst hid this (16 sufficed). The *rate* is adequate (2.67 px/clk × frame ≈ 3.3M px ≫ the
   2.07M px shrink reads/frame, 1.6× headroom) — the problem is keeping the DMA continuously fed, which
   the current lead-gated race-then-idle prefetch does not.

## What this means

- **The reviewer's bet (2.67 px/clk + non-thrashing cache + deep lead) holds on *rate* but the
  "non-thrashing cache" needs real LRU, not RR**, once eviction is mandatory (it never is in the TB).
  And the prefetch needs more pacing/depth than the TB implied.
- **Dual-clock fill is probably still NOT the answer** — the rate has 1.6× headroom; the loss is feed +
  eviction, not bandwidth. Halving fill time would ease the burst-lead pressure but doesn't fix the
  underlying feed/eviction inefficiency.

## Recommended next architecture step (for discussion before building)

1. **Per-set tree-PLRU** victim (4/8-way). With worst-set-live ≤ ways, PLRU never evicts a live tile →
   a modest cache (NTILE 512–1024) holds shrink's live working set with no thrash. This is the big one.
2. **Re-measure the real-time lead/PD with PLRU** — expect the impractical PD=128 / 200-row-lead to drop
   sharply once the cache stops thrashing, because the prefetch no longer wastes fills re-fetching
   evicted tiles. Only then size ways (8-way for rot20's lead-aware 5–7, per
   `tools/warp_lead_assoc.py`).
3. If PLRU + reasonable PD still can't feed the DMA continuously, revisit prefetch pacing (issue rate
   matched to fill capacity) before reaching for dual-clock fill.

## Status of the assigned fill rework

The fill rework itself is **done and correct** — `pg_warp_dma_tb` passes all four transforms
(underruns=0, bit-err=0), the gap-free fill hits 96 clk/tile, multi-outstanding works. What this
real-geometry gate adds is: **the TB is necessary but not sufficient** — it cannot exercise eviction or
the full-scale burst, and both bite at 1080p. The cache (`pg_tilecache_rt2`) now takes a `WAY` parameter
(4 default, plumbed through `pg_warp_engine`) so the PLRU + 8-way work has a clean home, and
`pg_warp_real_tb.v` is the gate to drive it.
