# Warp engine — round-3 for the reviewer

**From:** implementer.  **Re:** your round-2 (`docs/warp-engine-round2-review.md`).
**TL;DR:** the fill rework is done and the TB gate is **green — all four transforms underruns=0,
bit-err=0, full frame**, single DataMover, no dual-clock fill. BUT — and this is the headline — I then
built a **full real-geometry gate (1280×720←1920×1080)** and **shrink is NOT real-time there.** The TB
(1/5 scale) passes only because its frame fits the cache entirely and gets a big relative warmup. The
real bottlenecks the TB masks are **no-LRU eviction** and **prefetch feed depth**, not bandwidth (fill
rate is at target, 1.6× headroom). Full data in **`docs/warp-engine-real-geometry-findings.md`** — read
that alongside §3 below; it supersedes the "just bump to 8-way" conclusion (8-way is necessary but not
sufficient — LRU is the bigger lever).

---

## 1. The gate (sim) — all four real-time

`sim/pg_warp_dma_tb.v`, real HDL (4-way set-assoc cache + real `pg_tile_dma` + gap-free behavioral
DataMover), VTC-paced with leading V-blank warmup, one frame/sof:

| transform | underruns | bit-err | collected /36864 | verdict |
|---|---|---|---|---|
| rot20 (≈1:1)        | **0** | 0 | 36864 | PASS |
| rot45               | **0** | 0 | 36864 | PASS |
| shrink 1.5×         | **0** | 0 | 36864 | PASS |
| aniso (rot30+1.5×H) | **0** | 0 | 36864 | PASS |

Was, at handoff: rot20 1789 / rot45 5025 / shrink 17402 / aniso 22272 (+19 bit-err). Set-index
**unchanged** (`mul13_7/128set`, worst-set-live ≤4 re-verified before/after).

## 2. What the rework actually was

Three levers, in the order they moved the needle (each re-swept):

1. **Gap-free fill (`pg_tile_dma`)** — pipelined row commands (combinational AXIS handshake, `fetch_req`
   held / consumed on `fetch_ready`, VALID independent of READY) keep the DataMover command FIFO full so
   the beat stream never stalls between rows or tiles; variable-rate gearbox drains the full 64-bit beat
   (≤3 px/clk); a 2-slot pair ping-pong emits 2×2 blocks at the beat rate with no even-row dead phase.
   → ~96 clk/tile (2.67 px/clk) vs the old ~128+gaps. Alone: rot20 1789→1344, shrink 17402→15040.
2. **Multi-outstanding prefetch (`pg_tilecache_rt2`)** — pending-slot FIFO (PD=16) replaces single
   `pend_v`; fills route in request order to the FIFO head; free-way-first victim + reservation bits +
   invalidate-on-evict (non-thrashing while the working set fits the cache). This is what lets the
   prefetch run ahead and keep the DataMover fed.
3. **Operating point** — PD=16 (cache) + DREQ=16 (tile_dma request FIFO) + LEAD=8192 (TB-px). The
   queues must cover shrink's worst tile-row-crossing burst: 12/12 still starves, 16/16 clears it.

**No dual-clock fill.** The DataMover stays one 64-bit @ pixel-clk port (2.67 px/clk). Your read that
the expensive lever wasn't the bottleneck was correct.

(Three sim/HW bugs were load-bearing to get here and are worth flagging for anyone touching this:
DataMover-model FIFO pointer width, registered-vs-combinational fetch handshake, and — the nasty one —
a pending-availability check written as a function in a continuous-assign/`always@*` is **not sensitive
to the array reads inside the function** in xsim, so a just-issued tile never counted as pending and the
prefetch re-issued it forever. Fix: inline the array compares. Details in the commit log.)

## 3. Your caution #1, quantified — the real geometry needs 8-way

