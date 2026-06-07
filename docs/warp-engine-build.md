# Warp read engine — phased build tracker

Greenlit 2026-06-06 (gate passed, corrections math validated). Replaces the line-ring read path
(`pg_addrgen` + `pg_linefetch`) with an **arbitrary-geometry** path (`pg_affine` + `pg_tilecache`),
reusing the existing bilinear / Mackin / compose / FRC-genlock tail unchanged.

| Phase | Module | Status |
|---|---|---|
| 1 | **`pg_affine`** addrgen — incremental 2×3 affine DDA | ✅ done, sim bit-exact (`0a850e6`) |
| 2 | **`pg_tilecache`** fetch — tile DMA + LRU + prefetch | M1 ✅; M2 ✅ model; M3a ✅ gather; **M3b ✅ concurrent real-time cache — tear-free + bit-exact in RTL** (`d9b0e15`, `pg_tilecache_rt2.v`: identity/rot25/rot45/shrink all pass) |
| 3 | **integrate** (`pg_warp_engine`) | **datapath ✅ end-to-end bit-exact + real-time in RTL** (`239e8a8`, `pg_warp_engine_tb` rot20: 0 bit-err, 38376<56100 cyc). Remaining to bitstream: DataMover 2×2-block reorder · genlock/FRC wrap · BD swap · firmware affine coeffs |
| 3 | integrate (swap in for linefetch; wire bilinear/Mackin/compose) | pending |
| 3d | **`pg_tile_dma`** — tile fetch + 2x2 reorder (real DataMover fill) | ✅ real-time + bit-exact (`d63ebec`, `pg_warp_dma_tb`: warp+tile_dma+behavioral DataMover, VTC-paced + V-blank warmup, rot20 underruns=0/bit-err=0/56026<56100 cyc) |
| 3e | cache silicon rework (fits + logic-timing-clean) | ✅ `docs/warp-cache-timing.md` (12k LUT / 48 BRAM, logic 3.9ns) |
| 4a | BD swap: pg_warp_engine + pg_tile_dma into readengine_b_bd.tcl (DataMover, VTC sof, GPIO coeffs, output) | pending |
| 4b | firmware: affine coeffs (a..f) from geometry | pending |
| 4c | Vivado build + timing (the real in-context timing test) | pending |
| 5 | bench (owner) | pending |
| 5b | layer pincushion (radial) + keystone (projective divide) on addrgen | pending |

## Phase 2 — `pg_tilecache` architecture (the design to build)

**Job:** given a stream of source coords `(sx,sy)` from `pg_affine` (with bilinear neighbours), return
the 2×2 source pixels, fetching 32×32 tiles from the genlock-selected DDR frame through a BRAM LRU
cache, **without ever starving the genlocked output** (the real-time gate).

**Params (from the gate, `docs/affine-warp-gate-results.md`):** 32×32 tiles (3 KB), **128-tile cache
(384 KB BRAM)**, prefetch run-ahead + ~128-tile FIFO to absorb the ~115-tile/row worst burst.

**Blocks:**
1. **Tag/LRU store** — 128 entries: {tile_id (frame-relative), valid, lru_age}. Lookup = associative
   compare (or a hashed set-assoc to cut comparators). Hit → BRAM read; miss → enqueue fetch.
2. **Tile BRAM** — 128 × (32×32×3 B). Dual-port: write side = DMA fill; read side = the 2×2 sampler.
3. **Prefetch walker** — runs the SAME affine DDA *ahead* of the consumer by P pixels; for each
   look-ahead pixel, computes its tile(s); if not resident/pending, issues a DMA. This is what hides
   miss latency (the gate showed avg « budget, so run-ahead has slack to pre-pull bursts).
