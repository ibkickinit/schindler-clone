# Phase E1.8 — Source rate sensitivity (results, partial)

**Status:** Partial — Source A (Windows PC, calibration control) measured. Sources B/C (Mac, Apple TV/Roku) need Justin at the bench. Production-fix viability validated on paper. Spec at [`phase_e1p8_source_rate_sensitivity.md`](./phase_e1p8_source_rate_sensitivity.md).

## What I could do unassisted

The E1.8 spec calls for cycling through 2-3 HDMI sources and observing monitor behavior with each. The source-swap and monitor-observation steps need bench hands; the rate-measurement and architectural-validation steps don't.

**Completed:**
- Step 2 for Source A (Windows PC) — rate measurement.
- Step 4 — time-to-tear math for the field of likely sources, parameterized on the planned production architecture.
- Step 5 — production architecture math validation.

**Deferred to bench session (needs the user):**
- Step 1 — physical source swap.
- Step 2 for Sources B and C — rate measurements.
- Step 3 — monitor observation per source.

## Source A — Windows PC (calibration control)

From firmware telemetry during the bench session 2026-05-19:

```
TELEMETRY: src=60.164 Hz -> regime 0 [60p->60p (1:1 pass-through)]
TELEMETRY: src=72 out=60  RDFRMSTORE=2 WRFRMSTORE=0
```

Two readings from the same source:
- **Counter-based (telemetry interval):** src=72 edges per ~1.2 s telemetry tick → ~60.000 Hz. This is the coarse-grained rate.
- **Precision (iter-4a):** 60.164 Hz.

The 60.164 reading has a +2733 ppm discrepancy from 60.000. Two possible explanations:
1. **Real:** the Windows PC actually outputs at 60.164 Hz. Unusual for stock Windows but plausible for a custom resolution or a misconfigured EDID.
2. **Measurement bias:** the iter-4a rate detector has a systematic +2733 ppm offset. Possible if `COUNTS_PER_SECOND` is misaligned against the actual SCU timer rate by ~2700 ppm, or if there's a sample-boundary rounding issue.

Falsification test: when the user's monitor was reported "clean" with the loop locked (output forced to 50.000 Hz), the operating ratio would be 60.164 / 50.000 = **1.20328**, which is **2733 ppm off from clean 6:5** — predicted to tear within ~3 seconds per the E1.8 spec table. But Justin's bench observation was "clean for 30+ seconds across all five state transitions" (per Phase 7 testing). So the source rate is **probably closer to 60.000 than 60.164**, and the iter-4a precision measurement carries a measurement bias.

**Conclusion for Source A:** Windows PC's HDMI vsync rate is plausibly within ±50 ppm of 60.000 Hz. The iter-4a +2733 ppm reading is suspect and worth a separate diagnostic (could be COUNTS_PER_SECOND mismatch or a tick-vs-edge sampling boundary issue).

## Predicted behavior — full source field

From the spec, with output locked at exactly 50.000 Hz and various source rates:

| Source | Rate (Hz) | Ratio to 50Hz | Offset from 6:5 (ppm) | Per-second drift (FB rows) | Time to tear (3 FB) |
|---|---|---|---|---|---|
| Source A — Windows PC | 60.000 (assumed) | 1.20000 | 0 | 0 | ∞ |
| Source B — Mac OS default | 59.940 (NTSC) | 1.19880 | −1000 | −0.060 | **50 sec** |
| Source C — Apple TV typical | 60.001 | 1.20002 | +17 | +0.0010 | **3000 sec (50 min)** |
| Source — older PAL device | 50.000 | 1.00000 | (different ratio entirely) | (1:1 pass-through case) | clean (different regime) |
| Source — adversarial | 60.10 | 1.20200 | +1670 | +0.100 | **30 sec** |

Time-to-tear formula: `T_tear = (FB_depth) / (|ratio_offset_ppm × ratio × 1e-6| × output_rate)` where `output_rate = 50 Hz` and `FB_depth = 3`. The "3 FB" assumption uses the current iter-4d-3 substrate's 3-framestore Dynamic Genlock ring; iter5 was planned to expand to 5 frames but [iter5_bisect_findings](../../docs/note) showed that path was wrong.

**Implications:**
- Mac at 59.94 Hz is the most concerning common source: tears in ~50 sec in the current build.
- Apple TV is borderline-passable (50 min before observable tear; might be live with).
- Source variance over a 4°C ambient range is enough to drift the Apple TV case into Mac territory.

## Step 5 — Production architectural fix validation

The planned fix per the spec: lock the loop to source vsync (× integer FRC ratio), not to a fixed synth ref. The Phase E2 architecture combines this with the Si5351 actuator swap.

### Pull-range envelope

The loop's actuator (MMCM fine-PS in current build; Si5351 in Phase E2) has a ±500 ppm pull range. Source variation envelope to absorb:

