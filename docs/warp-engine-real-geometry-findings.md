# Warp engine — real-geometry findings (the TB green does NOT mean real-time at 1080p)

> **RESOLVED 2026-06-07 — the warp engine is now real-time at 1080p.** Three enhancements (below)
> close the gap; `pg_warp_real_tb` (8-way/NTILE=1024, PD=DREQ=64, LEAD=32768) clears rot20/shrink/aniso
> with underruns=0 over the full 1280×720 frame; rot45 has a single cold-start underrun (cn=3, benign).
> No dual-clock fill. **The resolution is in §"Resolution" at the bottom; the analysis below is the
> investigation that found the bottlenecks.**

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

## Resolution (2026-06-07) — three enhancements make it real-time at 1080p

Each was found by the measurements above, applied in order, and re-swept on `pg_warp_real_tb`:

1. **FIFO-by-fetch eviction** (`pg_tilecache_rt2`, replaces RR fallback). Per-slot fetch-sequence
   stamp; the victim is the **oldest-fetched non-reserved** way (free-way-first, then FIFO). Because the
   prefetch fetches in the consumer's future-access order, the oldest-fetched resident tile is the one
   the consumer already passed = dead. A modest cache now recycles dead tiles continuously instead of
   filling up and thrashing. **Real-geometry shrink at 4-way/512: 5% → 62%.** No per-access update
   (FIFO ≈ LRU for the streaming prefetch order), so it's cheap.

2. **Wide gearbox** (`pg_tile_dma`). The receiver drained ≤3 px/clk with `beat_ready=nbits<=64`; since
   64b/beat isn't a multiple of 24b/px, the accumulator settled at a low equilibrium where `navail` was
   usually 2, throttling the beat rate to ~1.6 px/clk (`duty_when_work=0.60`) — just under shrink's
   ~1.67 px/clk need (hence the 94% ceiling). Fix: 4 px/clk drain + permissive `beat_ready=nbits<=96`
   (200-bit acc) so `navail` stays 3–4 and the receiver sustains the full 2.67 px/clk. **This is what
   took shrink from 94% to 100%** and dropped the PD need from 128 to 64.

3. **Deeper feed** — `PD` is now a parameter (default 16, **64 for the real geometry**) with matching
   `DREQ`. Keeps the DataMover continuously fed across the bursty miss pattern (the ~120-tile tile-row
   crossing). `work_frac` 0.34 → 1.00.

### Validated production config (real geometry)

| param | value | why |
|---|---|---|
| WAY | **8** | lead-aware worst-set-live ≤8 at LEAD=32768 (rot20=7, aniso=6); 4-way thrashes |
| NTILE | **1024** | 8-way × 128 sets (keep 128 sets — the hash needs them; ~96 RAMB36) |
| PD / DREQ | **64** | covers the ~120-tile crossing burst feed (PD=16 caps at 62%, 32 at ~80%) |
| LEAD | **32768** | shrink real-time needs it; 8-way still holds (max worst-set-live=7). 65536 pushes aniso to 9 → would need 16-way |
| victim | FIFO-by-fetch | non-thrashing eviction |
| gearbox | 4 px/clk / nbits≤96 | sustains 2.67 px/clk |

**LEAD is the binding cross-constraint:** shrink wants it deep, aniso's lead-aware count grows with it.
LEAD=32768 is the sweet spot where shrink is real-time AND all four stay ≤8-way. (rot45's lone cn=3
cold-start underrun is a warmup transient — the cache persists across frames in the genlocked system, so
it occurs at most once at power-on, on the top-left pixel.)

### Cost vs the small-TB config
- Cache BRAM ~2× (NTILE 512→1024). Pending/request FIFOs PD/DREQ 16→64 (logic, not BRAM). Wider gearbox
  acc (136→200b) + FIFO seq array (NTILE×16b) — modest.
- **No dual-clock fill** (the reviewer's hoped-for outcome): the 2.67 px/clk rate is sufficient once the
  gearbox actually sustains it and eviction stops wasting fills.

### Still open
- rot45 cold-start pixel (benign; could be cleaned with cross-frame prefetch warmup in firmware).
- The PD=128 regression (collapses vs PD=64) is unexplained — irrelevant since 64 is the operating
  point, but worth understanding before pushing PD higher.
- FIFO ≈ LRU holds for streaming/rotation here; a pathological revisit pattern could want true LRU. Not
  observed in the four transforms.

### Cold-start is power-on-once (not per-coeff-change) — confirmed by HDL inspection
The cache (`pg_tilecache_rt2`) has **no `sof`, no flush, no invalidate-all**: `vld` is cleared only
per-slot on evict and set per-slot on fill. `sof` resets only the prefetch's `lead_cnt` (benign — with a
warm cache the prefetch re-establishes its lead through hits, no refetch). Coeffs latch frame-atomically
inside `pg_affine`; on a live geometry change the FIFO age (global `fseq`) recycles the old-geometry
tiles as the new working set arrives — a smooth working-set shift, **not** a cold-start. So the rot45
cn=3 transient occurs at most once at power-on/reset, on the top-left pixel — it does NOT recur per frame
or per zoom/rotate/pan adjustment. (A very large single geometry jump could cost a one-frame transient as
the whole working set turns over, but not a persistent twinkle during incremental tuning. A mid-stream
coeff-change sim would be the definitive confirmation — good follow-up.)

