# Phase E2.1 — Source-vsync as loop reference

**Status:** HDL + BD + firmware shipped + Vivado/Vitis build verified 2026-05-19 (commit `07a8b39`). Bench validation (UART + monitor) pending — needs user.

**Goal:** Lock the loop's reference to a Bresenham-divided HDMI source vsync (instead of the fixed-rate synth_vsync_gen). Closes the architectural gap E1.8 identified: source rate variations (Mac 59.94, Apple TV ~60.001, etc.) currently cause output/source ratio drift → monitor tears within tens of seconds. With source-derived reference, the ratio is locked-by-construction; output tracks source × M/N exactly, drift is zero regardless of source rate.

## Architecture

```
dvi2rgb_0/vid_pVSync     ───►  src_vsync_divider_0  ──►  ref_mux_0  ──►  vsync_timestamp_0
  (PixelClk domain,             (CDC sync + Bresenham      (sel=11 →       (loop's phase
   raw HDMI vsync)                fractional divider)       ref_ext1)       detector)
                                       ▲
                                       │ M, N from axi_gpio_srcdiv (M06)
                                       │ Firmware writes via UART 'n <M> <N>'
```

**Bresenham guarantees** exactly M output pulses per N source edges over the long run — zero long-term ratio drift. Short-term jitter ±1 source period (= 16.67 ms at 60 Hz); the loop's PI controller filters this out.

## Files changed

| File | Change |
|---|---|
| `hdl/src_vsync_divider.v` | NEW. 2-FF CDC sync + edge detect + Bresenham fractional divider. Pulse-based output (1 cycle per ref event). |
| `tcl/build_phase_b.tcl` | Added `add_files` for new HDL; bumped `axi_ic_lite` NUM_MI 6→7; added M06 clock+reset; instantiated `src_vsync_divider_0`, wired its inputs and output; instantiated `axi_gpio_srcdiv` for M/N control. Removed the `ref_ext1` tielow connection. |
| `constraints/zybo_z7_20_phase_b.xdc` | Added `set_false_path` on the new CDC sync's q1 register. |
| `sw/phase-b/src/main.c` | Added `REFSEL_SRC=0x3` enum; extended `cmd_ref_select` to handle "src"; new `cmd_srcdiv_set` bound to `n` command; updated help banner. |

## Test plan

### Build verification (no bench needed) — DONE

- [x] Vivado synth completes without errors. (One failed attempt: first build had WNS=-1.694 ns from a cross-domain reset wiring bug — `rst_mem` is on FCLK_CLK1; src_vsync_divider needed FCLK_CLK0's `rst_axi`. Fixed and rebuilt.)
- [x] WHS ≥ +0.050 ns intrinsic. Achieved WNS=+0.403 / WHS=+0.017 reported with +0.050 ns uncertainty → intrinsic **+0.067 ns** (E1.7 floor maintained).
- [x] No new critical warnings from src_vsync_divider or axi_gpio_srcdiv.
- [x] Firmware compiles cleanly against new XSA. Two pre-existing warnings (`MODE_720P60 defined but not used`, `measure_output_rate_mhz defined but not used`); none from E2.1 code.

### Functional UART tests (no bench monitor needed)

After JTAG load + firmware boot:

1. **Default boot state.** Confirm boot defaults are `r sync` (Phase 7 behavior preserved); src_vsync_divider exists but isn't selected. Send `q`; ts_ref should advance at 50 Hz from synth_vsync_gen (per existing behavior).

2. **Switch to source-vsync ref, 1:1.** Send `r src`. Confirm UART responds `[R] reference = SRC (source vsync × 1/1 via src_vsync_divider)`. Send `q`; ts_ref should now advance at **source rate** (~60 Hz for Windows source), not 50 Hz. Use `p` or `D` to confirm.

3. **Set FRC ratio 5/6 for 60→50.** Send `n 5 6`. Confirm UART responds `[N] src_vsync_divider M/N = 5/6  (ref rate = source × 5/6)`. Verify ts_ref now advances at ~50 Hz (source 60 × 5/6 = 50).

4. **Enable loop in src-ref mode.** Send `L`. Loop should acquire — integrator settles near 0 (because the loop is now bridging source→exact-50 instead of MMCM-natural→synth-50, which was the old +102 ppm gap).

5. **Source absence test.** Disconnect source HDMI temporarily (or simulate via firmware mask). Verify Phase 7 HOLDOVER kicks in correctly with src-ref mode (existing ref-absence detection should handle source-derived ref the same as synth-derived).

### Bench verification (needs user at monitor)

6. **60→60 case, monitor visual.** Set output VTC to MODE_720P60. `r src`, `n 1 1`, `L`. Output should lock to source rate 1:1. Monitor picture should stay clean even with Mac/Apple TV/other-source-rate sources, because output now floats with source.

7. **60→50 case, monitor visual.** Set output VTC to MODE_720P50 (default). `r src`, `n 5 6`, `L`. Output should lock to source × 5/6 = 50 Hz exactly. Monitor picture should stay clean across the source field.

8. **Multi-source soak.** Cycle through Windows / Mac / Apple TV / etc. with the src-ref mode active and `n 5 6`. All should produce clean monitor picture (this is the E1.8 architectural prediction's validation).

## Open design questions

- **Output-side VTC mode selection.** Firmware currently hardcodes MODE_720P50. For 60→60 to work via 'r src n 1 1', firmware needs a `vtc_mode <preset>` command — out of scope for E2.1 spike, but easy follow-up.
- **Auto-FRC-detection.** Firmware could detect source rate (via existing iter-4a measurement) and auto-set M/N. Defer; for the spike, manual `n <M> <N>` is fine.
- **Bresenham jitter and loop PI tuning.** With pulse-spacing variance of ±1 source period, the loop's per-edge phase error has more noise than synth-ref mode. Existing PI gains (Kp=10, Ki=1) should handle it but bench validation will confirm.

## Provenance

- **Branch:** `phase-e1-pll-spike`
- **Commit:** TBD after build verification
- **Build state:** Vivado batch running at write time
