# Phase D — Execution plan (deviations from the spec doc)

Companion to `si5351_phase_d_pullability.md` — that doc defines the goal and pass criteria. This doc records how I'm actually running it and why.

## Deviations from the spec

### 1. Branch: stay on `phase-g-iter1`, don't merge first

Spec doc references `phase-e1-pll-spike @ 35d41ef`, but commit `35d41ef` is on `phase-g-iter1` (where Phase A–C-lite shipped). The Si5351 driver, BD edits for `clk_wiz_si5351`, XDC for `si5351_clkin`, and external pull-ups all live on `phase-g-iter1`.

Phase D needs both Si5351 driver AND a frequency-measurement mechanism. The spec doc assumed `vsync_timestamp.v` from `phase-e1-pll-spike` would do measurement, but using it requires routing VTC TX off `clk_wiz_si5351` instead of `clk_wiz_pixclk_out` — a more invasive BD change than just adding a dedicated frequency counter.

**Decision:** stay on `phase-g-iter1`. Add a dedicated HW frequency counter module instead of porting/merging `vsync_timestamp`. Merge forward into the loop branch happens at Phase E.

### 2. Measurement: dedicated HW counter, not vsync edges

Spec doc Step 2 suggests "Divide the Si5351 output clock through clk_wiz_si5351 → VTC TX → vsync timestamp". That requires re-routing VTC TX's clock source (currently `clk_wiz_pixclk_out` for the 720p path).

**Decision:** add `hdl/si5351_freq_counter.v` — small CDC-safe counter:
- Free-running 32-bit counter in `si5351_clkin` domain
- Sample-on-tick crossing into FCLK_CLK0 domain (1 Hz tick, Gray-coded sync)
- Output to a new `axi_gpio_3` so firmware can poll

Each sample is the integer count of si5351_clkin edges in one second of FCLK_CLK0. Subtract two consecutive samples → edges-per-second = frequency. Compare to nominal (25_000_000) → ppm.

Resolution math: 1-second window, 25 MHz clock → ±1 count = ±0.04 ppm. Sub-ppm precision, well below the spec's 1 ppm residual criterion.

The catch: FCLK_CLK0 itself has ~50 ppm tolerance (Zynq PS PLL), and that bias affects the *measured* nominal. Same caveat as the spec doc's §9 watch-item — intercept reads as informational unless cross-checked with a calibrated counter; **slope and residuals are clean** because they're relative.

### 3. OUT_DIV_DENOM: c = 1,000,000

Per my review of the spec doc — using `c = 1,048,576 = 2^20` is invalid (Si5351 c max is `2^20 - 1 = 1,048,575`). I'll use `c = 1,000,000` for clean ppm arithmetic. Resolution loss is negligible (~0.05% of theoretical max precision).

### 4. Frequency-change approach: full recompute, not delta-trim

Spec doc suggests adjusting the MS0 fractional component, keeping PLLA fixed. That works but has a discontinuity at zero offset (a=24 for one direction, a=23 for the other).

**Decision:** I'll write `si5351_set_freq_hz(u32 target_hz)` that recomputes BOTH PLLA and MS0 from scratch for any target frequency. Etherkit-style: pick PLLA multiplier to keep VCO in 600–900 MHz range, then MS0 = PLLA_freq / target.

For Phase D's sweep, firmware computes `target_hz = 25_000_000 + 25 × ppm` and calls `si5351_set_freq_hz(target_hz)`. No discontinuity, simpler code, sets up cleanly for Phase E where the loop controller calls this same function.

### 5. Two-stage execution

Spec doc estimates 110 min total. My realistic estimate for everything in one go: 3–4 hours. To bound risk and produce shippable artifacts at each stage:

- **Stage 1 (this session):** firmware `si5351_set_freq_hz` + UART `f <ppm>` command + scope-based verification that the chip moves frequency in the right direction with the right approximate magnitude. ~90 min. Smoke test, not pass/fail.
- **Stage 2 (next session):** HDL frequency counter + BD edits + axi_gpio_3 + firmware counter readback + precision ppm sweep + linear fit + pass/fail against strict criteria. ~2 hours.

Stage 1 alone is enough to know if `si5351_set_freq_hz` is fundamentally correct (right direction, right magnitude to a scope's resolution). Stage 2 hardens that into the spec doc's strict pass criteria.

If Stage 1 reveals a math error, Stage 2 doesn't need to happen until the math is fixed — saves a Vivado rebuild on broken firmware.

## Pass criteria (unchanged from spec doc §5)

After Stage 2 completes, the sweep must satisfy:
- Slope within 1% of 1.0 (0.99 ≤ slope ≤ 1.01)
- |intercept| ≤ 5 ppm (informational note: ±50 ppm FCLK_CLK0 bias may dominate; cross-check with counter if available)
- R² ≥ 0.999
- Max residual ≤ ±1 ppm across all 11 sweep points (−50, −40, ..., +50)

## Watch items (unchanged from spec doc §9)

- PLL_RESET after every divider write — non-negotiable
- Fractional mode forced (MS_INT bit cleared on reg 16 after re-config)
- Thermal drift if board has been cold — 5 min warm-up before sweep

## Stage 1 implementation outline

Files touched this stage:
- `sw/phase-b/src/si5351.h` — add `si5351_set_freq_hz` prototype
- `sw/phase-b/src/si5351.c` — implement Etherkit-style PLL+MS computation, PLL_RESET, output enable preserved
- `sw/phase-b/src/main.c` — UART command parser for `f <signed_ppm>`

Smoke test (no BD change, no Vivado rebuild needed):
1. Boot board with new firmware
2. UART confirms `Si5351 init OK at 25 MHz`
3. UART command `f +1000` → Si5351 output should jump to ~25.025 MHz on scope
4. UART command `f -1000` → ~24.975 MHz on scope
5. UART command `f 0` → back to 25.000 MHz
6. Verify clean transitions (no missing cycles, scope frequency reading transitions cleanly)

If all three commands move the output in the right direction and approximate magnitude, Stage 1 PASS — proceed to Stage 2.
