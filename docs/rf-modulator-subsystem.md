# Schindler 2.0 — RF Modulator Output Subsystem

**Status:** CONFIRMED — banked 2026-05-11. Built into every V1 carrier (no daughter card, no Period SKU tier).
**Tier:** Standard V1 feature on all units (Base and Broadcast).

This doc holds architecture and parts spec for the RF modulated output subsystem. Decision history is in [`01-spec-changelog.md`](01-spec-changelog.md); summary spec entry in [`01-spec.md`](01-spec.md); BOM line items in [`bom-v1.md`](bom-v1.md) section 7.

---

## What this is

An RF modulated output on a TV channel carrier (NTSC Ch3 or Ch4, operator-selectable), feeding 1970s consumer CRTs that have only an antenna/RF input and no composite jack.

Rides on the existing ADV7393 composite encoding — the RF subsystem is a parallel output path that consumes the same composite signal the composite BNC consumes. Operator picks one of three analog output modes via UI:

| Mode | Live connectors | ADV7393 state | RF chain |
|---|---|---|---|
| **Composite** | composite BNC | composite mode | disabled |
| **RF (Ch3 or Ch4)** | F-connector | composite mode | enabled, Si5351 ch1 programmed for selected channel |
| **Component** | 3× component BNC (YPbPr) | component mode | disabled |

Composite mode and RF mode share the same ADV7393 composite encoding; they differ only in which output path is gated live. Mode-mux logic on the carrier handles the gating.

---

## Architectural decisions banked

### Why on every carrier, not a daughter card

The daughter-card pattern (mirroring SDI broadcast tier) was reconsidered and dropped 2026-05-11. Reasoning:

- BOM delta is small (~$33 vs $0). Doesn't justify SKU bifurcation the way SDI's $32 of broadcast-specific silicon does.
- Customer segments are fuzzy. A DP hauling a Schindler to set could encounter a period CRT on any shoot; that doesn't sort cleanly into "Period customer" vs "Base customer."
- FCC scope already covers every unit (WiFi/BT certification is required regardless). Adding RF to the cert is incremental, not bifurcating.
- Clean product story: every Schindler 2.0 has HDMI + SDI + an analog output that's composite OR component OR RF, selectable.

Result: SKU axis collapses to Base + Broadcast (SDI factory option). RF is universal.

### Why DSB-AM, no VSB filter, no audio modulation

- **DSB-AM (not VSB):** True VSB requires per-channel SAW filters or sharp LC bandpass networks. DSB-AM uses 2× the spectrum but works fine into consumer TV receivers — they're VSB *receivers* that filter the unwanted sideband at the IF stage internally. We're not broadcasting; we're cabling 2 m into a CRT.
- **No audio FM modulation:** Path A confirmed 2026-05-11. Silent CW pilot carrier from Si5351 at video_carrier + 4.5 MHz satisfies the period-CRT intercarrier AGC requirement (TV detects audio carrier presence, no audio to demodulate, speaker stays silent). Schindler's mission is camera-captured visuals; film cameras don't record CRT speaker audio, so audible audio is not a requirement. Audio FM modulation (with FPGA-generated 1 kHz tone via discrete Colpitts VCO with varactor) was considered and deferred — if customer-evidence in V1.x drives speaker output, the ~$3 BOM path is documented and ready.

### Why Ch3/Ch4 only

- US-centric customer base (film/TV production driving period US CRTs). Every period US set tunes Ch3 or Ch4 as the VCR-connect channel pair. The Zenith and Sony console in the playbook are both this case.
- Cleaner spectrum: bandpass filter centered 56–73 MHz (covers Ch3 video at 61.25 + Ch3 audio at 65.75 + Ch4 video at 67.25 + Ch4 audio at 71.75) rejects everything outside the channel band by design. Eliminates need for a separate harmonic LPF.
- Simpler UI: Ch3/Ch4 toggle (matches how VCRs presented it for 30 years).
- PAL/NTSC-J/PAL-M expansion is firmware-only later — same hardware, different Si5351 register loads + wider bandpass if international demand ever materializes.

