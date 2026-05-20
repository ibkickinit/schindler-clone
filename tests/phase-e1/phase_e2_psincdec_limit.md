# Phase E2 — MMCM psincdec actuator slew-limit characterization

**Date:** 2026-05-20 (bench session 3)
**Status:** **Outcome 2 (per review §5).** MMCM-based psincdec actuator is bench-falsified as production actuator. **Si5351 swap is the unblocker for Phase E1/E2 spike-done.**

This doc is the calibration baseline against which the post-Si5351 build will be compared. Captures the failure mode, the numeric evidence, and what it means for the architecture.

---

## The failure mode

With the loop engaged in src-vsync-ref mode (NTSC source 59.940 Hz, M/N=2500/2997, target output 50.000 Hz):

- **`cmd_mppm`** is pinned at the ±500 ppm clamp **continuously**. Saturation counter (`sat=N`) increments monotonically from boot.
- **`ach_rate`** stays at **+32 ppm** indefinitely. The actuator is delivering ~0 of the commanded rate change (cmd = -500 ppm, ach = +32 ppm → ~530 ppm gap).
- **`err`** mean is +200–400k ticks (depending on initial alignment). Distribution shape: broad +0..+600k spread, not tight around any value.
- **Loop state** stays `ACQUIRING` forever; never reaches `LOCKED` because the per-cycle err threshold can never be satisfied.
- **Picture** has a static phase-shift wraparound that splits the visible frame at a fixed position. **Ring depth (3→5) does not move the wrap** because Dynamic Genlock + FrameDelay=1 forces the reader to track 1 slot behind the writer regardless of available framestores.

This is the **Hypothesis B** signature predicted in [`phase_e2_bench_session_2_review.md`](phase_e2_bench_session_2_review.md) §2:

> Phase err = +200k ticks → Kp × err = 750 ppm → cmd clamped at -500 ppm. Integrator drives toward saturation. **Commanded** rate is -500 ppm. But MMCM psincdec's PSDONE handshake is rate-limited... the **achieved** rate change is probably ~-100 ppm.

Observed: -500 ppm commanded, +32 ppm achieved. The actuator is doing **less** than the review predicted — closer to zero than to -100. Possible reasons: (a) the dec-direction asymmetry from Phase 5 is even larger than the documented 2× factor, (b) the actuator is being commanded across the zero-crossing repeatedly and net-cancelling, (c) the cmd's per-cycle hunting back and forth between extremes prevents any accumulation.

---

## Sub-test results

### A) src-ref mode (Bresenham divider engaged) — fails

Conditions: `a` command applied (M/N=2500/2997), `L` engaged, SMOOTH mode.

| Metric | Value | Interpretation |
|---|---|---|
| cmd_mppm | -500000 ± brief excursions | Negative rail pinning |
| ach_rate | +32 ppm constant | Actuator near no-effect |
| err mean | +400k (was +200k before median filter) | Stable DC offset |
| err range | +210k..+600k | Broad, jitter from Bresenham still significant despite filter |
| sat counter | Monotonically increasing | Continuous saturation |
| int_mppm | Stuck at preload -94000 OR -470000 | Either preload-locked or fully wound to clamp |
| Picture | Static mid-frame wrap | Phase offset unresolvable by rate control |

### B) sync-ref mode (synth_vsync_gen, no Bresenham) — partial walk toward lock

Conditions: default boot (no `a`), `L` engaged. Synth ref is clean 50.000 Hz from FCLK_CLK1 divider; no Bresenham jitter.

The loop ACTUALLY walks err from its initial value toward zero over ~14 seconds:

```
err walking from -485k → -461k → ... → -34k → +541 → ... (then settles around +25k)
```

`int_mppm` jumps from preload -94000 to ~+410000 at the moment of zero-crossing (integrator finally takes over from saturated P-term).

After zero-crossing, loop oscillates around +20-30k err with cmd alternating ±200k..±500k. ach_rate varies from -236 to +32.

**This confirms the loop architecture works** against a clean reference. The fundamental problem is specifically the MMCM actuator's slew authority *relative to the Bresenham-divided ref's jitter envelope*. Against a clean ref the actuator can converge (slowly); against a noisy ref it cannot.

### C) 5-slot framestore — Outcome 2.5 test — fails

Conditions: BD rebuilt with `c_num_fstores=5`, NUM_FRAMES=5 in firmware, otherwise identical to A.

Theory from review §5: a deeper ring depth would absorb the static phase offset by moving the reader/writer collision out of the visible frame.

Result: **same wrap, same position on screen.** Justin's exact observation: "Monitor is stable, still phase-shifted as it has been... same position."

Why 5 slots didn't help: with Dynamic Genlock + FrameDelay=1, MM2S follows S2MM by exactly 1 slot regardless of how many slots exist in the ring. More slots = more available memory, but the reader-vs-writer phase relationship is the same. To actually decouple, would need to either change FrameDelay (e.g., 3) or switch to PARK mode. Neither is in the standard Xilinx VDMA pattern.

This is a useful data point: **the wrap is determined by VTC TX vsync timing relative to source vsync, not by ring-depth contention.** Confirms it's a phase problem, not a buffer-collision problem.

