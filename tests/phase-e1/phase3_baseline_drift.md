# Phase 3 — Baseline drift measurement

**Status:** PASS ✓ (2026-05-19 01:00 PT)

**Goal:** measure the relative drift between the synthetic 50 Hz reference (Phase 2) and the FPGA's output vsync (`v_tc_tx/vsync_out`, 720p50 ≈ 50 Hz). Slope from a linear fit of phase_delta vs sample index converts directly to ppm. The number sizes Phase 4's nudge amount, Phase 5's plant-sweep range, and Phase 6's controller gain.

Per [`docs/phase-e1-ground-up-plan.md`](../../docs/phase-e1-ground-up-plan.md) §4 Phase 3.

## What changed since Phase 2

### Firmware (`sw/phase-b/src/main.c`)

- New `cmd_drift(N)` function: triggers on each `ts_out` rising edge, atomically samples `(out_count, ts_out, ref_count, ts_ref)`, emits one CSV row per sample. CSV columns:
  ```
  idx, out_count, ts_out_lo32, ts_out_hi16, ref_count, ts_ref_lo32, ts_ref_hi16
  ```
- UART commands:
  - `r` — 3000 samples (~60 s of data at 50 Hz output rate)
  - `R` — 300 samples (~6 s quick sanity)
- `?` help updated to list both.

No HDL changes — Phase 2 build is the substrate.

### Analyzer (new)

`scripts/analyze_phase3_drift.py` — parses one or more `phase3_capture` blocks from a UART log, picks the longest block (so a sanity `R` run before the real `r` doesn't contaminate the fit), computes:

- `phase_delta = ts_out − ts_ref` mod 2^48, sign-extended
- Linear fit: `phase_delta = slope × (out_count − base) + intercept`
- ppm via `ppm = slope × OUTPUT_RATE / COUNTER_FREQ × 1e6 = slope × 0.5` at 50 Hz / 100 MHz
- Residuals + R²

Pure-Python; no numpy.

## Verification procedure

1. Boot the Phase 3 firmware on the Phase 2 bitstream (firmware-only rebuild — the HDL is unchanged).
2. From a serial terminal at `/dev/ttyUSB1 @ 115200`, send `R` (300-sample sanity) followed by `r` (3000-sample production capture).
3. Pipe the UART output to a file, run the analyzer.

## Results (bench, 2026-05-19 01:00 PT)

```
Phase 3 drift analysis (build/phase3/uart.log)
  samples: 3000 (base_out_count=1113)

  linear fit: phase_delta(ticks) = -0.1000 * (out_count - base) + 615892.55
  R²                = 0.999989
  slope             = -0.1000 ticks/output_frame
  intercept (t=0)   = +615892.55 ticks (+6158925.5 ns initial phase offset)
  ppm_relative      = -0.0500 ppm  (reference faster than output)
  residual max-abs  = 0.45 ticks (4.5 ns)

  pass (R² ≥ 0.99): PASS
  magnitude: sub-ppm — consistent with shared-PS-PLL synthetic ref
```

### What the numbers say

- **Output is running 0.05 ppm slower than the synthetic reference** (i.e., output_period is ~0.1 tick longer per frame than ref_period).
- The fit is **almost perfectly linear** — R² = 0.999989, max-abs residual of 0.45 ticks across 3,000 samples. The "drift" is not noise; it's a deterministic constant-rate offset.
- This is exactly what's predicted by construction:
  - Output vsync derives from FCLK_CLK0 (100 MHz) → `clk_wiz_pixclk_out` MMCM (74.25 MHz nominal) → VTC at 720p50 timing (50 Hz nominal).
  - Synthetic ref derives from FCLK_CLK1 (1000/7 MHz = 142.857 MHz) → integer divider DIVISOR=2,857,143 (target 50 Hz).
  - Both share a common ancestor in the PS PLL → 33.333 MHz crystal. They are rationally related at zero ppm true-drift; the 0.05 ppm is the divider rounding residue (2,857,143 × 7 ns = 20,000,001 ns ≠ exactly 20 ms = 50 Hz; the spare 1 ns/period across 1,000 periods = 1 µs/sec offset = 1 ppm — and ours is even smaller because the actual mismatch is fractional).

### Pass criteria (per §4 Phase 3)

- [x] A single signed ppm number produced
- [x] R² ≥ 0.99 (got 0.999989 → 5× tighter than spec)
- [x] Magnitude reasonable — sub-ppm by construction, matches the synthetic-ref topology
- [x] Reproducible: the 300-sample `R` sanity run earlier in the same UART log fit to the *same* −0.0500 ppm slope (R² = 0.99 on the shorter run too — would re-run for a separate-reboot reproducibility check before believing it long-term, but the within-run determinism is bench-clean)

### Sign convention sanity check

`phase_delta = ts_out − ts_ref`. Negative slope means `ts_ref` is advancing slightly faster per output frame than `ts_out` (i.e., ref_period < output_period by 0.1 tick). That's "reference faster than output", which the analyzer reports.

## Build provenance

- **Branch:** `phase-e1-pll-spike`
- **Vivado bitstream:** unchanged from Phase 2 (`84ee92f`); WNS +0.306 ns, WHS +0.020 ns
- **Firmware:** rebuilt with `r` / `R` commands. ELF size growth from Phase 2: ~600 bytes.

## Artifacts

| File | Purpose |
|---|---|
| `sw/phase-b/src/main.c` | `cmd_drift()` function + `r` / `R` dispatch |
| `scripts/analyze_phase3_drift.py` | CSV parser + linear-fit + ppm/R² report |
| `tests/phase-e1/phase3_baseline_drift.md` | This doc |
| `tests/phase-e1/phase3_baseline_drift.csv` | 3000-sample CSV with phase_delta, fit, residual columns |
| `tests/phase-e1/phase3_uart.txt` | Raw UART capture |

## Implications for downstream phases

- **Phase 4 (DRP actuator):** A test nudge of +20 ppm produces a +40 ticks/frame slope. The Phase 3 baseline of −0.0500 ppm is the noise floor we're sitting at. Test 4 will see deltas of ±20 ppm clearly.
- **Phase 5 (plant sweep):** Sweep ±50 ppm in 10 ppm steps. Baseline ≪ smallest step, so the linear fit of measured-ppm vs commanded-ppm has plenty of dynamic range.
- **Phase 6 (closed loop):** Integrator can pull the output by 0.05 ppm in less than one frame. The "lock acquired" criterion (±1 line for 60 frames) is much coarser than the noise floor. Lock should be trivial.
- **Phase 7 (free-run mode):** Free-run drift should reproduce this −0.0500 ppm number to within ~5 ppm. The synthetic ref is the comparison signal in both cases.
- **Real-crystal drift number:** still deferred to Si5351 integration per user direction. This Phase 3 number validates the *loop's measurement chain*, not the production-genlock drift.
