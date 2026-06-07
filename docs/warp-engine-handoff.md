# Warp read-engine — handoff to fresh-context agent (2026-06-07)

You're picking up an in-progress FPGA subsystem on **Schindler 2.0** (Zynq-7020 / Zybo Z7-20 dev board).
Justin authors nothing himself for this — you write HDL/firmware/tcl, build and sim from this host; he
does the physical/bench work. **Verify visuals on the bench MONITOR, never the MS2109 capture stick**
(it masks AND fabricates artifacts — burned us this session on a false bottom-bar alarm).

## What the warp engine is
A new read path that does **arbitrary geometry** (any-angle rotation, keystone, pincushion, downscale)
by replacing the existing line-ring read engine (`pg_read_engine_top` = `pg_addrgen`+`pg_linefetch`)
with `pg_affine` (2×3 affine DDA addrgen) → `pg_tilecache_rt2` (4-bank, 4-way set-assoc tile cache) →
bilinear → AXIS out. Output 1280×720, source 1920×1080, 60 Hz, 74.25 MHz pixel clock. Free-running
first bitstream (reads latest VDMA frame; genlock/FRC/Mackin layer on later). Production route-B path
is untouched — the warp path is a build variant (`WARP_ENGINE=1`).

## READ THESE FIRST (in order)
1. `docs/warp-engine-build.md` — phased tracker (M1..M5).
2. `docs/warp-realfill-sweep.md` — the real-HDL transform sweep that found the fill wall.
3. `docs/warp-engine-round2-review.md` — the independent reviewer's decisive round-2 (the metric).
4. `docs/warp-cache-timing.md` — the OOC silicon-closure history (6 fixes).
5. Memory: `schindler_affine_warp_gate.md`.
HDL: `hdl/pg_affine.v pg_tilecache_rt2.v pg_tile_dma.v pg_warp_engine.v pg_skid.v pg_warp_top.v`.
Sims: `sim/pg_warp_dma_tb.v` (THE sweep gate), `pg_warp_engine_tb.v`, `pg_warp_top_tb.v`.
Tools: `tools/warp_workingset.py` (per-set live-tile metric), `tools/warp_assoc_sweep.py` (cand sweep).
Branch: `iter5-1080p-clean`, head `4b0c208`. Build env: source Vivado 2025.2, and
`export BOARD_PARTS_REPO_PATHS=~/fpga/vivado-boards/new/board_files` (Digilent IP already at
`~/fpga/vivado-library`).

## State: capacity wall DOWN, fill wall is the binding item
Whole datapath + DataMover fill path (`pg_tile_dma`) is sim bit-exact; cache fits + logic-timing-clean.
Two real walls surfaced when the **real** set-assoc cache + **real** fill path met the hard transforms
(the earlier "all proven" used an idealized 4 px/clk fill + LRU gate — over-optimistic):
- **Capacity (DONE, validated, `4b0c208`):** shrink was associativity-bound (15 live tiles/set, 4 ways).
  Fix = set-index hash `(tx*13+ty*7)&127` @ **128 sets / 4-way / NTILE 512** — `tools/warp_assoc_sweep.py`
  shows worst-set-live ≤4 for ALL transforms while keeping cheap 4-way. HDL sweep confirms: shrink
  94%→47%, rot45 40%→14%.
- **Fill (YOUR JOB):** with capacity relieved, every transform is now fill-bound — residual underruns
  scale with tile-cross rate (pure starve), even rot20 tipped under. aniso also shows ~19 bit-err =
  eviction-vs-gather race that appears *because the prefetch runs behind*; a fast-enough fill removes
  both the underruns and the race.

Current sweep (NTILE=512, hash, single-outstanding 2 px/clk fill): rot20 1789 / rot45 5025 /
shrink 17402 / aniso 22272(+19 bit-err) underruns — all FAIL.

## Your task: the fill rework
Goal: `sim/pg_warp_dma_tb.v` sweep → **all 4 transforms underruns=0, bit-err=0, collected=NA**.
Design plan (decided with the reviewer; their crux call: 2.67 px/clk + non-thrashing cache + deep lead
should clear it WITHOUT the expensive dual-clock fill — that's the empirical question to confirm):
1. **Wide gearbox** in `pg_tile_dma`: 2 px/clk → use the full 64-bit beat (~2.67 px/clk).
2. **Per-pixel-streaming fill** likely replaces the 2×2-block fill: a wide gearbox at 3 px/clk breaks
   the 2×2 pairing, so stream raster px → parity banks (2–3/clk to distinct parity banks) instead.
   This is a real `pg_tilecache_rt2` fill rewrite + re-verify — keep the gather/tag side intact.
3. **Multi-outstanding fills**: `pg_tilecache_rt2` prefetch is single-in-flight (`pend_v`); pipeline it
   so the DataMover streams gap-free, and pipeline `pg_tile_dma` so tiles don't serialize.
4. Re-sweep after each change. If 2.67 px/clk + deep lead still can't hold shrink/45°, only THEN
   consider the dual-clock fill (reviewer says you likely won't need it — don't build it pre-emptively).
DO NOT change the set-index/associativity (it's validated); re-run `tools/warp_assoc_sweep.py` and
require worst-set-live ≤ ways before ANY cache-structure change.

## After the fill rework (each step verified, in order)
5. **Tag-lookup pipeline (timing, orthogonal):** in-context build failed WNS −3.5 ns on the cache
   lookup path (`u_tc/px_ → u_skid_p/m_data` / `u_dma`, ~−2.4 ns, 12 violated endpoints). Pipeline the
   tag lookup into its own register stage (prefetch has slack). Reviewer endorsed this lever.
6. **Rebuild:** `BOARD_PARTS_REPO_PATHS=... WARP_ENGINE=1 vivado -mode batch -source tcl/build_phase_b.tcl`.
   **First fix `tcl/readengine_warp_bd.tcl` line 58: `CONFIG.NTILE {256}` → `{512}`** to match the
   capacity fix (currently stale — would build the old small cache). Confirm post-route WNS ≥ 0.
7. **Round-3 to the reviewer:** they asked for the post-fill numbers back. Write it like
   `docs/warp-engine-round2-for-review.md` (data + analysis + questions); Justin relays it.
8. **Bench (Justin's):** the warp variant boots to the warped frame (mux sel default 1; sel→0 = VDMA
   passthrough fallback). Monitor only.

## Standing rules
- Stop the control daemon before JTAG re-program (frees /dev/ttyUSB1, or HDMI input won't re-lock).
- The bench monitor is the only truth surface (not MS2109).
- No coin-flip vsync builds; HDMI output spec-compliant; physical Pmod pin naming at the bench.
- Commit cadence: this engine work has been committing freely on `iter5-1080p-clean`; match that, and
  push only when Justin asks.
