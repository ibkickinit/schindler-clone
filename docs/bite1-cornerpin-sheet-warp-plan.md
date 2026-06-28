# Bite 1 — Corner-pin warps the whole output sheet (two-stage warp restructure)

Status: IN PROGRESS 2026-06-26. New module hdl/pg_place_affine.v created. Vetted by Plan agent.

## Model
output(ox,oy) → [corner-pin homography in pg_projective] → SHEET(xs,ys) →
[placement affine in pg_place_affine] → LOD(xl,yl). 3-way: off-sheet=BLACK,
on-sheet/off-content=GRAY MATTE (runtime color), on-content=sample. ONE reciprocal
(reuse the projective divide; place affine on already-divided sheet coords = no 2nd divide).

## Steps (file:line in the agent plan; execute in order)
1. [DONE] hdl/pg_place_affine.v — new placement module (2-stage, pen-gated, FB=20).
2. hdl/pg_projective.v: o_in_window → SHEET bounds (outw_eff/outh_eff), BOTH gen branches
   (~line 80 affine, ~307 proj). Add outputs o_sheet_x/o_sheet_y = full-Q sheet coord
   (sx_q proj line ~303, ax affine line ~73). Keeps o_src_col path for golden parity.
3. hdl/pg_warp_engine.v: instantiate pg_place_affine after u_aff_c AND u_aff_p; widen
   u_skid_c W=49→50 (add lod_in bit); prefetch skid keeps W=25 but its bit = (sheet_in&&lod_in)
   fetch-gate; tilecache: c_inwin=lod_in, add out_offsheet sideband (carry sheet_in); bilinear
   3-way mux (h_offsheet?black : h_in?lerp:matte).
4. hdl/pg_warp_top.v: add placement coeff ports pa..pf (NOT a2..f2 — name collision w/ existing
   2nd-stage sync regs line 109); CDC pa1/pa2.. mirror a1/a2; thread to engine→both place insts.
   matte already CDC'd (mt1/mt2).
5. tcl/readengine_warp_bd.tcl: replace xlconstant warp_matte (70-71,182) with axi_gpio_15 (24b)
   on axi_ic_lite2 M02. Add axi_gpio_16/17/18 (placement a2..f2) on axi_ic_lite2 M03/M04/M05
   (bump NUM_MI 2→6). Defaults: placement identity (a2=e2=0x00100000 @FB20, rest 0); matte 0x101010.
6. constraints/zybo_z7_20_phase_b.xdc: 6 false-paths for pa1..pf1 q1 regs (mirror inw_q1/lr1).
   (matte mt1 already false-pathed.)
7. tcl/build_phase_b.tcl: add pg_place_affine.v to file list (~line 72).
8. sw/phase-b/src/main.c: warp_set_rotation/apply_scale → write PLACEMENT GPIOs (scale+rot+center,
   Q.20); corner-pin/keystone → projective GPIOs (output→sheet pin). Identity corner-pin =
   m_a=m_e=2^20 rest 0. Matte color cmd 'T r g b' (R-B-G pack). Boot = clean passthrough.

## Test (1 build, UART steps): passthrough → T(matte color) → C(black exterior) → W(placement) → compose.
## Risk: WNS +0.12 tight; contingency = 3-stage place pipe. Stale warp TBs → elaboration + scaler_top_tb only.

---
## IMPLEMENTATION COMPLETE (2026-06-26)

All 8 steps done. Build = `run_decimate_1080_build.sh` (WARP_ENGINE=1 PROJECTIVE_BUILD=1
SCALER_MODULE=scaler_top RASTER_TO_TILE=0 OUTPUT_MODE=1080p30). Verified pre-build:
- xvlog/xelab elaborate clean (PROJECTIVE=0 and =1), only pre-existing pf_cnt[6:0] telemetry warn.
- pg_place_affine unit sim (/tmp/xvlog_lint/tb_place.v): 5/5 PASS — identity, off-content matte,
  off-sheet black, 0.5x scale, +translate. Math + both bounds bits + 3-way sideband all correct.
- BD validate_bd_design PASS (placement+matte GPIOs on axi_ic_lite2 M02-M05, NUM_MI 2->6).

### Two-stage model as built
- m_a..m_h = CORNER-PIN (output->sheet, the OUT_RASTER canvas). Boot = identity.
- pa..pf     = PLACEMENT (sheet->LOD). Rotation/scale/pan (warp_set_rotation) now write THESE.
- 3-way bilinear: off-sheet -> BLACK; on-sheet/off-content -> MATTE (runtime colour); else sample.
- Composite at boot (identity corner-pin ∘ placement) == old single-stage output->LOD -> passthrough.

### Bench runbook (1 build, UART /dev/ttyUSB1 @115200, monitor = bench display NOT MS2109)
Kill daemon FIRST (separate cmd), then program bitstream+ELF (build FW already in run script).
1. PASSTHROUGH: boot default. Expect full clean source filling 1080p output (composite identity).
2. MATTE COLOUR:  `T 255 0 0` (red), `T 0 80 0`, `T 16 16 16` (back to gray). Only visible once a
   region is off-content (do step 4 first if whole frame is covered) — or shrink placement.
3. BLACK EXTERIOR: corner-pin shrink, e.g. `C 240 135 1680 135 1680 945 240 945` (sheet quad inset
   ~12.5%). Output OUTSIDE the quad must be BLACK; inside shows the (still-full) source warped to
   the quad. This proves corner-pin warps the whole sheet incl. exterior=black.
4. PLACEMENT: `W 0 200 200` (zoom 0.5x via inv-scale) or `Z 50` -> source shrinks WITHIN the sheet,
   gray MATTE fills around it (on-sheet/off-content). `T` colour now clearly visible.
5. COMPOSE: do 4 then 3 -> placed+matted source, whole sheet then corner-pinned, black exterior.

### Open / watch
- Timing: prior substrate WNS +0.12 was tight; place stage adds DSPs+regs. If WNS<0 or wedge,
  contingency = split place into 3 stages OR phys_opt (already in flow). Check build WNS.
- Lead interaction: corner-pin (C/K) sets lead from its quad; placement (W) sets its own. With a
  downscaling placement + shrinking corner-pin both deep, leads may fight -> revisit in compose.
- Rotation cache resonance unchanged (10deg clamp still applies to placement rotation).
