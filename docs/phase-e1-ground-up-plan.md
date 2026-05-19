# Phase E1 — Ground-up plan

**Date:** 2026-05-18
**Status:** Active. This supersedes [`phase-e1-mmcm-tracking-spike.md`](phase-e1-mmcm-tracking-spike.md), which assumed we'd instrument the current (broken, scrolling, untrusted) build and measure from there. We're not doing that.
**Companion doc:** [`sync-architecture.md`](sync-architecture.md) — THE plan. Unchanged. This doc is the *path* to building it.

---

## 0. Why ground-up

The previous spike plan assumed we'd start by measuring the current build's drift. That assumption was wrong for three reasons:

1. **The current build is untrusted.** Output is scrolling/unlocked. We don't know which behaviors are real clock drift, which are broken fsync logic, which are mux state confusion, which are VDMA slot misalignment, which are scaler latency, which are capture-stick artifacts. Measuring on an unstable platform produces unstable numbers.
2. **The MS2109 capture stick is the wrong instrument.** It introduces resampling, frame drops, and analysis confounds. The right measurement of "phase between two clocks in the FPGA" is a **hardware timestamp counter inside the FPGA**, not a USB capture stick.
3. **TPG, VDMA, the scaler, and the axis_mux aren't relevant to whether the PLL works.** They're complexity carried over from the previous attempts. The spike validates one specific thing — can we pull the output clock to track a reference — and that doesn't need any of them.

So the ground-up principle is:

> **Build the ruler before measuring. Use the simplest possible output pipeline. Add complexity only after each prior layer is independently proven.**

---

## 1. Methodology principles

These hold throughout every phase below.

1. **One change per build.** Each phase introduces exactly one new HDL or firmware capability. No "while we're in here, also fix…" — every confound makes failure mode attribution harder.
2. **Every phase has a single pass criterion expressed as a number.** Not "it looks better." Not "I think it works." A number with units and a threshold.
3. **In-FPGA measurement, not capture-stick measurement.** The PLL is a sub-line phase-control loop; the measurement instrument must have finer resolution than the loop's target. A 100 MHz counter gives 10 ns resolution. The capture stick gives ~16 ms resolution. Wrong tool.
4. **Bench evidence as committed CSVs.** Every phase's output is a versioned artifact under `tests/phase-e1/`. Future regressions diff against these CSVs.
5. **Stop at the first failure.** Don't tune past a broken layer. If Phase 2's drift number is bogus, Phase 3's actuator characterization will be bogus on top of it.
6. **No TPG, no VDMA, no scaler in the spike.** They are confounds. They get added back in their own dedicated phases later, *after* the PLL is proven.

---

## 2. Rollback target

**Proposed:** `d71c994` — "Phase D iter 4d-3 FRC validation: 720p60→720p50 via Dynamic Master." Pure FRC pipeline, validated. No TPG, no fsync hacks, no axis_mux complexity. This is the last commit that was demonstrably working as designed.

Alternatives if the user prefers a different baseline:
- `ad5303a` — First end-to-end TPG. Same as `d71c994` plus TPG, before vertical-alignment debugging started.
- `8ecea05` — Last commit before fsync work. Everything that exists today minus the failed sync attempts.

**Recommendation: `d71c994`.** Less in the picture = fewer confounds. We don't need TPG to validate the PLL; we need the simplest output that draws *anything* on screen.

The current `mackin-impl-wip` branch stays preserved — we're not deleting work, we're creating a new branch `phase-e1-spike` from `d71c994` and building forward.

---

## 3. Phase map

Each phase is a separate commit, separately testable, with one pass criterion. **Eight phases, none of them optional.**

