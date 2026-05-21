# Si5351 Phase D — Open-loop pullability characterization

**Status:** OPEN — ready to execute once Phase C-lite is committed (`35d41ef`).
**Goal:** characterize Si5351 fractional-divider behavior under commanded ppm offsets. Produce a numeric plant-gain calibration that feeds into Phase E (closed-loop with Si5351 as actuator).

**Scope:** sweep commanded ppm across a range, measure achieved frequency offset via FPGA timestamp instrument, fit a line, declare pass/fail against strict criteria. This is the **Si5351 equivalent of sync spike Phase 5** (which characterized MMCM psincdec plant gain).

**Expected duration:** 90 minutes total — ~45 min firmware work + ~45 min bench measurement.

**Companion docs:**
- [`docs/si5351-bench-bringup.md`](../../docs/si5351-bench-bringup.md) — overall Si5351 bring-up plan; this is Phase D within it.
- [`phase5_plant.md`](phase5_plant.md) — sync spike Phase 5 (MMCM equivalent), for comparison.
- [`phase_e2_psincdec_limit.md`](phase_e2_psincdec_limit.md) — MMCM acceptance criteria table; Si5351 must beat MMCM's numbers strictly.

---

## 1. Context — why this phase matters

The sync spike's bench session 3 ([`phase_e2_psincdec_limit.md`](phase_e2_psincdec_limit.md)) concluded that **the MMCM psincdec actuator is insufficient for production** — `cmd_mppm=-500000` commanded but `ach_rate=+32 ppm` achieved (Hypothesis B confirmed). The production architecture requires Si5351 as the actuator.

Phase D doesn't yet close the loop. It answers the necessary prerequisite question: **does the Si5351's fractional divider deliver the commanded rate change cleanly?** If yes, Phase E can drop Si5351 into the existing PI loop with high confidence. If no, the Si5351 path also has limitations that need to be characterized before the spike can declare done.

Expected outcome: Si5351 dramatically outperforms MMCM. Numeric prediction in §6.

---

## 2. Pre-flight (15 min)

### State check

- [ ] Branch / commit: `phase-e1-pll-spike` at `35d41ef` (Phase C-lite passing) or later.
- [ ] Bench setup: Zybo + Si5351 breakout still wired per Phase C-lite. SMA from Si5351 CLK0 → Pmod JB Pin 7 (with GND on JB Pin 11).
- [ ] External pull-ups on SDA/SCL: confirmed in place (2.2 kΩ each per Phase C-lite lesson).
- [ ] LD3 lights when Phase C-lite firmware boots: confirms MMCM is locked to Si5351 CLK0.

### Gear

- [ ] Serial terminal on `/dev/ttyUSB1` (or platform equivalent), 115200 8N1.
- [ ] Scope or frequency counter (counter preferred for ppm-level claims).
- [ ] Notebook / scratch file for tabulating sweep results.

### One critical pre-check before Phase D coding starts

The Etherkit Si5351 library handles `PLL_RESET` automatically after divider writes. **If your `si5351.c` is hand-written from AN619 instead of ported from Etherkit, verify the PLL_RESET sequence is in place** before doing any Phase D sweep work:

- [ ] After every write to PLL feedback dividers or output multisynth dividers, the code must issue a write to register `0xB1` (PLL_RESET register) with the appropriate bit set (0x80 for PLLA, 0xA0 for PLLB).
- [ ] Without PLL_RESET, divider changes leave the PLL in an indeterminate state and outputs come up as wrong frequency / junk harmonics.

**If PLL_RESET is missing:** add it now. Phase D's sweep depends on every divider write actually taking effect; without PLL_RESET, the sweep results are meaningless.

---

## 3. Step 1 — Write `si5351_set_offset_ppm()` helper (30 min firmware)

### Goal

A firmware function with the signature:

```c
void si5351_set_offset_ppm(s32 ppm_offset);
```

That takes a signed ppm offset (positive = faster output, negative = slower) and writes the appropriate fractional divider values to the Si5351 to produce that offset relative to the nominal CLK0 frequency configured by Phase B/C-lite.

### Approach

Si5351 output frequency is:
```
f_out = f_xtal × ( PLL_MULT + PLL_NUM/PLL_DENOM ) / ( OUT_DIV_INT + OUT_DIV_NUM/OUT_DIV_DENOM )
```