---

## Architecture

```
[ADV7393 in composite mode] ──► [LMH6643 buffer]
                                       │
              ┌────────────────────────┼────────────────────────┐
              │                                                  │
              ▼                                                  ▼
       [composite BNC OUT]                          [Y input — ADL5391]
       gated by ADG419 SPST switch                  multiplier core
       (mode-mux: open in RF mode)
                                                     [Z input — DC bias]
                                                     for AM modulation depth

       [Si5351 ch1, dedicated RF subsystem]
       Ch3: 61.25 MHz / Ch4: 67.25 MHz
       (programmed by Zynq PS via I²C)
              │
              ▼
       [LPF, recover sinusoid]
              │
              ▼
       [X input — ADL5391]
              │
              ▼
       [ADL5391 output: AM-modulated video carrier]
              │
              ▼
       [Resistive combiner]◄──── [Si5351 ch2: pilot audio CW]
              │                   Ch3: 65.75 MHz / Ch4: 71.75 MHz
              ▼                   (no audio modulation — pure tone)
       [Bandpass filter: 56–73 MHz LC network]
              │
              ▼
       [ERA-3SM+ MMIC amp, ~22 dB gain]
       gated by Zynq PS GPIO via bias-inductor FET
              │
              ▼
       [50 → 75 Ω minimum-loss pad: 43.2 Ω series + 86.6 Ω shunt]
              │
              ▼
       [DC block + ESD]
              │
              ▼
       [F-connector, panel-mount 75 Ω] ──► RF OUT
```

### Tap point on carrier

Same composite signal that drives the composite BNC, taken from the existing LMH6643 output buffer. No additional buffer channel needed — the RF chain consumes the same buffered composite signal, which is ~1 Vpp into 75 Ω.

### Mode-mux logic

- **Composite BNC enable:** ADG419 (or equivalent SPST analog switch IC) in series with the BNC output, gated by Zynq PS GPIO. Open in RF mode + component mode; closed in composite mode.
- **RF amp enable:** ERA-3SM+ bias supply gated by FET switch, controlled by separate Zynq PS GPIO. Active in RF mode; off otherwise.
- **ADV7393 mode:** I²C-switched between composite mode (serves composite + RF) and component mode (serves 3× component BNC, kills composite signal path).

Total mode-mux silicon: ADG419 ($1.50) + bias-switch FET ($0.30) + 2 GPIO pins from Zynq PS. ~$2.

### Si5351 dedicated to RF subsystem

Separate from the genlock Si5351. Reasoning:
- Genlock Si5351 is constantly nudged by the FPGA loop filter to track the reference; RF subsystem wants stable fixed frequencies.
- Genlock Si5351 ch1/ch2 stay reserved for future GPSDO 10 MHz distribution.
- Decoupling avoids cross-coupling between the two subsystems through the shared chip.

RF Si5351 channels:
- **ch0:** unused (or future expansion)
- **ch1:** RF video carrier — 61.25 MHz (Ch3) or 67.25 MHz (Ch4), I²C-programmable from Zynq PS
- **ch2:** RF audio pilot carrier — 65.75 MHz (Ch3) or 71.75 MHz (Ch4), unmodulated CW

### Output level

~−40 to −30 dBm at the F-connector. Adjustable via ADL5391 GADJ pot (or Z-input bias trim) + ERA-3 fixed gain. Designed for short-coax-into-CRT use, not broadcast.

Stays inside FCC Part 15.119 cable-output limits with shielded RF section + bandpass filter (rejects everything outside Ch3/Ch4 band, including 2nd harmonics of video carriers which fall at 122.5/134.5 MHz — well outside passband).

### FCC strategy

- Shielded can over modulator + amp section + Si5351 + bandpass filter.
- Output limited to coaxial F-connector (no antenna driven).
- Bandpass filter naturally suppresses harmonics (2nd harmonic of 67.25 MHz Ch4 video carrier sits at 134.5 MHz, ≥60 dB below in passband response).
- Bench-verify radiated emissions before commercial shipping.
- Formal FCC Part 15 test campaign rolls into the WiFi/BT cert already required for every unit — incremental, not separate.

