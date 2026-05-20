# Phase E1 + E2 — Pre-bench code review

**Status:** REVIEW FEEDBACK — collected 2026-05-19 from reading E1.7, E1.8 (partial), E2.1, E2.2, E2.3.

**Purpose:** consolidate review notes across the recent work into one addressable list, ordered by priority. Each item is concrete enough to act on; either fix-in-place, verify-at-bench, or document-as-known-limitation.

**Audience:** the agent driving the next bench session and any follow-up firmware work.

---

## 1. What looks great (no action needed)

Brief inventory of things to keep doing — these are *not* the action items.

- **E1.7 diagnostic discipline.** Hold-path report identified vendor-IP origins (zero E1 modules at fault), tried cheapest fix first (clock_uncertainty), discovered the *actual* root cause was firmware-level (untimed polling loops + typeahead garbage), shipped both fixes, was honest about the ambiguity in the "was the timing fix necessary?" footer. Reproducibility check across `ExtraTimingOpt` directive sealed it.
- **E1.8 partial scope decision.** Math validated on paper for the production architecture; bench portion appropriately deferred to user availability. Caught and flagged the iter-4a measurement bias as a separate concern (60.164 Hz reading from a source that's clearly ~60.000 Hz).
- **E2.1 architecture.** Bresenham fractional divider is the right tool for ratio lock (zero long-term drift, runtime-configurable, clean CDC). Catching the cross-domain reset bug (`rst_mem` vs `rst_axi`) at synth time saved a bench-debug session.
- **E2.2 parameterization.** `lock_mode_t` struct with `g_active_mode` pointer is the right abstraction. No call-site changes in `loop_tick` keeps the controller correctness validated by Phase 6 intact.
- **E2.3 UX.** Single `a` command matches broadcast-equipment ergonomics. Honest about the NTSC limitation with three named workarounds.

---

## 2. Action items — fix or verify before declaring spike done

Each item has a unique ID for tracking. Priority levels: **P0** (must fix or verify), **P1** (should address), **P2** (document and move on).

### P0-1 — iter-4a measurement bias verification

**Source:** [`phase_e1p8_source_rate_results.md` §Source A](phase_e1p8_source_rate_results.md), [`phase_e2p3_auto_frc.md` §"How it works"](phase_e2p3_auto_frc.md)

**Problem:** the iter-4a precision rate detector reads Source A (Windows PC, known clean at ~60.000 Hz from monitor evidence) as **60.164 Hz** — a +2733 ppm offset. E1.8 correctly flags this as suspect measurement bias.

**Why P0:** **E2.3's auto-FRC math depends on this measurement being accurate.** If iter-4a reads 60.164 Hz when source is actually 60.000:

- Computing M/N for "60.164 → 50.000 Hz": gcd(50000, 60164) = 4 → reduced 12500/15041 — both exceed the 8-bit (≤255) M/N GPIO limit → **`a` REJECTS the canonical Windows source**.
- The whole point of E2.3 is automated lock; if it fails on the calibration source due to a measurement bug, the feature doesn't work even where the architecture is correct.

**To do:**

1. Feed a known-rate signal into the iter-4a detector path. Two cheap options:
   - synth_vsync_gen output (50.000 Hz, derived from FCLK_CLK1 — known to ~10 ppm of nominal).
   - Loop back FCLK_CLK0 / some_divisor as a synthetic source for the measurement chain.
2. If iter-4a returns ~50.000 Hz for the synth source → real bias in measurement, hunt the constant.
3. If iter-4a returns ~50.137 Hz (the same +2733 ppm signature) → confirmed measurement bias. Most likely cause: `COUNTS_PER_SECOND` constant misaligned with actual SCU timer rate, or sample-boundary rounding in the count-edges-over-interval logic.
4. Fix the constant; re-test against Source A; confirm Source A reads ~60.000 Hz.

**Done when:** known-rate signals read within ±50 ppm of their actual rate from iter-4a. E2.3's `a` against Windows source produces M/N = 5/6 (not REJECTED).

---

### P0-2 — Bresenham jitter envelope vs PI loop dynamics

**Source:** [`hdl/src_vsync_divider.v`](../../hdl/src_vsync_divider.v), [`phase_e2p1_source_vsync_ref.md` §"Open design questions"](phase_e2p1_source_vsync_ref.md), [`phase_e2p2_multi_mode_lock.md`](phase_e2p2_multi_mode_lock.md)

**Problem:** the Bresenham divider's output pulses fire **only on source edges**. For M=5, N=6, 60 Hz source: pulses land at source edges 2–6 of every 6-edge cycle, skipping edges 1 and 7. Inter-pulse intervals are 16.67 ms (4×) then 33.33 ms (1×) per 100 ms window. Average 50 Hz ✓, but **per-edge phase has ±10 ms (= ±500 µs in line units, = ±18,750 ticks) of jitter relative to ideal 20 ms spacing.**

Translating to PI loop dynamics, sampled at output vsync (50 Hz, locked):

- Per-output-edge, ts_ref jumps by 16.67 or 33.33 ms (Bresenham position-dependent), while ts_out jumps by ~20 ms.
- Per-tick phase error walks by ±3.33 ms or ∓13.33 ms → ±125 to ±500 lines at 720p50 (1 line = 2,667 ticks).
- At SMOOTH gains (Kp=10 ppm/line): per-tick correction command 1,250–5,000 ppm — past the ±500 ppm clamp **on every cycle**.
- Phase 6's lock criterion (`|err| ≤ 1 line for 60 consecutive frames`) is unachievable with this much per-edge jitter.

**Why P0:** the doc's claim "the loop's PI controller filters this out over time" may be true in steady-state but won't satisfy the lock criterion as written. Loop will probably report `ACQUIRING` forever even if the picture is clean.

**To do at bench (preferably first thing E2.1 session):**

1. **Engage `r src` + `n 5 6` in FILM mode (Kp=3, Ki=0.3)** — not SMOOTH. The lower Kp tolerates the larger per-tick err without saturating quite as hard.
2. **Measure two separate things:**
   - **Running mean of `err` over 60 frames** (true low-frequency phase error). Should converge to ~0 if the loop is averaging correctly. This is the *real* lock metric for src-ref mode.
   - **Actuator output stability** (the `cmd_mppm` value, low-frequency component). Should be stable around the correct offset. If `cmd` is hunting wildly, the integrator is being pumped by the jitter.
3. **Monitor picture is the truth.** If picture is clean → loop is doing its job, just with a noisy `err` per-sample. If picture is *not* clean → either the actuator is being driven by jitter, or the integrator is winding up.

**Possible outcomes and follow-up:**

- **Outcome A (best):** FILM mode locks with picture clean and `cmd_mppm` stable despite per-tick `err` jitter. Action: redefine the lock criterion for src-ref mode (rolling-mean of `|err|` over K frames ≤ some threshold, instead of instantaneous). Document the new criterion in [`phase_e2p1_source_vsync_ref.md`](phase_e2p1_source_vsync_ref.md).
- **Outcome B (middle):** FILM locks but SMOOTH and SNAP don't. Action: document that src-ref + FILM is the production combo; SMOOTH/SNAP only meaningful with synth_vsync_gen (legacy diagnostic mode).
- **Outcome C (bad):** even FILM doesn't lock — integrator runs away from jitter. Action: either (a) add a software median filter on `ts_ref` samples before phase computation, or (b) refactor the divider to produce evenly-spaced output via interpolated counter rather than source-edge-pulses. (a) is a few lines of firmware; (b) is real HDL work but produces a higher-quality reference.

**Done when:** at least one mode produces a monitor-clean picture in src-ref mode with bounded actuator output, and the lock criterion is appropriately defined.

---

### P1-3 — E2.3 NTSC rejection path is the *common case*, not the edge case

**Source:** [`phase_e2p3_auto_frc.md` §"Supported ratios"](phase_e2p3_auto_frc.md)

**Problem:** the doc lists 59.940 Hz (NTSC) as "REJECTED" with three named workarounds. But **NTSC is the dominant North American video standard** — most Macs, most cable boxes, most Apple TVs, most streaming devices output 59.94 Hz by default. If `a` rejects them, the auto-FRC feature is dead in practice.

The three workarounds in the doc:

1. **"Lock to nearest matching integer source"** — pretend source is 60.000 Hz, set M/N=5/6. The doc says the loop's ±500 ppm pull range absorbs the ~1000 ppm offset "barely." **Worked example:** for 59.94 source with M/N=5/6, ref pulse rate = 49.95 Hz. Loop locks output to 49.95 Hz exactly. Source/output ratio = 1.2000 → framestore arithmetic is clean → monitor sees 49.95 Hz (within monitor tolerance for 50 Hz signal). **The doc's framing about "absorbing ~1000 ppm offset" is misleading — the loop doesn't absorb the offset, it locks to a different output rate that produces a clean ratio.** Either re-frame the workaround or strike it.

2. **Widen M/N to 16 bits.** Trivial HDL change. With 12 bits, 2500/2997 fits comfortably. With 16 bits, room for any irreducible ratio likely to appear in practice. **This is the right fix.** Promote it from "Followup E2.3.1 idea" to a P1 action item.

3. **Pick a different output target.** Architecturally valid but not a workaround the operator can choose at runtime without the missing VTC mode-selection command.

**Math nit in the doc:** the listing says `59.940 Hz: 50000/59940 = 250/2997`. The correct reduction is **2500/2997** (gcd = 20, not 200). 250/2997 isn't even equal to 50000/59940 (250 × 200 = 50000 ✓ but 2997 × 200 = 599400, not 59940). Conclusion that "reduced terms too large" still holds either way — both 250 and 2500 fit in 8 bits, but 2997 doesn't.

**To do:**

1. Fix the math in the doc (250 → 2500).
2. Decide between workaround #1 (re-framed) and #2 (widen to 16 bits). **Recommend #2** — it's HDL one-liner and removes the "REJECTED on the common case" UX failure.
3. If sticking with #1 as the spike approach, re-frame the doc to describe the *actual* behavior (loop locks to source-ratio-clean output rate, not "loop absorbs 1000 ppm").

**Done when:** at least Mac at 59.94 Hz can run through `a` to a working state, with documented behavior matching reality.

---

### P1-4 — Lock criterion needs re-thinking for src-ref mode

**Source:** [`phase_e2p1_source_vsync_ref.md`](phase_e2p1_source_vsync_ref.md), [`phase_e2p2_multi_mode_lock.md`](phase_e2p2_multi_mode_lock.md)

**Problem:** Phase 6's lock criterion is "|err| ≤ 1 line for 60 consecutive frames" (`LOCK_THRESHOLD_TICKS = 2667`, `LOCK_FRAMES = 60`). Per P0-2 above, this is unachievable in src-ref mode due to Bresenham jitter — even when the loop is functionally working.

E2.2 wisely makes `lock_threshold_ticks` and `lock_frames` per-mode, but the current FILM tuning still uses an instantaneous criterion (`1333 t = 0.5 line`, `150 frames`). Tighter than SMOOTH; still impossible against jitter.

**To do:**

1. After P0-2 bench results land, decide the criterion shape. Most likely: **rolling-mean(|err|) over K frames ≤ threshold**, not instantaneous.
2. If keeping instantaneous: relax threshold to e.g. ±10 lines × 60 frames in src-ref mode.
3. Either way, document the criterion's *intent*: "loop is doing useful work, picture is monitor-clean" — not "every sample is within range."

**Done when:** lock criterion meaningfully reflects "loop is locked and picture is clean," not just a metric that happens to be tight under synth-ref-mode jitter conditions.

---

### P1-5 — Integrator preload assumption needs updating for src-ref mode

**Source:** [`sw/phase-b/src/main.c`](../../sw/phase-b/src/main.c) `INTEGRATOR_PRELOAD_MILLI_PPM`, [`phase_e1p6_baseline_root_cause.md` §"What changes when Si5351..."](phase_e1p6_baseline_root_cause.md)

**Problem:** the preload (−94000 mppm) was calibrated for synth-ref + MMCM context: synth ref at 50.000 Hz, MMCM natural at 49.99490 Hz (−102 ppm), loop needs to pull *up* by ~100 ppm. In src-ref mode, the steady-state needed varies by source:

- Windows PC at 60.000 Hz, M/N=5/6: ref at 50.000 Hz, MMCM still needs +100 ppm pull. Preload is correct.
- Mac at 59.94 Hz, M/N=5/6: ref at 49.95 Hz, MMCM needs −800 ppm pull. **Outside ±500 ppm range** — loop saturates.
- Apple TV at 60.001 Hz, M/N=5/6: ref at 50.0008 Hz, MMCM needs +101 ppm. Preload fine.

**Why P1:** the 59.94 case interacts with P1-3's "pretend 60.000" workaround. If the workaround is used and preload isn't adjusted, the loop will slew the wrong direction at startup, take longer to acquire, possibly never reach the right setpoint within the integrator clamp.

**To do:**

1. After P1-3 lands (E2.3 supports 59.94 either via wider M/N or via workaround), decide:
   - **If wider M/N (E2.3.1):** preload should be near zero (source × M/N = ideal output rate, MMCM just needs to track residual drift). Update preload to 0 mppm when src-ref mode is active.
   - **If "pretend 60.000" workaround:** preload should be source-rate-dependent. Probably set preload based on measured source rate during `a` command.
2. If switching reference modes (`r sync` ↔ `r src`) mid-operation, integrator value should be re-evaluated. Document the policy.

**Done when:** integrator preload behavior is documented and correct for each ref-mode + source-rate combination.

---

### P1-6 — Phase 8 slip mechanism is not actually wired

**Source:** [`phase8_cadence.md`](phase8_cadence.md) §"Scope decision"

**Reminder, not a new finding:** the Phase 8 "virtual slip" simulation validated the controller-side decision logic, but no actual VDMA park-pointer write happens. **This is fine for the spike's stated scope but is a real product-shipping gap.**

It interacts with src-ref mode work as follows: if a source/output ratio falls outside what the MMCM can pull (e.g., 59.94 source with M/N=5/6 in the "pretend 60" workaround → needs 800 ppm pull, has 500 ppm), the integrator saturates and the system relies on slip to recover. With slip not wired, recovery doesn't happen, picture eventually tears.

**To do:** add to the "must do before product MVP" list, separate from the spike-done declaration. Real VDMA park-pointer integration is a meaningful piece of work — needs PG020-conformant SOF-atomic writes and probably a state machine to coordinate with the existing Dynamic Genlock arithmetic.

**Not P0 because:** the canonical 60→50 case at clean 60 Hz source doesn't need slip (MMCM pull range is comfortable). Slip only matters for marginal cases.

---

### P2-7 — VTC mode-selection UART command missing

**Source:** [`phase_e2p1_source_vsync_ref.md` §"Open design questions"](phase_e2p1_source_vsync_ref.md), [`phase_e2p3_auto_frc.md` §"What's NOT in E2.3"](phase_e2p3_auto_frc.md)

**Problem:** firmware currently hardcodes `MODE_720P50`. E2.3's `a` command uses a hardcoded `g_output_target_mhz` (50.000 Hz). Without a runtime mode-switch command:

- Can't test 60→60 case (`a` against 60 Hz source would want output_target = 60).
- Can't test 60→24 or any other ratio.
- E1.8's bench portion (Mac/Apple TV at different rates) is artificially limited to "does it work for 50 Hz output."

**To do:** add a `v <preset>` UART command (probably `v 720p60`, `v 720p50`, etc.) that switches the VTC TX configuration *and* updates `g_output_target_mhz` atomically. Probably ~30 lines.

**Done when:** at least 720p60 and 720p50 modes are runtime-selectable, and `a` produces the right M/N for each.

---

### P2-8 — Auto-retrigger on source change

**Source:** [`phase_e2p3_auto_frc.md` §"What's NOT in E2.3"](phase_e2p3_auto_frc.md)

**Already documented as out of scope.** Just flagging here for completeness — a real product needs to notice when source changes (different rate) and re-run the auto-FRC computation. Not a spike-done blocker.

---

### P2-9 — Document E2.3 NTSC math correctly

Per P1-3, the doc says `50000/59940 = 250/2997` but the correct reduction is `2500/2997`. One-character fix, doesn't change the conclusion. While in the doc, also clarify the "lock with loop pull" framing per P1-5.

---

## 3. Recommended bench session ordering

The next bench session can validate E1.8 (Sources B/C), E2.1, E2.2, and E2.3 together. Suggested order:

### Session plan (single bench session, ~3 hours)

1. **First 30 min — P0-1 (iter-4a bias).** Critical and fast. Without this confirmed/fixed, E2.3 will fail on the canonical source and confuse all downstream tests. Either fix the constant or document the workaround (manual `n 5 6`).

2. **Next 30 min — P0-2 (Bresenham jitter, FILM mode).** Engage `r src`, `n 5 6`, `o film`, `L`. Watch:
   - Running mean of `err` (target: bounded near 0).
   - Actuator `cmd_mppm` stability (target: bounded near −100 ppm).
   - Monitor picture (target: clean).
   - LOCK indicator (expectation: probably ACQUIRING forever — confirm this is the case and document).

3. **Next 30 min — E1.8 source variation.** With the working E2.1+E2.3 build:
   - Switch to Mac source. Run `a`. Whether it succeeds depends on P1-3's resolution; either way, observe monitor.
   - Switch to Apple TV / Roku. Same.
   - Confirm the architectural prediction: src-ref mode → clean picture regardless of source rate.

4. **Last 60 min — E2.2 mode comparison + E2.1 multi-source soak.** Cycle SNAP/SMOOTH/FILM with src-ref active. Compare picture stability and acquire times. Run a 30-minute multi-source soak in the production combo (whichever mode wins).

### What to skip in this session

- Phase 8 real-VDMA slip integration (P1-6) — separate work, won't complete in this session.
- E2.3.1 widening M/N to 16 bits (P1-3 option) — pick the approach based on bench results; implement in a follow-up session.

---

## 4. Net assessment

The spike is essentially **one bench session + iter-4a bias fix + (maybe) one HDL tweak** away from declarable-done.

- **Architecture validated** by E1 phases 0–8 ✓
- **Production fix (src-ref) shipped** at E2.1 ✓
- **Operating modes** parameterized at E2.2 ✓
- **Operator UX** (single-button auto-FRC) at E2.3 ✓
- **Remaining blockers:**
  - P0-1 (measurement bias) — fast diagnostic, possibly a constant change
  - P0-2 (Bresenham jitter response) — bench-discovery; outcome shapes the next move
  - P1-3 (NTSC support) — likely promotes E2.3.1 (16-bit M/N) from idea to action

Everything else is documentation, follow-up product work, or known-deferred items. The team's pace has been remarkable; the discipline of "evidence-as-CSVs, honest qualified-passes, reverted bad changes" is showing in the doc quality.

---

## 5. Appendix — known-good interaction matrix

Quick reference for what's expected to work after the next bench session, by reference mode × source rate × actuator state. **Predicted, not verified.**

| Ref mode | Source rate | Output target | M/N | Loop behavior | Monitor |
|---|---|---|---|---|---|
| `r sync` (legacy) | any | 50 Hz | n/a | Locks to synth 50 Hz; FRC ratio drifts with source | Tears for non-60 Hz sources (E1.8 finding) |
| `r src` | 60.000 Hz | 50 Hz | 5/6 | Locks to source × 5/6 = 50 Hz; MMCM pulls +100 ppm | Clean |
| `r src` | 59.940 Hz | 50 Hz | 5/6 (workaround #1) | Locks to source × 5/6 = 49.95 Hz; MMCM saturates at −500 ppm pull, can't reach −800 needed | Slow tear; needs slip (P1-6) |
| `r src` | 59.940 Hz | 50 Hz | 2500/2997 (after E2.3.1) | Locks to source × 2500/2997 = 50.000 Hz; MMCM tracks normally | Clean |
| `r src` | 60.001 Hz | 50 Hz | 5/6 | Locks to source × 5/6 = 50.0008 Hz; MMCM pulls +101 ppm | Clean |
| `r src` | 60.000 Hz | 60 Hz | 1/1 (after P2-7) | Passthrough mode; loop just tracks source drift | Clean |

This matrix updates after bench validation lands.

---

## 6. Pre-bench fixes shipped (2026-05-19, commit `0c3a48e`)

Three of the items above were fixable without bench access. Status:

### P0-1 — iter-4a measurement bias: **FIXED** ✓

**Root cause:** Off-by-one in the interval-counting math, not a constant misconfiguration as initially hypothesized.

The original implementation captured `t_start` BEFORE the first rising edge. The loop then counted N rising edges and captured `t_end`. The actual elapsed time was:

```
elapsed = X + (N-1) × T    where X ∈ [0, T) is the startup phase offset
```

But the rate formula `rate = N × 1000 × CPS / ticks` assumed elapsed = N × T. The systematic bias is `+X/(N×T)` → averages to `+1/(2N-1)` over uniform X distribution. At N=60: predicted average bias = **+8400 ppm**. Observed +2733 ppm matches a specific X ≈ 0.16T (well within the expected variance).

`COUNTS_PER_SECOND` is fine — it correctly evaluates to `XPAR_CPU_CORTEXA9_CORE_CLOCK_FREQ_HZ / 2 = 333,333,343` Hz against an actual SCU rate of ~333,333,333 Hz (off by <0.1 ppm). The bias is purely algorithmic.

**Fix** (`sw/phase-b/src/main.c` `measure_source_rate_mhz`): wait for the first rising edge, THEN capture `t_start`. Count `target_edges` more rising edges = exactly `target_edges` intervals, then capture `t_end`. Bias eliminated.

**Predicted post-fix behavior:** ~60.000 Hz source reads as 60.000 ± a few ppm (limited by source jitter, polling-loop quantization, and SCU clock precision). E2.3's `a` against Windows source should now correctly produce M/N = 5/6.

### P1-3 — Widen src_vsync_divider M/N to 16 bits: **DONE** ✓

NTSC's irreducible 2500/2997 ratio now fits. Three coordinated changes:

| Layer | Change |
|---|---|
| HDL `src_vsync_divider.v` | `COUNT_WIDTH` parameter 8 → 16. Defaults stay at M=N=1. |
| BD `tcl/build_phase_b.tcl` | `axi_gpio_srcdiv`'s `C_GPIO_WIDTH` and `C_GPIO2_WIDTH` 8 → 16. |
| Firmware `sw/phase-b/src/main.c` | `g_srcdiv_m`/`g_srcdiv_n` u8 → u16; `compute_frc_ratio` arg types and cap (255 → 65535); `cmd_srcdiv_set` validation message and storage. |

**Predicted post-fix behavior:** `a` against an NTSC source returns M/N = 2500/2997 cleanly; loop locks to source × 2500/2997 = 50.000 Hz exactly with no need for the "pretend 60.000" workaround. The whole NTSC ecosystem (Mac OS default, cable boxes, Apple TV) becomes a turnkey case.

### P2-9 — E2.3 NTSC math typo: **DONE** ✓

`50000/59940` reduces to `2500/2997` (gcd = 20), not `250/2997` (which would require gcd = 200, off by factor 10). Corrected in `phase_e2p3_auto_frc.md` along with the supported-ratios table — the NTSC entry now lists "SUPPORTED after P1-3" instead of "REJECTED."

### Build verification

Single rebuild (HDL + tcl changes need a full Vivado pass):

| Metric | Pre-review build (E2.3) | Post-review build |
|---|---|---|
| WNS reported | +0.361 ns | **+0.637 ns** |
| WHS reported (with +0.050 ns uncertainty) | +0.017 ns | +0.014 ns |
| WHS intrinsic | +0.067 ns | **+0.064 ns** (still above E1.7 +0.050 floor) |
| New critical warnings | — | None on src_vsync_divider / axi_gpio_srcdiv |
| Firmware build | clean | clean |

WNS improved noticeably; WHS dropped 3 ps but stays well above the production floor. Acceptable.

### What still needs bench (carry-forward)

The P0/P1 items NOT addressed by this commit:

- **P0-2** — Bresenham jitter vs PI loop dynamics. The jitter analysis predicts ±125 to ±500 lines of per-tick `err` variance against the SMOOTH lock threshold of 1 line. Needs bench observation; the fix (rolling-mean criterion, FILM mode, or maybe an HDL refactor to interpolated counter output) depends on the outcome.
- **P1-4** — Lock criterion redefinition for src-ref mode. Cannot be designed without P0-2 data.
- **P1-5** — Integrator preload for src-ref mode. Now slightly simpler: with the P1-3 fix, the canonical case (any source → 50.000 Hz output) wants the same preload behavior as synth-ref mode (−94000 mppm bridges MMCM's −102 ppm offset). The 59.94-source edge case from the original review evaporates.
- **P1-6** — Phase 8 slip mechanism. Separate product-shipping work.
- **P2-7** — VTC mode-selection UART command. Tractable but deferred.
- **P2-8** — Auto-retrigger on source change. Tractable but deferred.

### Net spike-done assessment (updated)

Items remaining for spike-done declaration:

1. ~~P0-1 measurement bias~~ ✓ fixed in this commit
2. ~~P1-3 NTSC support~~ ✓ fixed in this commit
3. **P0-2 Bresenham jitter response** — single bench session
4. Bench validation of the cumulative E1.8 + E2.1 + E2.2 + E2.3 + P0-1 + P1-3 stack against multiple sources

Suggested bench session ordering (revised from §3):

1. **First 5 min — confirm P0-1 fix.** Disconnect any active capture (`U` first, then any pending `d`/`c`), send `a` against the Windows source. Expect M/N = 5/6 to be reported. If yes → bias fix validated.
2. **Next 10 min — NTSC bring-up.** Switch source to a Mac at default 1080p60 (Mac will output 59.940 Hz). Send `a`. Expect M/N = 2500/2997. If yes → P1-3 fix validated.
3. **Next 60 min — Bresenham jitter investigation (P0-2).** Sequence per §3 of this review. Engage FILM mode first; observe running-mean `err`, `cmd_mppm` stability, and monitor cleanliness. Document the outcome.
4. **Remaining time — multi-source soak.** Cycle through every available source, leave the production combo running for 30 min. Capture any UNLOCK events.

After that session: either the spike declares done, or P0-2 surfaces a real architectural issue that needs follow-up before declaring done.
