# Phase E2 Bench Session 2 — Code review + next-step instrumentation

**Date:** 2026-05-20
**Reviewer notes for:** the agent driving bench validation of the post-median-filter / post-iter4a-fix build (commit `b25d27d` + uncommitted median filter).

**TL;DR:** The diagnosis chain in [`phase_e2_bench_session_2.md`](phase_e2_bench_session_2.md) is sound and three real bugs were found and fixed. The proposed next step (post-`a` VTC re-alignment) is correct as a first attempt. But I want to push back on one piece of the analysis, add three instrumentation tasks before the alignment test, and pre-commit to branching plans for **four distinct possible outcomes** (Outcome 1 / 2 / 2.5 / 3) so the next session doesn't drift. **Of particular note: Outcome 2.5 — a 5-slot framestore rebuild — is a cheap intermediate test that may resolve the visible wrap without requiring the Si5351 promotion. The iter5 bisect that previously reverted 5 slots actually condemned a *different* bug (iter4h S2MM VSIZE over-allocate), not the slot depth itself.**

This review explicitly addresses the operator's hard stop: **"phase offset persists and is entirely unacceptable. Cannot continue the project in any form until that is resolved."** Spike-done depends on getting through this.

---

## 1. What the session got right

- **iter-4a known-signal injection diagnostic** is exactly the right shape. Confirmed shared bias on both real source (+1.69%) and 50 Hz test signal (+1.69%) → measurement-bug, not source-anomaly. One-line fix in `measure_source_rate_mhz`. Rigorous.
- **Cascade ordering of the three bugs** is well-documented: iter-4a bias produced wrong M/N, which produced ref-rate mismatch outside actuator range, which dominated loop behavior and masked the residual jitter and phase-offset issues. Each fix had to land before the next layer was diagnosable.
- **The "rate-only controller can't fix initial phase" framing is control-theory-correct.** Once rate-locked, the integrator settles at whatever value maintains rate match; phase is frozen wherever it landed.
- **Honest acknowledgement** that Session 1's "Bresenham jitter alone" attribution under-counted the actual cause stack. That kind of explicit correction is what good test discipline looks like.

---

## 2. Where I'd push back

The session doc frames the +200k tick offset as **purely initial-phase-at-lock**, fixable by re-running the VTC alignment dance after `r src`. That may be entirely correct. But there's a second hypothesis that's *also* consistent with the bench evidence, and it leads to different follow-up actions if it turns out to be the cause.

### Hypothesis A — Initial phase stuck (the session's working hypothesis)

Loop reached rate-lock with output vsync ~2 ms behind ref vsync. Integrator settled at whatever value maintains rate match. Phase is now frozen at +200k because rate-only control can't slew phase without breaking rate match.

**Fix:** post-`a` VTC alignment sets initial phase to ~0; loop maintains it. **Should work cleanly and indefinitely.**

### Hypothesis B — psincdec slew-limit pinned (alternative)

Phase err = +200k ticks → Kp × err = 750 ppm → cmd clamped at −500 ppm. Integrator drives toward saturation. **Commanded** rate is −500 ppm.

But MMCM psincdec's PSDONE handshake is rate-limited, and dec direction is documented (Phase 6) as ~2× slower than inc. So the **achieved** rate change is probably ~−100 ppm, not −500 ppm. That happens to be approximately the rate-cancellation setpoint. Rate matches, phase stays at +200k — not because the loop is at lock, but because the actuator can't go faster.

**If this is the cause:** the VTC re-alignment fix will:
- Set initial phase to ~0 ✓
- Hold for several seconds while actuator slew authority is small ✓
- Drift back to a non-zero offset over minutes as small disturbances accumulate beyond what the rate-limited actuator can correct
- Produce "clean for a few minutes, then visible tearing" — still a product blocker, just with longer time-to-failure

### How to discriminate before claiming the fix works

Instrument three values per second to distinguish A from B in the bench data:

1. **`err` mean (ticks)** — the displayed phase offset.
2. **`cmd_mppm` value** — saturated at ±500 (B) or sitting at the rate-cancellation setpoint ~−100 (A)?
3. **Actual achieved rate delta** — log the tick count between consecutive output vsync edges. Compute the implied rate. Compare to commanded.

