# Warp read engine — phased build tracker

Greenlit 2026-06-06 (gate passed, corrections math validated). Replaces the line-ring read path
(`pg_addrgen` + `pg_linefetch`) with an **arbitrary-geometry** path (`pg_affine` + `pg_tilecache`),
reusing the existing bilinear / Mackin / compose / FRC-genlock tail unchanged.

| Phase | Module | Status |
|---|---|---|
| 1 | **`pg_affine`** addrgen — incremental 2×3 affine DDA | ✅ done, sim bit-exact (`0a850e6`) |
| 2 | **`pg_tilecache`** fetch — tile DMA + LRU + prefetch | M1 ✅ functional (bit-exact); **M2 real-time gate done — see findings below** |
| 3 | integrate (swap in for linefetch; wire bilinear/Mackin/compose) | pending |
| 4 | Vivado build + timing | pending |
| 5 | bench | pending |
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
- **Free ROTATION is the HARD case** (surprise — the bandwidth gate made it look cheap). Rotation's
  source advances *orthogonal* to the output scan → low tile locality, sustained (not bursty) miss
  demand. Even at the aggressive config (8×8 tiles, 2 DDR ports = 32 B/cyc, deep lead) it leaves a
  tiny residual: rotate-90 ~47, rotate-30 ~174, rotate-45 ~510 underruns (≈0.01–0.07% of pixels).
  Fully closing rotation needs 3–4 DDR ports (the Zynq has 4 HP) and/or larger cache, OR a dedicated
  DDR-transpose path for the orthogonal 90/180/270 angles.

**Design implication for M3 HDL:** 16×16 tiles, 512-tile (384 KB) cache, deep prefetch (~4 K lead) +
FIFO, parameterized DDR-port count. The engine is **real-time-proven for the corrections** (the
priorities); **rotation is best-effort** at 1–2 ports and needs more DDR (or the transpose trick) to
be tear-free at all angles. Decision needed before M3: build for corrections now (solid) + treat
free-rotation as a later DDR-port/transpose upgrade?

## Phase 5b — corrections on the addrgen (after the engine benches)
Math already validated (`tools/correction_preview.py`): pincushion = radial post-multiply on
`(sx,sy)` (~4 mults/px, pipeline); keystone = projective + per-pixel reciprocal-LUT divide; warp =
9×9 mesh + 2D-bilinear of source coords. Each is an addrgen variant; the fetch is unchanged.