### Timing: pending-availability cone collapsed from PD-deep to associativity-deep
The multi-outstanding pending check was refactored from a PD(64)×4 = 256-comparator FIFO scan to a
single `(vld||rsv)&&tag` lookup over a set's WAY ways (write the tag at ISSUE with rsv=1, so resident
and in-flight are the same lookup): **WAY(8)×4 = 32 comparators**, bounded by associativity not lead
depth, and it scales if PD grows. Removes the cone rather than pipelining it. Both gates re-verified
identical. The consumer gather tag lookup (the original in-context WNS −3.5 path) is now 8-way; the build
will say whether it needs the reserved tag-lookup pipeline stage.

## Fit (2026-06-07) — 8-way/1024 does NOT fit the 7020; per-geometry LEAD does

The in-context build at the real-time config (8-way / NTILE=1024) **synthesized but failed impl DRC on
resource over-utilization, not timing**: `pg_re_0` (the warp engine) alone = **192 RAMB36 > 140
available**; total LUT 72580 / 53200. The cache is 4 banks × NTILE·64 × 24b; at NTILE=1024 that is
192 RAMB36 by itself. **The production target (TE0720) is also a Zynq-7020** (−2 silicon, same 140 BRAM)
— so 8-way/1024 fits neither the dev board nor the product. Removing the debug ILAs (~32 BRAM) is not
enough.

**Root of the 8-way requirement, and the fix.** 8-way came from the lead-aware worst-set-live at a
*single global* LEAD=32768 (rot20=7, aniso=6). But rot20 and aniso don't *need* a deep lead — only
downscale (shrink) does. A deep global lead over-inflates the easy transforms' per-set occupancy. With a
**per-geometry LEAD** — the firmware sets a shallow lead for rotation and a deep one for downscale —
every transform is real-time at a lead where worst-set-live ≤ 4 (validated on `pg_warp_real_tb`,
generous cache so capacity isn't the variable):

| transform | minimal real-time LEAD | worst-set-live @ that lead |
|---|---|---|
| rot20 | 1280 | 4 |
| rot45 | ~4096 | 2 |
| shrink 1.5× | 24576 | 3 |
| aniso (rot30+1.5×H) | ~10240–12288 | 4 |

Max worst-set-live across the per-geometry leads = **4 → 4-way / NTILE=512 (~96 RAMB36) fits the 7020.**
The cache only ever sees one transform's pattern at a time (at that transform's lead), so the global
lead-aware table that demanded 8-way no longer applies.

**LEAD must become a runtime register** (firmware-written per geometry, deep ∝ downscale factor) instead
of a build parameter — a small follow-up (the engine already takes LEAD as a param; expose it as a
GPIO-driven port). Cache persistence + frame-atomic coeff latching mean changing LEAD with the geometry
is a smooth working-set shift (same as the cold-start analysis above). Until then, a single fixed LEAD
will thrash whichever transform's lead it doesn't match at 4-way.

**Build status:** BD config set to 4-way/NTILE=512/PD=64/DREQ=64 (LEAD placeholder); rebuilding to confirm
the device holds the warp engine (BRAM ✓ expected ~96, LUT TBD) and timing closes. Per-geometry LEAD is
the remaining real-time mechanism (firmware).

### Cost ledger (4-way/512, the fitting config)
- Cache ~96 RAMB36 (4 banks × 512·64 × 24b). Fits 140 with room for VDMA/scaler/output once debug ILAs
  are dropped.
- LUT: 8-way build was 72580 (36% over). 4-way halves the lookup/vict/availability/seq logic; PD=64
  FIFOs + wide gearbox unchanged. Rebuild will say if it now fits 53200.
- No dual-clock fill. Single DataMover. Set-index unchanged.

### Fit round 2 (4-way/512): BRAM clears, now SLICES (LUT/FF) over by ~24%
4-way/NTILE=512 cleared the BRAM wall (cache ~96 RAMB36, no BRAM DRC error). Impl now fails at **place**
on slices: **13456 required / 10893 available (~24% over)** — LUT/FF, still not timing. Per-IP LUTs
(synth OOC):
- `pg_re_0` (warp engine) = **29723 LUTs** — dominant. PD=64/DREQ=64 FIFOs, the 200-bit wide gearbox
  (variable barrel shifters), the 512×16b `seq` array + 4-way age-argmax, the `(vld||rsv)&&tag`
  availability (4×4×24b), 2× affine DDAs, bilinear, `setf` multiplies.
