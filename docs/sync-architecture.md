# Sync architecture — SSOT

**Date:** 2026-05-18
**Status:** THE plan. Single source of truth for the Schindler 2.0 output-clock synchronization architecture. This is MVP scope, not a future phase.
**Relates to:** [`01-spec.md §3.7`](01-spec.md) (genlock subsystem), [`§3.8`](01-spec.md) (dual SYNC OUT), [`tpg-sync-architecture-review.md`](tpg-sync-architecture-review.md) (why we're here), [`phase-e1-mmcm-tracking-spike.md`](phase-e1-mmcm-tracking-spike.md) (how we build it).

---

## 1. The model in one paragraph

The output pixel clock is **always** driven by a software-closed phase-locked loop (PLL). The loop's reference input is selectable at runtime: free-run (no reference), input-lock (source vsync), or genlock (external sync — LTC / tri-level / black burst / word clock / SDI VITC). Phase alignment between reference and output is corrected continuously by nudging the FPGA's MMCM via dynamic reconfiguration (sub-line accuracy, ±500 ppm pull range). Rate alignment beyond the MMCM's range — including intentional cadence conversion (60→50) and large transient offsets — is absorbed by the VDMA framestore ring via discrete frame skip/repeat events. Reference loss freezes the loop's integrator at its last-known-good correction; the output continues at the most-recently-tracked rate until reference returns.

This architecture is **MVP**. No part of it is deferred. No "free-running output for v1, PLL for v2." The product is a frame rate converter with genlock; it does not exist without the loop.

---

## 2. Why the architecture has to look like this

Two independent oscillators at the same nominal rate cannot stay phase-aligned. This is a physics fact, not an engineering constraint — it's true regardless of clock quality, board layout, or how the alignment was initiated. Any architecture that tries to avoid the loop ends up rediscovering this through bench evidence (see [`tpg-vsync-alignment-debug.md`](tpg-vsync-alignment-debug.md) Attempts A–D, and the moving-wrap evidence in image #11).

The product's job — frame rate conversion with genlock to a film camera reference — is specifically *the case where you must close the loop*. There is no half-measure that achieves "stable output locked to an external reference" without an active PLL on the output clock. Frame buffering alone gives you tearing protection, not phase lock.

Adopting this architecture from the start avoids paying the cost twice (once for a free-running output that has to be torn out, once for the real loop). The work to build the loop is the work the product requires.

---

## 3. The reference selector (user-facing model)

The UI exposes one control: **Reference Select**, with three positions.

| Mode | Reference | Behavior | Failure mode |
|---|---|---|---|
| **Free-run** | None | PLL integrator held at zero correction. Output clock runs at its nominal rate, free of any reference. | N/A — this *is* the failure mode for the others. |
| **Input-lock** | Source vsync from the currently selected video input (HDMI / composite / component / SDI) | PLL tracks input vsync. Output is phase-locked to input frame timing. | Source loss → integrator freezes at last-known-good correction → output continues at last-tracked rate until source returns. |
| **Genlock** | External sync input, with sub-mode select: LTC / tri-level / black burst / SDI ref / word clock | PLL tracks external reference. Output is phase-locked to studio reference, independent of input. | Reference loss → integrator freezes → free-run holdover until reference returns. |

**Lock-state indicator** in UI: Acquiring / Locked / Holdover (formerly-locked, now in ref-loss freeze) / Free-run. Visible in the front-panel TFT and the web UI.

This matches `01-spec.md §3.7`'s "Acquiring / Locked / Lost" state machine. The behavior is what every broadcast frame sync exposes (Teranex, FS-HDR, Cobalt 9904, AJA FS series). It maps cleanly to user expectation.

**Implementation insight:** Free-run is not a separate code path. It's the PLL with `integrator_correction = 0` and reference input ignored. The same firmware that runs Input-lock and Genlock also runs Free-run — only the selector multiplexer state and the controller-enable bit change.

---

## 4. Dual-loop architecture: phase vs rate

The system has two cooperating correction mechanisms, each conserving a different quantity.

### 4.1 MMCM phase loop — conserves phase

- **What it does:** continuously adjusts the output pixel clock by sub-ppm increments so that output vsync edges land at the same time as reference vsync edges.
- **Mechanism:** firmware reads timestamped vsync edges (reference + output), computes phase error, applies a correction to the MMCM's fractional divider via DRP.
- **Range:** ±500 ppm (per prior-art memory `xilinx_mmcm_psincdec_tracking`).
- **Resolution:** sub-line, limited by timestamp counter resolution and DRP step size.
- **Loop bandwidth:** ≈5–10 Hz during spike validation; **≈0.5 Hz** in production per [`01-spec.md §3.7`](01-spec.md). Slow loop = good rejection of reference jitter, slow capture; fast loop = quick capture, more jitter passed through. Production value tuned against real broadcast references.
- **Failure mode:** integrator freezes on ref loss. Output continues at last-tracked rate.

### 4.2 VDMA cadence loop — conserves rate

- **What it does:** absorbs whole-frame rate differences between input and output via discrete skip/repeat events in the framestore ring.
- **Mechanism:** VDMA Dynamic Genlock provides the substrate (5-slot ring, read pointer chases write pointer through completed slots). The control logic *deliberately* allows the ring to slip a frame when the average rate offset between input and output exceeds what the MMCM can absorb, or when the user has selected a different output rate from the input (cadence conversion).
- **Range:** unbounded. Any rate ratio expressible as discrete frame events.
- **Resolution:** one frame (16.67 ms at 60 Hz).
- **Failure mode:** none — the ring always has a frame to read.

### 4.3 How they cooperate

The two loops handle disjoint regimes:

| Scenario | MMCM phase loop | VDMA cadence loop |
|---|---|---|
| Same-rate drift (±50 ppm crystal slop) between source and output | Locks phase. Zero frame slips. | Idle — reader stays 1 frame behind writer, no slip. |
| 60 → 50 cadence conversion | Locks phase between slips. | Drops ~10 frames/sec by design. Deliberate, predictable. |
| 24 → 60 (3:2 pulldown) | Locks phase between slips. | Repeats frames per the 3:2 cadence pattern. |
| Out-of-range transient (>500 ppm offset, e.g., hot-plugged ref) | Saturates at ±500 ppm. Reports "saturated" state to controller. | On controller request, releases one frame slip to bring accumulated phase error back into MMCM capture range. |
| Source / reference dropout | Integrator freezes (holdover). | Reader continues consuming whatever's in the ring; eventually depletes if input is truly gone. |

**The control logic boundary:** when MMCM has been saturated for ≥ N consecutive frames (N to be characterized — likely 30–60), the controller requests a discrete frame slip from VDMA, then re-engages the MMCM loop from the new phase. The slip is a step disturbance the MMCM converges out within its loop bandwidth.

**Predictability:** every frame slip is logged and counted. The UI exposes a "frames added/dropped" counter and a "conversion ratio" indicator (1:1 / 60→50 / 3:2 / etc.). Frame slips are deliberate events, not errors.

### 4.4 What this is NOT

- Not "MMCM is the real loop and VDMA is a backup." Both are essential and always running.
- Not "VDMA Dynamic Genlock is the genlock." VDMA Dynamic Genlock is the *frame-buffer ring substrate* the cadence loop runs on top of. Genlock proper is the MMCM phase loop plus the reference selector.
- Not "free-run is an inferior mode." Free-run is a valid user choice (no reference available, or user wants the output to be the master). Same code path.

---

## 5. Lock-state machine

Single state machine in firmware, exposed via UART, GPIO LED, and UI:

```
                  ┌─────────────────┐
                  │    FREE-RUN     │ ← user-selected, or boot default
                  │ integrator=0    │
                  └────────┬────────┘
                           │ user selects Input-lock or Genlock
                           ↓
                  ┌─────────────────┐
                  │   ACQUIRING     │ ← loop closed, not yet within ±1 line for 60 frames
                  │  loop active    │
                  └────────┬────────┘
                           │ |phase_err| ≤ 1 line for 60 consecutive frames
                           ↓
                  ┌─────────────────┐
       ┌──────────│     LOCKED      │
       │          │  loop active    │
       │          └────────┬────────┘
       │ ref loss          │ |phase_err| > 5 lines for 60 frames
       │                   │ (loop dropped lock somehow)
       │                   ↓
       │          ┌─────────────────┐
       │          │   ACQUIRING     │
       │          └─────────────────┘
       ↓
┌──────────────┐
│  HOLDOVER    │ ← integrator frozen at last-good value
│  (was locked)│
└──────┬───────┘
       │ ref returns
       ↓
  → ACQUIRING
```

Each state surfaces:
- A GPIO LED (binary lock indicator, visible without UART).
- A UART status string (full state name + phase error magnitude + frame-slip counter).
- A UI status card on both front-panel TFT and web UI.

This matches `01-spec.md §3.7`'s lock-detector spec.

---

## 6. Implementation map

| Component | Role | Where it lives |
|---|---|---|
| MMCM (`clk_wiz_pixclk_out`) | Output pixel clock. Pullable via DRP. | FPGA, BD-instantiated. |
| DRP driver | Translates ppm-correction commands to DRP register writes. | Firmware (PS, bare-metal or PetaLinux). |
| Timestamp capture (ref + output vsync) | Cycle-accurate edge timestamps for phase error computation. | FPGA: small free-running counter + edge-triggered capture register per vsync. AXI-readable. |
| Reference multiplexer | Selects which signal feeds the PLL's reference input. Inputs: source vsync (from current input), external sync recovery (RP2040 / Si5351 feedback), or tied-low (free-run). | FPGA, controlled by firmware via AXI. |
| PI controller | Computes correction from phase error. Tuned per loop BW. | Firmware. |
| VDMA cadence logic | Detects MMCM saturation and intentional rate ratio. Issues frame skip/repeat commands. | Firmware. VDMA itself does the slip via Dynamic Genlock mechanism. |
| RP2040 + Si5351 | External-reference recovery (LTC / tri-level / black burst). Drives one of the reference mux inputs. | Production hardware per [`README.md`](../README.md), bench-bringup later. |
| Lock state machine | Aggregates loop status, surfaces to UI. | Firmware. |
| UI: Reference Select | User-facing control. | PetaLinux web UI + front-panel TFT (driven by STM32H735). |

---

## 7. Build order

This is the order to build it, not the priority of the components. Each step's deliverable is independently testable.

1. **MMCM DRP actuator** — prove the output clock is pullable. [Phase E1 spike Test 2](phase-e1-mmcm-tracking-spike.md).
2. **Vsync timestamp capture (ref + output)** — small Verilog module, AXI-readable. Required for any phase measurement.
3. **PI controller in firmware** — close the loop. Reference = source vsync, the only available reference at the bench. [Phase E1 spike Test 4](phase-e1-mmcm-tracking-spike.md).
4. **Lock state machine + LED indicator** — make lock status observable without a UART connected.
5. **Reference multiplexer + UI Reference Select** — even with only one usable reference (input vsync), expose the mux. Free-run becomes a tested mode.
6. **VDMA cadence cooperation** — controller requests frame slips on MMCM saturation. [Phase E1 spike Test 7](phase-e1-mmcm-tracking-spike.md).
7. **RP2040 + Si5351 reference recovery** — adds external-genlock reference inputs to the mux. Production hardware bringup.
8. **Cadence conversion (60→50, 3:2 pulldown, etc.)** — uses the same VDMA slip mechanism, scheduled deterministically per output-rate selection.

Steps 1–6 are the Phase E1 spike scope and validate the entire architecture on the bench using only signals already present. Steps 7–8 ride the foundation steps 1–6 lay.

---

## 8. What MVP means here

MVP is **step 8 working end-to-end**: a user can plug in a film camera's tri-level reference, select Genlock mode, and the Schindler's output locks to that reference within sub-line tolerance and holds through normal operation. Cadence conversion works across the spec'd frame-rate matrix. Reference loss falls back to holdover, not visible glitch.

Anything short of that is not the product. The work to get there is the work in §7. There is no smaller scope worth shipping — a frame rate converter that can't genlock is a fancier version of an HDMI splitter.

---

## 9. Open architectural questions (to resolve during build)

These are real unknowns to nail down with bench evidence, not vibes:

1. **Where does the timestamp counter live, and what's its width?** Need ≥1 frame period of resolution; 32-bit counter at 74.25 MHz wraps every ~57 seconds, fine.
2. **What's the right N for "MMCM saturated → request frame slip"?** Probably tunable; characterize during spike Test 7.
3. **How is reference jitter (especially analog LTC after recovery) shaped before entering the PI controller?** Likely a single-pole IIR before the loop; cutoff TBD against real LTC.
4. **What's the holdover quality requirement?** Spec doesn't say. Industry expectation is ≤1 ppm/°C-equivalent drift during ref-loss; needs to be confirmed against the TE0720's actual oscillator stability.
5. **Does the reference multiplexer need glitch-free switching?** Probably yes. Easy in firmware: switch reference → force re-acquire → user sees a brief unlock event. Acceptable for a deliberate user action.

These are all "build, measure, decide" questions. None of them change the architecture; they tune it.
