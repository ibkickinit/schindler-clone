# G1 bench finding — S2MM sub-geometry reconfig breaks MM2S genlock

**Date:** 2026-06-01
**Branch:** `iter5-1080p-clean`
**Builds involved:** `ffcd4ce` (G1 runtime-size HDL) + `64aabe6` (G1 BD size-GPIO + firmware `scaler_reframe`)
**Verification surface:** bench MONITOR (not MS2109) — per `schindler-ms2109-verification-trap`.

## TL;DR

The committed G1 firmware path (`scaler_reframe()` in `sw/phase-b/src/main.c`) **breaks HDMI
output** (monitor goes black / "no signal") whenever a geometry control moves off the full-size
default. The DDR framebuffer is *correct* (frame-dump proves it) — only the genlock-coordinated
output path dies. **Root cause: AXI VDMA dynamic genlock requires S2MM (master) and MM2S (slave)
to keep MATCHING frame geometry.** `scaler_reframe` stopped S2MM and reconfigured its VSIZE to the
sub-window (e.g. 540 lines) while MM2S kept reading the full 720 → the genlock frame-completion
handshake broke → MM2S output corrupted → VTC lost valid input → no signal. Resetting geometry to
full (both 720) **recovered** the output, confirming the mechanism.

## What we observed (monitor-confirmed)

1. Programmed G1 firmware. Boot at full-size default (1280×720, pos 0,0): clean passthrough, normal.
2. Frame-dump of DDR after setting 960×540 @ (160,90) black matte: **correct** — picture bbox
   cols[20..139] rows[12..78] vs expected cols[20..140] rows[11..78]. Size, position, matte all
   measured correct; `POS_Y_FUDGE=1` confirmed. The *framebuffer write path is good.*
3. **But the monitor went black** as soon as the sub-window reframe ran. HDMI = no signal.
4. Status snapshot during the blackout: `source_lock=True`, 1920×1080@59 in, VTC 720p60 — source
   side healthy. So the failure is strictly in the MM2S→VTC→rgb2dvi output leg.
5. Resetting geometry to full (out_w=1280, out_h=720, pos 0,0 — which reconfigures S2MM back to 720)
   **brought the picture back, full image.**

## Root cause

Dynamic genlock topology (see `tcl/build_phase_b.tcl` VDMA config + `docs/iter6-s2mm-fsync-fix.md`):
- S2MM = master, FrameDelay=0, hardware fsync from `dvi2rgb vid_pVSync` (iter6).
- MM2S = slave, FrameDelay=1, EnableSync=1, `mm2s_addr[i] = s2mm_addr[i] + STRIDE` (1-line read offset).

The slave follows the master's **frame boundaries**. When `scaler_reframe` set S2MM VSIZE to 540
while MM2S VSIZE stayed 720, the per-frame line counts no longer agreed. The master signals
frame-done after 540 lines; the slave is mid-720-line read → the follow handshake desyncs → MM2S
emits a corrupt/partial raster → VTC sees no valid active video → "No Signal."

Two distinct lessons:
- **Never let S2MM and MM2S frame geometry diverge under genlock.**
- **Stop/reconfig of a VDMA channel mid-genlock is dangerous** even when you intend to restart it;
  the slave's follow state does not cleanly re-establish from a master VSIZE change.

## The implementation drifted from the agreed design — and the bench proved the design right

`docs/adjustable-scaler-design.md` (agreed with Justin 2026-06-01, "as written") specifies geometry
as a **post-color, per-output PRESENTATION compositor** (route B): §"HDL deltas" point 2 explicitly
says matte/window is "cleanest as an **output compositor** … route B … now preferred *because*
geometry is post-DDR per-output." The G1 phase row says "post-color present_geom … compositor."

The firmware I committed at `64aabe6` did the **opposite**: it put runtime size into the *input-side*
scaler (`ffcd4ce`) and did the windowing by *reconfiguring S2MM* in firmware. That is closer to the
rejected input-side draft than to the agreed output-compositor design. **The bench failure is the
agreed design doc being right:** geometry must not touch the genlock ring; it belongs after MM2S,
on the output side.

## Status of the committed code

- `ffcd4ce` (runtime out-size in `scaler_h`/`scaler_v`/`scaler_top`): **harmless at default** (sim
  no-regression; at out=OUT_W/OUT_H it is bit-identical to pre-G1). But it is the *wrong layer* for
  geometry under the agreed architecture. Will be reverted or repurposed by the redesign.
- `64aabe6` (`scaler_reframe` + axi_gpio_8 size GPIO): **DEAD-ON-ARRIVAL — do not use.** Reachable
  only via a raw `J` command (the `hdmi.*` geometry controls are deliberately NOT in the catalog/UI),
  so the live bench is SAFE at full-size passthrough as long as geometry is not hand-poked. The
  redesign replaces `scaler_reframe` entirely.

**Bench-safety note:** the production passthrough at boot (full size, no reframe call) is unaffected
— the size GPIO defaults full and `reframe` is not invoked until a `control.set`. Nothing automated
sends one.

## The redesign (in flight)

Geometry moves to a **post-color output-side compositor** (route B), between the color stack and
`axis_to_vid_io`, clocked at the VTC pixel clock. S2MM/MM2S stay full-geometry → genlock never
touched → no firmware VDMA reconfig, no framebuffer matte-clear. A multi-agent design panel
(2026-06-01) is scoring A (scaler emits full raster) vs B (output compositor) vs C (reconfigure both
S2MM+MM2S) against genlock-correctness, throughput/timing on -1 silicon, architecture fit, and
implementation/bench risk; its synthesis + implementation sketch + first bench checkpoint will be
appended here.

## Cross-refs

- `docs/adjustable-scaler-design.md` — the agreed master+presentation architecture (route B).
- `docs/iter6-s2mm-fsync-fix.md` — the S2MM hardware fsync this finding interacts with.
- memory `schindler-vdma-dynamic-genlock`, `xilinx-vdma-dmasr-bits`, `schindler-ms2109-verification-trap`.