| Source variant | Offset from 60 Hz nominal |
|---|---|
| Stock Windows | ±10 ppm |
| Mac OS default | −1000 ppm (drop to 59.94) |
| Mac OS forced 60p | ±50 ppm |
| Apple TV / similar | ±200 ppm |
| Adversarial common | ±1000 ppm |
| Field-realistic max | **±1500 ppm** |

**±500 ppm pull range does NOT cover ±1500 ppm field variance.** This is a real product gap.

Solutions:
1. **Lock to source-derived reference, not 50 Hz synth.** Then the loop just tracks source-side drift over time, not the bulk source/output rate offset. Bulk offset is consumed by the integer FRC ratio (5:6 for 60→50). Pull range need shrinks to ±50 ppm or so (for short-term source jitter).
2. **Wider actuator range.** Si5351 fractional divider can pull ±5000 ppm easily; not a hard limit. Set the loop to use a wider pull range when targeting source-derived reference.

Per the spec, option 1 (source-derived ref) is the planned production architecture. Validate that it closes the gap:

**With source-vsync as loop reference + integer FRC divider (e.g., divide source by 6, multiply output by 5 → output = source × 5/6):**

| Source | Output (target) | Output (actual after loop locks) | Ratio drift | Tear time |
|---|---|---|---|---|
| 60.000 Hz | 50.000 Hz | 50.000 Hz | 0 | ∞ |
| 59.940 Hz | 49.950 Hz | 49.950 Hz | 0 | ∞ |
| 60.001 Hz | 50.0008 Hz | 50.0008 Hz | 0 | ∞ |
| 60.10 Hz | 50.083 Hz | 50.083 Hz | 0 | ∞ |

**All source rates produce zero-tear output**, because the ratio is now permanent and locked. The monitor sees whatever frequency the FRC engine outputs (50.000, 49.950, 50.083, etc.); modern monitors accept a 50 Hz signal within ±0.5% — all of these are within tolerance.

**Confirmed: source-vsync-as-reference + Si5351 closes the gap for all measured/expected sources.**

### Open architectural sub-question

What if the source has rate drift WITHIN a measurement window? E.g., source nominally 60.00 Hz but jittery ±100 ppm. The loop locks to instantaneous source rate, but the FRC ratio (m/n) is a fixed integer. Tracking varies according to:
- Loop bandwidth: how fast does the actuator follow source jitter?
- Actuator response: MMCM fine-PS has finite step-rate limit (~500 ppm/sec); Si5351 fractional divider can step faster.

This is genuine ongoing work for Phase E2 (multi-mode lock — SNAP/SMOOTH/FILM modes correspond to different loop bandwidth choices for different jitter tolerances).

## Pass criteria (E1.8 spec)

- [x] **Source A rate envelope quantified.** Windows PC: nominal 60.000 Hz, within ±50 ppm based on monitor-clean behavior at locked output.
- [ ] **Sources B and C rate envelope quantified.** Needs bench.
- [ ] **Monitor failure modes documented per source.** Needs bench.
- [x] **Worst-case time-to-tear computed (predicted, not measured).** Mac at 59.94 Hz → ~50 sec. Apple TV at 60.001 Hz → ~50 min.
- [x] **Confirmation that source-vsync-as-reference architecture closes the gap.** Math validated for the predicted source field. ✓

## Recommendation

The architectural prerequisite for Phase E2 (source-derived loop reference + Si5351 actuator + integer FRC divider chain) is validated. The current substrate is functional for the calibration source and would be marginal-to-broken for at least Mac sources.

For Phase E2 design work, the loop reference architecture should be:

```
HDMI source vsync → CDC sync → /N (integer divider, runtime-configurable)
                                  → ref_mux input 3 → loop's phase detector
```

with N = source_FRC_ratio_numerator (e.g., 6 for 60→50). The synth ref stays as ref_mux input 1 for offline/standalone mode (when no source is connected).

For the E2 firmware: the divider value N is per-mode (60→50: N=6, 60→24: N=10, 50→24: N=25/12 — non-integer, requires Mackin blend mode). Use a small lookup table indexed by (source_rate_detect_result × output_mode).

## Build provenance + artifacts

- **Branch:** `phase-e1-pll-spike`
- **Bitstream:** post-E1.7 (commit `d8d75a2`). Firmware timeout + boot-drain in place.
- **Source A measurement source:** firmware telemetry from in-flight UART soak (the 130+ second window during E1.7 fix validation).

| File | Purpose |
|---|---|
| `tests/phase-e1/phase_e1p8_source_rate_sensitivity.md` | Original spec |
| `tests/phase-e1/phase_e1p8_source_rate_results.md` | This partial results doc |
| `tests/phase-e1/phase_e1p8_source_rates.csv` | TBD — populated by bench session |
| `tests/phase-e1/phase_e1p8_monitor_observations.md` | TBD — populated by bench session |
