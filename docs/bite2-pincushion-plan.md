# Bite 2 — Pincushion (Stage-2 radial warp)

Net-new non-linear address-gen. Builds on the Bite 1 two-stage substrate.

## Architecture
Pincushion is a radial distortion inserted as a Stage-2 step **between `pg_projective` (corner-pin,
output→sheet) and `pg_place_affine` (placement, sheet→LOD)** — mirroring how the placement stage was
added in Bite 1, in BOTH consumer and prefetch legs (equal latency → cache stays coherent).

```
output --(corner-pin⁻¹, pg_projective)--> sheet --(PINCUSHION, pg_pincushion)--> sheet'
       --(placement, pg_place_affine)--> LOD --(3-way bilinear)--> pixel
```

`pg_pincushion` displaces the sheet coord radially about the output centre `c=(out_w/2,out_h/2)`:
```
r2  = dx² + dy²              (dx=sx-cx, dy=sy-cy, in px)
g   = k_pin * r2             (signed, Q.FB)
s'  = s + (s-c)*g
```
`k_pin = round((amt/r2max)*2^40)` so `|displacement| = amt` at the corner (amt = pincushion fraction).
`k_pin>0` pushes edges OUT, `<0` pulls IN (barrel). `k_pin=0` → transparent → byte-for-byte Bite 1.

7-stage pen-gated feed-forward pipe (one DSP product registered raw per stage, no chained multiplies →
74.25 MHz). Unit-sim (`/tmp/xvlog_lint/tb_pin.v`) 6/6 PASS: transparent, centre, corner ±10%, mid, TL.

## Why sheet-space (after corner-pin), not output-space (before)
Under an IDENTITY corner-pin the sheet coord == the output coord, so this IS output-space pincushion —
the primary use (lens correction with no keystone). It also avoids restructuring pg_projective's DDA
(a far bigger change). **v1 limitation:** the corner-pin's BLACK exterior (sheet_in, tested in the
projective PRE-pincushion) is carried through unchanged → the black border does NOT itself bow when
pincushion + corner-pin are combined. The source AND its matte DO bow (LOD/matte bounds are re-tested
in pg_place_affine on the displaced coord). Bowing the black too = output-space pre-warp = a follow-up.

## Wiring
- `hdl/pg_pincushion.v` (new) + `pg_warp_engine.v` (u_pin_c / u_pin_p both legs, centre from out dims) +
  `pg_warp_top.v` (k_pin port + 2-FF CDC kp1/kp2) + XDC `kp1` false-path + `build_phase_b.tcl` file add.
- BD: projective build adds `axi_gpio_19` (signed 32-bit, default 0) on axi_ic_lite2 M06 (NUM_MI 6→7);
  affine build ties k_pin=0 via the existing `pl_zero` constant.
- FW: `warp_set_pincushion(amt_e3)` + `I <amt>` UART cmd (1/1000 signed; KPIN_BASE = axi_gpio_19).

## Bench runbook (±10% target; monitor = bench display, NOT MS2109)
1. REGRESSION: boot default `I 0` → clean passthrough, full frame (== Bite 1). Confirms k=0 transparent.
2. PINCUSHION dir: `I 100` (+10%) then `I -100` (barrel) → smooth radial bow, opposite directions,
   no tearing/scramble. Telemetry opix should stay 2073600 (±10% is in the proven-clean fetch zone).
3. Sweep `I 50` / `I 100` / `I 150` → find where it stays clean; expect ≥±10% clean, more may starve.
4. COMPOSE: centred placement shrink (red matte frame) + `I 100` → the source AND red matte frame bow
   together (proves pincushion warps the placed sheet incl. matte). Black corner-pin border (if added)
   stays straight (the v1 limitation).
5. Reset `I 0` → back to clean passthrough.