---

## Parts spec

### 1. AM modulator (the critical part)

**Primary:** `ADL5391ACPZ-R7` — Analog Devices DC-to-2.0 GHz multiplier, 16-LFCSP, ~$15 single qty (R7 reel cut), ~$18 at qty 100.

**Fallback:** `AD835ARZ` — 250 MHz 4-quadrant multiplier, 8-SOIC, ~$25 at qty 100.

Order both for prototype bench eval. Discussion of trade-offs and rejection of alternatives (AD834, AD633, ADL5390, ADRF6755, single-chip TV modulators) in the rejected pile — see [`01-spec-changelog.md`](01-spec-changelog.md) 2026-05-11 RF tier entry.

### 2. RF carrier generation

**Si5351A-B-GT** local on carrier (dedicated to RF subsystem) + **25 MHz crystal**. ~$2 total.

### 3. RF amplifier

**Mini-Circuits ERA-3SM+** MMIC. DC–3 GHz, ~22 dB gain, SOT-89, 50 Ω native. ~$3.50.

### 4. 50→75 Ω match — resistive minimum-loss pad (MLP)

**Two resistors: 43.2 Ω series + 86.6 Ω shunt** (off-the-shelf 43 Ω + 82 Ω at 1% tolerance is close enough — 0.7% Z-mismatch is invisible at our level budget). ~$0.10 total in passives. **5.7 dB insertion loss** — the mathematical minimum for a purely resistive 50↔75 Ω match. Broadband DC-to-GHz, no tuning, no drift.

**Why MLP, not a transformer.** 50→75 Ω wants a 1:1.5 impedance ratio, which means turns ratio √1.5 ≈ 1.22:1. That's not a standard manufacturing ratio. Commercial "1:4 impedance" RF transformers (Mini-Circuits TC4-1W+ class, MACOM MABAES0061 class) do 50↔200 Ω, NOT 50↔75 — confirmed by datasheet re-read 2026-05-11 PM. True 50↔75 transformers (Mini-Circuits TM2-43X+, TCM2-33X+ class) exist with internal 1:1.5 turns but cost $3–8 and save only ~4 dB vs the pad.

**Why the loss doesn't matter for us.** ERA-3SM+ has ~22 dB of gain. Target output is −40 to −30 dBm at the F-connector. CRT tuners accept −50 to −10 dBm. We have enough dB headroom that 5.7 dB to the pad is rounding error. Trading the pad for a $3–8 transformer to save dB we don't need is solving a problem that doesn't exist.

### 5. Output bandpass filter

5th-order LC bandpass centered ~64 MHz, passband 56–73 MHz. Coilcraft 0805CS class inductors + C0G ceramic caps. ~9 parts, ~$1.50. Topology (Chebyshev vs Butterworth) synthesized after bench-characterizing harmonic content.

### 6. Combiner (video AM + audio pilot)

3-resistor resistive combiner before bandpass filter. ~$0.50.

### 7. Mode-mux silicon

- **ADG419BRZ** (SPST analog switch) on composite BNC output, ~$1.50.
- **FET switch** on ERA-3 bias supply for RF amp gate, ~$0.30.
- 2× Zynq PS GPIO pins (free).

### 8. F-connector + protection

- **Amphenol RF 82-4421** class panel-mount 75 Ω, ~$1.50.
- **PESD3V3L1BA** TVS for ESD, ~$0.20.
- **C0G 0.1 µF 50 V** DC block, ~$0.10.

### 9. Shield can

**Wurth WE-SHC** or Laird small-format (~25×25 mm) with frame, over modulator + amp + Si5351 + bandpass filter section. ~$2.50.

### 10. Bypass / decoupling

Generic 0.1 µF + 10 µF per power rail. ~$1.

### Total RF subsystem BOM

