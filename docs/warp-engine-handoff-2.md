# Warp read-engine — handoff #2 to fresh-context agent (2026-06-08)

You're continuing the **warp read-engine** on Schindler 2.0 (Zynq-7020 / Zybo Z7-20 dev board; production
target TE0720 = also a 7020). Justin authors nothing himself — you write HDL/firmware/tcl, build and sim
from this host; he does the physical/bench work. **Verify visuals on the bench MONITOR, never the MS2109
capture stick.** Branch `iter5-1080p-clean`. Source Vivado 2025.2 (`source /tools/Xilinx/2025.2/Vivado/
settings64.sh`) and `export BOARD_PARTS_REPO_PATHS=~/fpga/vivado-boards/new/board_files`.

## ⚠️ SCOPE: the warp path MUST support 1080p OUTPUT (not just 720p) — re-target timing to 148.5 MHz
Everything below was developed/validated at **720p output** (1280×720) from a **1080p source**
(1920×1080), at the 74.25 MHz / 13.468 ns output clock. **Justin confirmed (2026-06-08) the warp path
must also do 1080p OUTPUT.** That runs at **148.5 MHz / 6.734 ns — half the period.** Implications you
must carry from the start:
- The banked WNS **−15.38 ns is against the 13.468 ns (720p) clock** → the critical path is ~28.8 ns. At
  the 1080p period that's **WNS ≈ −22 ns**, and there are ~2.25× the output pixels. Closing 1080p60
  needs the path ≤6.7 ns — a ~4.3× reduction (TE0720 −2 silicon only buys ~15–20%).
- **Re-target the warp timing constraint to 148.5 MHz now** so you solve the real problem (constrain the
  warp logic to 6.734 ns even though the 1080p60 HDMI *output stage* is Zybo-silicon-blocked — that's
  the TE0720-relevant number). Then read WNS against 6.7 ns.
- The storage-shape fix (Step 1) is even more critical at 1080p (it cuts per-stage logic). Pipelining
  (Step 2) must go **deeper** — each stage ≤6.7 ns. Latency budget exists (prefetch-led cache), so it's
  plausible, but the stateful prefetch issue loop is the hard part to pipeline arbitrarily deep.
- **Architectural fallback if pipelining can't reach 6.7 ns:** decouple the warp logic from the output
  clock — process **2 px/clk at 74.25 MHz** (back to a 13.5 ns budget) with an output FIFO. Costs 2×
  cache read bandwidth (more banks / dual-port reads). Evaluate this if deep pipelining stalls.
- The 720p-out validation (real-time, BRAM/slice fit, per-geometry leads) does NOT transfer to 1080p out
  unchanged — 1080p out reads the source more densely (more fill bandwidth + bigger working set) and runs
  2× faster. Re-validate `pg_warp_real_tb` at OUT_W/OUT_H=1920/1080 and re-check the cache fit/leads.

## What the warp engine is
An arbitrary-geometry read path (any-angle rotate, keystone, pincushion, downscale): `pg_affine` (2×3
affine DDA addrgen, ×2 — one consumer, one prefetch) → `pg_tilecache_rt2` (set-assoc tile cache, FIFO
eviction, multi-outstanding prefetch fill) → bilinear → AXIS out. 1280×720 out from 1920×1080 in @
74.25 MHz. A build variant (`WARP_ENGINE=1`); route-B is untouched. HDL: `hdl/pg_affine.v pg_skid.v
pg_tilecache_rt2.v pg_tile_dma.v pg_warp_engine.v pg_warp_top.v`.

## READ FIRST (in order)
1. **`docs/warp-engine-real-geometry-findings.md`** — THE state doc. Read §Resolution, §Fit, §"Fit round
   2/3/4/5", §"avm-snapshot design note", and especially **§"★ LEAD next-session step"** (your task).
2. Memory: `schindler_warp_fill_rework.md` (the one-screen summary + resume plan).
3. `docs/warp-engine-round3-for-review.md` (reviewer thread; relayed by Justin).
Gates: `sim/pg_warp_dma_tb.v` (small 1/5-scale, bit-exact, ~13 s via `sim/run_warp_sweep.sh`) and
`sim/pg_warp_real_tb.v` (full 1280×720←1920×1080 real-time gate; override LEAD with `-d LEADV=<n>`).

## State: real-time SOLVED, device-fit SOLVED, TIMING is the only blocker
The warp engine is **real-time at 1080p and fits the 7020** — the in-context build places, routes, and
writes a bitstream. The remaining blocker is **WNS = −15.38 ns** (74.25 MHz). Everything else is done:
- **Real-time:** all four transforms (rot20/rot45/shrink/aniso) starvation-free at the full geometry
  with **per-geometry LEAD** (rot20@1280, rot45@4096, shrink@24576, aniso@12288). Mechanism: FIFO-by-
  fetch per-set victim + a wide 2.67 px/clk gearbox + PD=DREQ=64 feed. No dual-clock fill.
- **Fit:** **4-way / NTILE=512 / PD=DREQ=64** (BD: `tcl/readengine_warp_bd.tcl`), with the **debug ILAs
  gated off (`NO_ILA=1`)** — needed to fit slices. (8-way/1024 was over BRAM; per-geometry lead lets
  4-way hold worst-set-live ≤4.) Both gates green: small TB 4/4 bit-exact; real geom all real-time.