To trim by ppm, the cleanest approach is to keep the PLL config fixed (PLL_MULT, PLL_NUM, PLL_DENOM) and adjust the **output multisynth fractional component** (OUT_DIV_NUM/OUT_DIV_DENOM). This gives sub-ppb resolution.

Specifically:
- Nominal: `f_out_nom = f_xtal × PLL_ratio / OUT_DIV_INT` (integer output divide, no fractional).
- Trimmed: `f_out = f_xtal × PLL_ratio / (OUT_DIV_INT + OUT_DIV_NUM/OUT_DIV_DENOM)`.
- For small offsets: `Δf/f ≈ -OUT_DIV_NUM/(OUT_DIV_DENOM × OUT_DIV_INT)`.

Pick OUT_DIV_DENOM = 1,000,000 (or 1,048,575 = 2^20 − 1, the Si5351 maximum) so that ppm offsets map cleanly to NUM values.

**Suggested implementation pattern (port from Etherkit or write from scratch):**

```c
void si5351_set_offset_ppm(s32 ppm_offset) {
    // Compute fractional divider for the desired offset
    // (math depends on nominal config from Phase B/C-lite)
    s32 num_offset = (s32)(((s64)ppm_offset * (s64)OUT_DIV_DENOM * (s64)OUT_DIV_INT) / 1000000);
    
    // Apply offset to base divider config
    u32 num = base_num + num_offset;  // base_num typically 0 at nominal
    
    // Pack into MS0_P1/P2/P3 registers (see AN619 §3.2 / Etherkit's si5351_set_freq)
    pack_and_write_multisynth(0, OUT_DIV_INT, num, OUT_DIV_DENOM);
    
    // !!! CRITICAL !!! Issue PLL reset
    // Si5351A has shared PLLA for multiple outputs; resetting PLL re-locks
    // the multisynth chain. Skip this and your offsets are silently wrong.
    si5351_write(REG_PLL_RESET, 0x80);  // PLLA reset
}
```

### UART command to expose it

Add a `f <signed_ppm>` command:

```
f +50     → set Si5351 offset = +50 ppm
f -30     → set Si5351 offset = -30 ppm
f 0       → return to nominal
```

UART output should echo what was set, plus a brief readback that confirms the register write took effect.

### Pass criterion for Step 1

- [ ] `si5351_set_offset_ppm(0)` returns to exactly nominal frequency.
- [ ] `si5351_set_offset_ppm(+50)` results in a measurable frequency change on the scope/counter at the Si5351's SMA output.
- [ ] No glitches in the output — the frequency change should be clean, no missing cycles or wrong frequencies during the transition.

If glitches happen, that's a missing-PLL-RESET signature; revisit step 2 of the pre-flight.

---

## 4. Step 2 — Sanity check at zero offset (10 min)

Before sweeping, verify the baseline is stable.

### Procedure

1. Boot board. LD3 lit (MMCM locked to Si5351 CLK0).
2. Send `f 0` to ensure baseline.
3. Run the existing FPGA timestamp instrument to measure the actual frequency at the FPGA pin. The existing infrastructure in [`hdl/vsync_timestamp.v`](../../hdl/vsync_timestamp.v) measures vsync edges; for a clock-rate measurement you'll need to either:
   - Divide the Si5351 output clock through clk_wiz_si5351 → VTC TX → use VTC TX's vsync edge as the timed signal (same approach as sync spike Phase 3 baseline drift measurement).
   - Or count Si5351 clock edges directly within a 100 MHz reference window via a small counter module (overkill for this phase — reuse VTC vsync path).

4. Capture 60 seconds of timestamp data. Compute the implied frequency.

### Pass criterion

- [ ] Frequency stable within ±5 ppm of nominal across the 60-second window.
- [ ] No drift trend in the time-series (slope < 1 ppm/min).

If drift is present, something is wrong with the baseline — possible causes: PLL_RESET sequence missing (Si5351 in wrong divider state at boot), or the Si5351's onboard 25 MHz crystal is unusually warm/cold and not at steady state.

---

## 5. Step 3 — The pullability sweep (30 min)

### Procedure

