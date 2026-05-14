# Phase C — Polyphase Scaler (HD-to-HD, configurable ratio)

**Status (2026-05-14):** ✅ **Phase C.1 done** at **1080p → 720p**. Build #6 (`scaler_v` 1-cycle pipeline rewrite, WNS +0.294 ns) brings up a recognizable Mac desktop on the bench monitor — geometry correct, colors clean, menu bar readable. Residual cross-clock-domain tearing (visible as two stacked copies of the frame with a salt-and-pepper mid-band) is **Phase D scope**: input runs on dvi2rgb-recovered PixelClk (148.5 MHz), output on PS-derived `clk_wiz_pixclk_out` (74.25 MHz), both nominally 60 Hz but un-genlocked. Victory image: `build/ila-capture/phase-c-victory/scaler-720p-monitor.jpg`. See "C.1 first-light debug" below for the build #5→#6 debug arc.

**Goal:** add a polyphase scaler block to the Phase B DDR3 pipeline. First-light target was 1080p → 480p; pivoted to **1080p → 720p (3:2 H and V)** mid-session. Reusable inside Phase G's composite encoder terminal (which needs HD→SD downconvert) per spec §2.1.

## Pivot from 480p (2026-05-14)

The Digilent **rgb2dvi IP only accepts `kClkRange = 1, 2, or 3`** — which puts a floor on the pixel clock of roughly 40 MHz at kClkRange=3 (MMCM VCO must stay ≥ 600 MHz). 480p's 27 MHz pixel clock is below that floor, triggering DRC `MMCM_adv_ClkFrequency_div_no_dclk` at bitstream-time (VCO=135 MHz, way under spec).

Options considered:
1. **Patch rgb2dvi's component.xml** to extend `kClkRange` to {1,2,3,4,5}. The underlying VHDL handles MULT_F up to 25 (dvi2rgb does this for HDMI RX of 25 MHz signals). ~10 min effort. Deferred.
2. **Write a custom TMDS encoder** to bypass rgb2dvi. Days of HDL work.
3. **Pivot to 720p output** (74.25 MHz, kClkRange=2). Done.

For the eventual SD/CRT output target, the path is **not** HDMI-480p — it's the composite encoder terminal (Phase G), which drives an ADV7393 via parallel YCbCr, totally independent of HDMI. So forcing 480p through HDMI was only a "convenient HDMI test" goal; pivoting to 720p doesn't change the long-term plan.

Per [`01-spec.md`](01-spec.md) §2.1: "RGB or YCbCr 4:2:2 at up to 1080p60 flows from input decoder through **scaler / color / geometry** to a shared HD signal bus." The scaler is a stage on the HD bus — independent of terminal encoders, which may apply additional SD-specific filtering.

Per [`dev-roadmap.md`](dev-roadmap.md) Phase C: "Xilinx Video Scaler IP vs custom 8-tap H / 4-tap V. 1080p → 720p / 480p test cases." Choosing **custom HDL** — Schindler is supposed to be open, inspectable, every coefficient tunable.

Phase C has four sub-steps:

