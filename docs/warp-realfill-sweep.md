# Warp engine — real-fill transform sweep (round-2 for the reviewer), 2026-06-07

Built the silicon-matched gate the review asked for — except it's the **real HDL**, not a model:
`sim/pg_warp_dma_tb.v` runs the actual 4-way set-assoc cache + real `pg_tile_dma` fill path +
behavioral DataMover, VTC-paced with V-blank warmup, one output frame/sof.

## Result — the review was right; the hard transforms starve

| transform | underruns | collected /36864 | verdict |
|---|---|---|---|
| rot20 (1:1, low tile-cross) | 0 | 36864 | PASS |
| rot45 | 14,961 | 21,903 | FAIL 40% |
| shrink 1.5× | 34,560 | 2,304 | FAIL 94% |
| aniso (rot30 + 1.5×H) | 30,748 | 6,116 | FAIL 83% |

All `bit-err=0` → **pure starve, not corruption** (the cache returns correct data; the engine just
can't deliver pixels in time). And this is with the *idealized* DataMover (no DDR burst penalty) — the
real DDR makes it worse.

## Root cause — bandwidth/pipelining, with set-conflict secondary

- **Hashed set index experiment** (`{ty^,tx^}`): helped shrink (34560→17402 underruns — so set-conflict
  aliasing *is* real there) but **broke rot20** (0→36711) and barely moved rot45/aniso. So aliasing is
  a real-but-secondary factor; a naive XOR is not a clean win. Reverted.
- **Dominant cause = fill rate, not amortized bandwidth.** Amortized, the fill fits: shrink's ~324
  tiles × 128 cyc/tile = 41k < 56k frame. But the fill is **single-in-flight, ~128 cyc/tile** (the
  cache issues one tile fill, waits for `fill_last`, issues the next; `pg_tile_dma` gearboxes at 2
  px/clk, capped below the beat's 2.67). The consumer **bursts** new tiles (shrink: a new tile every
  ~11 output px) far faster than the single-in-flight fill delivers them, the prefetch lead erodes, and
  it starves. This is the same shape as the M2-gate over-optimism: the gate modeled 16 B/cyc + LRU; the
  silicon is 8 B/cyc (64-bit DataMover @ pixel clk) + set-assoc + single-outstanding.

## Fix path (in impact order — this is real fill-path rework, not a tweak)

1. **Multiple-outstanding fills** — pipeline the cache prefetch + `pg_tile_dma` so tiles fill
   back-to-back with no inter-tile latency gap → approaches the steady 2.67 px/clk.
2. **Widen the gearbox 2 → ~2.67 px/clk** (emit 2 or 3 adaptively) — uses the full 64-bit beat.
3. **Faster fill clock** (fill/DMA write side @ 2× pixel, dual-clock BRAM, gather stays @ pixel) →
   ~5.3 px/clk — the big hammer if 1+2 aren't enough for shrink/45°.
4. **Better set index / more ways** — for the aliasing component (a good hash or 8-way), after the
   bandwidth fix so it's measured against a non-starving baseline.
5. **DDR efficiency** (review #3): per-tile larger transfers vs 16×48 B — orthogonal, do alongside 1.

## Status

- rot20-class (low tile-cross: modest rotation, ~1:1) is real-time + bit-exact on the real fill path.
- **Arbitrary geometry (downscale / 45° / anisotropic) is NOT real-time yet** — needs the fill-path
  rework above. The engine is not bench-ready for its headline feature until that closes.
- In-context Vivado build also failed timing (WNS −3.5, cache lookup path) — needs the tag-lookup
  pipeline; orthogonal to the fill rework.
