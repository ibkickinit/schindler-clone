# Phase E1.8 — Source rate sensitivity (real HDMI input)

**Status:** OPEN — blocking declaration of spike done.

**Goal:** characterize the current build's behavior across a range of real HDMI source rates, confirm the predicted monitor-tear failure modes, and quantify the gap that the source-vsync-as-reference architecture must close in production. **This test does not fix anything.** It quantifies an architectural assumption that has been implicit throughout the spike.

**Why it matters:** every Phase 0–8 test was conducted against a single HDMI source (Windows PC at nominally 60 Hz). The loop locks output to a synthetic 50 Hz reference, which produces FRC-clean 6:5 ratio with the source *only if the source is exactly 60.000 Hz*. Real HDMI sources are not exactly 60.000 Hz — Mac OS commonly outputs 59.94 Hz, Apple TV often 60.001 Hz, and any source drifts. Until we test, we don't know whether the current spike "works" for one specific HDMI source or for the field of real ones.

---

## 1. The architectural assumption being tested

Per [`phase_e1p6_baseline_root_cause.md`](phase_e1p6_baseline_root_cause.md), a monitor-clean picture requires the source-to-output frame rate ratio to land on its FRC target (6:5 for 60→50). Currently:

- **Output rate** is set by the loop, which pulls the MMCM to lock against the synthetic 50 Hz reference. Output ≈ 50.000 Hz regardless of source rate.
- **Source rate** is whatever the HDMI input device produces. Nominally 60 Hz; actually somewhere in a band around 60 Hz that depends on the source's own clock.

So the operating ratio is:

```
ratio = source_rate / output_rate ≈ source_rate / 50.000 Hz
```

The framestore arithmetic works cleanly only when ratio = 1.2 (= 6:5) exactly. Any deviation accumulates as drift between the read and write pointers, eventually lapping the framestore depth and producing monitor tearing.

Predicted behavior at common source rates:

| Source | Ratio | Per-second drift in framestore | Time to tear (3-slot ring) |
|---|---|---|---|
| 60.000 Hz (calibration source) | 1.2000 exact | 0 frames/sec | ∞ (clean) |
| 59.940 Hz (Mac / NTSC) | 1.1988 | −0.06 frames/sec | ~50 sec |
| 60.060 Hz (60 + ~1000 ppm) | 1.2012 | +0.06 frames/sec | ~50 sec |
| 59.999 Hz (subtle drift) | 1.1999 | −0.0005 frames/sec | ~6000 sec |

Time-to-tear scales inversely with the rate-ratio offset.

**The architectural fix** (already planned for Phase E2 / production): wire HDMI source vsync into the reference mux's input 3 (`ref_ext1` slot, currently tied low per [`phase7_states.md`](phase7_states.md)). Then divide it down to the output cadence (e.g., `source_vsync / 6 × 5` for 60→50 — or in production, just divide by the integer ratio and let the loop track), and use *that* as the loop's reference. The output then tracks source × (5/6) exactly, ratio stays clean regardless of source drift.

This phase characterizes the current state, before the architectural fix lands.

---

## 2. What to do

### Step 1 — Identify the test sources

Three sources, ideally:

- **Source A:** the calibration source already used through Phase 0–8 (Windows PC). Confirms expected clean operation. Treat as the control.
- **Source B:** a Mac (any Mac) at default 1080p60 HDMI output. Mac OS typically generates 59.94 Hz at this setting; some configurations 60.00. Worth measuring the actual rate before assuming.
- **Source C:** any other available source — Apple TV, Roku, a video player, a different PC. Just needs to be a different HDMI device with a different oscillator.

Optional: a programmable HDMI generator (Diversified Photonics, Quantum Data, etc.) if you have access to one — gives controlled source rates.

### Step 2 — Measure each source's actual rate

Boot the Phase 8 build. Connect each source in turn. Use the timestamp infrastructure to read source vsync edges (this means the loop reference for measurement; even though the reference mux's input 3 is currently tied low in the BD, the HDMI dvi2rgb's `vid_pVSync` is still wired into other observability paths — find the existing TLAST counter / GPIO that already counts source vsyncs, or add a temporary scope read).

Compute and record `source_rate_hz` to 4 decimal places for each source.

If the timestamp instrument isn't easily wired to source vsync without a BD change, alternative: count source-side TLAST events over a known interval via the existing scaler observability counters. Accuracy is lower but sufficient for ±10 ppm.

### Step 3 — Observe monitor behavior at each source rate

For each source, with loop locked against synth ref (default `r sync`):

