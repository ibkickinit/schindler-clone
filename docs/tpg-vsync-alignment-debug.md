# TPG vsync alignment — debug log

> **STATUS: ARCHIVED 2026-05-18.** This document is a sealed record of why a fsync-only
> approach to aligning two free-running oscillators cannot work. Attempts A–D all failed in
> the same architectural way; bench image #11 confirmed that even the most-gated one-shot
> (Attempt D) produces a slowly-drifting wrap, not a stable picture. The path forward is a
> software-closed MMCM phase-tracking loop. See [`sync-architecture.md`](sync-architecture.md)
> for the new plan (SSOT) and [`phase-e1-mmcm-tracking-spike.md`](phase-e1-mmcm-tracking-spike.md)
> for the build steps. The independent review in
> [`tpg-sync-architecture-review.md`](tpg-sync-architecture-review.md) (especially §3, §7, §9.4)
> covers why fsync-gating cannot substitute for a phase-locked loop.
>
> Do not edit further. If you find yourself wanting to try a fifth fsync variant, read §9 of
> the review doc first.

---

**Date opened:** 2026-05-18
**Branch:** `mackin-impl-wip` (with TPG work layered on)
**Goal (user `/goal`):** "finish the TPG with working sync and no vertical misalignment.
It should work with external signal present or without referencing external sync at all.
test with output set at 1080p60, 1080p30, 720p60. Don't stop until it works every time."

---

## 1. What the TPG is and what it's supposed to do

Built-in test pattern generator implemented in `hdl/tpg_input.v`. Goal: an unmistakable,
on-FPGA video source that bypasses the entire HDMI receive path so we can isolate scaler /
VDMA / output-timing bugs from source / HDMI-receive bugs.

- **Source resolution:** 1920×1080 at 60 Hz, internal AXIS @ source pixel rate.
  HTOTAL=2200, VTOTAL=1125 (full CEA-861 1080p60 blanking).
- **Patterns (8):** SMPTE 75% bars, solid color, gradients, dot, crosshatch, sweep, counter, etc.
- **Markings (so we can't confuse it with MS2109's fallback):**
  - 1-pixel **magenta** border around the whole frame.
  - Top-left 256×48 **dark-blue counter overlay** with yellow hex digit cells, frame-counted.
- **Routed via `axis_mux_2to1`** — runtime-selectable between HDMI-in (s0) and TPG (s1).
- **UART control:** `t`/`p`/`n`/`f`/`c` commands choose pattern / motion / source / rate / solid color.

Downstream pipeline is unchanged: TPG → axis_src_mux → scaler_top (1920×1080 → 1280×720) →
VDMA S2MM → DDR3 framestore ring → VDMA MM2S → color pipeline → axis_to_vid_io → rgb2dvi → HDMI out.

---

## 2. The problem in one sentence

The TPG output reaches the MS2109 capture stick **stable and intact**, but the **counter overlay
appears at display-row ~280 instead of display-row 0** — i.e., the source frame is showing up on
the display with a 270–290 row vertical wrap. The frame is "rolled" by a fixed amount that survives
reboots (and varies coin-flip between reboots).

Symptom history across the session:
1. Earliest: "Deeply unlocked..." — torn / scrolling. (no fsync mechanism)
2. After continuous fsync_in pulse-every-source-vsync: severe tear, "scrolling, dynamic, wrong."
3. After **one-shot** fsync_in firing on first source vsync post-reset: **stable** picture, but
   counter at ~40% down the display (~270–290 output rows offset).

Stable but offset = phase error has stopped *changing*, but it's not zero.

---

## 3. Architecture context that's relevant

### Two independent clock domains

