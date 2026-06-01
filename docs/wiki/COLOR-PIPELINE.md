# Color Pipeline

Three-stage runtime-tunable color processing between MM2S and `axis_to_vid_io`.

Source: HDL `hdl/color_saturation.v`, `hdl/color_correct.v`, `hdl/color_matrix.v`; memory `schindler_color_pipeline`, `schindler_pipeline_rbg_byte_order`, `schindler_uart_commands`.

## Pipeline order

```
MM2S ──► color_saturation ──► color_correct ──► color_matrix ──► axis_to_vid_io
              │                     │                  │
              ▼                     ▼                  ▼
        sat 0..200%          black/white per ch    3×3 matrix + offsets
        (Q1.15)              (8-bit per channel)   (Q2.14 coeffs)
        GPIO 3               GPIO 3                GPIO 4/5/6
```

All stages bench-validated 2026-05-18 on `iter5-1080p-clean` commit `7af40e1`.

## R-B-G byte order

**The pipeline carries pixels as `tdata[23:16] = R, [15:8] = B, [7:0] = G`**, NOT the standard RGB byte order. This is a Digilent dvi2rgb empirical quirk.

Any channel-aware HDL must respect this. The color modules already do; new channel-aware work (YCbCr conversion, gamma LUT, etc.) must as well.

Memory: `schindler_pipeline_rbg_byte_order`.

## Stage 1: color_saturation

Q1.15 saturation factor 0.00 → 2.00 (= 0% to 200%). 100% = passthrough.

Implements Rec.601 luma-derived saturation: luma is computed, then `output = luma + sat × (input - luma)` per channel.

GPIO 3 holds the saturation factor (16-bit Q1.15 in lower half).

## Stage 2: color_correct

Per-channel black/white knobs implementing a diagonal RGB matrix. Useful for per-channel level adjustment without affecting other channels.

GPIO 3 (upper half) + part of GPIO 4 for the eight values (4 bytes for black RGB, 4 for white).

## Stage 3: color_matrix

Full 3×3 Q2.14 matrix + 8-bit per-channel offsets. Implements arbitrary color transforms — identity passthrough, Rec.601-derived grayscale, color shifts, etc.

9 Q2.14 coefficients + 3 offsets = 21 bytes across GPIOs 4, 5, 6.

Default at boot: identity matrix (full color). The 2026-05-30 audit team verified this is correct (commit `f97da45`).

## Runtime UART commands

Live tuning from `/dev/ttyUSB1 @ 115200 8N1`:

| Command | Effect |
|---|---|
| `?` | Print help |
| `i` | Identity matrix (full color) |
| `g` | Rec.601 grayscale |
| `s <pct>` | Saturation 0..200 |
| `m <pct>` | Matrix-derived saturation 0..200 |
| `b <r> <g> <b>` | Black levels 0..255 each |
| `w <r> <g> <b>` | White levels 0..255 each |
| `r` | Reset all |

See [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md) for the full command reference (including non-color commands like `F`, `a`).

## Async-CDC WNS soft fail

The GPIO writes cross from the AXI clock domain to `pclk_out`. Vivado reports WNS=-3.5 ns on these paths because the timing-ignore XDC patterns don't match Vivado's hierarchical names. Functional via `ASYNC_REG` attribute on the CDC flops.

See [KNOWN-BUGS](KNOWN-BUGS.md) for the open task to fix the XDC constraint pattern.

## How frames see changes

Color writes go through `axi_sync_inputs.v` (the multi-flop CDC) and latch frame-atomically at the next TUSER. So mid-frame UART writes don't tear the picture — they take effect at the next frame boundary.

The 64-bit width fix (memory `axi_sync_inputs_cdc_width`) matters here: the CDC pipeline must be sized to match the port. iter5b's 48→64 widening caught a silent truncation bug; same class of bug would re-emerge if anyone widens a GPIO without widening the corresponding sync regs.

<!-- AGENT_TASK[hdl-7]: Add gamma LUT stage to color pipeline. Memory `schindler_color_pipeline` mentions it as future work. Should slot between sat and correct, or after matrix. -->

<!-- AGENT_TASK[hdl-8]: RGB↔YCbCr conversion module. Required for some FRC modes that work better in YCbCr (chroma sub-sampling preservation). Future. -->

<!-- AGENT_TASK[hdl-9]: Fix the async-CDC false-path XDC constraint pattern (cross-listed from KNOWN-BUGS). Cosmetic fix; functional via ASYNC_REG today. -->

## Why a 3-stage pipeline (not one big matrix)

The three stages are mathematically equivalent to one big matrix per pixel, but separating them gives **operator-comprehensible knobs.** Saturation is one concept, per-channel level is another, full transform is a third. An on-set DP can dial each axis independently without computing matrix products.

Operator-facing UI (planned web UI + front-panel) maps directly to these stages.
