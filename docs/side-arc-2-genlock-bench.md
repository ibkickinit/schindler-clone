# Side-arc 2 — Genlock / sync subsystem bench bring-up

**Status:** Banked 2026-05-14
**Type:** Bench bring-up side-arc (parallel to main HD pipeline Phase A–G)
**Goal:** Validate the genlock subsystem end-to-end on the bench — analog reference input (BB / tri-level / LTC) through PGA + ADC, FPGA-resident digital PLL, RP2040 + Si5351 closed-loop control, and operator H/V phase trim. Establishes the clock-domain foundation that every output sync generator depends on.

## Why this is its own side-arc

Genlock spans **four chips + significant FPGA logic** and is the deepest single subsystem in the design. It deserves its own bench bring-up arc rather than being a phase or a slice of one. It's independent of the Phase A–G ordering — can run in parallel as long as the relevant EVAL boards are on the bench.

This side-arc is **larger than Side-arc 1** and naturally breaks into five sub-arcs (2a–2e).

## Clocking architecture banked here

### The two clocking regimes

| Regime | Reference source | Clock extraction |
|---|---|---|
| **1 — Digital input lock** | HDMI RX (LT8619C) or SDI RX (GS3470) | Receiver chip recovers a clean CMOS pixel clock on a pin. |
| **2 — Analog reference lock** | Black burst / tri-level / LTC on BNC REF IN | No clock to recover — only sync edges (or LTC biphase-mark transitions). Must measure frequency from edge counting and regenerate clean clock. |

### Hybrid architecture — Si5351 always routes the master clock

**Decision banked:** the master FPGA clock comes from Si5351 in *both* regimes. Recovered clocks from digital inputs feed in as a *reference* into the FPGA digital PLL → Si5351 path, not directly into the fabric. This is now reflected in `01-spec.md` § 3.7.

Rationale:
- **Free-run hold on input loss** — no glitched output mid-frame.
- **Jitter cleaning** — Si5351 ~50 ps RMS output, independent of input source quality.
- **Architectural uniformity** — downstream sync generators don't care which regime is active.

Cost: a few frames of lock acquisition time when input changes. Acceptable.

### Architecture diagram (Regime 2 path)

```
REF IN ─→ PGA ─→ 20 MSPS ADC ─→ FPGA ─→ digital PLL math ─→ correction word
(BB/TLS/LTC)  (LTC6912) (AD9204)        (phase det + loop filter + NCO)
                                                                │
                                                                ▼
                                                            RP2040 ←── (slow path, I²C)
                                                                │
                                                                ▼
                                                            Si5351 ─→ FPGA master clock
                                                                       (27 / 74.25 / 148.5 MHz)
                                                                │
                                                                ▼
                                                            FPGA sync generators
                                                            (H/V offset trim here, not in Si5351)
```

### Why hybrid (not pure in-FPGA, not pure external)

**Pure in-FPGA fails because:**
- Zynq MMCM dynamic re-tuning via DRP is slow and coarse — not suitable for sub-Hz lock to a drifting analog reference.
- MMCM output jitter (~100–200 ps RMS) is marginal for broadcast SYNC OUT distribution.

**Pure external fails because:**
- Silicon that locks an analog PLL to BB/tri-level (Gennum/Semtech legacy parts) is EOL or expensive.
- The ADC stream is already in the FPGA — putting the PLL math there is free silicon-overlap-wise.

### Camera phase/offset trim

**100% FPGA-side, post-Si5351-lock.** Si5351 stays locked to the reference and is *not* wiggled for trim.

What's wiggled: **sync generator start-of-frame offset registers** inside the FPGA. Two operator-facing values per output:
- **H phase offset** — N pixel-clock cycles. Resolution = one pixel-clock period (≈18 ns at 54 MHz SD, ≈6.7 ns at 148.5 MHz HD).
- **V phase offset** — M lines.

Sub-pixel resolution (rarely needed; mostly for SC/H phase on composite) via MMCM phase-tap muxing (4× resolution) and the existing 32-bit chroma NCO in `chroma_gen.v`.

## Bench plan — five sub-arcs

Each sub-arc is independently scope-checkable. Land them in order; later ones depend on earlier ones.

### Sub-arc 2a — Si5351 standalone bring-up

**Goal:** Si5351 outputs a commanded frequency, scope-verified.

- RP2040 dev board + Si5351 breakout (Adafruit or similar) on the bench.
- Firmware: I²C register writes per Skyworks AN619.
- Scope CLK0 output → verify commanded frequency (27 MHz, 74.25 MHz, 148.5 MHz target set).
- Tune fractional-N divider live, verify smooth frequency steps.

**Effort:** ~1 day.

### Sub-arc 2b — AD9204 + LTC6912 bring-up

**Goal:** Function-generator analog input → captured cleanly in FPGA fabric, gain controllable.

- AD9204-80EBZ (already procured) + LTC6912 EVB on bench.
- Function generator → PGA in → ADC in → parallel data into Zybo via PMOD.
- FPGA HDL: capture ADC samples into BRAM ring buffer, dump over UART/JTAG to host for inspection.
- Verify: sine input at 1 kHz captures as clean digital sine; PGA gain command via I²C changes amplitude correctly.