4. **DMA engine** — AXI DataMover (reuse the existing one's pattern): tile = 32 rows × 32×3 B at
   stride = frame width; 32 short bursts, or a 2D descriptor. Fill the inactive tile-BRAM slot.
5. **Sampler** — on the consumer coord, read the 4 neighbour pixels from tile BRAM (handle the 2×2
   straddling up to 4 tiles, like pg_linefetch's window), present to the existing bilinear.
6. **Stall/underrun guard** — consumer stalls if its tile isn't resident yet; the output FIFO
   (existing in compose) covers the slack. The TB must prove FIFO never empties for the worst case.

**Real-time gate (Phase 2 sim):** a behavioral DDR model (latency + burst throughput) drives the
tile DMA; the TB runs the worst transforms (pincushion, rotate-45, shrink) and asserts **the output
FIFO never underruns** + the sampled pixels are **bit-exact** vs a golden warp. This sim IS the
cycle-accurate real-time proof (the Python gate proved bandwidth; this proves no-stall with real
latency). If it underruns: deepen prefetch run-ahead / FIFO, or raise cache associativity — knobs,
not walls (avg bandwidth has headroom).

**Risks / open:**
- Prefetch run-ahead depth P vs DMA latency — tune in sim.
- Frame coherence under FRC: cache invalidates when the genlock ring switches source frame (per-frame
  cold, as the gate modeled). Simplest: flush-on-frame (tag includes frame slot; mismatch = miss).
- BRAM budget: 384 KB cache + ~FIFO vs the 7020 ~600 KB shared with VDMA/scaler — verify at Phase 4.
- Associative tag compare timing at 128 entries — use set-associative (e.g. 4-way × 32 sets) if needed.

## M2 real-time gate findings (cycle-accurate, `tools/tilecache_realtime_gate.py`) — 2026-06-06

Cycle-accurate model: full 720p60 timing (active + blanking), prefetch walker, single-channel DDR
(latency + throughput), output FIFO. Underrun cycles must be 0. **This inverts a bandwidth-gate
assumption** (which counted only avg miss bandwidth): cycle-timing tells a different story.

- **Tile SIZE is the dominant lever.** 32×32 (3 KB/tile) FAILS everything — one bursty row needs
  ~60 misses × 384 cyc ≫ a row. **16×16 tiles (same 384 KB cache)** is the design point.
- **CORRECTIONS are real-time ✅** at 16×16 + ONE DDR port (16 B/cyc): **pincushion, shrink/scale**
  (and keystone, same locality class) — 0 underruns. These are the stated-priority features.
- **The rotation "wall" was a MODEL ARTIFACT (cold start).** First runs put V-blank AFTER active, so
  the cache started cold at pixel (0,0) — manufacturing the rotation underruns. Real 720p60 has ~25
  blank lines BEFORE active (~41k cycles of free prefetch warmup).
- **With correct timing (leading-blank warmup) + a deep prefetch lead (~8192 px ≈ 6 rows): EVERY
  transform is TEAR-FREE at the BASE config — 16×16 tiles, 512-tile (384 KB) cache, ONE DDR port
  (16 B/cyc).** pincushion, rotate-90/30/45, shrink: 0 underruns. Also passes at 2× and 4× DDR, so
  there's large headroom if real DDR is slower than modeled.

**Design point for M3 HDL (LOCKED):** 16×16 tiles, 512-tile (384 KB) cache, **prefetch run-ahead
~6 rows + output FIFO, pre-filled during V-blank**, single DDR port (parameterize port count for
margin). Tear-free for the whole geometry family — corrections AND arbitrary rotation. The two
non-obvious requirements the HDL MUST honor: (1) 16×16 tiles (32×32 is too coarse — bursty rows),
(2) deep prefetch that runs through V-blank so the cache is warm at the first active pixel.

## Phase 5b — corrections on the addrgen (after the engine benches)
Math already validated (`tools/correction_preview.py`): pincushion = radial post-multiply on
`(sx,sy)` (~4 mults/px, pipeline); keystone = projective + per-pixel reciprocal-LUT divide; warp =
9×9 mesh + 2D-bilinear of source coords. Each is an addrgen variant; the fetch is unchanged.
