# Overview

## What Schindler 2.0 is

A modern open-source replacement for the **Cal Media Schindler MVPHD-24** — a niche 24fps frame-rate converter used in film production for sending playback content to CRT monitors that need to match a 24fps shutter cadence. The original is rare (~75 surviving units), unmaintained, and prone to failure.

**Target market:** rental houses, music-video DPs, period DPs, and film productions that still use CRT monitors for on-set creative-direction reference.

## What makes Schindler distinctive

- **Multi-format input.** HDMI, component, composite, S-Video (planned), optional SDI.
- **Multi-format output.** HDMI + analog (composite/S-Video/component via ADV7393).
- **Production-grade FRC** with three runtime-selectable modes inspired by the Retrotink RT4K:
  - **Frame Lock** — output clock derived from input clock; matched rate only; lowest latency.
  - **Gen Lock** — MMCM `psincdec` tracking; absorbs near-rate drift (e.g., 59.94 vs 60.000).
  - **Triple Buffer / Async Ring** — free-running output + framestore ring for picky sinks.
- **Mackin virtual-shutter blend** — temporal blender that degenerates to drop/repeat at clean integer ratios and produces smooth cross-fades at ugly near-1:1 ratios.
- **Live color tuning over UART** — sat → correct → matrix pipeline runtime-tunable without rebuilds.
- **Web UI** (planned) for operator control.

## End-state hardware

A 1RU box built around a **Trenz Electronic TE0720** SOM on a custom carrier PCB. Currently we develop on a Digilent Zybo Z7-20 — same Zynq-7020 silicon, so HDL ports 1:1.

Two SKU plans documented in `../packaging-skus.md`: a **Mini** (cost-optimized, no front panel) and a **Pro** (front panel + mezzanine for advanced I/O).

## Signal flow at 50-ft level

```
                                ┌─────────────────────────────────────┐
HDMI in ──► dvi2rgb ──► scaler ─┤      DDR3 VDMA frame buffer         ├─► axis_to_vid_io ──► rgb2dvi ──► HDMI out
                                │  (Dynamic Genlock S2MM + MM2S ring) │      ▲
                                └─────────────────────────────────────┘      │
                                                                              ├─ color pipeline (sat/correct/matrix)
                                                                              │
                                                            ┌─ Phase E1: MMCM phase tracking ─┐
                                                            └─ Phase E2: Si5351 actuator      │ (future merge)
                                                                              │
                                                             Phase E2/E4: Mackin temporal blender
                                                                              │
                                                                              ▼
                                                        Phase G: ADV7393 DAC ──► component / S-Video / composite out
```

Detailed topology in [ARCHITECTURE](ARCHITECTURE.md).

## Why "Schindler 2.0"

The original Cal Media unit had unique behavior that defined a workflow. We're preserving the *workflow* — what an operator does and what they see — while making the underlying silicon, firmware, and connectivity match what's expected from a 2020s device.

See also `../mvphd-comparison.md` for a feature-by-feature comparison with the original.