Sweep commanded ppm across **11 points**: `-50, -40, -30, -20, -10, 0, +10, +20, +30, +40, +50`. (Adjust range if Phase E's expected operating range is wider — but ±50 ppm is plenty for characterization.)

For each point:

1. Send `f <ppm>` via UART.
2. Wait 5 seconds for the PLL to settle (it's near-instant in practice, but be conservative).
3. Capture 30 seconds of timestamp data.
4. Compute the achieved frequency offset in ppm.
5. Record: commanded ppm, achieved ppm, achieved-minus-commanded residual.

Total time: 11 points × 35 seconds per point = ~7 minutes of bench time + setup.

### Pass criteria (strict — Si5351 must beat MMCM)

After fitting a line `achieved_ppm = slope × commanded_ppm + intercept`:

- [ ] **Slope within 1% of 1.0** — i.e., 0.99 ≤ slope ≤ 1.01. (MMCM was 1.0796 — 8% off. Si5351 fractional divider should be much closer to 1.0.)
- [ ] **|intercept| ≤ 5 ppm.** (MMCM was +102 ppm — that was the hardware-floor offset. Si5351 should be near 0 because it can hit the nominal frequency exactly.)
- [ ] **R² ≥ 0.999.** (MMCM was 0.9950. Si5351 should be ≥0.999, ideally 0.9999.)
- [ ] **Max residual ≤ ±1 ppm across all 11 points.** (MMCM was ~3.21 ppm.)

### If any of these fail

Don't proceed to Phase E. The Si5351 must produce a clean plant for the closed loop to work. Debug:

- **Slope off by more than 1%** → register-write math is wrong. Compare against Etherkit library reference implementation.
- **Intercept off by more than 5 ppm** → baseline (`f 0`) isn't actually at nominal. Re-check Phase B/C-lite divider config.
- **R² too low / residuals noisy** → measurement system noise dominates. Try longer per-point capture (60s instead of 30s), or use a frequency counter instead of FPGA timestamps for one or two points as a cross-check.
- **Non-monotonic behavior** → catastrophic — possible register write collision or PLL_RESET timing issue. Debug per-write timing.

---

## 6. Numeric prediction (what "clean Si5351" should look like)

For comparison against the actual measured data:

| Metric | MMCM (sync spike Phase 5) | Si5351 (Phase D target) |
|---|---|---|
| Slope | 1.0796 | **0.99–1.01** (within 1%) |
| Intercept | +102 ppm | **±5 ppm** |
| R² | 0.9950 | **≥0.999** |
| Max residual | 3.21 ppm | **≤±1 ppm** |
| Plant linearity | Asymmetric (dec ~2× slower than inc) | **Symmetric** (single fractional divider) |
| Range | ±500 ppm clamp | ±5000+ ppm available (use ±50 ppm for this test) |

If the actual results match this table within tolerance, Si5351 is validated as the actuator and Phase E can proceed.

If the actual results show Si5351 hitting some unexpected limit (e.g., non-monotonic at the extremes, or stuck-at-integer-step quantization), that's important data — but the architecture should still work, just with a tightened operating range.

---

## 7. Data artifacts

Commit alongside the final session writeup:

- `tests/phase-e1/si5351_phase_d_sweep.csv` — 11 rows: `commanded_ppm, achieved_ppm, residual_ppm`.
- `tests/phase-e1/si5351_phase_d_plot.png` (optional) — scatter + fit line for visual verification.
- `tests/phase-e1/si5351_phase_d_results.md` — final pass/fail writeup with the four metrics and any notes.

---

## 8. After Phase D passes — what changes for Phase E

Phase E is the actual actuator swap in the closed-loop controller. With Phase D's `si5351_set_offset_ppm()` helper proven, Phase E becomes mostly a one-line firmware change:

```c
// Old: actuator_apply_ppm(cmd_mppm);   // → mmcm_psincdec_drive(...)
// New: actuator_apply_ppm(cmd_mppm);   // → si5351_set_offset_ppm(cmd_mppm/1000)
```

The PI controller, lock state machine, reference mux, etc. are all unchanged.

Expected Phase E results, per [`phase_e2_psincdec_limit.md` §"Recommended Si5351 swap acceptance criteria"](phase_e2_psincdec_limit.md):

| Metric | MMCM | Si5351 (target) |
|---|---|---|
| ach_rate vs cmd | -530 ppm gap | match within ±5 ppm |
| sat counter at steady state | rising | stable at 0 |
| int_mppm at steady state | -94k to -480k (drifting) | small magnitude (<10k) |
| Lock state | Never LOCKED | LOCKED within seconds |
| Picture (src-ref + NTSC source) | static wrap | clean |
| Time-to-LOCKED | Never | < 5 seconds |
| Sub-test B (sync ref) convergence | ±25k limit cycle over 14 s | settles to ±1k, no limit cycle |

If Phase E lands within these targets, **the sync project's "cannot continue in any form until that is resolved" stop condition resolves itself.** Spike declares done.

---

## 9. Watch items / known gotchas

### PLL_RESET is the single most common Si5351 bring-up bug

Already flagged in §2 and §3. Worth saying again: every divider write needs a PLL_RESET after. Etherkit library handles it. Hand-rolled code often misses it. Phase D's pass/fail will silently lie if PLL_RESET isn't in the path — outputs will be wrong frequency without any warning.

### Fractional vs integer divider mode

If `OUT_DIV_NUM/OUT_DIV_DENOM` ever gets set to `0/anything` (integer-only mode), ppm trim resolution collapses. The Etherkit library's `si5351_set_freq` automatically chooses between integer and fractional based on the requested frequency; for Phase D we want **always fractional**. Verify the helper forces fractional mode.

### Frequency counter accuracy

If using the FPGA timestamp instrument to measure frequency, remember the timestamp's own clock (FCLK_CLK0 at 100 MHz) has its own ppm tolerance (~50 ppm typical for the Zynq PS PLL). This is a *common-mode* error — affects both the Si5351 measurement and the nominal — so it cancels for relative measurements (the slope and R² of the sweep). It does NOT cancel for the intercept measurement — the intercept will have ±50 ppm of measurement bias.

**Implication for the intercept criterion:** if intercept reads as "−45 ppm" or "+38 ppm," that may not be a Si5351 problem; it may be the FCLK_CLK0 reference offset. For a definitive intercept measurement, cross-check with a real frequency counter (which uses a more accurate reference).

### Si5351 thermal drift

Si5351's 25 MHz crystal has typical thermal drift of a few ppm over the operating temperature range. If the board has been off and is warming up during the sweep, you may see a small linear drift in the baseline across the 7 minutes of measurement. Mitigation: warm the board up for 5 minutes before starting the sweep.

---

## 10. After-session

- [ ] Commit `si5351_phase_d_sweep.csv` and `si5351_phase_d_results.md`.
- [ ] Commit any updates to `si5351.c` / `si5351.h` (helper function additions).
- [ ] Update [`docs/si5351-bench-bringup.md`](../../docs/si5351-bench-bringup.md) Phase D status from OPEN to PASS (or document any partial pass).
- [ ] Note any Phase E prep items discovered during Phase D (e.g., if max ppm range is narrower than expected).

---

## 11. Why the strict pass criteria matter

MMCM passed Phase 5 with a qualified PASS (slope 1.08 / intercept +102 ppm / R² 0.995). That qualified pass turned out to be load-bearing for the eventual Hypothesis B failure — the +102 ppm baseline was the actuator's irreducible offset, and the slope nonlinearity was diagnostic for the psincdec PSDONE rate limit. The sync spike took the qualified pass at the time, but it was a flag that we missed.

For Si5351, we want a **clean pass** — no qualifiers, no asterisks. A symmetric fractional divider with the right register-write math should produce slope 1.000 / intercept 0 / R² 0.9999. Anything less suggests a firmware or hardware issue worth investigating before proceeding to Phase E.

If Phase D produces a *qualified* pass (e.g., slope 1.005 / intercept −12 ppm / R² 0.998), that's still better than MMCM but is a yellow flag. Investigate before declaring done.

---

## 12. Total session shape

Roughly the bench checklist looks like:

```
Pre-flight              (15 min)
Step 1 — helper code    (30 min — firmware only, no bench)
Step 2 — baseline       (10 min)
Step 3 — sweep          (30 min)
Step 3a — analyze       (15 min — fit, plot, evaluate)
After-session writeup   (10 min)
                        ----
                       110 min total
```

If everything goes cleanly, this is a single afternoon. If anything fails the strict criteria, expect a few rounds of debug — most likely in the register-write math.