| Phase | What it builds | Pass criterion |
|---|---|---|
| 0 | Strip back to baseline. Branch from `d71c994`. Confirm build, confirm output is stable picture (even if not aligned to anything). | Output displays a clean, non-scrolling test pattern. (Note: at this baseline, drift exists but is invisible at human time-scales over a minute or two.) |
| 1 | Add **vsync timestamp infrastructure**: one free-running 32-bit counter at 100 MHz, two edge-capture registers (one for reference vsync, one for output vsync). AXI-readable from PS. | Firmware can read both timestamps via UART command; reading the same vsync twice produces matching values; counter wraps cleanly. |
| 2 | Add **synthetic reference vsync generator**: divide FCLK_CLK1 down to nominal 60 Hz, expose as a 1-bit signal. This becomes the "reference" — known rate, independent of HDMI, independent of TPG, derived from a PS clock that's separate from the pixel-clock MMCM. | Counter at 100 MHz between reference vsync edges = expected period within ±1 tick. |
| 3 | **Measure baseline drift.** Compute phase delta per frame between reference vsync and output vsync. Plot phase vs time over 60 sec. Slope = drift in ppm. | Single signed ppm number with R² ≥ 0.99. Repeatable across reboots within ±5 ppm. |
| 4 | Add **MMCM DRP actuator**. Reconfigure `clk_wiz_pixclk_out` for runtime DRP. Firmware can issue a `+N ppm` correction via UART. | Drift number from Phase 3 changes by the predicted amount when DRP is nudged. Output stays glitch-free during DRP writes. |
| 5 | **Open-loop sweep.** Step DRP through ±N points around zero; record measured ppm at each. | Plot is linear, monotonic, slope within 10% of 1.0. |
| 6 | **Close the loop.** P-only controller, then PI. Reference = synthetic vsync from Phase 2. | Phase error within ±1 line for 60 consecutive frames. 30-minute soak: no unlock events, bounded phase error. |
| 7 | Add **reference multiplexer and lock state machine**. Inputs: synthetic vsync (Phase 2), tied-low (Free-run). Add the Acquiring / Locked / Holdover / Free-run states + GPIO LED. | All four states observable on the LED. Free-run reproduces Phase 3's drift number. Holdover (with reference masked mid-run) freezes the integrator and shows ≪ Free-run drift. |
| 8 | Add **VDMA cadence cooperation**. Pull the FRC scaffolding from `d71c994` back into the build. Controller commands a frame slip when MMCM saturates. Inject a synthetic 1000 ppm bias to force saturation. | Predicted number of slips occurs within ±20%. MMCM re-locks between slips. |

After Phase 8, the architecture from [`sync-architecture.md`](sync-architecture.md) is validated end-to-end on bench hardware, against a clean and traceable build. Subsequent work is hardware integration (Si5351, analog reference recovery, UI), not architecture.

---

## 4. The phases in detail

### Phase 0 — Strip back to baseline

**Branch:** `phase-e1-spike` from `d71c994`.

**Procedure:**
1. `git checkout -b phase-e1-spike d71c994`
2. Confirm build: `bash scripts/build_phase_b.sh` (or whatever the build script was at that revision) succeeds with no errors.
3. Program board. Confirm the output displays a stable picture (the FRC pipeline output, whatever the test source was at that point).
4. Do not modify anything. The point is to verify the baseline is clean.

**Pass:** Clean build, clean output, no scrolling visible to the eye over 60 seconds of observation.

**Artifact:** A short note (`tests/phase-e1/phase0_baseline.md`) confirming the build hash, build log clean, observed output stable.

**Why this matters:** If this fails, the rollback target is wrong, not the spike plan. Stop and pick a different baseline before going further.

---

### Phase 1 — Vsync timestamp infrastructure

**Goal:** build the measurement instrument the rest of the spike will use.

