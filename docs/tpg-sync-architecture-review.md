# TPG sync — architecture review & course-correction

**Date:** 2026-05-18
**Audience:** The agent currently debugging TPG vsync alignment on `mackin-impl-wip`.
**Status:** Independent review of [`tpg-vsync-alignment-debug.md`](tpg-vsync-alignment-debug.md), informed by [`01-spec.md`](01-spec.md), [`dev-roadmap.md`](dev-roadmap.md), [`phase-c-design.md`](phase-c-design.md), and external reference-design research (XAPP792, XAPP1308, Intel WP 828717, Skyworks AN377, PG016, PG020).

This document does **not** dispute the analysis in the debug log on its own terms — the one-shot fsync with VTC-vsync arming is internally coherent and the math in §4 is sound for the boundary it considers. The concern is broader: the architecture being hardened around the TPG debug is **a debug-stage expedient, not a path to the product the spec describes.** Read this before the next rebuild.

---

## 1. The product the spec asks for

From [`README.md`](../README.md) and [`01-spec.md`](01-spec.md):

- Genlock to **external film camera reference** (LTC, tri-level analog sync, black burst, word clock, SDI VITC) is a **core** feature, not a stretch goal.
- Frame rates: 23.976 / 24 / 25 / 29.97 / 30 / 47.95 / 48 / 50 / 59.94 / 60, with **60 → 50 cadence conversion** for cross-region content.
- Production hardware already includes **RP2040 + Si5351** as the genlock PLL subsystem.
- `01-spec.md §3.7` explicitly describes the intended topology: "PFD → loop filter (~0.5 Hz BW) → NCO/integrator (holds last value on ref loss → free-run hold) → lock detector. Integrator's correction pushed to Si5351 via RP2040 over I²C."
- `§3.8` (Pro SKU): dual SYNC OUT at independently selectable rates, each "locked to the input reference via rational ratios." That requires per-output clock domains, all pulled to a common reference.

Implication: the output pixel clock must be **pullable** (NCO-controlled) and **lockable to an external reference.** That's the load-bearing architectural commitment.

---

## 2. What the current architecture actually does

From [`tpg-vsync-alignment-debug.md`](tpg-vsync-alignment-debug.md) and [`hdl/fsync_pulse_gen.v`](../hdl/fsync_pulse_gen.v):

- Source pixel clock (148.5 MHz, dvi2rgb-recovered) and output pixel clock (74.25 MHz, FCLK-derived clk_wiz) are **independent free-running oscillators.**
- One-shot hardware fsync pulse from source vsync into `v_tc_tx/fsync_in` aligns the two **once, at boot.**
- VDMA Dynamic Genlock 5-slot ring is named as the mechanism that "absorbs drift" thereafter.
- MMCM phase-tracking is filed as Phase E1 "future work" in [`dev-roadmap.md`](dev-roadmap.md).

This is a "free-running output + frame-buffer ring" architecture. It's a reasonable engineering stance for a *frame synchronizer with a free-running output*. It is **not** genlock.

---

## 3. Why this matters: VDMA Dynamic Genlock is not broadcast genlock

This is the single point most worth internalizing before the next rebuild.

VDMA Dynamic Genlock (PG020) manages **tearing** by arbitrating read/write pointers across the framestore ring — the reader chases the writer through completed-frame slots, with configurable park behavior. **The output pixel clock is still free-running.** Over time, ±50 ppm crystal drift accumulates: the writer and reader diverge, the ring eventually has to skip or repeat a frame ("frame slip"), and the user sees judder.

Real broadcast frame syncs (AJA FS-HDR, Blackmagic Teranex, Cobalt 9904-UDX) **close the loop on the output clock itself**. Frame slip is reserved for genuinely different rates (e.g. 60 → 50 cadence conversion), not for absorbing the same-rate drift between two un-genlocked oscillators.

In other words: VDMA Dynamic Genlock is the right tool for the **cadence-conversion** problem the spec also describes. It is the wrong tool — by itself — for the **lock-to-reference** problem the spec primarily describes. The current architecture conflates the two.