| Item | Per unit |
|---|---:|
| ADL5391ACPZ-R7 | $18 |
| Si5351A-B-GT + 25 MHz crystal | $2 |
| ERA-3SM+ RF amp | $3.50 |
| 50→75 Ω MLP (2 resistors) | $0.10 |
| Output bandpass filter (LC passives) | $1.50 |
| Audio combiner passives | $0.50 |
| Mode-mux (ADG419 + FET) | $1.80 |
| F-connector + ESD + DC block | $1.80 |
| Shield can + frame | $2.50 |
| Bypass / decoupling passives | $1 |
| **RF subsystem total** | **~$32 per unit** |

Built into every V1 unit (Base + Broadcast). No daughter card, no mezzanine, no PCB extension.

---

## Rear panel placement

F-connector lives **beside the composite BNC** on the rear panel. Both physically present; only one electrically live at a time per mode-mux state.

Panel-area impact: F-connector is ~10 mm cutout. Absorbed in the existing ~179 mm of unused panel slack documented in [`panel-layout.md`](panel-layout.md). No connector reorganization needed.

---

## Open questions for bench-eval phase

- **Final modulator chip:** ADL5391 vs AD835 — pick after prototype characterization. Order one of each.
- **Output bandpass topology:** Chebyshev (steeper, with ripple) vs Butterworth (flat, gentler) — synthesize after measuring actual harmonic content from the modulator.
- **Si5351 channel allocation:** confirmed ch1 = video carrier, ch2 = audio pilot, ch0 free. Pin layout TBD at schematic phase.
- **Channel selection UI surface:** front-panel quick-select button (Ch3/Ch4 toggle) or web-only? Defer to UI spec phase.
- **Audio FM modulation in V1.x:** if customer reports drive audible audio (speaker actually plays sound), Path B from 2026-05-11 audio analysis (discrete Colpitts VCO + FPGA 1 kHz NCO via PWM + LPF, ~$3 BOM, ~1 day HDL) is the documented next step.

---

## Bench bring-up checklist

1. Order **EC Buying ADL5391 breakout board** ($15-25 AliExpress) + **ADL5391ACPZ-R7** ($15 DigiKey, authenticity backup) + **AD835ARZ** ($25 DigiKey, fallback) + **ERA-3SM+** (~$4 Mini-Circuits direct) + **43 Ω + 82 Ω 1% resistors** (cents, DigiKey, for the 50→75 Ω MLP) + **F-connector + adapters** (~$10 DigiKey).
2. Drive Si5351 at 61.25 MHz (Ch3 video carrier) from existing Adafruit 2045 breakout. Verify clean sinusoid out of LPF.
3. Feed Zybo Z7-20 composite test pattern output into modulator Y input. Adjust DC bias via Z input for proper AM modulation depth (sync tip → max carrier, peak white → min carrier).
4. Scope + spectrum analyzer (or Rigol DHO814 with FFT) on modulator output. Verify AM modulation envelope follows video.
5. Add bandpass filter + ERA-3 amp + F-connector. Verify output level ~−30 to −40 dBm.
6. Connect F-connector to 1970s CRT antenna input via 75 Ω coax. Tune CRT to Ch3. Verify lock + picture.
7. Re-program Si5351 to 67.25 MHz (Ch4). Verify clean retune + Ch4 picture.
8. Add Si5351 ch2 at 65.75 MHz (Ch3 audio pilot). Verify CRT still locks; if any 1970s set shows AGC hunt without pilot, this resolves it.
9. Bench-characterize harmonic content with spectrum analyzer. Design output bandpass topology to suppress.
10. Bench-verify radiated emissions in test enclosure before formal FCC pre-comp.

---

## Cross-references

- Spec entry: [`01-spec.md`](01-spec.md) — "RF modulator output (built-in)" section
- Decision history: [`01-spec-changelog.md`](01-spec-changelog.md) — 2026-05-11 entries (initial analysis, daughter-card scope, bake-in commit, audio Path A)
- BOM line items: [`bom-v1.md`](bom-v1.md) — Section 7
- Rear-panel placement: [`panel-layout.md`](panel-layout.md)
- Prior daughter-card framing (superseded): [`rf-modulator-daughter-card.md`](rf-modulator-daughter-card.md) — stub redirects here
