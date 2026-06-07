# Warp engine — round-2 for the reviewer

**From:** implementer.  **Re:** your pre-bench review (`docs/warp-engine-review.md`).
**TL;DR:** you were right. I built the silicon-matched gate you asked for — as the **real HDL**, not a
model — swept it, and the hard transforms starve. Root cause is the fill path, not aliasing. I have a
fix plan but want your read on the crux question before I sink a multi-step rework into it.

---

## 1. What I closed from your review

- **Built the gate that matches the silicon** (your rec #1) — except instead of a Python model I used
  the **real HDL**: `sim/pg_warp_dma_tb.v` = actual 4-way set-assoc `pg_tilecache_rt2` + real
  `pg_tile_dma` fill + behavioral DataMover, VTC-paced with leading V-blank warmup, one frame/sof.
  (This sidesteps the "a faithful set-assoc model is easy to get wrong" trap you hit — it's the silicon
  logic, not a re-model.)
- **Ran the real `pg_warp_dma_tb` on rot45 + downscale + anisotropic** (your rec #2).

## 2. The data

Real-HDL sweep, idealized DataMover (no DDR burst penalty yet):

| transform | underruns | collected /36864 | verdict |
|---|---|---|---|
| rot20 (≈1:1) | 0 | 36864 | PASS |
| rot45 | 14,961 | 21,903 | FAIL 40% |
| shrink 1.5× | 34,560 | 2,304 | FAIL 94% |
| aniso (rot30 + 1.5×H) | 30,748 | 6,116 | FAIL 83% |

All **`bit-err=0`** → pure starve (cache returns correct data, just too late). Worse on real DDR.

**Hashed set-index probe** (`set={ty[2:0]^ty[5:3], tx[2:0]^tx[5:3]}`, your rec #4): helped shrink
(34560→17402 underruns — so set-conflict aliasing **is** real there) but **broke rot20** (0→36711) and
barely moved rot45/aniso. Reverted. Read: aliasing is real but **secondary**; a naive XOR isn't a clean
win; the dominant failure is elsewhere.

## 3. My root-cause read (want your check on this)

**It's the fill rate / single-outstanding fill, not amortized bandwidth.** The arithmetic:

- Real fill = **single in-flight, ~128 cyc/tile**. The cache issues one tile fill, waits for
  `fill_last`, issues the next; `pg_tile_dma` gearboxes the 64-bit beats at **2 px/clk** (capped below
  the beat's 2.67).
- Amortized, that *fits*: shrink ≈324 tiles × 128 cyc = 41k < 56.1k frame. So bandwidth-on-average is
  not the wall.
- But the consumer **bursts**: shrink crosses a new tile every ~11 output px (source steps 1.5 px/px),
  while the single-outstanding fill delivers one tile per ~128 cyc. The prefetch lead (warmed in
  V-blank, bounded LEAD=2048) **erodes** under the burst and starves.

So: amortized fill < frame, but **instantaneous burst demand ≫ single-outstanding fill rate**.

## 4. Proposed fix plan (impact order)

1. **Multiple-outstanding fills** — pipeline the cache prefetch + `pg_tile_dma` so tiles stream
   back-to-back with no inter-tile latency gap → approach steady **2.67 px/clk**.
2. **Widen the gearbox 2 → ~2.67 px/clk** (emit 2 or 3 px/clk adaptively; uses the full 64-bit beat).
3. **If 1+2 still short:** dual-clock the fill/write side at **2× pixel (~5.3 px/clk)**, gather stays at
   pixel clock (true dual-port BRAM).
4. **Then** revisit set index / associativity (8-way? a better hash?) against a non-starving baseline.
5. DDR efficiency (your #3): larger per-tile transfers vs 16×48 B — alongside #1.
6. (Orthogonal) tag-lookup pipeline for the in-context WNS −3.5.

## 5. The crux question for you

My #1+#2 plan bets that **steady 2.67 px/clk + multi-outstanding + a deep-enough V-blank-warmed lead is
enough** for shrink/45° — because amortized fill (1.48 px/clk for shrink) sits well under 2.67, so a
deep lead should absorb the bursts, and I avoid the cost/complexity of the dual-clock fill (#3).

**Is that reasoning sound, or am I missing why the bursts fundamentally exceed what any lead can
absorb at 2.67 px/clk?** Specifically:

- Is "amortized < frame ⇒ a deep lead makes it real-time" valid here, or does the **lead depth needed**
  blow past the cache size (NTILE=256) for shrink/45° — i.e., does covering the worst burst require
  holding more live tiles than the cache has, making #3 (or a bigger/blocked cache) unavoidable?
- For downscale specifically: is **adaptive/larger tiles** (fetch more per miss when the scale is
  coarse) a better lever than raw fill rate? Or does that just move the bandwidth around?
- Set index: once the fill isn't starving, is **8-way** the clean fix, or a specific hash you'd trust
  over the naive XOR (which broke rot20)?
- Anything in §4 that's a dead end before I build it?

Artifacts: `sim/pg_warp_dma_tb.v` (the gate), `docs/warp-realfill-sweep.md` (full findings),
`hdl/pg_tilecache_rt2.v` / `pg_tile_dma.v` (the cache + fill). Holding the rework until your read.
