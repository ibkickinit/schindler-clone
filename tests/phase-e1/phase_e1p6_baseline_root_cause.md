# Phase E1.6 — Root cause of the +102 ppm baseline

**Status:** PASS ✓ 2026-05-19. The +102 ppm baseline is MMCM-specific (not measurement bias) AND load-bearing for monitor compat at 60→50 FRC. Loop's job is to compensate it. Phase 4–8 validated at monitor level when loop is locked.

## Phase 1 of the investigation — why +102 ppm

The drift is from the MMCM, not the measurement chain. `.xci` reports:

```
"C_CLKOUT1_REQUESTED_OUT_FREQ": 74.250 MHz
"C_CLKOUT1_OUT_FREQ":           74.24242 MHz   ← (-102 ppm)
```

### Why -102 ppm is the achievable minimum

Enabling `CLK_OUT1_USE_FINE_PS_GUI=true` (needed for Phase 4's actuator) restricts the MMCM solver to integer `CLKFBOUT_MULT_F`. Exact 74.25 MHz from 100 MHz would require integer M satisfying `100 × M / (D × O) = 297/4`. Since `gcd(297, 100) = 1`, minimum M = 297, which exceeds the MMCME2_ADV primitive's hard cap of 64. Confirmed by Vivado error when we attempted to override:

```
ERROR: [IP_Flow 19-3460] MMCM_CLKFBOUT_MULT_F should be in the range 2 - 64
```

Exhaustive search across O ∈ [9,16] (legal VCO range 600–1200 MHz):

| O | Best (M,D) | Output | ppm error |
|---|---|---|---|
| 11 | M=49, D=6 | **74.2424 MHz** | **-102** ✓ current |
| 14 | M=52, D=5 | 74.2857 | +481 |
| (rest) | — | — | farther |

**-102 ppm is the hardware floor.** Changing the PS PLL clock doesn't help (PS PLL integer FBDIV is similarly restrictive).

## Phase 2 of the investigation — the false-start fix

Hypothesis: if -102 ppm is the achievable rate, retune the synth ref to match it, eliminating the loop's chase. Implemented as `synth_vsync_gen.v` DIVISOR 2,857,143 → 2,857,434.

UART-level metrics looked perfect:
- Free-run drift: +102 ppm → +0.14 ppm
- Lock integrator setpoint: -210k mppm → -98 mppm
- Lock err: 1-tick steady-state

**But the physical monitor was corrupted.** Heavy horizontal-stripe tearing + vertical-echo replication of the source image. With loop on or off. Even after rebuild + clean reload.

## Phase 3 of the investigation — what the monitor was telling us

Source is 60 Hz Windows; output target is 50 Hz. The pixel pipeline (Phase D iter-4d-3 substrate: Dynamic Genlock + 3 framestores + FrameDelay=1) handles FRC by hardware-enforced master/slave frame-pointer following. It works cleanly **only when the source/output rate ratio is exactly 6:5** — small drift is absorbed by the 3 framestores; large mismatch laps within the framestore depth and tears.

- **d71c994 build** (pre-fine-PS): MMCM auto-picked fractional MULT_F=11.875, output = 74.21875 MHz, vsync = **50.000 Hz exactly**. Source(60):output(50) = clean 6:5. Monitor clean. (Confirmed: QSPI boot today.)
- **Phase 4+ build, loop off**: fine-PS forces integer MULT, MMCM lands at 74.2424 MHz, vsync = **49.99490 Hz**. Ratio = 1.20012:1. Drifts past framestore depth quickly → monitor tearing.
- **Phase 4+ build, loop locked, DIVISOR=2,857,143** (Phase 7/8 ref rate, 50 Hz exact): loop pulls output up to match ref → output = **50.000 Hz exactly** → clean 6:5 → monitor clean.
- **Phase 4+ build, loop locked, DIVISOR=2,857,434** (E1.6 retune, ref matched to MMCM rate): loop locks but output stays at **49.99490 Hz** → broken ratio → monitor still corrupted.

So the +102 ppm baseline is the gap between the synth ref's "what monitor wants" (50.000 Hz exactly, dictated by clean source-ratio) and the MMCM's native rate (49.99490 Hz, dictated by integer-MULT constraint). **The loop's job is to bridge that gap.** The integrator's steady-state setpoint of -94 ppm is correct and load-bearing.

The E1.6 DIVISOR retune was a regression. Reverted.

## Phase 4 of the investigation — what the MS2109 was lying about

The MS2109 USB capture stick has been the only visual-verification tool through all of Phase 4–8. Initial post-mortem suspicion: it was hiding monitor corruption across the entire phase progression.

That suspicion was *partially* wrong. The Phase 4–8 docs that claimed "loop locked, picture stable" were **correct** — locked output at 50.000 Hz produces a clean 6:5 ratio that the monitor accepts. MS2109 and monitor agree on that state.

What MS2109 *did* hide: the **loop-off state**. With loop off, output drifts at native 49.99490 Hz vs the monitor's expected 50.000 Hz, ratio breaks, monitor tears. MS2109 absorbs the drift (its internal framebuffer re-samples). So:
- Phase 7's "free-run mode picture stable" claim was MS2109-mediated and false. (Free-run = loop forced off → monitor would have shown corruption if checked.)
- Phase 7's "LOCKED state stable" claim was correct on both MS2109 and monitor.
- Phase 8's slip-injection picture-stability claim probably also MS2109-mediated for the saturated portions.

Updating these docs in a separate follow-up. The underlying Phase 4–8 architecture is sound.

## Loop locking is mandatory for monitor compat

Once fine-PS is enabled and 60→50 FRC is needed (anything other than 1:1 ratios), **the loop must be locked for the picture to be monitor-clean.** Loop-off is now a degraded/diagnostic state, not a normal operating point.

Implications for Phase E2 onward:
- **Auto-enable loop at boot.** Manual `L` should not be required for normal operation.
- **Loss-of-lock behavior matters.** If the loop ever drops out of lock, the picture corrupts within a few framestore-depths. Need either fast re-lock (Phase 7's hold-over already gives <1s after brief signal loss) or graceful degradation. Consider mute / freeze-frame on prolonged loss.
- **For other FRC ratios** (60→24, 50→60, 24→60, etc.): same principle — output must lock to integer ratio with source. Phase E2's three-mode design (SNAP / SMOOTH / FILM) needs to formalize this.

## Build provenance (working state)

- **Branch:** `phase-e1-pll-spike`
- **Bitstream:** 2026-05-19 (Phase 7/8-equivalent ref rate). WNS=+0.309 ns, WHS=+0.026 ns.
- **Firmware:** INTEGRATOR_PRELOAD = -94000 mppm restored.
- **Net change vs Phase 8 (47eb7d2):** documentation only. Active HDL/firmware values are identical to Phase 7/8.

## Open items for next phase

1. **Auto-enable loop at boot** (firmware tweak, ~5 lines).
2. **Substrate timing closure pass.** WHS=+0.026 ns is uncomfortably tight; intermittent UART hangs through this session likely hold-margin failures. Consider adding hold-margin pessimism / placement constraints.
3. **Loss-of-lock UX.** Decide between fast re-lock vs mute/freeze on prolonged loss.
4. **Document MS2109 caveats** in the Phase 4–8 docs.

## Artifacts

| File | Purpose |
|---|---|
| `hdl/synth_vsync_gen.v` | DIVISOR=2,857,143 (50 Hz exact); comment block documents why E1.6 retune was wrong |
| `sw/phase-b/src/main.c` | INTEGRATOR_PRELOAD_MILLI_PPM = -94000 |
| `tcl/build_phase_b.tcl` | Comment block documenting MMCM hardware floor |
| `tests/phase-e1/phase_e1p6_baseline_root_cause.md` | This doc |
| Justin's webcam shot of corrupted monitor | Evidence of loop-off broken-FRC tearing |
