# Projective front-end scope — keystone + corner-pin (homography)

**Goal:** extend the warp read-engine from *affine* (2×3) to *projective* (3×3 homography) so it can do
**keystone** and **corner-pin**, reusing the existing tile cache / DataMover / bilinear / output stages
unchanged. Prerequisite: the **consumer demand-fetch** (just landed) — projective foreshortening spreads
source coordinates harder than steep rotation, so the no-wedge guarantee is load-bearing here.

## 1. The math (what changes vs affine)

Affine today (`pg_affine`, 2 accumulators, no divide):
```
sx = a·ox + b·oy + c
sy = d·ox + e·oy + f
```
Projective (homography H = [[a,b,c],[d,e,f],[g,h,i]]):
```
w  = g·ox + h·oy + i          (= 1 for affine, where g=h=0)
sx = (a·ox + b·oy + c) / w
sy = (d·ox + e·oy + f) / w
```
Numerators and denominator are **all linear in (ox,oy)** → all three stay incremental DDAs (the cheap part).
The **only new operation is the per-pixel divide** (or reciprocal-multiply). Affine is the exact subset
g=h=0, i=1, so one projective engine subsumes affine — no separate rotation/affine path.

Keystone is a *constrained* corner-pin (symmetric H/V trapezoid). Same HDL; the firmware derives the 4
corners from the keystone amounts. So: **build the homography engine once, expose both UX layers in
firmware/GUI.**

## 2. HDL — `pg_projective` (drop-in replacement for `pg_affine`)

Same port interface as `pg_affine` (o_valid/o_ready, o_src_col/row, o_h_frac/v_frac, o_in_window, o_new_row)
so it drops into `pg_warp_engine` for BOTH instances (consumer + prefetch) with no cache/DMA/bilinear change.

Internals:
- **3 incremental accumulators** nx, ny, w (was 2): per-pixel += {a,d,g}; per-row reset to {b,e,h}·oy + {c,f,i}.
- **Reciprocal** iw = 1/w — one pipelined unit per instance (consumer + prefetch = 2 total).
- **2 DSP multiplies** per instance: sx = nx·iw, sy = ny·iw → split to int (src_col/row) + frac.
- Parameterize `PROJECTIVE` (0 = affine, divide elided; 1 = projective) so the production affine build is
  byte-for-byte unchanged and only the projective build pays the divide.

Reciprocal options (decide in P1):
1. **Xilinx Divider Generator** (LogiCORE, radix-2, fully pipelined, 1/clk). Easiest to integrate + validate.
   Latency ~width cycles — *hidden by the prefetch lead*, so latency is free; throughput stays 1 px/clk.
2. **LUT + Newton-Raphson** (coarse 1/w from a LUT on w's top bits, 1 NR step = 2 mults). Lower latency,
   fewer cells, more control — the area/timing-optimal choice if the IP path is tight.
   → Start with (1) for correctness, fall back to (2) only if timing/area demands.

Precision / Q-format (a P1 design task):
- Normalize H so i = 1.0; firmware guarantees a **valid (convex, in-front) quad → w > 0 across the frame**,
  so no div-by-zero / horizon crossing in-frame. HDL still clamps w to a small ε as a guard → matte.
- Need ~12 frac bits of sub-pixel accuracy on sx/sy at the far (foreshortened) edge. Budget the
  reciprocal mantissa + product widths against a Python golden before committing widths.

## 3. Coefficients path (BD + GPIO)

Affine uses 6 values over axi_gpio_8/9/10 (3 dual GPIOs). Projective needs **g, h** too (i = 1 fixed, or
normalized in firmware) → **+1 dual GPIO** (one new axi_gpio for {g, h}). Wire to two new `pg_warp_top`
inputs `m_g, m_h`. Coeffs latch atomically at sof via the existing coeff-CDC; the geometry-change
**soft-reset** (already in) covers the projective transitions too.

## 4. Firmware

- **Homography solver**: given 4 output-corner → source-corner correspondences, solve the 3×3 inverse-map H
  (output→source, since the engine inverse-maps). Standard 8×8 / DLT solve, or the closed-form 4-point
  formula. Fixed-point or float-then-quantize on the on-device CPU (one-time per geometry change — cheap,
  like the gamma curve compute).
- `warp_set_cornerpin(x0,y0,…,x3,y3)` → solve H → write a,b,c,d,e,f,g,h.
- `warp_set_keystone(h_amt, v_amt)` → derive the 4 corners → call cornerpin.
- UART: `C` (corner-pin, 8 args) and `K <h> <v>` (keystone). Daemon `warp.set` extended with
  corner/keystone params; GUI gets a keystone H/V pair + a corner-drag (later).

## 5. Build + bench

- Timing is the wildcard: the reciprocal + 2 mults/instance add to the WNS-critical cache+coord cone.
  Mitigate: deep-pipeline the divide, force the mults onto DSP48, false-path the new coeff CDCs (same trap
  as lr1/dsel1/sr1 — every GPIO→pclk crossing MUST be false-pathed). The 7020 has DSP headroom (+6 DSP).
- Bench: keystone H/V sweep, then a 4-corner pin. Demand-fetch guarantees a picture (no wedge) even at
  extreme foreshortening; underrun on the most-foreshortened edge is the perf tail (per-region lead later).

## 6. Phasing & sequencing

| Phase | Work | Output |
|------|------|--------|
| **P1** | `pg_projective` HDL + reciprocal + Python golden, bit-exact sim | coord generator proven |
| **P2** | Integrate into `pg_warp_engine` (param), faithful-TB keystone/corner-pin → must COMPLETE (demand-fetch) + bit-exact | engine proven in sim |
| **P3** | BD/GPIO: +1 dual GPIO {g,h}, wire m_g/m_h, false-paths | coeffs reach silicon |
| **P4** | Firmware homography solver + cornerpin/keystone + UART + daemon/GUI | operable |
| **P5** | Build (timing!) + bench keystone then corner-pin | shipped |

**Sequencing vs current work:** comes AFTER the in-progress 1080p30 + demand-fetch build is bench-validated
(demand-fetch is the hard prerequisite; 1080 proves the datapath). Then P1→P5. Mesh/lens warp (non-linear)
is a later, separate front-end on the same backend — not in this scope.

**Prior art:** `tools/affine_tilecache_gate.py` + `docs/affine-warp-gate-results.md` (2026-06-06) already
validated keystone/pincushion are real-time on the 7020 with this tile-cache (<700 MB/s). This scope is the
HDL realization of that gate.