---

## What this means for the architecture

The Phase E1/E2 spike was always going to surface the question: "is the MMCM phase-tracking actuator strong enough for production?" The spike has now bench-falsified that claim. **MMCM psincdec is insufficient for source-derived-ref tracking with a Bresenham-divided source.**

From the spike's design, Si5351 was always the intended production actuator; the MMCM was the bench-validation stand-in. Now:

- **Architecture is validated** for everything except the actuator itself. v_tc_rx detector works. Auto-FRC math works. Median filter rejects Bresenham jitter at the firmware layer. VTC alignment dance works. The whole stack is structurally correct.
- **MMCM is retired as actuator at the spike level.** Code stays in place for SYNC-mode regression testing and as the "stand-in actuator" baseline.
- **Si5351 swap is the unblocker.** Per `docs/si5351-bench-bringup.md`, the dev board is on order. When it arrives, the swap should be a fast win: Si5351 has wide pull range (±5000 ppm), no slew limit comparable to MMCM PSEN/PSDONE handshake, and direct fractional-divider output that eliminates the Bresenham approximation entirely (output is at source × M/N exactly).

---

## Open question: SYNC mode loop converged "eventually"

Sub-test B (sync ref + 5 slots) showed the loop actually walking err toward zero over 14 seconds. That's the first time we've seen anything like convergence in this session. Two questions worth thinking about:

1. **Why didn't earlier SYNC tests (with 3 slots) converge similarly?**
   They had the same loop dynamics. Maybe they did converge but we never observed long enough; or maybe the 5-slot test happened to have a different initial phase offset that was within the actuator's reachable range.

2. **Even when it "converged," it oscillated around +20k–30k err** (not zero). Why?
   The MMCM actuator's quantization (each PSEN pulse = ~22 ps of phase shift = ~6 ppm of rate) plus the asymmetric inc/dec rate. The actuator can't sit exactly at the rate-cancellation setpoint; it overshoots, undershoots, overshoots... limit-cycle behavior.

These are interesting but secondary. They don't change the spike-done conclusion.

---

## Recommended Si5351 swap acceptance criteria

When the Si5351 lands and the swap is bench-tested, expect:

| Metric | MMCM (this build) | Si5351 (target) | Why |
|---|---|---|---|
| ach_rate vs cmd | -530 ppm gap (cmd-500, ach+32) | Match within ±5 ppm | Si5351 has direct rate authority via fractional divider |
| sat counter at steady state | Monotonically rising | Stable at 0 | Si5351 doesn't need to peg at clamp |
| int_mppm at steady state | -94k to -480k (drifting) | Small magnitude (<10k) | Loop doesn't need to integrate against actuator deficit |
| Lock state | Never LOCKED | LOCKED within seconds | Loop's lock threshold is achievable |
| Picture | Static wrap at fixed phase | Clean | Phase tracks ref over time, no DC offset |

**These metrics ARE the calibration baseline for the post-Si5351 acceptance test.** Anything in the Si5351 build that LOOKS like this MMCM characterization → the Si5351 swap hasn't done its job; investigate.

---

## Spike-done declaration deferred

Spike-done CANNOT be declared until either:

1. **Si5351 swap lands + above metrics are met.** Expected primary path.
2. **An alternative MMCM-side fix is found that addresses the slew limit.** Unlikely given the hardware-authority nature of the limit. Possibilities (each speculative): different psincdec drive pattern (e.g., commit only INC steps, never DEC, by always biasing the integrator to a "pull-up" operating point); software-side compensation for the asymmetric inc/dec gain. Not pursuing — these are workarounds for a fundamental actuator inadequacy.

**Status as of this doc:** Phase E1/E2 architecture validated except for actuator. Awaiting Si5351 hardware delivery to close the loop.

---

## Files committed this session

| File | Purpose |
|---|---|
| `hdl/iter4a_test_mux.v` + tcl wiring | Diagnostic mux for known-signal injection (commit b25d27d) |
| `sw/phase-b/src/main.c` measure_source_rate_mhz | Iter-4a bias fix — `prev=1` after sync break (b25d27d) |
| `sw/phase-b/src/main.c` cmd_srcdiv_set / cmd_auto_frc | 16-bit M/N + auto-FRC (committed in earlier session) |
| `hdl/src_vsync_divider.v` COUNT_WIDTH=16 | Widened from 8 to 16 bits for NTSC support |
| `sw/phase-b/src/main.c` err median filter | Bresenham jitter rejection (commit 6eb38b8) |
| `sw/phase-b/src/main.c` ach_rate logger + histogram | Slew-limit diagnostic (commit 348a338) |
| `sw/phase-b/src/main.c` cmd_auto_frc VTC re-alignment | Post-`a` alignment dance (commit 04cc00a) |
| `tcl/build_phase_b.tcl` c_num_fstores 3→5→3 | Outcome 2.5 attempted, reverted (commits b4cf00c → this doc's revert) |
| `tests/phase-e1/phase_e2_bench_session_2_review.md` | Updated by Justin pre-session to add Outcome 2.5 branch |
| `tests/phase-e1/phase_e2_psincdec_limit.md` | This doc |