**Effort:** ~2–3 days.

### Sub-arc 2c — BB sync separator + autosense classifier

**Goal:** FPGA correctly identifies and decodes a black burst reference.

- Generate BB waveform offline in Python (15.734 kHz H-sync, 59.94 Hz V-sync, NTSC structure) → load into ADC ring buffer for offline testing first.
- FPGA HDL: sync separator (slicer + edge detector + line/field counter), autosense classifier (LTC biphase / BB / TLS signature).
- Validate on captured ADC stream first; then live-feed from a function generator playing the BB waveform; then a real broadcast sync generator if available.
- Extend to tri-level (1080i/p reference) and LTC (audio-band timecode).

**Effort:** ~1 week.

### Sub-arc 2d — Closed-loop digital PLL

**Goal:** FPGA-computed correction drives Si5351, Si5351 output locks to BB reference.

- Combine 2a + 2b + 2c on Zybo.
- FPGA digital PLL: phase/frequency detector, loop filter (0.5 Hz bandwidth default), NCO/integrator with free-run hold.
- Correction word → RP2040 over UART → Si5351 over I²C.
- Validate: frequency-shift the input BB source, watch Si5351 output track it after lock settles; pull the BB cable, watch free-run hold engage cleanly.
- Verify lock acquisition time, lock detector state machine (Acquiring / Locked / Lost), phase-error magnitude, 1 s stddev quality metric.

**Effort:** ~1–2 weeks.

### Sub-arc 2e — H/V phase offset trim

**Goal:** Operator-facing H and V phase trim that shifts output sync timing relative to the locked reference.

- Add H/V offset registers to the sync generator (modify `vid_timing.v` or build a parameterized successor).
- Expose via I²C/UART from PetaLinux user-space — eventually wired to UI knobs.
- Scope: dual-channel, REF IN and CVBS OUT. Vary H offset, watch the output's HSYNC slide relative to the ref. Same for V.
- Validate range: ±1 full line on H, ±1 full frame on V.
- Optional polish: MMCM phase-tap muxing for sub-pixel H if needed.

**Effort:** ~3–5 days.

## Success criteria

| Sub-arc | Pass condition |
|---|---|
| 2a | Si5351 output frequency matches commanded value within ppm; tune steps smooth on scope. |
| 2b | Sine-in → captured-sine-out matches; PGA gain commands change amplitude predictably. |
| 2c | Sync separator correctly identifies BB / tri-level / LTC on offline + live captures; per-format decoders extract H/V timing accurately. |
| 2d | Si5351 output frequency tracks input BB drift after lock; free-run hold engages glitch-free on ref loss; lock state machine reports correct state. |
| 2e | Output HSYNC/VSYNC shifts relative to REF IN by the commanded H/V offset, scope-verified, full range exercised. |

## Effort estimate (total)

| Sub-arc | Effort |
|---|---|
| 2a | ~1 day |
| 2b | ~2–3 days |
| 2c | ~1 week |
| 2d | ~1–2 weeks |
| 2e | ~3–5 days |
| **Total** | **~3–5 weeks of focused work** |

## Deliverables

- `hdl/sync_sep.v` — BB / tri-level sync separator
- `hdl/ltc_decode.v` — LTC biphase-mark decoder + TC parser
- `hdl/ref_classifier.v` — autosense classifier across all three input types
- `hdl/digital_pll.v` — phase/frequency detector + loop filter + NCO/integrator
- `hdl/ref_mux.v` — reference selector (operator override + autosense priority)
- `hdl/vid_timing_genlock.v` — successor to `vid_timing.v` with H/V phase offset registers (or in-place modification)
- RP2040 firmware: Si5351 driver + UART protocol to Zynq PS + autosense slow-control
- PetaLinux user-space: genlock UI state machine, lock-state display, trim knob handlers
- Scope captures banked in `docs/scope-captures/side-arc-2/` (folder TBD)

## What this enables

Once Side-arc 2 lands:
- Every output's sync generator can run locked to an external reference (broadcast-grade behavior).
- Camera-timing workflow (the original Schindler mission for filming CRTs) is fully operational.
- Pro SKU's dual SYNC OUT (§ 3.8) has the timing source it needs — adds the per-OUT DAC + driver chain on top of this foundation.
- VITC extraction from SDI (Pro only) plugs in via GS3470 once Side-arc 4 (LT8619C) and an eventual SDI side-arc activate.

## Cross-references

- Dev roadmap: [`dev-roadmap.md`](dev-roadmap.md) § 2.5
- Spec — genlock subsystem: [`01-spec.md`](01-spec.md) § 3.7 (updated with Si5351-routes-both-regimes + camera trim location)
- Spec — dual SYNC OUT (downstream consumer): [`01-spec.md`](01-spec.md) § 3.8
- Sibling side-arc: [`side-arc-1-adv7393-bench.md`](side-arc-1-adv7393-bench.md)
- Reference designs (AJA FS1 / FS-HDR genlock topology is relevant prior art): [`reference-designs.md`](reference-designs.md) § 3.1