**HDL:**
- One free-running 32-bit counter on a 100 MHz clock (use `FCLK_CLK0` or an existing system clock — anything fast and stable, *not* the pixel clock we're going to be modulating later).
- Two edge-capture registers, each latching the counter value on a rising edge of its input.
  - `ts_ref`: latches on reference vsync (driven low for now; Phase 2 connects the real signal).
  - `ts_out`: latches on `v_tc_tx/vsync_out` (or equivalent output-side vsync).
- AXI-Lite slave: PS can read `ts_ref`, `ts_out`, and the current counter value at any time.
- All registers self-clearing on read is optional; not necessary if firmware just compares pairs of reads.

**Firmware:**
- UART command `q` ("query") prints current counter, last `ts_ref`, last `ts_out`.
- UART command `p` ("phase") prints `(ts_out - ts_ref) mod 2^32` — the phase delta in 100 MHz ticks.

**Pass:**
- `q` returns three numbers. Counter advances between calls at expected rate.
- With ref vsync tied to a known test toggle (e.g., a PS-driven GPIO pulsed by firmware), `ts_ref` updates at the expected interval.
- Reading the same register twice in rapid succession returns matching values (no glitches).

**Why it matters:** Every later phase uses this counter pair as its measurement instrument. If it's broken, every later measurement is broken on top of it. Don't move on until reads are stable.

**Artifact:** `tests/phase-e1/phase1_timestamps.md` — verification log showing register reads, counter wrap-around behavior.

---

### Phase 2 — Synthetic reference vsync

**Goal:** generate a stable reference signal at nominal 60 Hz that doesn't depend on HDMI, doesn't depend on TPG, and doesn't share a clock domain with the pixel-clock MMCM we're going to be modulating.

**HDL:**
- Divider in the `FCLK_CLK1` domain (or any PS-FCLK that isn't driving the pixel-clock MMCM).
  - `FCLK_CLK1` configured for, say, 50 MHz.
  - Counter divides down to 60.000 Hz: divisor = `floor(50e6 / 60)` = 833,333. (Phase Phase 3 will measure the actual achieved rate to several digits; the divider doesn't need to be perfectly 60 Hz, just stable.)
- Pulse output: high for one cycle, low otherwise.
- Wire that signal to Phase 1's `ts_ref` input.

**Firmware:**
- No change. Phase 1's `q` and `p` commands now produce meaningful data because `ts_ref` actually toggles.

**Pass:**
- Successive `q` reads show `ts_ref` advancing by ~1,666,667 ticks per second (at 100 MHz counter / 60 Hz reference).
- Period jitter across 100 consecutive captures < 100 ticks (1 µs). Anything more and there's a metastability or sync issue worth chasing.

**Why it matters:** This is the reference the PLL will lock to. If the reference itself is jittery or wrong-rate, the loop will track it perfectly — to a bad target. Verify the reference before relying on it.

**Artifact:** `tests/phase-e1/phase2_reference.csv` — 1000 consecutive `ts_ref` captures, plotted. Should be a straight line with negligible residual.

**Note on rate:** the synthetic reference at "nominal 60 Hz" derived from FCLK_CLK1 is *not* the same Hz as the output's nominal 60 Hz (derived from FCLK_CLK0 → pixel MMCM). They drift relative to each other at the PS-PLL-vs-pixel-MMCM offset rate. That's *fine* — it's the whole point. We want to measure and then correct this drift. The numbers we get in Phase 3 will reflect the FCLK_CLK1-vs-pixel-MMCM relationship specifically. When real reference inputs (HDMI source vsync, Si5351, external genlock) are added later, they replace the synthetic source in the reference mux.

---

### Phase 3 — Baseline drift measurement

**Goal:** the actual baseline. Single signed ppm number, measured with the in-FPGA ruler, on the clean baseline build.

**Setup:** Phase 2 build, no changes.

**Procedure:**
1. Firmware loops at 60 Hz: every output vsync, capture `(ts_out, ts_ref)`, compute `phase_delta = ts_out - ts_ref`, log via UART.
2. Run for 60 seconds → 3,600 samples → CSV.
3. Unwrap the phase delta (handle counter wraps and 60 Hz period wraps).
4. Fit a line to `phase_delta` vs `sample_index`. Slope = drift in ticks/frame.
5. Convert to ppm: `ppm = slope_ticks_per_frame × frame_rate / counter_freq × 1e6 = slope × 60 / 100e6 × 1e6 = slope × 0.6`.
6. Sign convention: positive = output running faster than reference.

**Pass:**
- A single signed ppm number with R² ≥ 0.99.
- Magnitude in the expected range (5–100 ppm typical for two independent on-chip-PLL outputs).
- Reproducible across reboots within ±5 ppm.

**Why it matters:** this number sizes everything downstream (Phase 4 nudge amount, Phase 5 sweep range, Phase 6 controller gains, Phase 8 disturbance magnitude). It's the calibration baseline for the whole spike.

**Artifact:** `tests/phase-e1/phase3_baseline_drift.csv` + plot + a one-paragraph summary with the number, units, sign, R², and build hash.

---

### Phase 4 — MMCM DRP actuator

**Goal:** prove the output clock is pullable. One single nudge, observable in Phase 3's measurement framework.

**HDL:**
- Reconfigure `clk_wiz_pixclk_out` for runtime DRP (`Allow Override Mode`, `Dynamic Reconfiguration: DRP`).
- Expose DRP interface to PS via AXI bridge.

**Firmware:**
- UART command `m <signed_ppm>` — apply a one-shot correction.
- Translates ppm → DRP register values per the clk_wiz programming guide.
- Performs the multi-write DRP sequence with handshake.

**Procedure:**
1. Phase 3 measurement running in background.
2. Issue `m +20` (commanded +20 ppm).
3. Re-measure. Drift should change by approximately +20 ppm.
4. Issue `m -40` (commanded -40 ppm net).
5. Re-measure. Drift should change by approximately -40 ppm relative to step 3.

**Pass:**
- Drift moves by commanded amount within ±20% (gain isn't calibrated yet — that's Phase 5).
- Output stays glitch-free during DRP writes. No DVI sink unlock events.

**Why it matters:** the actuator is the second half of the loop (the counter pair is the sensor). Both need to be working before closing anything.

**Artifact:** `tests/phase-e1/phase4_actuator.csv` — before/after drift measurements at three or four commanded points.

---

### Phase 5 — Open-loop plant characterization

**Goal:** measure the precise gain of "commanded ppm" → "measured ppm" so Phase 6's controller has correct numbers to work with.

**Procedure:**
1. Sweep commanded ppm across 11 points: −50, −40, −30, −20, −10, 0, +10, +20, +30, +40, +50 (or whatever range Phase 3's baseline justifies).
2. At each point, hold for 30 seconds, run Phase 3's measurement, record the resulting ppm.
3. Plot measured vs commanded. Fit a line.

**Pass:**
- Slope within 10% of 1.0 (commanded ppm and measured ppm are the same scale).
- Intercept within ±5 ppm (a constant offset corresponds to Phase 3's baseline).
- R² ≥ 0.99.

**Why it matters:** if the plant isn't linear, a simple PI controller won't be stable. Almost always passes for MMCM DRP, but verify.

**Artifact:** `tests/phase-e1/phase5_plant.csv` + plot.

---

### Phase 6 — Closed-loop tracking

**Goal:** close the loop. Lock output vsync to reference vsync within ±1 line, indefinitely.

**Firmware:**
- Every output vsync: read phase delta, compute correction, apply via DRP.
- Controller: PI with `Kp` and `Ki` initialized from Phase 5's plant gain.
- Integrator saturation: ±500 ppm (clamped to MMCM's pull range with margin).
- Lock-state output: bit set when |phase_error| ≤ 1 line for 60 consecutive frames. Wire to a GPIO LED.

**Procedure:**
1. Boot with loop disabled. Confirm Phase 3 baseline drift still present.
2. Enable loop. Watch phase error converge to ~0.
3. Run for 30 minutes. Log every frame.

**Pass:**
- Acquire time < 10 seconds.
- After lock: |phase_error| ≤ 1 line for 100% of the 30-minute window.
- No unlock events.
- Phase-error histogram bounded with no slow trend.

**Why it matters:** the headline test. If this fails, the architecture argument is wrong or the controller is mis-tuned. Both are recoverable, but the spike doesn't graduate without this.

**Artifact:** `tests/phase-e1/phase6_locked_30min.csv` + plot + a one-paragraph summary with acquire time, residual error stats, slip-event count (should be zero in this phase).

---

### Phase 7 — Reference multiplexer and lock state machine

**Goal:** prove the user-facing Reference Select model works (Free-run, Input-lock, Holdover).

**HDL:**
- Add reference mux: inputs = synthetic vsync (Phase 2), `1'b0` (Free-run), placeholder pins for future inputs.
- AXI register: `ref_select`.

**Firmware:**
- UART command `r <free|sync>` — switches the mux.
- UART command `s` — mask the synthetic ref vsync, simulating a ref loss.
- State machine: `FREE-RUN / ACQUIRING / LOCKED / HOLDOVER`.
- GPIO LED reflects state.

**Procedure:**
1. **7a Free-run:** select `free`. Confirm LED reports `FREE-RUN`. Re-run Phase 3 measurement. Drift should match Phase 3's baseline.
2. **7b Input-lock acquire:** select `sync`. Confirm transition `FREE-RUN → ACQUIRING → LOCKED`.
3. **7c Holdover:** while locked, mask the reference (`s`). Confirm transition to `HOLDOVER` within ~60 frames. Integrator freezes. Drift over 60 sec should be ≪ Phase 3's baseline (because the integrator is holding the correction that *was* matching the reference).
4. **7d Re-acquire:** un-mask. Confirm `HOLDOVER → ACQUIRING → LOCKED`.

**Pass:**
- All transitions observable on LED and UART.
- Free-run drift matches Phase 3 baseline within ±5 ppm.
- Holdover drift ≪ Free-run drift.
- Re-acquire time matches Phase 6's acquire time.

**Artifact:** `tests/phase-e1/phase7_states.csv` — full transition timeline with timestamps.

---

### Phase 8 — VDMA cadence cooperation

**Goal:** prove the dual-loop handoff. When MMCM saturates, controller releases a frame slip, MMCM re-locks.

**This is the only phase that touches VDMA.** We bring the FRC scaffolding from `d71c994` back into the build now, after the PLL is fully proven. Everything before this point used a minimal direct-from-VTC output path.

**HDL changes:**
- Add the VDMA scaffolding back. Confirm the FRC path still works as it did at `d71c994`.

**Firmware:**
- Add controller logic: if MMCM correction has been at ±500 ppm rail for ≥ 30 frames, request one VDMA frame slip via PG020's frame-pointer mechanism.
- Add UART command `b <signed_ppm>` — inject a bias on the reference timestamp before the controller sees it, simulating an over-range reference.

**Procedure:**
1. Lock the loop (Phase 6 conditions).
2. Inject `b +1000`.
3. Observe: MMCM saturates at +500 ppm. After ~30 frames at the rail, controller releases one frame slip. Phase error jumps by one frame's worth. MMCM re-locks.
4. Continue 60 sec. Expected slips: 1000 × 60 / 1e6 ≈ 0.06 slips/sec, ≈3.6 slips total.
5. Disable bias. Confirm steady state returns within settling time.

**Pass:**
- Slips occur (controller doesn't stick at the rail).
- Slip count within ±20% of prediction.
- Between slips, MMCM holds lock.
- After bias removed, system returns to zero-slip steady state within ~10 seconds.

**Artifact:** `tests/phase-e1/phase8_cadence.csv` — slip events + phase error over a 60 sec biased run.

---

## 5. What's deliberately not in this plan

- **No TPG.** Not needed to validate the PLL. May be re-introduced after Phase 8 as part of normal product work; not part of this spike.
- **No axis_mux complexity.** Not needed.
- **No HDMI source connected.** Not needed; reference is synthetic.
- **No capture-stick analysis.** All measurement is in-FPGA via the counter pair.
- **No Si5351 or RP2040.** Their integration is wiring them into the reference mux in a later phase, after the loop is proven.
- **No specific cadence schedules (60→50, 3:2 pulldown, etc.).** Phase 8 proves the mechanism; specific schedules are configured per product mode later.
- **No UI integration.** Status surfaces over UART and GPIO LED in the spike. Front-panel TFT and web UI wiring is normal product work after the spike.

---

## 6. What "spike done" means

All eight phases pass on bench hardware. All CSVs committed under `tests/phase-e1/`. A one-page summary at `tests/phase-e1/README.md` lists the headline numbers:

- Baseline drift (Phase 3)
- MMCM actuator linearity (Phase 5)
- Lock acquire time (Phase 6)
- 30-minute residual error stats (Phase 6)
- State-transition timing (Phase 7)
- Cadence slip rate vs prediction (Phase 8)

After that, every architectural claim in [`sync-architecture.md`](sync-architecture.md) is bench-validated. The remaining work to ship MVP is wiring the proven loop into real reference sources (HDMI vsync recovery, Si5351, analog sync front-end) and surfacing the state to the UI. None of that requires touching the loop.

---

## 7. What changes for the agent doing the work

The previous spike doc told the agent to instrument the current build. **That's no longer the plan.** This doc replaces it. Key differences:

| Old plan | New plan |
|---|---|
| Start from `mackin-impl-wip` (current, untrusted) | Branch from `d71c994` (known good) |
| Capture-stick analysis of TPG output | In-FPGA vsync timestamps, no capture stick |
| Reference = HDMI source vsync (requires HDMI plugged in) | Reference = synthetic vsync from FCLK_CLK1 (no HDMI needed) |
| TPG and VDMA in the pipeline from frame 1 | Minimal direct-from-VTC output until Phase 8 |
| 8 tests labeled Test 1–8 | 8 phases labeled Phase 0–8 (Phase 0 is "confirm rollback baseline") |
| Test 1 was the conflicting "measure drift on current build" | Phase 3 is the drift measurement, after Phases 0–2 build the instrument and the reference |

The old doc ([`phase-e1-mmcm-tracking-spike.md`](phase-e1-mmcm-tracking-spike.md)) is left in the repo as superseded reference, not as instructions to follow.