If `cmd_mppm` is at the rail but achieved rate is small (~−100 ppm), that's Hypothesis B's signature. If `cmd_mppm` settles at ~−100 ppm and achieved rate matches, that's Hypothesis A and the alignment fix will hold.

---

## 3. Instrumentation tasks before the alignment fix

These are small, additive, and provide the data to distinguish A vs B above. Suggested order — none take more than 15 minutes:

### 3a. Achieved-rate logger (~15 min firmware)

Add to the LOCK summary line (1 Hz):

```
... ach_rate=NNNNN
```

where `ach_rate` is the median of the last 50 output-vsync-to-output-vsync tick deltas, expressed as a ppm offset from nominal (`2,000,000` ticks at 50 Hz). The median rejects single-cycle jitter; the 50-sample window averages over Bresenham pattern cycles.

If `ach_rate` is consistently close to `cmd_mppm`, actuator is delivering what's commanded → Hypothesis A. If `ach_rate` is much smaller magnitude than `cmd_mppm`, actuator is slew-limited → Hypothesis B.

### 3b. Saturated-frames counter (~5 min firmware)

Count consecutive frames where `cmd_mppm` is at ±clamp. Print in LOCK summary. If saturation count stays high indefinitely → loop is hitting the rail; that's B's signature.

### 3c. Phase-error histogram dump (~10 min firmware)

UART command `h` that dumps a histogram of `err` values over the last 60 seconds (in some sensible bucket size — 10k ticks per bucket should be enough resolution). Helps see whether:
- The distribution is tight around +200k (Hypothesis A — rate-locked at offset)
- Distribution is broad and skewed (loop hunting against a slew limit — Hypothesis B)

Stack these on top of the existing per-second summary and the existing CSV dump.

---

## 4. Run the post-`a` VTC alignment fix

After §3 instrumentation lands, implement and run the fix as described in the session doc's "next session work" §1–§5. Procedure:

1. Boot, source connected, `a` to engage src-ref. Wait for `[A] APPLIED: M/N = 2500/2997 ...` confirmation.
2. **New post-`a` step:** firmware waits for next ref pulse (poll the appropriate GPIO bit), then re-runs `vtc_setup()` so VTC's first vsync after this point lands aligned to the ref pulse.
3. `L` to engage loop.
4. **Capture instrumented data for 30 minutes.** Don't just eyeball the first few seconds.

---

## 5. Outcomes — pre-committed branching

Branch on the 30-minute observation, not the first 30 seconds.

### Outcome 1 — Clean picture, stable for 30+ minutes, `cmd_mppm` ~−100, achieved rate matches commanded

Hypothesis A confirmed. **Spike done.** Commit the VTC re-alignment, write up the results doc, update the bench review doc, declare Phase E1/E2 spike production-architecture-validated. Move to Mackin functional or Si5351 swap per the roadmap.

### Outcome 2 — Clean for a few seconds/minutes, then visible offset returns; `cmd_mppm` pinned at ±500 with small `ach_rate`

Hypothesis B confirmed. The MMCM psincdec actuator is structurally insufficient for the production architecture. **Do not** try to fix this with more firmware — it's a hardware-authority limit. Two actions:

1. **Document the slew-limit characterization** in a new `phase_e2_psincdec_limit.md` doc. Quantify the achieved-rate-vs-commanded curve from §3a's data. This becomes the calibration baseline against which Si5351 is later compared.
2. **Promote Si5351 swap ahead of spike-done.** The Si5351 dev board is ordered per `docs/si5351-bench-bringup.md`; when it arrives, the swap becomes the unblocker. The MMCM gets retired as actuator at that point.

This is **not a failure of the spike** — it's exactly what the spike was designed to surface. The architectural claim "MMCM phase-tracking can be the production actuator" is now bench-falsified; the alternative claim "Si5351 is the production actuator" is the path forward. The spike has done its job.

### Outcome 2.5 — Try 5-slot framestore rebuild before Si5351 promotion