- **Timing so far (this session, monotone, committed, both gates green each step):** WNS −28.76 →
  −20.27 (pipelined the prefetch feedforward / setf multiplies out of the issue cone) → −15.38
  (replaced the vict age-argmax with an O(1) per-set FIFO pointer).

## YOUR TASK — close WNS −15.38, then the firmware, then bench

### Step 1 (LEAD lever — confirmed, HAZARD-FREE, do this first)
The −15 ns cone is a **512:1-mux storage-shape artifact**, NOT inherent. `tag`/`vld`/`rsv` in
`pg_tilecache_rt2.v` are flat `reg x[0:NTILE-1]` read everywhere at the full slot `{set,way}` (a 9-bit
dynamic address → a 512-entry mux, in both the availability lookup and `vict`). A set-assoc cache
shouldn't do this. **Restructure to set-indexed wide words** (the set addresses storage; the ways come
out in parallel; W comparators):
- `reg [WAY*TIDW-1:0] tagset[0:NSET-1]`; `reg [WAY-1:0] vldset[0:NSET-1], rsvset[0:NSET-1]`.
- Reads: `tagset[set]` (a 128-deep read → LUTRAM/shallow), slice to WAY ways, WAY parallel comparators.
- The 2×2 needs 4 neighbour tiles in 4 different sets in ONE cycle → store these **LUTRAM-replicated ×4**
  (128×96b ×4 ≈ 48 Kb distributed RAM, cheap on the 7020; async read = combinational, no added latency).
  Four addresses → four wide words → comparators. `vict`'s free-way/rr read uses the same wide word.
- Writes (issue/fill) write one way's slice: `tagset[set][way*TIDW +: TIDW] <= ...` (and the ×4 replicas).
- **This is a storage-shape change, IDENTICAL logic** → re-verify is just the two gates (bit-exact); no
  control-flow change, no re-issue hazard. Quick win: also narrow `TIDW` 24→16 (tidf only uses 16 b) —
  helps area (not WNS depth).
- Build, read WNS. **If it closes (≥0) → DONE: no pipelining, no hazard.**

### Step 2 (only if step 1 partially closes — hazard-prone, careful)
The `avm-snapshot + k-deep recently-issued CAM` prefetch pipeline. **Read the trap first**
(`docs §"avm-snapshot design note"`): naive precompute is STALE because adjacent coords share tiles →
double-issue → starvation; the CAM bypass fixes it. Re-verify BOTH gates with attention to the shared-
tile case. Then pipeline `vict`'s reads if still critical. This is the "must not be done tired" junction.

### Step 3 — runtime-LEAD firmware (independent of timing)
Real-time-for-all-four needs LEAD set **per geometry** (shallow for rotation, deep ∝ downscale factor).
LEAD is a build param today; make it a GPIO-driven port on `pg_warp_engine`/`pg_warp_top` and have the
firmware compute it from the affine coeffs. Until then a fixed LEAD thrashes whichever transform it
mismatches at 4-way. (Cache persists across frames + frame-atomic coeffs → changing LEAD with geometry is
a smooth working-set shift, not a cold-start.)

### Step 4 — round-3 final + bench
Update `docs/warp-engine-round3-for-review.md` with the closed-timing WNS + the final config; Justin
relays. Then bench (Justin's, monitor only): warp variant boots to the warped frame (mux sel default 1;
sel→0 = VDMA passthrough). ⚠️ **NO_ILA build = no on-chip ILA visibility** in warp builds — carry this
into any bench debug.

## Build / verify
- Sim gate (fast): `sim/run_warp_sweep.sh` (small TB, ~13 s). Real geom: compile the 5 HDL + the TB with
  `-d LEADV=<lead>`, `xelab pg_warp_real_tb`, `xsim -R`.
- In-context build: `WARP_ENGINE=1 NO_ILA=1 BOARD_PARTS_REPO_PATHS=... vivado -mode batch -source
  tcl/build_phase_b.tcl > build_logs/<name>.log 2>&1 &` (~30–40 min; reports `TIMING: WNS=` at the end;
  writes a bitstream even on negative WNS — do NOT bench a negative-WNS bitstream). The latest fitting
  build log is `build_logs/warp_build_pipe2.log`.
- After a build, read the worst path: `open_checkpoint <impl_1>/*routed.dcp; report_timing -max_paths 1`.

## Standing rules
- Re-verify BOTH sim gates after ANY cache change (underruns=0 AND bit-err=0 small TB; real-time real
  geom). The set-index hash (mul13_7) and per-set-live ≤ ways are validated — re-run `tools/
  warp_assoc_sweep.py` / `warp_lead_assoc.py` before any cache-structure change.
- Stop the control daemon before JTAG re-program (frees /dev/ttyUSB1). Bench monitor is the only truth.
- No coin-flip vsync; HDMI spec-compliant; physical Pmod pin naming at the bench.
- Commit freely on `iter5-1080p-clean`; push only when Justin asks.
- The Vivado build + WNS read is the step that bites tired sessions (build-manifest history) — keep a
  clear head for it; the build runs unattended.