You flagged that a deep lead adds prefetched-but-unconsumed tiles to the per-set live set, so
worst-set-live ≤4 *without* the lead does not guarantee ≤4 *with* it. I built the lead-aware metric
(`tools/warp_lead_assoc.py`: each tile's live span starts LEAD output-px earlier) and swept it on the
**real 1280×720 ← 1920×1080** geometry with the production `mul13_7` hash:

| LEAD (out-px) | rot20 | rot45 | shrink | aniso | 4-way? |
|---|---|---|---|---|---|
| 0     | 4 | 2 | 2 | 3 | OK |
| 1280 (1 row)  | 4 | 2 | 2 | 3 | OK |
| 2560 (2 rows) | **5** | 2 | 2 | 3 | NO |
| 12800 (10 rows) | 6 | 2 | 2 | 4 | NO |
| 25600 (20 rows) | 7 | 2 | 3 | 5 | NO |

The real-time lead is several-to-tens of rows (it has to cover filling a whole tile-row of misses at
2.67 px/clk during a crossing). At that lead, **worst-set-live hits 5–7 → 4-way thrashes.** Minimal
config that holds (within NTILE≤512 candidates and beyond):

| config | NTILE | BRAM~ | holds at 10–20-row lead? |
|---|---|---|---|
| 4-way / 128set (current) | 512 | ~48 | **NO** (rot20 6–7) |
| 8-way / 64set | 512 | ~48 | **NO** — fewer sets concentrate (rot20 12–13) |
| **8-way / 128set** | **1024** | **~96** | **YES** (all ≤8) |
| 16-way / 64set | 1024 | ~96 | yes (overkill) |

So it's exactly your prescription — **bump ways, not the hash** — and the cheap-4-way headroom is what
makes it available. The cost is **NTILE 512→1024, ~2× cache BRAM (~96/140 RAMB36 on the 7020).** Note
8-way/64set does **not** work: you must keep 128 sets and add ways, so the tile count doubles.

Why the TB gate passes at 4-way anyway: the TB is a 1/5-linear-scale proxy (256×144 ← 384×216), and at
that size the **whole frame fits the 512-slot cache** (max distinct tiles/set over the frame ≤4), so no
eviction ever happens and any lead is safe. The real geometry has far more than 512 tiles → eviction is
mandatory → the lead-aware bound bites. The TB proves the *datapath + control* are real-time; it cannot
prove the *capacity* point, which is what the lead-aware metric is for.

One more real-geometry implication: once eviction is mandatory, the all-occupied victim needs to be
LRU-ish (evict the dead tile). With worst-set-live ≤ ways (i.e. once we're 8-way), exact LRU never
evicts a live tile; the current free-way-first + RR fallback is only safe while the frame fits. So the
8-way build should also carry a small per-set LRU (or pseudo-LRU) for the all-occupied case.

## 4. What I want your read on

1. **8-way / NTILE=1024 (~2× BRAM) — agree that's the call?** It's the only NTILE-doubling that holds
   the real-time lead with the validated hash. The alternative is a smaller lead, but the sim says a
   shallow lead re-starves shrink. Is doubling the cache BRAM acceptable for the warp variant, or do you
   want me to chase a lead-vs-tile-size trade (coarser tiles cut tile count but you warned that wastes
   edge bandwidth and doesn't fix ty-constant concentration)?
2. **Real-time lead value.** My 10–20-row estimate is scaled from the TB (which needs ~24–32 TB-rows).
   A real-geometry sim would pin it but is ~25× the TB cost. Worth running before committing the ways,
   or is the lead-aware ceiling table enough to size 8-way conservatively?
3. **LRU for the all-occupied case** at 8-way — exact 4→8-way LRU is a chunk of state; is tree-PLRU
   acceptable given worst-set-live ≤ ways makes any "evict a non-live way" policy correct?
4. Anything you'd verify before I bump ways and rebuild?

Artifacts: `sim/pg_warp_dma_tb.v` (gate), `tools/warp_lead_assoc.py` (lead-aware metric),
`tools/warp_assoc_sweep.py` (capacity), `hdl/pg_tilecache_rt2.v` / `pg_tile_dma.v` (cache + fill).
The in-context Vivado build (WNS, with the tag-lookup pipeline) is the next step and will go in a
follow-up note — holding the ways decision for your read first.
