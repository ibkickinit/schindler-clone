# Architecture

The Schindler 2.0 pipeline on iter5-1080p-clean substrate.

## Pipeline topology

```
HDMI IN
  │
  └─► dvi2rgb ──► v_vid_in_axi4s ──► scaler_top ──► axi_vdma S2MM
                                       │              │
                                       │              ▼
                                       │           DDR3 frame buffer (5-slot ring, Dynamic Genlock)
                                       │              │
                                       │              ▼
                                       │           axi_vdma MM2S
                                       │              │
                                       │              ▼
                                       └────────► color pipeline (sat → correct → matrix)
                                                      │
                                                      ▼
                                                axis_to_vid_io
                                                      │
                                                      ▼
                                             v_tc_tx (VTC timing)
                                                      │
                                                      ▼
                                                  rgb2dvi ──► HDMI OUT
```

Built by `../../tcl/build_phase_b.tcl` (~1000 lines, 47 BD cells, 227 BD wire ops). Top-level wrapper: `phase_b_top.v`.

## Clock domains

| Domain | Rate | Source | Used by |
|---|---|---|---|
| `pclk_in` | dvi2rgb-derived (e.g., 148.5 MHz at 1080p60) | dvi2rgb internal MMCM | scaler, S2MM input side |
| `pclk_out` | 74.25 MHz at 720p60 | `clk_wiz_pixclk_out` MMCM | VTC TX, axis_to_vid_io, color pipeline, rgb2dvi |
| `ref_clk_200` | 200 MHz | `clk_wiz_ref` PLL | IDELAYCTRL for dvi2rgb |
| `axi_clk` | 100 MHz | Zynq PS FCLK_CLK0 | AXI-Lite + DMA control plane |

Async crossings handled via `hdl/axi_sync_inputs.v` (multi-flop sync per port) + `hdl/vsync_cdc_pulse.v` (edge-detect pulse generator). Both are well-trodden; see [XILINX-IP-NOTES](XILINX-IP-NOTES.md) for the CDC width-mismatch trap.

## AXIS pixel format

**Important:** the pipeline carries pixels as `tdata[23:16] = R, [15:8] = B, [7:0] = G` — **not** standard RGB. This is a Digilent dvi2rgb byte-order quirk discovered empirically. Any channel-aware HDL (color matrix, YCbCr conversion, gamma LUT, etc.) must respect this layout.

Documented in memory `pipeline_rbg_byte_order`.

## Scaler

`hdl/scaler_top.v` wraps `scaler_h.v` (horizontal, 1920→1280 hardcoded) + `scaler_v.v` (vertical, 1280→720 hardcoded). Internal lbuf BRAMs absorb input-row timing.

**Current production kernel (iter12 + iter13 + iter13b):**
- H: 2-tap boxcar `(s_axis_tdata + window[0] + 1) >> 1`. Newest tap is the freshly arriving pixel; oldest is the registered previous pixel.
- V: 2-tap boxcar `(tap2 + tap3 + 1) >> 1` post-`tap0_slot` rotation.
- The `+1` is round-to-nearest, fixing the −0.5 LSB DC bias the truncating `>>1` introduced.

History of why this kernel: see [PHASES](PHASES.md) iter ledger + `../iter6-h-shift-analysis.md` (RESOLVED banner explains the bug class).

## VDMA configuration

`axi_vdma_0` runs **Dynamic Genlock** mode (S2MM mode=2 = Dynamic Master, MM2S mode=3 = Dynamic Slave with `repeat_en`, FrameDelay=1). 5-slot framestore ring.

iter6 added hardware S2MM fsync (`c_use_s2mm_fsync=1` + `c_flush_on_fsync=1`) driven by a 1-cycle pulse on rising edge of `dvi2rgb_0/vid_pVSync`. Bypasses the ~27-row internal TUSER-detect pipeline lag.

## Color pipeline

Three stages between MM2S and `axis_to_vid_io`, all runtime-tunable via UART:
1. `color_saturation` (Q1.15 saturation 0..200%)
2. `color_correct` (per-channel black/white knobs — diagonal RGB matrix)
3. `color_matrix` (full 3×3 Q2.14 matrix + 8-bit offsets)

See [COLOR-PIPELINE](COLOR-PIPELINE.md) for stage details + UART command reference.

## Output side

`axis_to_vid_io` adapts AXIS-Video to discrete vid_data/vid_sync. `v_tc_tx` (Xilinx VTC) generates timing. `rgb2dvi` (Digilent) drives the HDMI TX TMDS.

## Memory layout (DDR3 at 0x1000_0000)

| Region | Use |
|---|---|
| Slot 0..4 (5 × frame size + STRIDE) | VDMA framestore ring. Each slot = `FRAME_BYTES + STRIDE` for guard region. |

`FRAME_H × STRIDE` per slot; STRIDE = `1280 × 3` bytes for 720p RGB24. Computed in firmware (`sw/phase-b/src/main.c`).

## Sub-pages for deeper detail

- [FRC-ARCHITECTURE](FRC-ARCHITECTURE.md) — Methods A/B/C/D/E, RT4K three-mode framing
- [COLOR-PIPELINE](COLOR-PIPELINE.md) — color stack details
- [XILINX-IP-NOTES](XILINX-IP-NOTES.md) — IP-specific gotchas

<!-- AGENT_TASK[docs-4]: Add a Mermaid block diagram (or PlantUML) showing the precise BD cells + connections. Current ASCII is approximate. -->

<!-- AGENT_TASK[hdl-3]: scaler_coeffs_h.v + scaler_coeffs_v.v are now dead code kept alive only by `_coef_keep` synth-keep wires. When iter14 lands, these come back online with new (linear/Gaussian) coefficients. Tech debt: document the decision to keep vs. retire. -->
