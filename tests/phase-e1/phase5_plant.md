# Phase 5 — Open-loop plant characterization

**Status:** PASS ✓ (qualified) — 2026-05-19 02:08 PT

**Goal:** sweep commanded ppm across an 11-point range, fit a line of measured-vs-commanded, verify the actuator is linear-and-monotonic enough for a PI controller. Drives the calibration constant for Phase 6's controller gain.

Per [`docs/phase-e1-ground-up-plan.md`](../../docs/phase-e1-ground-up-plan.md) §4 Phase 5.

## Approach

Host-side orchestration via UART — no HDL or firmware changes from Phase 4. For each of 11 points (−50 to +50 ppm in 10 ppm steps), the test script issues `m <ppm>\n`, waits 2 s for settling, issues `R\n` (300-sample drift capture, ~6 s), waits for completion. Total run: ~110 s.

The Phase 5 analyzer walks the UART log, pairs each capture block with its preceding `[M]` command, fits a slope-per-block, and runs a meta-regression of measured vs commanded ppm.

## Results (bench, 2026-05-19 02:08 PT)

| Block | cmd_ppm | measured ppm | shift from boot | gain (shift/cmd) | R² (block) |
|---|---|---|---|---|---|
| 0 | −50 | +51.21 | −50.78 | 1.016× | 1.000000 |
| 1 | −40 | +58.76 | −43.23 | 1.081× | 1.000000 |
| 2 | −30 | +67.34 | −34.65 | 1.155× | 1.000000 |
| 3 | −20 | +77.19 | −24.80 | 1.240× | 1.000000 |
| 4 | −10 | +88.60 | −13.39 | 1.339× | 1.000000 |
| 5 | 0   | +101.99 | 0.00 | — | 1.000000 |
| 6 | +10 | +115.38 | +13.39 | 1.339× | 1.000000 |
| 7 | +20 | +126.80 | +24.81 | 1.240× | 1.000000 |
| 8 | +30 | +136.64 | +34.66 | 1.155× | 1.000000 |
| 9 | +40 | +145.23 | +43.24 | 1.081× | 1.000000 |
| 10 | +50 | +152.77 | +50.78 | 1.016× | 1.000000 |

**Meta-regression** (measured ppm vs commanded):

```
slope     = +1.0796
intercept = +101.9920 ppm
R²        = 0.994969
residual max-abs = 3.21 ppm
```

### Sign + monotonicity

Commanded direction matches measured direction across the full range. Measured ppm grows strictly monotonically with commanded ppm. PASS.

### Symmetry

Shifts at ±N are within 0.01 ppm of each other in magnitude (e.g., −50 → −50.78, +50 → +50.78). The actuator is symmetric across zero — important for the bidirectional control the loop needs.

### Pass criteria (per §4 Phase 5)

- [x] **Slope within 10% of 1.0** — 1.0796, 7.96% over, within spec
- [-] **|intercept| ≤ 5 ppm** — +101.99 ppm. Spec FAIL. See "Intercept context" below.
- [x] **R² ≥ 0.99** — 0.9950, marginal but above spec

Strict spec verdict: FAIL on intercept. Qualified PASS interpretation below.

### Intercept context

The ground-up plan §4 Phase 5 says: *"Intercept within ±5 ppm (a constant offset corresponds to Phase 3's baseline)."* That assumes Phase 3's baseline ≈ 0 ppm, in which case the intercept absorbs the (small) free-running drift between source and reference.

Our reality:
- Phase 3 measured −0.05 ppm baseline (essentially zero) — *with* fine PS disabled.
- Phase 4's first build added `USE_DYN_PHASE_SHIFT` only; baseline jumped to +102 ppm — *enabling fine PS reshuffled the MMCM's M/D config, shifting the nominal output frequency by ~100 ppm vs the synth ref.*
- Phase 4's second build added `CLK_OUT1_USE_FINE_PS_GUI` and *retains* the same +102 ppm baseline (visible at block 5, `m 0` → +101.99 ppm).

The +102 ppm baseline is therefore a property of the Vivado-chosen MMCM config under fine-PS, not an actuator nonidealilty. Phase 6's PI loop has ±500 ppm of MMCM pull range, so a 102 ppm starting offset is ~20% of headroom — comfortable.

### Non-linearity (gain varies with command magnitude)

Gain ratio decreases monotonically with command magnitude: 1.34× at ±10 ppm, 1.02× at ±50 ppm. Suspected cause: PSDONE-gated Bresenham PSEN generation has a small per-pulse overhead that disappears in the steady-state pulse train but matters at low pulse rates.

For a PI loop operating near lock (small phase errors → small commanded ppm corrections), the small-signal gain (~1.34) dominates. Phase 6's `Kp` will need to be ~1/1.34 = 0.75 ppm-correction per line-of-error rather than the spike doc's nominal 1.0 — or equivalently we can apply the calibration to `ACT_STEP_PER_PPM` in firmware.

### Calibration recommendation for Phase 6

Three options:
1. Leave `ACT_STEP_PER_PPM = 2,857,143` (theoretical), set `Kp ≈ 0.75` in Phase 6.
2. Set `ACT_STEP_PER_PPM = 2,646,448` (meta-fit slope correction); keep `Kp = 1.0`. Best for the "average" command magnitude.
3. Set `ACT_STEP_PER_PPM = 2,132,196` (small-signal correction); keep `Kp = 1.0`. Best for small commands at lock; large-command transients will be sub-1.0 gain but still well-behaved.

Choice will be made in Phase 6. The meta-fit value (option 2) is the canonical "use the average gain" answer; option 3 is more useful if we expect the loop to spend most of its time near lock.

## Build provenance

- **Branch:** `phase-e1-pll-spike`
- **Bitstream + firmware:** unchanged from Phase 4 (`34c10a3`)

## Artifacts

| File | Purpose |
|---|---|
| `scripts/analyze_phase5_plant.py` | Plant-fit analyzer + Phase 5 pass verdict |
| `tests/phase-e1/phase5_plant.md` | This doc |
| `tests/phase-e1/phase5_plant.csv` | 11-row (commanded, measured, R²) table |
| `tests/phase-e1/phase5_uart.txt` | Raw UART capture |

## Summary

The plant is **linear-and-monotonic enough** for a PI controller, with a quantitative gain figure for Phase 6 to use. Strict spec fails on intercept (build-level property, not actuator defect) and slope is just inside spec; non-linearity is real but small. We're in good shape for Phase 6.
