# Warp engine — 1080 status + the road to 1080p60

Snapshot at the end of the 2026-06-09 session. The warp engine (affine read-engine) is the path to
arbitrary geometry (rotation now, keystone/corner-pin next) and to 1080p60. This captures exactly where it
stands and the three substantial pieces between here and a 1080p60 bench test.

## Where it is now (bench-proven)

- **720p60 warp: clean** — identity + gentle rotations stable (production-grade on `iter5-1080p-clean`).
- **1080p30 warp: RENDERS but underruns.** The bench photo (2026-06-09) shows the **top ~60% a clean,
  correct, full-width 1080p test pattern** (sharp colors, grid, timecode), then it **tears into garbage at
  the bottom**. So the datapath, geometry, and timing are all CORRECT at 1080 — the engine simply can't
  *feed* a full 1080 frame. Branch `warp-1080p30-plain`, build archived
  `warp-1080p30-plain-1080p30-...-d039c0b`, WNS +0.035 (tight but functional — a clean top proves timing
  isn't glitching).

## The three blockers (each a real rework, in priority order for 1080p60)

### 1. Tile-DMA throughput (blocks CLEAN 1080) — the current wall
**Diagnosis (proven):** during active video both 720p and 1080 need the same **223 MB/s instantaneous**
fetch (1 px/clk). The AXI DataMover delivers ~200 MB/s at **~37% efficiency** because every tile fetch is a
**48-byte (one 16-px tile-row), strided** read (`pg_tile_dma`), and the DataMover M_AXI runs at **pclk =
74.25 MHz** (not the 143 MHz HP1 clock). 720p's larger H-blank (370 clk) recovers the per-line deficit;
**1080's smaller H-blank (280 clk) can't → the prefetch lead erodes through the frame → bottom tears.**
Lead-sweep confirms it's *fetch rate*, not look-ahead: opix only crept 868k→999k from lead 8k→65k and
plateaued at half-width lines. No DataMover parameter fixes it (probed: no outstanding-reads/pipe-depth knob;
burst is capped by the 48-byte command).
**Fix options (pick one):**
- **(a) Bigger contiguous bursts** — coalesce consecutive tile-rows in `pg_tile_dma` (for axis-aligned/
  identity, consecutive tiles are contiguous in DDR → one 192–768-byte burst instead of 4–16×48 B).
  Contained to one module, stays at pclk (no CDC). Helps identity/axis-aligned most (the clean-1080 case);
  rotation tiles aren't contiguous so it helps less there.
- **(b) DataMover @ 143 MHz** — move M_AXI/M_AXIS to FCLK_CLK1 (2× read-issue rate → ~440 MB/s effective,
  clears 1080 for ALL geometries). Cost: AXIS clock-converters on cmd + data + status between the 143 MHz
  DataMover and the 74.25 MHz `pg_tile_dma`; SmartConnect simplifies to single-clock. Universal but a BD
  rework with CDC/reset care.
- **(c) Tiled DDR layout** — S2MM writes the source tile-ordered so a 16×16 tile is one contiguous 768 B
  read. Biggest efficiency win, helps everything, but touches the capture path. Largest change.
Recommended: **(b)** for a universal fix, or **(a)** for a fast identity-1080 win.

### 2. Demand-fetch FSM (blocks robust 1080 ROTATIONS)
The consumer demand-fetch (`05fec34` on `main`) is sim-validated bit-exact and eliminates every wedge, BUT
its combinational cone (`cs00 gather → cdemand → vict_dem → commit`, 25 logic levels) is **WNS −12.2 ns**.
It must be **pipelined into registered FSM stages** (the consumer is stalled while demand-fetching, so a few
cycles of latency are free): stage 1 latch the absent tile (cd_tid/cd_set + neighbour tids) on a 1-bit
`dem_busy` interlock; stage 2 `vict_dem` → register ua_way; stage 3 issue/commit. Single-issue per cycle
(arbitrate demand vs prefetch). Re-enable the `rot-162` faithful-TB case as the gate (must complete +
bit-exact). This is orthogonal to 1080 throughput.

### 3. 1080p60 output (blocks p60 specifically) — hardware
Zybo Z7-20 (-1) rgb2dvi can't serialize 148.5 MHz (needs a 1485 MHz MMCM VCO; -1 caps at 1200). 1080p60
HDMI out needs the **TE0720** (-2 silicon, the production target) or an external HDMI transmitter. Nothing
above changes — it's a board swap + rebuild once a TE0720 is on the bench. (1080p30 stays the Zybo ceiling.)

## Sequenced path to a 1080p60 bench test
1. **Tile-DMA throughput (1b or 1a)** → clean 1080p30 identity on the Zybo bench.
2. **Demand-fetch FSM (2)** → robust 1080 rotations (and finally a wedge-free shippable warp at 720p too).
3. **TE0720 (3)** → 1080p60 output.
Then **projective front-end** (`docs/projective-front-end-scope.md`) layers keystone/corner-pin on top — it
rides the same backend and *needs* both demand-fetch (foreshortening) and the DMA throughput.

## Quick reference (this session's commits)
- `05fec34` demand-fetch (main, −12.2 ns, needs FSM) · `06fa7bb` 1080p30 output support ·
  `07713d9` projective scope · `warp-1080p30-plain` branch = 1080p30 on the proven plain cache (renders,
  throughput-limited).
