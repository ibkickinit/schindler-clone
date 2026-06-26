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