**Insert this branch between Outcome 2 and Outcome 3.** If §3 instrumentation confirms Hypothesis B (slew-limit pinned), there is a cheaper, lower-risk intermediate test worth running *before* promoting Si5351 to "next bench session."

**The change:** one line in [`tcl/build_phase_b.tcl`](../../tcl/build_phase_b.tcl) — `CONFIG.c_num_fstores {3}` → `{5}`. Plus a Vivado rebuild. No HDL change, no firmware change, no architectural commitment.

#### Why this might fix the visible wrap independent of the slew-limit issue

The vertical wrap pattern is caused by the VDMA reader and writer being in the same framestore slot at the same time — not directly by the vsync phase offset. The phase offset *determines where on screen the collision lands*. Phase=0 puts the collision in blanking (invisible); phase=2 ms puts it at row 144 (visible).

With a 3-slot ring, the writer's slot (advancing at source rate) and the reader's slot (advancing at output rate, one slot behind via FrameDelay=1) have minimal margin. Any small phase offset puts the collision into the visible frame.

With a 5-slot ring, the writer can be 4 slots ahead of the reader without lapping. Collision moves *outside the visible frame* even with significant phase offset, because the reader is no longer adjacent to the writer's active slot. **This sidesteps the slew-limit issue entirely:** phase doesn't need to be near zero if the reader is reading from a slot the writer is nowhere near.

#### Why iter5's reversion does not condemn this path

Looking at [commit `81e17a8`](.) ("iter5 scroll bisect") carefully: the actual root cause was **iter4h's S2MM VSIZE over-allocate**, not the 5-slot configuration. The bisect process reverted multiple things in cascade (1080p→720p, scaler_bypass→scaler_top, NUM_FRAMES 5→3, then iter4h additions). Step 3 — reverting iter4h additions alone — fixed the scroll. Step 4 confirmed: re-adding over-allocate alone brought scroll back.

**The 5-slot configuration was reverted as part of the cleanup, never tested in isolation as the cause.** The production substrate shipped at 3 slots because that's where the bisect process happened to land, not because 5 slots was proven harmful.

The current Phase E1/E2 spike build has none of the iter4h baggage (no AXIS FIFO between scaler and S2MM, no c_flush_on_fsync=1, no VSIZE+27 over-allocate). So 5 slots on the current substrate is going to a configuration that was never actually broken — it's just untested.

#### Cost / risk

**Cost:**
- Additional DDR memory: 2 extra frames × 1280×720×3 bytes ≈ 5.5 MB. TE0720 has 1 GB; negligible.
- Additional output latency: ~33 ms (2 extra frames at 50 fps). Acceptable for FRC; not noticeable to the operator.
- One Vivado rebuild (~30 min).

**Risk:**
- May not fix the visible wrap if the root cause is something other than 3-slot-collision-window. In that case, no progress, ~1 hour lost, but Outcome 2 (Si5351 promotion) is still on the table.
- Could re-surface the "bottom-bars" artifact iter4h was originally trying to fix. But the iter5 bisect concluded that was source-content-dependent (SMPTE bars on ImagePro), not a structural bug — laptop sources didn't show it.

#### How to evaluate

After the 5-slot rebuild:

1. Boot, source connected, `a` to engage src-ref, `L` to engage loop.
2. **Do not run the post-`a` VTC alignment fix in this test** — that's a confound. If 5 slots alone produces a clean picture, that's a stronger result than "5 slots + alignment + median filter."
3. Observe monitor for 30+ minutes. Capture per-second telemetry per §3 instrumentation.
4. Same `err` mean / `cmd_mppm` / `ach_rate` data — but now we're checking whether the *picture* is clean, not whether the *phase* is zero. They're different.

**Branch on monitor result:**