- **Source pixel clock:** 148.5 MHz, recovered from dvi2rgb (HDMI receiver). Independent oscillator.
  When TPG is the source, this is still dvi2rgb's PixelClk — TPG was wired to live on the same
  clock as the HDMI input to avoid an architectural disruption (and because we exhausted the
  Z7-20's 4-MMCM budget on a prior attempt).
- **Output pixel clock:** 74.25 MHz (720p60) or other rates, from `clk_wiz_pixclk_out` driven by
  FCLK_CLK0. Different oscillator.
- These two clocks are **nominally** the same ratio but drift over time. Their phase at any given
  moment is arbitrary.

### Theorem we keep banging into

> Two independent free-running oscillators at the same nominal rate cannot produce
> phase-aligned vsyncs without an explicit alignment event.

Therefore the source vsync and the output vsync **must be tied together** by one of:
- (a) shared clock (we can't — MMCMs gone, mode-switch matrix forbids it long-term),
- (b) hardware sync pin on the timing generator (this is what Xilinx provides: v_tc `fsync_in`),
- (c) PLL phase tracking (Phase E1 — future work),
- (d) phase-agnostic buffer rotation only (VDMA Dynamic Genlock handles drift, but not initial phase).

### v_tc `fsync_in` per Xilinx PG016

> "The video timing generator is synchronized to fsync_in if used. fsync_in should be driven
> High for only **one clock cycle per frame**, which resets all internal generator counters and
> starts the generated frame timing synchronized to this input."

PG016 forbids continuous resyncs unless you actually want the generator to restart every frame
(which only makes sense if both pipelines share a clock — they don't here).

---

## 4. What we've tried, in order

### Attempt A — pure firmware polling (original)

Firmware polled dvi2rgb's vsync, then wrote the VTC CTL register with GE bit set. Boot-time
race: AXI bridge latency between "vsync detected" and "register written" is non-deterministic.
Result: vertical phase **coin-flips** every reboot. This is the old [Phase D vsync-phase coin
flip](../memory/schindler_phase_d_vsync_phase.md) problem reappearing.

### Attempt B — continuous hardware fsync (broken)

Built `fsync_pulse_gen.v` as a CDC edge detector: every rising edge of source vsync produces a
1-cycle pulse in the VTC clock domain, wired to `v_tc_tx/fsync_in`.

**Why this fails:** the source and output clocks drift. So the source vsync rising edge arrives
at the VTC generator at an arbitrary point in *its* current frame every frame. Each fsync_in
pulse resets the generator mid-frame. Downstream (axis_to_vid_io → rgb2dvi → HDMI sink) sees
truncated vsync intervals and never establishes lock.

Bench: severe tear, "Deeply unlocked..." image.

### Attempt C — one-shot hardware fsync (still wrong, current state pre-rebuild)

Added a `fired` latch to `fsync_pulse_gen.v`. Pulse fires on the **first** source vsync rising
edge after fsync_pulse_gen leaves reset, then latches off forever.

```verilog
// Excerpt:
if (vsync_q2 && !vsync_q3) fired <= 1'b1;
assign fsync_pulse = vsync_q2 && !vsync_q3 && !fired;
```

Bench: **stable** picture. Major win — no more tearing. But counter still at ~display-row 280.

**Root cause of the remaining offset:** `fsync_pulse_gen` leaves reset early in the boot
sequence — as soon as `rst_pixclk_out` releases, which happens shortly after `clk_wiz_pixclk_out`
locks. That's many seconds before the firmware finishes its boot sequence and writes the VTC
CTL register to actually *enable* the generator.

So the one-shot pulse fires into a **disabled** VTC TX. The pulse goes to a generator that
isn't running. The latch sets, but the generator has no counters to reset. Later, when firmware
finally enables the generator, the VTC counters start at whatever phase the firmware happened
to write the enable bit on — same coin-flip as Attempt A.

This is the state captured in the last bench image: counter at ~display-row 280, stable.

### Attempt D — one-shot fsync gated by VTC's own vsync (current rebuild)

The deterministic fix: only **arm** the fsync_pulse_gen after we've observed VTC TX produce its
own first `vsync_out` rising edge. That's proof the firmware has enabled the generator and it
is actually running.

```verilog
// Arm on VTC TX's first vsync rising edge — guarantees VTC is actually running.
if (vtc_vsync_in && !vtc_q1 && !armed) armed <= 1'b1;
// Fire once after armed, on the NEXT source vsync rising edge.
if (armed && vsync_q2 && !vsync_q3 && !fired) fired <= 1'b1;

assign fsync_pulse = armed && vsync_q2 && !vsync_q3 && !fired;
```

Wiring in BD:

```tcl
connect_bd_net [get_bd_pins v_tc_tx/vsync_out] \
               [get_bd_pins fsync_pulse_gen_0/vtc_vsync_in]
```

State machine: `!armed → armed → fired`.

1. Boot. MMCM locks. `rst_pixclk_out` releases. `fsync_pulse_gen` exits reset with armed=0.
2. Firmware boots. Calls `vtc_setup()`. Writes CTL with GE bit. **VTC starts emitting frames.**
3. Within ≤16.67 ms, VTC's first `vsync_out` rising edge. `armed` latches to 1.
4. Within ≤16.67 ms of that, the next source vsync rising edge. `fsync_pulse` fires for 1 aclk
   cycle. `fired` latches to 1. Generator counters reset.
5. From that point on, both pipelines start their respective vblanks **at the same time**, and
   VTC TX free-runs on its own clock thereafter.

Expected total time-to-alignment: ~33 ms after firmware finishes vtc_setup. First aligned frame
is the second or third frame the user sees.

### What the math predicts the residual offset will be

After fsync_in fires at t=0:
- Source is at start-of-vblank (vsync rising edge marks vsync pulse start).
- VTC counter = 0 = start-of-vblank for VTC.
- Source active video starts after source's (vsync_width + back_porch) = 41 lines @ source clock
  → 41 × (2200 / 148.5 MHz) = **607 µs** after t=0.
- VTC active video starts after VTC's (vsync_width + back_porch) = 25 lines @ output clock
  → 25 × (1650 / 74.25 MHz) = **555 µs** after t=0.
- VTC active starts **52 µs before** source active. In output-row units: 52 / 22.22 ≈ **2.3 rows**.

So display row 0 sees the *previously completed* slot's row 0 (one frame of lag — a constant,
acceptable), and source row 0 lands at display row ~2.3. Counter overlay (256×48 at source rows
0–47) lands at display rows ~2.3 → ~34.3.

**If, after this rebuild, the counter still appears at row 280 and not row ~2, the offset is
not boot-phase** and we need to investigate scaler latency / VDMA stride / axis_to_vid_io
lead-in.

---

## 5. Files changed in this debug

- `hdl/fsync_pulse_gen.v` — added `vtc_vsync_in` port + armed/fired state machine.
- `hdl/tpg_input.v` — earlier in session: HTOTAL=2200 / VTOTAL=1125, magenta border, counter
  overlay, 2-FF vsync_in sync.
- `hdl/axis_mux_2to1.v` — runtime AXIS mux between HDMI (s0) and TPG (s1).
- `tcl/build_phase_b.tcl` — fsync_pulse_gen instantiated; added new net
  `v_tc_tx/vsync_out → fsync_pulse_gen_0/vtc_vsync_in`.
- `sw/phase-b/src/main.c` — UART commands `t/p/n/f/c` (TPG controls) and `v 720`/`v 30` (VTC
  mode switch). 500 ms delay between S2MM start and MM2S start. `Xil_DCacheFlushRange` after
  guard zero (this killed an earlier "bottom over-read showing stale DDR" artifact unrelated
  to the vsync alignment).
- `scripts/capture_hdmi.sh`, `scripts/analyze_tpg_capture.py`, `scripts/tpg_test_cycle.sh` —
  bench-automation tooling.

---

## 6. Open risks if this rebuild still doesn't align

In rough order of likelihood:

1. **VTC TX's first `vsync_out` arrives before fsync_pulse_gen leaves reset.** If
   `rst_pixclk_out` releases very late (e.g., MMCM relock after firmware fiddles with it), and
   firmware enables VTC before fsync_pulse_gen sees a transition, we'd miss the arming edge.
   Mitigation: vtc_q1 starts at 0 and any 0→1 transition arms us, including the very first one.
   Should be safe — but worth checking on the scope if needed.

2. **VTC TX's vsync_out polarity / pulse width.** Standard CEA-861 has vsync_out high during
   the vsync interval (~5 lines). Edge detect catches start-of-vsync. Should be unambiguous.

3. **Pipeline latency (scaler + axis_to_vid_io)** adds rows beyond the 2.3-row prediction.
   Scaler latency is documented (`schindler_scaler_pipeline_throughput`); should be <50 rows.
   axis_to_vid_io lead-in: <10 cycles. Neither should produce 280-row offset.

4. **VDMA stride misalignment.** Unlikely — we'd see scrolling or torn rows, not a clean offset.

5. **VTC's `fsync_in` is masked unless a SYNC_ENABLE bit is set in the CTL register.** PG016
   does mention this is automatic when detector is disabled (it is — see
   `CONFIG.enable_detection {false}`), but worth verifying with a register dump if alignment
   still fails. **TODO if 280-row offset persists.**

---

## 7. Test plan once the rebuild lands

Bench cycle:
1. Program board via `xsct tcl/program_phase_b_full.tcl`.
2. Physical USB unplug/replug of MS2109 (software reset doesn't work — `/dev/bus/usb/...` is
   non-writable from this user account; see `bench_observation_tools` memory).
3. `printf 't 1\r' > /dev/ttyUSB1` to switch source to TPG.
4. `bash scripts/capture_hdmi.sh /tmp/tpg_iter.jpg` (kills cheese first).
5. `python3 scripts/analyze_tpg_capture.py /tmp/tpg_iter.jpg` — analyzer reports counter row.

Pass criterion: counter at output row ≤ 5 (analyzer accepts ≤5 rows offset). Then repeat at
1080p30 and 720p60 via `v 30` / `v 720` UART commands.

---

## 8. User feedback driving this work

Direct quote (early in the session): *"I feel like this should be more of an AHA certainty
than tweaking a few lines here and there. Isn't there a mathematical formula? This seems more
touchy feely vibes based than science. Deeply unlocked... no way a professional product would
pull this."*

That feedback drove the switch from firmware-polling (Attempt A) to hardware-fsync (Attempts
B–D). Attempt D — armed-by-VTC-vsync — is the one with deterministic math behind it. If it
doesn't work, the next attempt should be similarly grounded, not a tweak.
