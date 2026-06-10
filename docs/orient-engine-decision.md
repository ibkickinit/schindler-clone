# Orient Engine — Decision Dossier (2026-06-10)

**Purpose.** Decide how to deliver the production orient read-engine: **press on** the current
`orient-integration` branch, or **clean-restart** from trunk with a purpose-built engine using the
now-refined spec. This document is the full context for an EVALUATOR (see §10) — it is written to be
self-contained. Companion: `docs/CURRENT-STATE.md` (forensic log) and the git history on `orient-integration`.

---

## 1. The refined spec (what we actually need — learned the hard way)

A production read-engine that takes the captured **1080p source** and presents it **oriented + scaled +
positioned** to the output raster:

- **Orientation:** the FOUR cardinal orientations **0 / 90 / 180 / 270** only. (Arbitrary rotation is a
  separate future feature; see §3.) 90/270 are transposes.
- **Scale:** zoom, where **100% = fit-to-output** (the rotated source fits the raster, letterboxed,
  aspect-preserved). Zoom in crops; zoom out shows matte.
- **Position:** signed pan in output pixels; matte fills the vacated edge.
- **Output:** 1280×720 on the Zybo Z7-20 bench; **1080p60 on the production TE0720** (same RTL — the Zybo
  just can't serialize 1485 MHz TMDS; see `[[zynq7020_rgb2dvi_1080p60_limit]]`).
- **Quality:** rock-solid — no tearing, no per-change black flash, clean at all four orientations + the full
  zoom/pan range.
- **Constraints (hard):** XC7Z020-1, **140 BRAM tiles (currently 100% used)**, one HP port ≈ **1.14 GB/s**,
  per-pixel datapath must close **148.5 MHz** for 1080p60.

This spec was NOT clear at the start; it was discovered through the journey below.

---

## 2. The journey (why the branch is a roundabout)

1. **Inherited the arbitrary-warp engine** (`pg_warp_top` = `pg_affine` raster DDA + `pg_tilecache_rt2`
   4-way associative cache + `pg_tile_dma` + bilinear + line-FIFO). Built for *arbitrary* rotation.
2. **Tabled arbitrary rotation** — the associative cache has set-hash resonance at specific angles, needs
   eviction + a demand-fetch FSM, and is a per-angle tuning rabbit hole. Pivoted to the 4 cardinals.
3. **Proved tiled DDR** (the throughput foundation): store the source as 16×16 tiles → any orientation reads
   contiguous 768 B bursts instead of 48 B strided rows (~37%→~1.1 GB/s). `orient_throughput_proof.py`.
4. **Built + sim-validated the tiled backend**: `pg_raster_to_tile` (raster→tiled DDR), `pg_tile_dma TILED`
   (1 burst/tile), full-engine-with-TILED bit-exact incl. rot90.
5. **Integrated tiled into the warp engine + BD**, bench: 0/180 OK at a 1:1 *center crop*; 90/270 off-screen.
6. **Fixed the firmware affine** (was the off-screen bug): added **fit-to-output scale** (90/270 were mapping
   the 1280-wide output across >1080 source rows) + a **pan** parameter (shift was a no-op). Firmware-only.
7. **The fit exposed full-frame tearing.** Telemetry (`starved=`, LEAD sweep): the BRAM-shrunk associative
   cache (NTILE=256) cannot hold the **~300-tile full-frame working set**; the 1:1 crop only touched 3600
   tiles and hid it. No LEAD value fixes it.
8. **Pivoted to OUTPUT-TILE processing.** Walk the output in 16×16 tiles instead of raster, so an output
   tile's few source tiles stay cached for all its 256 px → tiny working set → tiny cache.
   Built+sim-validated `pg_affine_tile` (tile-order DDA) + `pg_tile_to_raster` (reorder); bolted tile-order
   onto `pg_warp_engine`; shrank NTILE 256→64; freed BRAM with `NO_ILA`. Built clean (WNS +0.377), ran.
9. **Bench (current):** the **frame now COMPLETES** (opix 921600 vs 910825 — working-set solved) BUT a
   residual **progressive DMA-throughput starvation** remains: 0° renders the full source clean ~top-55%,
   then wraps + tears; **90/180/270 far worse** (transpose → source tiles strided in DDR → DMA even less
   efficient); scale-smaller worst. This is the present state.

---

## 3. What is PROVEN vs what REMAINS

**Proven (transfers to any path):**
- The **spec** (§1) and the **fit/pan affine math** (firmware `warp_set_rotation`: rotated-dims → fit-scale,
  `cos==0` transpose test, signed pan). Bench-correct.
- **Tiled DDR** is the right backend (throughput proof + bit-exact sims).
- **Output-tile processing** is the right structure (working set collapses; frame completes on silicon).
- **Per-pixel timing**: `pg_affine` +1.832 ns and `scaler_h` (resample) +0.550 ns @148.5 MHz; the orient
  per-pixel path is read-BRAM→bilinear, shallow. 1080p60 timing is not the risk.
- **BRAM can fit** (NO_ILA frees ~32; tile-order cache is tiny).
- Validated modules: `pg_affine_tile`, `pg_tile_to_raster`, `pg_raster_to_tile`, `pg_tile_dma TILED`.

**Remaining (the one wall):** raw **DMA fetch throughput**. Per output tile, ~4-9 source tiles are pulled as
*separate* 768 B commands; horizontal neighbors are contiguous in DDR but not coalesced, vertical/transpose
neighbors page-miss → effective throughput < the ~800 MB/s the fit needs → progressive starvation.
**Fixes:** (a) DMA read **coalescing** (merge a contiguous run of tiles into one burst); (b) **column-major
tile copy** (or a single Morton/Z-order layout) so the transpose is contiguous too; (c) optionally bypass the
line-FIFO and frame from `pg_tile_to_raster`'s own SOF/EOL.

**Note:** "Arbitrary warp / keystone / pincushion" remain a *future* feature on the same tiled backend with a
projective/mesh front-end (`docs/projective-front-end-scope.md`). Out of scope for the orient engine.

---

## 4. The baggage (why "press on" is heavier than it looks)

The current engine is **bolted onto `pg_warp_engine` + `pg_tilecache_rt2`** — machinery built for *arbitrary*
warp that the deterministic cardinal-orient engine does NOT need:
- **Associative cache** (tags, 4 ways, set-hash `tx*13+ty*7`, FIFO/rr eviction, consumer-replica, demand-fetch
  hooks). Output-tile access is deterministic + local → a **direct region buffer** is correct and far simpler.
- **Prefetch/consumer split + 20-bit LEAD machinery + skids** — needed to hide the cache's race; the
  output-tile fetch is local + deterministic → no lead, no race.
- **Soft-reset (lead_cfg[31])** — a band-aid for cache-transition wedges; deterministic engine needs none
  (this is also the **black-flash-on-change** the user dislikes).
- **Line-FIFO** SOF-early machinery — the reorder band already buffers; likely removable.
- The branch also carries dead-ends: the `warp-demand-fetch-fsm` work, multiple warp build variants, the
  scale-slider/color-temp quirks, etc.

So "press on" = adding DMA coalescing + column-major tiles + framing changes **on top of** an
associative-cache stack we don't use well — the cache's set-hash actually *limits* the reuse that coalescing
wants.

---

## 5. The two options

### Option A — Press on (`orient-integration`)
Add DMA coalescing + column-major-transpose + line-FIFO bypass to the current bolted-on stack.
- **Pro:** the hard parts already run on silicon (frame completes, timing/BRAM fit); most incremental path
  to a *first* clean 0° picture.
- **Con:** layering throughput fixes onto the associative-cache machinery we don't need; the set-hash fights
  the coalescing reuse; the soft-reset/black-flash and line-FIFO stay unless separately removed; continued
  cruft accumulation on an already-tangled branch.

### Option B — Clean integration from trunk (refined spec)
Purpose-build a small **output-tile orient engine** from §1's spec, reusing the PROVEN pieces:
- Engine core: `pg_affine_tile` (coords) → **direct 4-bank region buffer** (the output tile's ~4×4 source
  tiles, double-buffered) ← **coalesced tiled DMA** → bilinear → `pg_tile_to_raster` → raster. No tags, no
  eviction, no prefetch/lead, no soft-reset, no line-FIFO.
- Reuse verbatim: the **firmware** fit/pan + UART, `pg_affine_tile`, `pg_tile_to_raster`, `pg_raster_to_tile`,
  the **tiled-DDR BD recipe** (raster→tile in capture path, tiled S2MM geometry HSIZE=768/VSIZE=tiles/
  STRIDE=768), and the **gotchas** (§8).
- Design the **DMA coalescing and the transpose layout in from the start** (they're the whole point).
- **Pro:** simpler, smaller, no baggage; direct region buffer closes timing easier than the cache;
  black-flash gone by construction; the throughput fix is native, not retrofit.
- **Con:** re-do the BD/firmware integration (recipe is documented), discard the bolted-on engine glue
  (but it's baggage), risk of re-hitting integration gotchas (mitigated by §8).

---

## 6. My recommendation (the implementing agent's view)

**Option B — clean integration, but *informed* by everything here.** The current branch did its real job:
it proved the **spec** and the **architecture** (tiled DDR + output-tile processing + fit/pan). What it did
NOT produce is a clean *implementation* — it grafted those ideas onto an arbitrary-warp associative-cache
engine, and every step since has been fighting that foundation's baggage (set-hash, eviction, lead,
soft-reset, line-FIFO). The remaining DMA-throughput work is exactly the kind of thing that is **far cleaner
to design into a purpose-built engine than to bolt onto the warp DMA + cache.**

Crucially, a clean build is NOT starting over: ~80% of the hard-won value (the affine/fit/pan math, the
tile-order walk, the reorder, the tiled-DDR recipe, the throughput/timing analysis, the gotchas) transfers
directly. The clean engine core is a *smaller* module than `pg_warp_engine`+`pg_tilecache_rt2` combined.

**Caveat / where A wins:** if the goal is the *fastest path to a single clean 0° frame for a demo*, A is
closer (one DMA-coalescing change might get 0° clean). B is the better *production* answer. If the team
values a shippable, maintainable engine that also kills the black-flash and is honest at 148.5 MHz, B.

**Middle path worth naming:** Option B' — clean-build the ENGINE CORE but keep the current branch's *proven
infrastructure* (the BD wiring, firmware, tiled S2MM) rather than re-deriving it from trunk. Lower
integration risk than full-trunk B, most of the cleanliness. The evaluator should weigh B vs B'.

---

## 7. Reusable assets (inventory for whichever path)

| Asset | Where | State |
|-------|-------|-------|
| Fit/pan affine + UART | `sw/phase-b/src/main.c` `warp_set_rotation`, `W`/`L` cmds | bench-correct |
| Tile-order affine DDA | `hdl/pg_affine_tile.v` | sim bit-exact (ident/rot90) |
| Output band→raster reorder | `hdl/pg_tile_to_raster.v` | sim bit-exact |
| Raster→tiled-DDR writer | `hdl/pg_raster_to_tile.v` | sim bit-exact |
| Tiled tile-DMA (1 burst/tile) | `hdl/pg_tile_dma.v` `TILED=1` | sim-valid (needs coalescing) |
| Tiled-DDR BD recipe | `build_phase_b.tcl` splice + `main.c` S2MM geom (ORIENT_TILED) | bench-running |
| Throughput proof / golden / timing | `tools/orient_throughput_proof.py`, `orient_golden.py`, OOC @148.5 | done |
| **DROP:** warp engine + assoc cache + soft-reset + line-FIFO | `pg_warp_engine.v`, `pg_tilecache_rt2.v` | baggage |

---

## 8. Integration gotchas already paid for (any path must respect)

- Board files: `export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files`.
- `NO_ILA=1` env frees ~32 BRAM (and ~10k LUT) — debug ILAs are not needed; UART telemetry is separate.
- BRAM is 100% full; the reorder band is ~40 BRAM (deep 16×OUT_W×24); budget carefully.
- Module-ref HDL must be `add_files`'d in `build_phase_b.tcl` before `create_bd_cell`.
- AXIS BD splice needs `s_axis_*/m_axis_*` port naming for interface inference.
- 1080 is not a multiple of 16 (67.5 tile-rows) — handle the partial last band (or pad to 1088).
- Tiled S2MM geometry: HSIZE=768, VSIZE=tiles/frame, STRIDE=768 (`#ifdef ORIENT_TILED` in main.c).
- **Bench truth = the monitor, NOT the MS2109** (`[[schindler_ms2109_verification_trap]]`); verify the Osee
  input first (`[[schindler_osee_switcher_topology]]`).
- Daemon: venv at `/tmp/schindlerd-venv/bin/python3` (EPHEMERAL — recreate if gone), catalog
  `control-plane/catalog-v0.2.0.json`, launch from `control-plane/schindlerd/`. UART telemetry has
  `starved=`/`opix/frame=`; tune live via `L <n>`. `pgrep schindlerd` self-matches — check with
  `ps -eo args | grep schindlerd.py | grep -v grep`.
- **Progress only happens via launched builds** (background tasks re-invoke the agent); answering "status"
  without launching = no progress.

---

## 9. Open technical questions for the design (whichever path)

1. **DMA coalescing**: merge consecutive same-`ty` tiles into one burst at the `pg_tile_dma` issuer +
   per-tile fill split at the receive. How deep a run? Does the region-buffer fill want it row-major?
2. **Transpose contiguity (90/270)**: column-major second copy (2× DDR + a second `pg_raster_to_tile` pass)
   vs a single Morton/Z-order tile layout (both orientations semi-contiguous) vs accept strided + coalesce
   only the contiguous axis. Tradeoff: DDR, writer complexity, throughput.
2.b The throughput proof (`orient_throughput_proof.py`) assumed per-tile 768 B bursts sustain all
   orientations — the bench shows it does NOT in practice (command overhead + page-misses). Re-derive the
   real budget WITH coalescing before committing.
3. **Region buffer**: size for the worst fit-scale (90° fit s≈2.67 → output tile maps to ~43×43 src →
   ~4×4 tiles) + double-buffer; 4-bank for 1-cycle 2×2 bilinear gather. BRAM cost vs the dropped cache (44).
4. **Partial 1080 band** (67.5 tile-rows): pad source to 1088, or partial-band handling in writer/reader.
5. **Framing**: can `pg_tile_to_raster`'s band replace the line-FIFO entirely (SOF-early)? (Kills wrap + a
   module.)

---

## 10. EVALUATOR TASK

(See the prompt the requester will hand you.) You are to EVALUATE — not implement. Read this dossier +
`docs/CURRENT-STATE.md` + skim the `orient-integration` branch. Deliver a written assessment of **press-on
(A) vs clean-restart (B) vs hybrid (B')**, a recommendation with reasoning, the top risks of each, and any
holes in the spec/analysis (especially §9). Do not write engine code.