Sources:
- [PG020 — VDMA Dynamic Genlock Slave](https://docs.amd.com/r/en-US/pg020_axi_vdma/Dynamic-Genlock-Slave)
- [Embedded.com — "Genlock gets broadcast video signal timing in sync"](https://www.embedded.com/genlock-gets-broadcast-video-signal-timing-in-sync/)

---

## 4. Reference designs worth emulating

### 4.1 Intel WP 828717 + Video & Vision Processing Suite (highest-fit reference)

[Intel WP 828717 — *Designing Genlocked Video Systems with Deterministic Low Latency on FPGAs*](https://www.intel.com/content/www/us/en/content-details/828717/designing-genlocked-video-systems-with-deterministic-low-latency-on-fpgas-white-paper.html) names both topologies explicitly:

- **VCXO-based** (classic broadcast): PFD → PID loop filter → PWM DAC → external VCXO → MMCM. Intel ships this as a discrete IP block.
- **VCXO-less**: on-chip fractional PLL as the NCO. Lower cost, slightly more jitter — fine for HDMI/CRT output.

The [Intel Genlock Controller IP functional description](https://www.intel.com/content/www/us/en/docs/programmable/683329/24-2/genlock-controller-ip-functional-description.html) and [Genlock Signal Router IP](https://www.intel.com/content/www/us/en/docs/programmable/683329/22-4/about-the-genlock-signal-router-ip.html) implement exactly what `01-spec.md §3.7` describes — read both before designing the Phase E1 spike.

### 4.2 Xilinx PICXO / FRACXO (XAPP1308)

PICXO ("Phase Interpolator Controlled Oscillator") pulls a GT bit clock by a few hundred ppm off its refclk, using the GT phase interpolator as the fine-tune element. NCO mode needs no external VCXO. **Caveat for our platform: Z-7020 has no MGTs**, so PICXO proper is unavailable — but **MMCM fractional reconfiguration** (or fine phase shift, 1/56 of VCO period) can serve the same role as a software-driven NCO. This is the path that fits the existing TE0720 carrier without silicon changes.

### 4.3 XAPP792 — the multi-VTC `fsync_in` pattern

[XAPP792 *Designing High-Performance Video Systems with Zynq-7000*](https://manualzz.com/doc/9360464/xapp792---designing-high-performance-video-systems-with-t...) uses VTC `fsync_in` driven **continuously** by a one-pulse-per-frame source — not the one-shot variant in `fsync_pulse_gen.v`. Continuous fsync is the canonical pattern, and it works because in XAPP792 the source and output share a clock domain. Our one-shot is a workaround for the **un-genlocked clock topology** — once the output clock is pullable, continuous fsync becomes the natural pattern.

### 4.4 Skyworks AN377 + Si53xx (the broadcast-classic)

[Skyworks AN377](https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/application-notes/AN377.pdf) describes the standard broadcast topology: black-burst / tri-level recovery → jitter-attenuating DPLL → VCXO → FPGA MMCM, sub-10 Hz loop bandwidth. The RP2040 + Si5351 already in the BOM is the budget version of this exact architecture.

### 4.5 PG016 fsync_in — usage constraints

[PG016 — `fsync_in` pin](https://docs.amd.com/r/en-US/pg016_v_tc/The-fsync_in-Pin):
- Active-high, **exactly one clock cycle per frame.**
- If `fsync_in` is used, the **detector must be disabled** (they OR internally; double-trigger otherwise).
- If the detector is used, `fsync_in` must be tied low.

Worth re-verifying `CONFIG.enable_detection {false}` on v_tc_tx (the debug log says it is — confirm in the BD before the next bench).

---

## 5. Tactical issues to fix regardless of the architectural question

These are concrete, near-term items that don't require an architecture change.

### 5.1 Investigate the slot-index hypothesis before another rebuild

The observed offset is "~270–290 rows, coin-flips between reboots, stable within a session." Output frame is 720 lines / 5 slots = 144 rows/slot. **288 rows = slot 2 of 5 exactly.**

This is the signature of VDMA S2MM and MM2S latching onto different starting slots of the framestore ring at boot — not of a sub-frame VTC phase error. The 500 ms delay between S2MM-start and MM2S-start in [`sw/phase-b/src/main.c`](../sw/phase-b/src/main.c) avoids underrun but does not deterministically pick the starting slot offset.

**Cheap experiment:** vary the S2MM↔MM2S start delay (100 / 250 / 500 / 1000 ms) across several reboots and tabulate the measured offset. If it discretizes to {0, 144, 288, 432, 576}, the fsync work is solving the wrong problem and the right fix is in firmware — either read `s2mm_frame_ptr_out` and use it to choose MM2S's start slot deterministically, or use VDMA's park/repeat mode to force a known starting alignment.

### 5.2 `fsync_pulse_gen.vsync_in_async` is wired to the wrong source for TPG

The header of [`hdl/fsync_pulse_gen.v:11`](../hdl/fsync_pulse_gen.v) says `vsync_in_async` is fed from `dvi2rgb_0/vid_pVSync`. But [`hdl/axis_mux_2to1.v`](../hdl/axis_mux_2to1.v) shows that when the mux selects TPG, the dvi2rgb path is back-pressured. The HDMI source may be unlocked entirely (no HDMI cable) and `vid_pVSync` may be static or unrelated to the TPG's actual frame timing.

When TPG is the source, `fsync_pulse_gen` must see **TPG's own internal vsync**, not dvi2rgb's. Either:
- (a) Add a small 2:1 mux on `vsync_in_async` selected by the same `sel` line as `axis_mux_2to1`, or
- (b) Always drive `fsync_pulse_gen` from whichever vsync is downstream of the source mux (TPG-internal or dvi2rgb-recovered, selected before reaching the CDC sync).

This is independent of the broader architecture question and is likely contributing to bench irreproducibility even if Attempt D is otherwise sound.

### 5.3 The "arm by VTC vsync" race is worth bench-confirming

The debug log lists it as low-risk; the analysis is correct that `vtc_q1` starts at 0, so any 0→1 transition arms. The risk worth checking on the scope: if `rst_pixclk_out` releases **after** firmware enables VTC TX (e.g., because the reset tree has VTC and `fsync_pulse_gen` in different reset domains), the first VTC vsync edge happens while `fsync_pulse_gen` is still in reset. Confirm reset-tree ordering in the BD, or add a small "saw vtc_vsync go high *at least once*" capture register accessible from firmware so this is observable.

---

## 6. Recommended path forward

### Short term (this week) — finish the TPG goal at debug-tier quality
1. Run the slot-index experiment in §5.1.
2. Fix the dvi2rgb-vs-TPG vsync routing bug in §5.2.
3. If §5.1 shows discrete slot bins: implement deterministic starting-slot selection in firmware. The TPG offset bug resolves and we move on.
4. If §5.1 doesn't show discrete bins: the current Attempt D one-shot fsync with VTC-vsync arming is probably correct as built — proceed with the planned rebuild, expect counter near row ~2 per the math in §4 of the debug log.

### Medium term (next arc) — promote Phase E1 from "future" to "next"
The single architecturally meaningful step: **make the output pixel clock pullable.** Smallest viable spike:

- Configure `clk_wiz_pixclk_out` with dynamic reconfiguration (DRP) enabled.
- Add a software loop on the PS: measure phase error between source vsync and output vsync (timestamp counters on both edges), apply a small phase nudge through the MMCM each frame.
- Loop bandwidth ~0.5–1 Hz, single-pole IIR filter, deadband to suppress dither.
- Goal: demonstrate that the output vsync can be **held within ±1 line** of an arbitrary reference vsync. The reference can initially be source vsync (same problem the one-shot fsync solves, but in steady state). Once that works, swap the reference for the Si5351 / RP2040 path.

This is several weeks of work, not days. But it's the work that puts a real foundation under everything in `01-spec.md §3.7` and `§3.8`. Until it exists, every additional layer of VDMA-Genlock-as-drift-absorber is reinforcing a topology the product spec doesn't want.

### Long term — adopt the Intel Genlock Controller architecture
PFD → PID → NCO → MMCM, with Si5351 driven by RP2040 over I²C acting as the external NCO/VCXO. The spec already describes this; the references in §4 show how it's implemented in industry. The VDMA ring stays — but its job becomes **cadence conversion (60→50) and reference-loss holdover**, not clock-domain locking. That's a coherent, broadcast-tier role for it.

---

## 7. The framing question worth holding onto

The debug log opens with the user quote:

> "I feel like this should be more of an AHA certainty than tweaking a few lines here and there. Isn't there a mathematical formula? This seems more touchy feely vibes based than science."

That instinct is correct, and it points at a deeper problem than the one Attempt D is solving. The mathematical answer to "how do I align two oscillators?" is **you don't — you make one of them slave to the other through a phase-locked loop.** That's the AHA. Everything else (one-shot fsync, VDMA ring depth, MMCM phase tracking) is just *implementation* of that idea, with different tradeoffs in lock time, residual jitter, and silicon cost.

The current architecture is missing the phase-locked loop. Adding more frame-buffering or smarter fsync gating can't substitute for it. The next big move is to build the loop — initially software-closed against the MMCM, eventually hardware-closed against the Si5351.

---

## 8. References

- [PG016 — Video Timing Controller, `fsync_in`](https://docs.amd.com/r/en-US/pg016_v_tc/The-fsync_in-Pin) · [PG016 v6.2 PDF](https://www.xilinx.com/content/dam/xilinx/support/documents/ip_documentation/v_tc/v6_2/pg016_v_tc.pdf)
- [PG020 — VDMA Dynamic Genlock Slave](https://docs.amd.com/r/en-US/pg020_axi_vdma/Dynamic-Genlock-Slave)
- [XAPP792 — Designing High-Performance Video Systems with Zynq-7000](https://manualzz.com/doc/9360464/xapp792---designing-high-performance-video-systems-with-t...)
- [XAPP1092 — SMPTE SDI on Zynq GTX (PICXO context)](https://docs.amd.com/api/khub/documents/aC8vMuC1~D7J3OtVq7UwyQ/content)
- [Intel WP 828717 — Designing Genlocked Video Systems with Deterministic Low Latency on FPGAs](https://www.intel.com/content/www/us/en/content-details/828717/designing-genlocked-video-systems-with-deterministic-low-latency-on-fpgas-white-paper.html)
- [Intel Genlock Controller IP](https://www.intel.com/content/www/us/en/docs/programmable/683329/24-2/genlock-controller-ip-functional-description.html)
- [Intel Genlock Signal Router IP](https://www.intel.com/content/www/us/en/docs/programmable/683329/22-4/about-the-genlock-signal-router-ip.html)
- [Intel Video & Vision Processing Suite](https://www.intel.com/content/www/us/en/products/details/fpga/intellectual-property/dsp/video-vision-processing-suite.html)
- [Skyworks AN377 — Timing and Synchronization in Broadcast Video](https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/application-notes/AN377.pdf) · [Si53xx Reference Manual](https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/reference-manuals/si53xx-reference-manual.pdf)
- [Embedded.com — Genlock gets broadcast video signal timing in sync](https://www.embedded.com/genlock-gets-broadcast-video-signal-timing-in-sync/)
- Internal: [`01-spec.md §3.7`](01-spec.md) (genlock subsystem), [`§3.8`](01-spec.md) (dual SYNC OUT), [`dev-roadmap.md`](dev-roadmap.md) Phase E1, [`phase-c-design.md`](phase-c-design.md) (cross-clock tearing seam).

---

## 9. Response from the debug-thread agent

**Date:** 2026-05-18
**Reviewer:** the agent that authored [`tpg-vsync-alignment-debug.md`](tpg-vsync-alignment-debug.md) and executed Attempts A–D at the bench.
**Status:** Evaluation of §1–§8 above, anchored to bench evidence (images #10 and #11) and to the four attempts already on the record.

### 9.1 What this review gets unambiguously right

**§3 (VDMA Dynamic Genlock ≠ broadcast genlock).** Matches my own memory notes — `schindler_vdma_dynamic_genlock` and `xilinx_vdma_drift_limits` both flag that PG020 doesn't promise drift tolerance and that FrameDelay=1 + 3 framestores is brittle. The review correctly names that we've been treating a frame-syncing tool as a clock-locking tool.

**§4.3 (XAPP792's continuous-fsync pattern only works under shared clock).** Confirmed empirically by **Attempt B**: continuous fsync_in on independent clocks produced severe tearing (image: "Deeply unlocked…"). The review's framing — continuous fsync is the natural pattern *once* the clocks are locked — is exactly the lesson Attempt B taught at the bench.

**§7 (the framing AHA).** This is the right answer to Justin's quote. Attempts A–D are all implementations of "align two oscillators without a PLL" — and that is mathematically impossible to keep stable. The current architecture is missing the loop. Adding more frame-buffering or smarter fsync gating cannot substitute for it. **My work supports this conclusion, not against it.**

### 9.2 What my work directly disproves or substantially weakens

#### §5.1's specific arithmetic — "288 = slot 2 of 5" — does not survive scrutiny

The reviewer divides 720 lines / 5 slots = 144 rows/slot and calls 288 "exactly slot 2 of 5." That conflates two things:

- In VDMA Dynamic Genlock, **each slot is a full 720-line frame**, not 144 rows. Slot-index offset means MM2S reading frame N−2 instead of N — visible as **temporal lag**, not vertical row offset.
- A "row 288 offset" cannot come from slot indexing in PG020's framestore-ring model.

Moreover — and this is the bigger disproof — **Justin's latest bench evidence (image #11) shows the wrap point is *moving frame-to-frame*, not static.** Slot indexing would produce a stable offset that coin-flips between reboots and stays put within a session. Continuous motion of the wrap is the signature of **clock drift between two un-genlocked oscillators** — which is precisely §3 and §7's argument, not §5.1's.

So §5.1's *experiment* (vary the S2MM↔MM2S delay) is cheap and worth running for completeness, but the **predicted 144-row bin spacing has no theoretical basis** and the moving-wrap evidence already largely rules out the slot-index hypothesis.

#### Attempt C ("stable but offset ~280 rows") was overstated in the debug log

The review summarizes Attempt C as stable-but-offset. That matched image #10. **But image #11 (taken after Attempt D's build) shows the wrap is drifting** — even Attempt D doesn't produce a steady-state offset. The "stable but offset" language in [`tpg-vsync-alignment-debug.md`](tpg-vsync-alignment-debug.md) §4 (Attempt C) should be read as "stable for a few seconds, then drifts." This **strengthens** the review's central thesis: no amount of fsync-gating produces steady-state alignment without a PLL.

### 9.3 Color commentary on hypotheses my work doesn't contest

#### §5.2 (fsync_pulse_gen wired to wrong vsync when TPG is selected) — plausible secondary bug

The review is correct that when `axis_src_mux` selects TPG, the dvi2rgb path is back-pressured at the AXIS handshake. But **dvi2rgb's `vid_pVSync` pin continues to toggle** as long as an HDMI cable is plugged in and locked at the receiver — it's a raw HDMI-decoded signal, independent of the AXIS interface. So `fsync_pulse_gen` *does* see real source vsync edges in our current bench setup (because there is an HDMI source physically present).

But those edges are aligned to the **HDMI input's** frame timing, not TPG's. TPG runs on the same PixelClk but its frame counters start from boot reset, not from HDMI vsync. So fsync_in resets VTC TX to dvi2rgb's frame phase while the data flowing through the pipeline is TPG-phase. **That mismatch is real and is a credible contributor to the residual offset**, particularly when testing with no HDMI source (where `vid_pVSync` would be static).

The fix the review proposes (mux the vsync source alongside the data) is correct. **Adds nothing to disprove the PLL argument** — but worth fixing if we continue down the TPG-debug path before pivoting to E1.

#### §5.3 (reset-tree ordering race) — worth a scope check, not a blocker

`rst_pixclk_out` releases when proc_sys_reset sees MMCM lock + sync. That happens very early in boot, long before firmware enables VTC. So Attempt D's "armed by VTC vsync" gating should latch the first edge. I'd give this <10% probability of being the bug, but a one-line firmware-readable "saw vtc_vsync at least once" status bit is cheap insurance.

#### §4.1 + §4.2 (Intel WP 828717 + PICXO / MMCM fractional reconfig) — these are the right references

The Intel paper names exactly the topology `01-spec.md §3.7` describes. PICXO via MMCM fractional reconfig is the path that fits Z-7020 without changing silicon. The existing memory note `xilinx_mmcm_psincdec_tracking` (±500 ppm range, prior art from Intel/rrk1/ascal) is the matching building block. The review and my existing notes converge here. **Phase E1 isn't a research project — it's an integration task with well-mapped prior art.**

#### §6 short-term path — the slot-index experiment is cheap but unlikely to pay

Worth running for completeness only because reboots are ~30 s each. If it shows no bin structure (which I expect, given the moving-wrap evidence), we have confirmed the architectural answer is the only answer.

#### §4.5 (PG016 `enable_detection=false` check)

Confirmed: `tcl/build_phase_b.tcl` has `CONFIG.enable_detection {false}` on `v_tc_tx`. Not a contributor.

### 9.4 Suggested new plan

The review's medium-term recommendation — **promote Phase E1 from "future" to "next"** — is the right call. Specifically:

1. **Stop** iterating on TPG fsync variants. Attempts A–D all live in the same "no PLL" failure mode; further tweaks won't escape it.
2. **Park** [`tpg-vsync-alignment-debug.md`](tpg-vsync-alignment-debug.md) as a sealed record of why fsync-only doesn't work — it is already good source material for future readers.
3. **Pivot** to a software-closed MMCM phase-tracking spike against `clk_wiz_pixclk_out`. Reference: existing `xilinx_mmcm_psincdec_tracking` memory + Intel WP 828717. Goal: hold output vsync within ±1 line of an arbitrary reference vsync. Reference initially = source vsync (proves the loop closes). Eventually = Si5351 / RP2040 (matches spec §3.7).
4. **Defer** the §5.2 vsync-mux fix until after the PLL spike — it becomes either obviously correct or obviously moot once the architecture changes.

The review is right that the AHA Justin asked for isn't a smarter fsync — it's a phase-locked loop. The bench is telling us the same thing in image form.

