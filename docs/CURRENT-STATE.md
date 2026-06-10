# Schindler 2.0 — CURRENT STATE (2026-06-10)

Single source of truth for where everything is. Supersedes scattered status. Read with
`docs/orient-engine-architecture.md`, `docs/warp-1080-and-roadmap.md`, `docs/build-manifest.md`.

---

## TL;DR

- **Production direction:** a **cardinal-orientation engine** (0/90/180/270 + scale + position),
  1080p60-capable. Arbitrary rotation (the "warp") is **TABLED** as a future feature.
- **The orient engine is fully DE-RISKED** (timing, throughput, function all proven) but **not yet
  integrated into a bitstream** — the remaining work is BD/DMA plumbing + bench iteration.
- **1080p60 *display* needs the TE0720** (Zybo HDMI serializer can't do 1485 MHz TMDS). Everything *up to
  the serializer* (engine logic @148.5 MHz + DDR throughput) is provable on the Zybo.

---

## Branches (git)

| Branch | What it is | State |
|--------|-----------|-------|
| `iter5-1080p-clean` | Production substrate: scaler/route-B path, color pipeline, gamma | Shipped, stable |
| `warp-demand-fetch-fsm` | Arbitrary-warp engine + demand-fetch FSM | **TABLED**, silicon-validated (below) |
| `warp-1080p30-plain` | 1080p30 + plain cache | Renders top-clean/bottom-torn (DMA wall) |
| **`orient-integration`** | **Production orient engine (CURRENT)** | HDL done+validated; BD integration WIP |

---

## A. Arbitrary warp (TABLED — do not invest further unless un-tabled)

`warp-demand-fetch-fsm`, silicon-validated 2026-06-09:
- **Gentle rotations (≤~45°): clean + stable**, full frame, no deadlock, no total-black wedge.
- **Steep angles (90/135/162): underrun to a sliver** then recover (the tile-DMA throughput wall — see C).
- **Specific angles (e.g. -60): set-hash resonance** → eviction → underrun (an arbitrary-angle problem the
  cardinal engine sidesteps entirely).
- Timing **+0.0029 ns @74.25 MHz** (marginal but functions; will NOT do 148.5 MHz — associative cache).
- GUI: rotation slider + Scale rerouted to the warp (`warp.set`), debounced.
- Root cause docs: the demand-fetch fixes correctness (deadlock), not bandwidth.

**Conclusion that drove the pivot:** arbitrary rotation on this cache is a per-angle-tuning rabbit hole; the
4 cardinal orientations are bounded, rock-solid by construction, and 1080p60-capable.

---

## B. Production orient engine (`orient-integration`) — the active work

**Spec:** 0/90/180/270 + zoom + pan, 1080p60-capable, rock-solid (no resonance/eviction/demand-fetch).

### B.1 Confidence — ALL THREE PILLARS PROVEN (data-backed)
1. **Throughput** (`tools/orient_throughput_proof.py`): tiled 768 B reads = **~1.1 GB/s** vs 373 (1:1) /
   746 (2× zoom-out) MB/s needs, for EVERY orientation incl. the 90/270 transpose. 3× headroom.
2. **Function**: bit-exact in sim — addressing golden (`orient_golden.py`), `pg_raster_to_tile`,
   `pg_tile_dma TILED`, and the **full engine + tiled backend** (`pg_warp_tiled_tb`: ident/rot20/**rot90**).
3. **Timing @148.5 MHz** (1080p60 clock, OOC synth+P&R on 7020-1): `pg_affine` **+1.832 ns**, `scaler_h`
   resample **+0.550 ns**. The only thing that ever failed 148.5 MHz was the warp associative cache, which
   the orient engine does NOT use.

### B.2 HDL status
| Module | Role | Status |
|--------|------|--------|
| `hdl/pg_raster_to_tile.v` | capture raster → tiled DDR (16-row band → 16×16 tiles), AXIS ifaces + SOF | ✅ sim PASS (512/512, sof@beat0) |
| `hdl/pg_tile_dma.v` (`TILED=1`) | 1 contiguous 768 B burst/tile (vs 16 strided 48 B) | ✅ sim PASS; TILED=0 legacy untouched |
| `hdl/pg_warp_top.v` (`TILED` param) | plumbs TILED → pg_tile_dma | ✅ |
| `hdl/pg_affine.v` | the addressing (= orient front-end, 4 orientations) | ✅ reused, +1.832 @148.5 |
| `hdl/pg_tilecache_rt2.v` | the cache (used at 720p) | ⚠️ won't do 148.5 MHz — see B.4 |

### B.3 REMAINING — BD integration → first bench test
The HDL composes (proven in sim). What's left is build-out, all on `orient-integration`:
1. **Splice `pg_raster_to_tile` into the capture path** — `build_phase_b.tcl:380` is
   `scaler_0/m_axis → axi_vdma_0/S_AXIS_S2MM`; insert the writer between them. Ports are AXIS now.
2. **Reconfigure the S2MM geometry for the tiled write** — `sw/phase-b/src/main.c:115-117`
   (`cfg.HoriSizeInput/VertSizeInput/Stride`). Tiled: **HSIZE=768, VSIZE=tiles/frame, STRIDE=768**
   (720p: 80×45=3600 tiles; 1080p: 120×68=8160). Read `frame_base` = the tiled frame base.
3. **Set `pg_re_0 CONFIG.TILED=1`** in `readengine_warp_bd.tcl`.
4. **Build 720p → bench.** Expect 1-2 debug iterations (AXIS framing into the VDMA, tiled-S2MM geometry,
   genlock pointer alignment). NOTE: 1080 has a partial last tile-row (1080/16=67.5) — start at 720p
   (clean multiples: 1280/16=80, 720/16=45).

### B.4 Known design note for the 1080p60-FINAL
The 720p integration above reuses the warp **associative cache** (`pg_tilecache_rt2`) — fine at 74.25 MHz,
but it will NOT close 148.5 MHz. For the **final 1080p60** build the orient engine should use a **simple
deterministic direct/band buffer** (the access is regular for the 4 orientations → no tag CAM, no eviction).
That buffer is NOT yet written. The 720p tiled build validates the full chain first; the direct buffer is
the last HDL piece for the p60-timing-final. (The per-pixel path it plugs into — affine + BRAM read +
resample — is already measured to close 148.5 MHz.)

---

## C. The tile-DMA throughput wall (now SOLVED by tiling)

Both the warp's steep-angle underrun AND the 1080 underrun were the **same wall**: `pg_tile_dma` legacy mode
reads 48 B strided tile-rows → page-miss every read → ~37% efficient (~200-343 MB/s) < 373 needed. The
**tiled-DDR fix** (B above) lifts it to ~1.1 GB/s. So tiling fixes orient, 1080, AND (if un-tabled) the warp.

---

## D. Hardware constraints

- **Zybo Z7-20 (-1)** is the bench. 720p60 / 1080p30 HDMI work. **1080p60 HDMI is BLOCKED** — rgb2dvi needs
  a 1485 MHz TMDS clock; the -1 MMCM VCO caps at 1200. Pure silicon.
- **TE0720** (-2, production target) for 1080p60 *output*. **Not on the bench.** Same RTL; swap the
  serializer. The engine logic @148.5 MHz + the DDR throughput are provable on the Zybo (clock the engine at
  148.5, output headless/at p30).

---

## E. Tools & docs
- `tools/orient_throughput_proof.py` — the 1080p60 throughput proof.
- `tools/orient_golden.py` — the orient addressing golden (= pg_affine restricted).
- `tools/warp_assoc_sweep.py`, `tools/warp_workingset.py` — cache associativity analysis.
- `docs/orient-engine-architecture.md` — the full engine design + the confidence section.
- `docs/warp-1080-and-roadmap.md` — the DMA-wall characterization + warp roadmap.
- `docs/projective-front-end-scope.md` — keystone/corner-pin (future, rides the same tiled backend).

## F. How progress actually happens (process note)
The assistant only runs on prompts — it does NOT work in the background between messages. To make multi-hour
progress, **launch builds as background tasks**: each completion notification re-invokes the assistant to
iterate/program. Answering "status" without launching a build = no progress. (Lesson from 2026-06-09/10.)

---

## G. HANDOFF FOR A NEW AGENT — exact state + runnable commands

**Git:** branch `orient-integration`, latest commit `a018dba`. ALL orient HDL/sim is committed and clean.
The only uncommitted tree changes are **Justin's KiCad RF-board WIP** (`KiCad/...`) and `control-plane/web/
index.html` (GUI rotation slider) + `clockInfo.txt` — **do NOT touch the KiCad files** (he edits them live;
branch checkouts are blocked by them — work on the isolated HDL/sim/tcl files only).

### G.1 Re-verify the 3 sims (all PASS today; ~30 s each)
```bash
cd ~/Dropbox/_PROJECTS/Schindler-2.0 && source /tools/Xilinx/2025.2/Vivado/settings64.sh
# 1) raster->tile writer (expect: collected=512/512 tiles_tlast=2 sof=1 errs=0 PASS)
W=sim/.v1; rm -rf $W; mkdir -p $W; cd $W; xvlog --nolog ../../hdl/pg_raster_to_tile.v ../../sim/pg_raster_to_tile_tb.v && xelab --nolog pg_raster_to_tile_tb -s t && xsim t -R --nolog | grep RASTER2TILE; cd ../..
# 2) tiled DMA (expect: 4 tiles 256/256, DMA_TILED: PASS)
W=sim/.v2; rm -rf $W; mkdir -p $W; cd $W; xvlog --nolog ../../hdl/pg_tile_dma.v ../../sim/pg_tile_dma_tiled_tb.v && xelab --nolog pg_tile_dma_tiled_tb -s t && xsim t -R --nolog | grep -E "tile\(|DMA_TILED"; cd ../..
# 3) FULL engine + tiled backend (expect: ident/rot20/rot90 all bit-err=0 PASS)
W=sim/.v3; rm -rf $W; mkdir -p $W; cd $W; xvlog --nolog ../../hdl/pg_affine.v ../../hdl/pg_skid.v ../../hdl/pg_tilecache_rt2.v ../../hdl/pg_tile_dma.v ../../hdl/pg_warp_engine.v ../../sim/pg_warp_tiled_tb.v && xelab --nolog pg_warp_tiled_tb -s t && xsim t -R --nolog | grep WARP_TILED; cd ../..
```

### G.2 Re-verify 148.5 MHz timing (OOC, ~5 min each)
```bash
# pg_affine -> expect WNS ~ +1.8 ns ; scaler_h -> expect ~ +0.55 ns. Period 6.734ns = 148.5MHz.
# (synth_design -mode out_of_context, create_clock -period 6.734, opt/place/route, report SLACK.
#  For scaler_h, read BOTH hdl/scaler_h.v AND hdl/scaler_coeffs_h.v.)
```

### G.3 The exact NEXT actions (BD integration → first 720p bench)
1. **`tcl/build_phase_b.tcl:380`** currently: `connect_bd_intf_net [get_bd_intf_pins scaler_0/m_axis]
   [get_bd_intf_pins axi_vdma_0/S_AXIS_S2MM]`. Replace with: create `pg_raster_to_tile` BD cell
   (`create_bd_cell -type module -reference pg_raster_to_tile r2t_0`, set CONFIG IN_W=1280 LTILE=4 for 720p),
   wire `scaler_0/m_axis → r2t_0/s_axis` and `r2t_0/m_axis → axi_vdma_0/S_AXIS_S2MM`, hook r2t_0 clk/rstn to
   the same pixel clock/reset scaler_0 uses. Gate behind an env (e.g. `ORIENT_TILED`) so non-tiled builds
   still work. NOTE the AXIS interface auto-infers from the s_axis_*/m_axis_* port names (already renamed).
2. **`sw/phase-b/src/main.c:115-117`** (S2MM cfg): for the tiled write set HSIZE=768, VSIZE=tiles/frame
   (720p: 80*45=3600), Stride=768. Read side (`pg_re_0`) frame_base = the tiled frame base (unchanged DDR
   slot; the frame is just tile-ordered). MM2S cfg at :130-132 stays output-raster (1280*3).
3. **`tcl/readengine_warp_bd.tcl`**: set `pg_re_0` (pg_warp_top) `CONFIG.TILED {1}`.
4. **Build** (background task — its completion notification re-invokes you): the warp build invocation is in
   the build manifest / prior `build_warp_*.log` commands; it runs `vivado -mode batch -source
   tcl/build_phase_b.tcl` with WARP_ENGINE + the env. Launch with `run_in_background: true`, then on the
   completion notification grep the log for `TIMING: WNS=` and `BUILD_EXIT` and the `.bit` path.
5. **Program + bench**: ping Justin (this IS a bench test). Verify on the MONITOR not the MS2109 (see memory
   `schindler_ms2109_verification_trap`). Confirm the Osee input first (memory `schindler_osee_switcher_topology`).

### G.4 Gotchas already paid for (don't re-discover)
- **`dm_ready` must reflect the DataMover's readiness (`!busy`)** in any tiled-DMA TB — always-1 makes
  pg_tile_dma think a command was accepted mid-stream → dropped tiles. (Cost ~1h on 2026-06-09.)
- **SOF to pg_warp_engine is a SINGLE-cycle pulse**; a 2-cycle pulse re-triggers the affine → duplicated
  pixel 0. The real engine (pg_warp_top) generates a 1-cycle pulse from vsync.
- **The `pg_tile_dma_tiled_tb` uses a MULTISET check** (order-independent) — it would NOT catch a fill-block
  ORDER bug. The full-engine `pg_warp_tiled_tb` (bit-exact) is the real guard; trust that one.
- **1080 has a partial last tile-row** (1080/16=67.5) — `pg_raster_to_tile` currently assumes full 16-row
  bands. Start at 720p (clean), add partial-band handling before 1080.
- **`pg_tilecache_rt2` (associative) will NOT close 148.5 MHz** — fine for the 720p validation build, but the
  1080p60-final needs the simple direct/band buffer (not yet written; see B.4).
- **Process:** launch builds as BACKGROUND tasks; the completion notification is what re-invokes the agent.
  Do not answer "status" and stop — nothing drives progress between prompts otherwise.

---

## H. BENCH FINDINGS 2026-06-10 (first tiled-orient build) — READ THIS

First tiled-orient bitstream (warp engine + pg_tile_dma TILED=1 + pg_raster_to_tile, NTILE=256/LEAD=2048
to fit BRAM) built clean (WNS +0.128) + ran on silicon. Bench results:

- **Tiled path WORKS at partial read:** 0/180 at 1:1 (a 1280x720 CENTER CROP = 3600 tiles) render clean.
- **Firmware affine had two real bugs (FIXED, firmware-only, committed):**
  1. NO fit-scale -> 90/270 (transpose) mapped the 1280-wide output across >1080 source rows = OFF-SCREEN.
     Fix: `warp_set_rotation` now fits the rotated source to the raster (cos==0 detects transpose; robust
     to the daemon's 270->-90 normalization). User invx/invy = scale ON TOP of fit.
  2. NO pan input -> Shift was a no-op. Fix: panx/pany param, wired firmware+daemon+GUI.
- **BUT the fit (full-frame read = 8160 tiles) STARVES the cache -> scrambled/torn output.** Telemetry:
  `opix/frame=910825 (exp 921600)`, `eol=711 (exp 720)`, **`starved=12107`**. LEAD sweep vs the starved
  counter: best is LEAD=12288 (starved 12107->7575, still torn); 16384+ FREEZES (eviction). **No LEAD
  eliminates starvation.** => the BRAM-shrunk associative cache CANNOT sustain the full-frame orient read.
  The 1:1 crop hid this (3600 vs 8160 tiles).

**CONCLUSION (data-backed): the warp associative cache is the wrong structure for the orient read.** The
production-final needs the DIRECT/STREAMING buffer: the orient access is SEQUENTIAL (row-major for 0/180,
column for 90/270), so read tiles in order into a small streaming buffer — no associative tags, no eviction,
no starvation, and far less BRAM than NTILE=512 (which doesn't even fit alongside r2t). This is THE next
build. The firmware fit+pan + the tiled capture/DMA all stay; only the cache module is replaced.

Bench tip learned: the daemon venv is `/tmp/schindlerd-venv/bin/python3` (ephemeral!), catalog is
`control-plane/catalog-v0.2.0.json`, launch from `control-plane/schindlerd/`. UART telemetry has `starved=`
/`opix/frame=` — tune live via `L <n>` and read the counter, no image needed.

---

## I. DIRECT ENGINE = OUTPUT-TILE PROCESSING (2026-06-10, decided)

BRAM is 100% full (140/140 tiles, impl util report). So the fix must REDUCE BRAM, not add. The associative
cache (44 BRAM @256) can't hold the ~300-tile full-frame working set, and there's no room to grow it.

**Architecture: process the OUTPUT in 16x16 tiles (not raster).** For each output tile, the affine gives the
source region -> fetch its 1-4 source tiles (tiny working set, ~2 BRAM) -> bilinear-resample -> emit the
output tile -> a tile->raster band reorders to raster for the VTC. No prefetch race, no eviction, no
starvation (deterministic per-tile fetch); ~30 BRAM total (output band + a few source tiles) vs the 44+ cache
-> FREES BRAM. Handles 0/90/180/270 (the in-tile transpose) + scale + pan, and the per-pixel path
(BRAM-read + bilinear) closes 148.5 MHz (already measured).

Pieces: [P1] pg_tile_to_raster (output band->raster; mirror of validated pg_raster_to_tile) [P2] output-tile
address-gen + source-tile fetch (reuse pg_affine + pg_tile_dma TILED) [P3] bilinear resample from the few
fetched tiles [P4] integrate, swap out the warp prefetch/cache/gather. Firmware fit+pan + tiled capture stay.

---

## J. BENCH 2026-06-10 PM — tile-order engine: working-set SOLVED, DMA throughput is the wall

Built+ran the tile-order engine (pg_affine_tile + pg_tile_to_raster, NTILE=64, NO_ILA, WNS +0.377).
- **WIN:** frame now COMPLETES — telemetry opix/frame=921600 (was 910825), eol=720 (was 711). The
  tile-order walk collapsed the working set so the tiny cache no longer starves on the WORKING SET.
- **REMAINING:** residual starved=33608 (constant across LEAD 256..3072 -> NOT a lead problem). It's a
  progressive DMA-THROUGHPUT shortfall: 0deg renders clean ~top-55%, then the DMA falls behind -> line-FIFO
  empties mid-line -> axis_to_vid_io advances -> line WRAPS (lateral shift) + bottom tears. 90/180/270 far
  worse (transpose -> source tiles STRIDED in DDR -> DMA even less efficient). Scale-smaller worst (most
  source area/output tile). Scale-bigger noisy. Pan ~works.
- ROOT: per-output-tile fetch of ~4-9 source tiles, each a separate 768B DataMover command; horizontal
  neighbors are CONTIGUOUS in tiled DDR but fetched as separate bursts, and vertical/transpose neighbors
  page-miss. Effective DMA throughput < the ~800 MB/s the fit demands.

**NEXT (the real fix): DMA read coalescing in pg_tile_dma** — merge a run of consecutive tiles (same ty,
tx..tx+k contiguous in DDR) into ONE burst (k*768 B) -> far fewer commands + page-opens -> throughput jumps.
For the transpose (90/270) the tiled-DDR layout strides; a column-major tile copy (or storing BOTH layouts)
makes those contiguous too. Also worth: bypass the line-FIFO and drive m_axis from pg_tile_to_raster's own
SOF/EOL (the band already buffers SOF-early) to remove any FIFO-regen contribution to the wrap.
Engine + reorder + tile-order walk are PROVEN (sim bit-exact, frame completes on silicon); this is the last
throughput layer.