- **Picture clean for 30+ minutes** → 5 slots fixed it. Commit the BD change. Document that the slew-limit issue is real but masked by sufficient framestore depth. Spike-done declarable with this configuration. Si5351 swap stays scheduled but de-urgent.
- **Picture still wraps** → the slew limit is producing more disturbance than 5 slots can absorb (or the failure mode isn't slot-collision at all). Revert to 3 slots, promote Si5351 per Outcome 2.

#### Why this ordering matters

The 5-slot test costs 1 hour of bench time and 1 rebuild. The Si5351 swap costs days of bench bring-up. If 5 slots is sufficient for MVP, the time saved is significant and the architecture remains validated against the bench-stage actuator. If 5 slots isn't sufficient, you've lost an hour and gained a definitive answer about ring-depth contribution.

This is the same engineering principle as the cheapest-fix-first sequence used in E1.7 (clock_uncertainty before placement constraints).

### Outcome 3 — Something neither A nor B nor 2.5 (rare, but possible)

If the data is inconsistent with all the above hypotheses (e.g., cmd settles near 0 but err stays at +200k, and 5 slots doesn't help), capture all instrumented data and stop. Don't try to invent a fourth hypothesis at the bench — bring the data back for analysis. Most likely root cause would then be in the framestore arithmetic itself (VDMA slot-phase initialization), not in the loop or the ring depth.

---

## 6. What NOT to do

Two failure modes to actively avoid in the next session:

1. **Do not add more loop tuning or filtering** before checking §3 instrumentation. The control-theory analysis is correct: rate-only control can't fix initial phase, and a slew-limited actuator can't track a step disturbance faster than its rate limit. Any further loop iteration is rearranging deck chairs.

2. **Do not declare success on a 30-second observation.** Hypothesis B's failure mode is "clean for a while, then drifts" — if you only watch for a few minutes, B looks like A. Run the 30-minute soak. Capture the histogram. *Then* declare.

---

## 7. Context to keep in mind

The Phase E1/E2 spike was always going to surface the MMCM-vs-Si5351 question eventually. The spike doc explicitly named Si5351 as the production actuator and the MMCM as the bench-validation stand-in. **Outcome 2 above isn't a regression or a failure — it's the spike validating exactly what it was meant to validate.**

Phrase to remember: "the last issue surfaced is the one that always was there, just hidden by louder failures." If the slew-limit hypothesis confirms, that's the truth the architecture was always going to expose; we just needed to clear three louder failures first.

---

## 8. After the next session

Whichever outcome lands:

- Commit the instrumentation from §3 regardless. It's permanently useful for any future loop work.
- Commit the post-`a` VTC alignment regardless. It's correct in all outcomes; in Outcome 2 it's not sufficient by itself, in Outcome 2.5 it may not be needed.
- If Outcome 2.5 lands: commit the 5-slot BD change and document the latency / memory tradeoff in the spike-done writeup.
- Update [`phase_e1_e2_bench_review.md`](phase_e1_e2_bench_review.md) §5 interaction matrix with the measured behavior.
- Write `phase_e2_bench_session_3_results.md` documenting which outcome matched and what the data showed.

Endpoint by outcome:
- **Outcome 1** — spike done; MMCM is the actuator; 3-slot ring stands.
- **Outcome 2** — Si5351 promoted ahead of spike-done.
- **Outcome 2.5** — spike done with 5-slot ring; MMCM is the actuator; Si5351 stays scheduled but non-urgent.
- **Outcome 3** — return to analysis; bring data back for review.

All four are defined endpoints, not open questions.

---

## 9. Suggested run order for the next bench session

Updated for the four-outcome branch. Roughly 3 hours total if all sub-tests run.

1. **Land §3 instrumentation** (30 min firmware): achieved-rate logger, saturated-frames counter, histogram dump.
2. **Land §4 post-`a` VTC alignment fix** (30 min firmware).
3. **Run the alignment test** (30 min observation): does Outcome 1 land cleanly?
4. **If yes → spike done.** Stop. Write up.
5. **If no → run the 5-slot test** (30 min Vivado rebuild + 30 min observation): does Outcome 2.5 land cleanly *without* the alignment fix engaged?
6. **If yes → spike done with 5-slot config.** Stop. Write up.
7. **If no → Outcome 2 confirmed.** Document the slew-limit characterization from §3 data; promote Si5351; spike concludes "MMCM insufficient, Si5351 path validated as the production answer."
8. **If Outcome 3 lands at any point** → stop early, capture data, surface for review.

Cheapest tests first. Si5351 promotion happens only after both cheaper options are eliminated by bench evidence.
