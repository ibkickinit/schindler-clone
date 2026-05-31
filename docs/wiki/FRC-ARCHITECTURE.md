# FRC Architecture

Frame Rate Conversion strategy. Schindler 2.0 implements (or plans) five FRC methods inspired by the Retrotink RT4K's three-mode UX + Mackin Inc's virtual-shutter blend.

Source corpus: memory entries `schindler_frc_architecture_compass`, `frc_mackin_virtual_shutter_blend`, `schindler_phase_e_roadmap`, `xilinx_mmcm_psincdec_tracking`, `xilinx_vdma_drift_limits`, `schindler_vdma_dynamic_genlock`, `schindler_two_oscillators_no_pll`, `fpga_video_ascal_reference`.

## Method codes (per format-support-matrix.md)

| Code | Method | Description | Phase | Status |
|---|---|---|---|---|
| **A** | **Frame Lock** | Output clock derived from input pclk; no FRC; matched rate only | A/D | ✅ Shipped on iter5 |
| **B** | **Gen Lock** | MMCM `psincdec` tracks input via vsync-delta feedback; absorbs ~±500 ppm drift | E1 | 🟢 Spike shipped on `phase-e1-pll-spike` |
| **C** | **Triple Buffer / Async Ring** | Free-running output + 5-slot ring + firmware hysteresis. Picky-sink compat mode, accepts drop/repeat | E3 | 🔲 Not started |
| **D** | **Drop/Repeat (Dynamic Genlock)** | Nearest-neighbor frame pick at output vsync. Current shipping FRC | A/D | ✅ Shipped on iter5; the workhorse |
| **E** | **Mackin Virtual-Shutter Blend** | Phase-weighted 2-frame blend; degenerates to drop at clean ratios; smooth at ugly | E2 | 🟡 HDL/sim complete, bench wiring placeholder |

## Architectural foundation: Method D (Dynamic Genlock)

This is what ships today. The `axi_vdma_0` runs:
- **S2MM mode 2** (Dynamic Master)
- **MM2S mode 3** (Dynamic Slave with `repeat_en`)
- **FrameDelay=1**
- **5 framestores** (bumped from 3 in iter5 for drift headroom — see `xilinx_vdma_drift_limits` memory)

S2MM writes whenever the source has a new frame. MM2S reads whenever output asks for one. If output is faster than source, MM2S re-reads the most-recent completed frame (repeat). If slower, MM2S skips ahead (drop).

**Caveat (memory `schindler_vdma_dynamic_genlock`):** PG020 doesn't promise SOF-atomic latching for firmware PARK_PTR_REG writes per vsync. The all-hardware Dynamic Genlock path is what we use; firmware-PARK anti-pattern is documented to NOT do.

**Caveat (memory `xilinx_vdma_drift_limits`):** PG020 doesn't promise drift tolerance. FrameDelay=1 + 3 framestores is brittle; 5 framestores give 2× headroom but not infinite. Long-term mitigations are firmware hysteresis OR MMCM/PLL tracking (Methods B/E).

## Method B (Gen Lock, Phase E1)

Closed-loop MMCM phase nudge via DRP. Firmware measures vsync delta between source and output; PI controller computes a tiny per-frame phase step; applied to output `clk_wiz_pixclk_out` via the DRP port.

Range: **±500 ppm pull** (MMCM `psincdec` hardware limit). Handles NTSC 1000/1001 drift with zero dropped frames. Outside ±500 ppm, falls back to drop/repeat.

Substrate: `phase-e1-pll-spike` branch. Bench-clean 60→60 matched-rate motion 2026-05-30. NOT designed for 5:2 or other large FRC ratios — `phase-e1` will saturate the tracking loop on those.

Prior art memory: `xilinx_mmcm_psincdec_tracking` — Intel VSYNC-mod, rrk1 FPV-scaler, ascal `o_lltune` are documented predecessors.

## Method E (Mackin blend, Phase E2)

Temporal blender that interpolates between two adjacent source frames based on the output's phase position. At a clean 5:2 ratio it degenerates to drop/repeat (alpha snaps to 0 or 1). At an ugly near-1:1 ratio (e.g., 60.0001→60.0000), it smoothly cross-fades.

**Cost:** ~1.5× HDL of pure blend (the phase-weighted mux adds vs. straight 50/50).

**HDL status (memory `schindler_mackin_implementation`):**
- Mackin core HDL: ✅ complete
- Python golden model: ✅ complete
- Sim suite: ✅ 3360/3360 bit-exact PASS
- Bench wiring: ⚠️ placeholder `axis_clone` — both VDMA paths feed the same frame so alpha changes nothing visible
- Dual-VDMA + classic-Genlock wiring: ⏳ deferred to bench session

Memory `frc_mackin_virtual_shutter_blend` documents the algorithm + the trade-off chart.

UART command: `a <hex>` (Q1.15 alpha, 0..0x8000). See [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md).

## Method C (Triple Buffer, Phase E3)

Free-running output clock + 5-slot framestore ring + firmware hysteresis to absorb non-matched rates. Lowest correctness, highest sink compatibility. Used by RT4K as a fallback mode for picky displays.

Not started.

## Method auto-selection (planned)

Per `format-support-matrix.md` §6: firmware picks A/B/C/D/E automatically based on:
- `dvi2rgb pLocked` (source presence)
- VTC rate detector (source rate vs. configured output rate)
- Drift accumulator (how far apart over time)

Today: always Method D via Dynamic Genlock. Auto-selection requires Methods B+E real-wired first.

<!-- AGENT_TASK[fw-3]: Implement FRC method auto-selection per format-matrix priority. Currently always Method D. Add A/B/C/E selection on top of rate-detect + GPIO override. -->

## The "two oscillators" hard rule

Memory `schindler_two_oscillators_no_pll`: two free-running oscillators at the same nominal rate cannot be kept phase-aligned by any fsync gating, framestore depth, or buffer trick. **The architecture answer is always a PLL.**

This is why Phase E1 (MMCM `psincdec`) exists. It's also why Phase E2 wants Si5351 — to extend pull range beyond MMCM's ±500 ppm.

Proven 2026-05-18 across 4 fsync variants by the user himself: "Isn't there a mathematical formula? This seems more touchy-feely vibes-based than science." The mathematical formula IS a PLL.

## Prior art

Memory `fpga_video_ascal_reference` documents the MiSTer `ascal` polyphase scaler + triple-buffer + `o_lltune` PLL nudge as the closest community analog to Schindler's stack. Worth reading when building Phase E modes.

## RT4K three-mode UX framing

Memory `schindler_frc_architecture_compass`: long-term target is RT4K's three-mode UX = Frame Lock + Gen Lock + Triple Buffer modes user-selectable at runtime, plus Mackin blend as a deeper-tuned setting.

This aligns Methods A/B/C/D/E to a clean operator-facing surface:
- "Frame Lock" = A
- "Gen Lock" = B (+ E auto-engages at near-matched-but-drifting)
- "Triple Buffer" = C
- D is the legacy fallback when E1/E2 unavailable

<!-- AGENT_TASK[docs-8]: When Methods B+E are real-wired and Methods C is built, write the operator-facing FRC mode UI/UX spec. Maps to RT4K's three-mode model. -->

## Open question for the project

How does FRC choice interact with Phase G analog out? Composite and S-Video have stricter sub-carrier phase requirements than HDMI. Likely answer: Phase G clocking budget should drive Method choice when analog output is engaged.