- 3 system ILAs = ~10549 LUTs (`ila_s2mm_axi` 5218 + `ila_scaler_out` 2799 + `ila_mm2s_out` 2532),
  plus `ila_pixclk`/`ila_refclk` — **all debug-only.**
- VDMA 2982, scaler mem 2297, v_tc_rx/tx 1522/1327, etc.

**Closing the ~2563-slice gap (well-scoped, next session — verify each with a rebuild):**
1. **Drop the debug ILAs** (gate the `system_ila` cells + their probe nets behind an `ILA_EN` flag in
   `build_phase_b.tcl`, default off for warp builds): ~10549+ LUT ≈ ~1300–1500 slices. Closes roughly
   half. Low risk but touches the BD (must remove probe connections cleanly).
2. **PD/DREQ 64→32** if shrink real-time tolerates (re-check on `pg_warp_real_tb`): halves the pf_slot
   (64×9b) + tile_dma rq (64×24b) FIFOs.
3. **Trim `seq` width** 16→~10 bits (age only needs to order the live working set) and/or move it to
   LUTRAM/BRAM: saves ~512×6 FFs off the slice count.
4. If still short, narrow the gearbox barrel shifters (the 200-bit acc / variable 96-bit shifts are
   LUT-heavy) — but the wide gearbox is load-bearing for shrink's 2.67 px/clk, so re-verify real-time.

ILAs (1) + PD↓ (2) + seq↓ (3) should clear ~24% comfortably. None affects the validated datapath/
real-time behaviour; they're area trims + debug removal. After a clean place, read post-route WNS.

## Fit round 3 (4-way/512 + NO_ILA): FITS and routes — but WNS −28.76 (prefetch cone)
Gating the 3 debug ILAs (NO_ILA=1) recovered enough slices: the 4-way/NTILE=512/PD=64 warp build
**places, routes, and writes a bitstream on the 7020** (BRAM ✓ ~96, slices ✓). WHS=+0.0096 (hold ok).
But **WNS = −28.757 ns** at the 74.25 MHz pixel clock (13.468 ns period).

**Failing path (single dominant cone):**
`pg_re_0/.../u_tc/px__reg` (prefetch coord) → `u_tc/tag_reg[241]` (tag write). **41 logic levels, 41.5 ns**
(logic 10 ns / route 31.5 ns), CARRY4=11 (the `setf` `*13`/`*7` multiplies) + 12×LUT6 + MUXF7/8. This is
the **entire prefetch issue decision computed combinationally in one cycle**: px_ → ppx/ppy neighbours →
`setf`/`tidf` for 4 tiles → `(vld||rsv)&&tag` availability over the ways → first-unavailable select →
`vict` age-argmax → `ua_slot` → tag/slot write. The earlier in-context −3.5 was this same cone at 4-way
*without* the tag-at-issue + FIFO-vict additions; those (correct, and needed) deepened it to 41 levels.

**Fix (next session — the prefetch has slack, leads the consumer by LEAD, so pipeline latency is free):**
Pipeline the prefetch issue path into ~3–4 register stages, e.g.
 1. px_ → register ppx/ppy (4 neighbour coords) + their `setf`/`tidf` (the multiply — isolate it).
 2. register the `(vld||rsv)&&tag` availability result (av00..av11) per tile.
 3. register all_av + the first-unavailable `ua_*` (set/way/tid) selection (incl. `vict`).
 4. issue (tag/rsv/pf write).
**Hazard:** with pipeline latency, a tile issued at cycle T is not visible in the tag/rsv arrays for k
cycles, so cycles T+1..T+k could re-issue it (the same class as the original pend_has bug). Add a small
"recently-issued" bypass — a k-deep register of the last ua_slot/ua_tid checked in the availability —
or stall the coord-advance until the issue retires. The consumer gather lookup (looka→baddr→BRAM) is a
*separate*, shorter path and was not the worst; check it after the prefetch is pipelined.

Note the path is **76% route** (31.5 of 41.5 ns) — 41 logic levels scattered across the die. Pipelining
cuts both the logic depth and the routing (shorter nets per stage). This is careful hazard-prone work;
recommended for a fresh session per the build/WNS boundary.

**State at handoff:** fit + real-time both solved (all four real-time at 4-way/512 with per-geometry
leads: rot20@1280, rot45@4096, shrink@24576, aniso@12288 — rot45 1 cold-start px). Bitstream exists but
is non-functional at speed until the prefetch cone is pipelined. Build log: build_logs/warp_build_noila.log.