- **C.0 — Plumbing pass-through.** Identity scaler (1080p → 1080p, identity coefficients). Verifies the BD insertion + VDMA AXIS width changes + clocks. Picture on monitor identical to Phase B output.
- **C.1 — First-light downscale.** 1080p → 480p with Lanczos-2 coefficients, both H and V. 720×480p picture on the monitor (or stretched on 1080p panel via monitor's scaler).
- **C.2 — Configurable ratio.** Parameterize scale ratios; add 1080p→720p as a second test case.
- **C.3 — Tune & characterize.** Test patterns, aliasing inspection, coefficient variants (Lanczos vs Mitchell vs custom CRT-optimal).

## Architecture

```
HDMI RX TMDS ──► dvi2rgb ──► v_vid_in_axi4s [PixelClk_in 148.5 MHz, source-locked]
                                  │ AXIS 24-bit RGB, 1080p
                                  ▼
                          polyphase_scaler ◄── coeff ROM (BRAM)
                                  │ AXIS 24-bit RGB, scaled size (720x480 for C.1)
                                  ▼
                          AXI VDMA S2MM
                                  │
                                  ▼
                                DDR3 (3-frame ring, scaled-size frames)
                                  │
                                  ▼
                          AXI VDMA MM2S ──► axis_to_vid_io ──► rgb2dvi ──► HDMI TX
                                                              [PixelClk_out 27 MHz for 480p,
                                                               or 74.25 MHz for 720p]
                                  ▲ vtiming
                                  │
                                v_tc (reconfigured for output resolution)
```

**Pipeline placement: scale-on-write.** Scaler sits between `v_vid_in_axi4s` and `axi_vdma_0/S_AXIS_S2MM`. DDR3 stores already-scaled frames (smaller). MM2S/output side stays as-is from Phase B.

Rationale: scaling before DDR3 means
- Less DDR3 bandwidth and memory used per frame
- MM2S/adapter/VTC stay simple — they just emit a smaller frame at the output pixel rate
- Output clock is whatever resolution we choose (27 MHz / 74.25 MHz / etc.) via clk_wiz_pixclk_out reconfigure
- Future Phase D (FRC) can re-use the post-scaler frame buffer without scaler entanglement

## Scaler block

```
        AXIS in [24-bit RGB, in_w × in_h, runs at PixelClk_in]
              │
              ▼
    ┌──────────────────────────┐
    │ scaler_h.v               │  8-tap polyphase H filter
    │  • shift register, 8 px  │  64 phases
    │  • MAC × 3 channels      │  step = in_w / out_w (fractional, e.g. 1920/720 = 2.667)
    │  • output_valid per      │  output width × in_h scanlines on output
    │    phase-counter wrap    │
    └──────────┬───────────────┘
               │ AXIS 24-bit RGB, out_w × in_h
               ▼
    ┌──────────────────────────┐
    │ scaler_v.v               │  4-tap polyphase V filter
    │  • 4 × out_w line BRAM   │  64 phases
    │  • MAC × 3 channels      │  step = in_h / out_h (e.g. 1080/480 = 2.25)
    │  • new output line when  │  out_w × out_h on output
    │    V phase wraps         │
    └──────────┬───────────────┘
               │ AXIS 24-bit RGB, out_w × out_h
               ▼
       (to VDMA S2MM)
```

### Coefficients

- Precomputed at build time via `python/gen_coeffs.py`
- Lanczos-2 windowed sinc by default (good sharpness/aliasing balance)
- 64 phases, 8 taps H × 4 taps V
- Stored as signed 12-bit fixed-point fractions in BRAM:
  - H: 64 phases × 8 taps × 12 bits = 6144 bits = 1 × 18 Kbit BRAM (plenty headroom)
  - V: 64 phases × 4 taps × 12 bits = 3072 bits = ½ × 18 Kbit BRAM
- Output of MAC tree truncated to 8 bits per channel with rounding

### Pixel format

- 24-bit RGB888 (matches v_vid_in_axi4s output, matches Phase B AXIS).
- Each channel scaled independently. This is suboptimal vs YCbCr (chroma should be filtered more aggressively to avoid color fringing) but matches existing pipeline; YCbCr-aware scaling deferred until [Phase E color pipeline](dev-roadmap.md) lands.

### Output clocking

For 480p output:
- Pixel rate: 27.00 MHz (CEA-861 480p = 720×525 frame at 60 Hz → 720×480 active)
- `clk_wiz_pixclk_out` reconfigured: 200 MHz FCLK_CLK2 input → 27 MHz output (MMCM, easy fractional)
- Or use FCLK_CLK0 (100 MHz) → 27 MHz output

For 720p output:
- Pixel rate: 74.25 MHz
- `clk_wiz_pixclk_out`: 200 → 74.25 MHz

The scale ratio is fixed at IP-generate time for C.1, so the output clock is also fixed per build. C.2 will plumb a runtime-reconfigurable clock via PS dynamic-reconfig of clk_wiz.

## VTC reconfig

Firmware writes new timing registers for the chosen output resolution. For 480p:
- HActive=720, HTotal=858, HSync start=736, HSync end=798
- VActive=480, VTotal=525, VSync start=489, VSync end=495
- Polarity: 480p sync is **negative** (active-low H+V) per CEA-861 — flip GPOL bits

For 720p:
- HActive=1280, HTotal=1650, HSync start=1390, HSync end=1430
- VActive=720, VTotal=750, VSync start=725, VSync end=730
- Polarity: positive (active-high H+V)

Add `vtc_setup_480p()` and `vtc_setup_720p()` functions to `sw/phase-b/src/main.c`; firmware picks one at build time for C.1.

## VDMA reconfig

S2MM frame size: was 1920×1080×3 = 6,220,800 B for Phase B. For 480p: 720×480×3 = 1,036,800 B. For 720p: 1280×720×3 = 2,764,800 B.

Firmware needs new `FRAME_W`, `FRAME_H`, `STRIDE` constants. Probably good to add a `#define OUTPUT_FORMAT_480P` (or `_720P`) at the top so they're picked at compile.

## Implementation steps

**C.0 — Plumbing pass-through (~0.5 day)**:
1. Write `hdl/scaler_passthrough.v`: AXIS in → AXIS out, single-cycle latency, just a register. Same width.
2. Insert into BD between v_vid_in_axi4s and VDMA S2MM (BD edit).
3. Build, program, verify picture identical to Phase B output. If yes, plumbing is correct.

**C.1 — Polyphase 1080p → 720p (pivoted, status: HDL done, bitstream built, bench-verify pending)**:
1. ✅ `python/gen_coeffs.py`: Lanczos-2 coefficient .hex generation.
2. ✅ `hdl/scaler_coeffs_h.v`, `hdl/scaler_coeffs_v.v`: BRAM ROMs.
3. ✅ `hdl/scaler_h.v`: 8-tap polyphase H, parameterized but currently hardcoded 1920→1280.
4. ✅ `hdl/scaler_v.v`: 4-tap polyphase V with 4-line BRAM buffer, hardcoded 1080→720.
5. ✅ `hdl/scaler_top.v`: wraps H + V.
6. ✅ `clk_wiz_pixclk_out` reconfigured for 74.25 MHz (720p pixel clock).
7. ✅ Firmware `vtc_setup_720p()` added with CEA-861 720p timing; FRAME_W/FRAME_H updated to 1280/720.
8. ✅ Build #5 produced clean bitstream (WNS +0.343, WHS +0.009). Saved to `build/ila-capture/phase-c-victory/scaler-720p-build5.bit`.
9. ❌ Bench bring-up: monitor + capture stick both show "alternating digital snow and squished video like 1080i doubling into a P frame", LEDs all lit, VDMA registers clean. See "C.1 first-light debug" below.
10. ✅ `sim/scaler_top_tb.v` xsim testbench reproduces deterministically — 360 lines per frame instead of 720 (no backpressure), and 1067-wide instead of 1280-wide lines under 80% backpressure. Sim log: `build/ila-capture/phase-c-victory/scaler-sim-bugs.log`.
11. ✅ `hdl/scaler_v.v` rewritten with 1-cycle-throughput output pipeline; sim passes 0 errors under both no-bp and 80% bp.
12. ✅ Build #6 (scaler_v 1-cycle rewrite) closed timing at WNS +0.294 / WHS +0.019, programmed, bench shows recognizable Mac desktop with menu bar visible. Residual cross-clock-domain tearing → Phase D scope. Victory image: `build/ila-capture/phase-c-victory/scaler-720p-monitor.jpg`.

## C.1 first-light debug (2026-05-14)

Build #5's bitstream programmed cleanly and the firmware came up fine — VTC reported 1280×720 timing with the RU bit set, fsync pulses, VDMA running with HSIZE=3840/VSIZE=720, error bits clean, PARK rotating through 0/1/2 (S2MM was actively writing frames). But the picture was unusable: alternating digital snow and "squished video like 1080i doubling into a P frame", same on the bench monitor and the MacroSilicon capture stick.

Built `sim/scaler_top_tb.v` — an xsim frame-level testbench that drives one full 1920×1080 input frame through `scaler_top` and asserts per-frame pixel/line counts. Two distinct bugs reproduced:

**Bug A (no backpressure):** output frame had **360 lines × 1280 pixels** (correct width, half the expected count). Pattern: per 3 input rows, two `v_cross` events fire on consecutive rows (rows 1+2, 4+5, 7+8, ...). The old `scaler_v.v` ran a 2-cycles-per-pixel output pipeline (1 pixel per `(stage 0 read + stage 2 latch)` pair), so a 1280-pixel emit took 2560 cycles — longer than the 1970-cycle input-row time. The second cross's TLAST handler did `emit <= 1; out_col <= 0;` while emit 1 was still mid-row, clobbering it. Net: every "pair" of crosses produced only one TLAST'd output line. 720/2 = 360. Matches the bench observation exactly ("squished video" = vertically halved).

**Bug B (80% backpressure):** lines collapse to 1067-wide. Same root cause — pipeline got slower under stall, more emits got clobbered earlier.

**Fix:** rewrite `scaler_v.v` output pipeline to 1 pixel per cycle. Stage 0 (issue BRAM read at `out_col`) and stage 1 (MAC + present on m_axis) now both advance every cycle when `pipe_advance = !m_axis_tvalid || m_axis_tready`. 1280-pixel emit now takes 1280 cycles, comfortably inside the 1970-cycle row time — no more cross collisions. Same fix tolerates ~30% sustained backpressure before colliding again, well past anything VDMA should ever produce.

Sim run on the fix: **0 errors**, both no-bp and 80%-bp cases.

**Lesson:** the doc's own "Risks and unknowns" section already called this out ("AXIS handshake during downscale. ... Build-time-sim with cocotb or VVP would catch mistakes early."). Two builds and one bench session later, that's exactly what caught it. Future scaler ratio changes should run the testbench first.

**Build history**:
- #1: failed — DRC INBB-3 black-box on scaler_0 at impl_1 (Vivado OOC linking quirk for module-reference cells with sub-modules)
- #2: failed — `GENERATE_SYNTH_CHECKPOINT` set_property read-only error
- #3: failed at bitstream-time — rgb2dvi MMCM VCO 135 MHz out of spec for 27 MHz pixel clock (the actual fundamental issue). Caching from earlier build runs made the OOC linking self-resolve along the way, so the scaler black-box issue went away by attempt #3 and didn't require a workaround in the final TCL.
- #4: failed — `kClkRange=5` rejected by rgb2dvi IP (only allows {1,2,3}).
- #5: built clean (WNS +0.343, WHS +0.009) but bench-broken — half-frames due to 2-cycle-per-pixel scaler_v pipeline.
- #6: same TCL + scaler_v rewritten to 1-cycle pipeline; sim-verified pass.

**C.2 — Configurable ratio (~1-2 days)**:
- Parameterize H/V scale ratio via top-level Verilog generics or AXI-Lite registers.
- Switchable coefficient sets (480p vs 720p vs 1080p).

**C.3 — Tune & characterize (~ongoing)**:
- Test patterns from Phase 2 HDL (vbi_gen / sample_gen) for systematic aliasing inspection.
- Compare Lanczos-2 vs Mitchell-Netravali vs custom coefficient kernels.

## Risks and unknowns

- **AXIS handshake during downscale.** Polyphase H consumes ~scale_ratio input pixels per output pixel — output TVALID is gated, input TREADY is gated. Need careful state machine. Build-time-sim with cocotb or VVP would catch mistakes early.
- **Line buffer addressing.** V-filter needs 4 simultaneous output-line reads from one BRAM. Either 4-port BRAM (Vivado doesn't natively, would need 4 BRAMs) or time-multiplex within one clock period. With 27 MHz output and 4 taps, we have ~4 cycles per output pixel — feasible to multiplex.
- **Output resolution support on test monitor.** Some HDMI monitors reject 480p (DVI-A spec). Backup plan: do C.1 at 720p first if the monitor balks.
- **YCbCr-aware filtering.** Pure RGB filtering creates color fringes at sharp edges (especially on saturated content). Acceptable for first-light; Phase E will revisit.

## What's NOT in Phase C scope

- FRC (frame-rate conversion) — Phase D
- Color matrix / LUT — Phase E
- Geometry warp — Phase F
- Composite encoder rate-conversion (5:2 cadence for 24 fps cinema → NTSC) — Phase G