1. Switch to the source, wait for HDMI to lock.
2. Confirm loop achieves LOCKED state (it should — the loop is locking to the synth ref, which doesn't care what the source is doing).
3. Watch the **physical monitor** (not MS2109). Document:
   - Time from HDMI lock to first visible monitor disturbance.
   - Nature of disturbance (horizontal tear, vertical roll, scrolling stripes, judder, none).
   - Whether the disturbance is steady or accumulating.
4. Record source rate (Step 2), predicted drift (table above), and observed monitor-tear time. Tabulate.

### Step 4 — Compute the rate envelope to handle

From the measurements, extract:

- **Min and max source rates observed in the field.** This sizes the required pull range when source-vsync replaces synth-ref.
- **Worst-case time-to-tear in current build.** This is the *manual-intervention window* — how long an operator has to notice and react before the monitor breaks. Anything under a few minutes is a meaningful UX gap.
- **Whether any common source is *unable* to produce a clean picture in the current build.** A binary product-blocker check.

### Step 5 — Validate the architectural fix plan

Confirm that the predicted production architecture — wire source vsync into the reference mux, divide by integer FRC ratio, lock loop to source-derived reference — would actually close the gap for the worst observed source. This is a paper exercise:

- Does the MMCM (or Si5351) pull range cover source variation? Existing ±500 ppm should comfortably absorb ±150 ppm of source variation.
- Does the divider arithmetic in `synth_vsync_gen` generalize to source-derived references? It's currently a fixed FCLK_CLK1/divisor counter; the divisor needs to become a function of the input integer ratio.

---

## 3. Pass criteria

This is an **investigation phase**, not a fix phase. The pass criterion is *characterization*, not improvement:

- [ ] Source rate envelope quantified (min/max/typical observed ppm offsets).
- [ ] Monitor failure modes documented per source.
- [ ] Worst-case time-to-tear measured.
- [ ] Confirmation (or refutation) that the source-vsync-as-reference architecture closes the gap for all measured sources.

If any source produces a fundamentally unfixable failure mode (e.g., source rate outside the planned actuator pull range), that's a finding that promotes itself to a real product issue.

---

## 4. What this phase intentionally does NOT do

- **Doesn't add HDMI source vsync to the reference mux.** That's production work and depends on either Si5351 swap (which fixes the +102 ppm floor problem) or a parallel BD change. Adding it here would blur the boundary between "characterize the gap" and "fix the gap."
- **Doesn't validate Mackin functionality.** Mackin depends on dual-VDMA, which is independent of this work.
- **Doesn't test cross-rate conversion outside 60→50.** Once we know how source rate variation affects 60→50, the same logic extrapolates to 60→24, 50→60, 24→60. Don't repeat the entire matrix here.

---

## 5. Open questions to resolve during the work

1. **Is `synth_vsync_gen.v` flexible enough to be replaced by a source-derived reference?** Look at its current implementation. If the divisor is a runtime-configurable counter and the input clock can be swapped, the change is small. If it assumes a fixed input clock, that's a wider BD change.
2. **Is the existing dvi2rgb `vid_pVSync` already wired to a CDC-safe domain that could feed the reference mux?** Phase 1's vsync_timestamp module sampled output vsync; the parallel module for source vsync may already exist or be trivial to add.
3. **For sources with significant drift (Mac at 59.94), is the loop-OFF behavior (per E1.6) the same kind of monitor failure?** I.e., is the 59.94 → 50.0 case the same architectural problem as the +102 ppm case from E1.6, or a different failure mode entirely? Worth understanding before treating them as one.

---

## 6. Why this matters before declaring the spike done

The spike was scoped as "validate the sync architecture." A perfectly valid sync architecture that locks to a synthetic reference but can't handle real HDMI source variation is not validated for the product use case.

If this test confirms the current build works fine within a narrow source-rate band and only breaks at unusual sources, that's a documented limitation with a clear architectural fix. If this test reveals that even the calibration source (Windows PC) is at a marginal rate and the picture is borderline-tearing for non-obvious reasons, that's an unknown that needs to be closed.

Either outcome is useful. Not knowing is the only bad outcome.

---

## 7. Artifacts to produce

- `tests/phase-e1/phase_e1p8_source_rates.csv` — measured source rates per source, with predicted drift columns.
- `tests/phase-e1/phase_e1p8_monitor_observations.md` — per-source monitor behavior log.
- Optional: webcam photos of monitor under each failure mode (consistent with the E1.6 evidence approach).
- `tests/phase-e1/phase_e1p8_source_rate_sensitivity.md` — final summary with the envelope, the worst-case finding, and confirmation that the production fix plan is sound.
