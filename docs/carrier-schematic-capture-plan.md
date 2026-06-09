# Carrier Schematic — Component Capture Plan

**Status:** TO-DO / build-ready · created 2026-06-09
**Purpose:** Block-by-block checklist for capturing carrier silicon into `KiCad/SchindlerSchematic_V1.kicad_sch`. Banked from the 2026-06-09 BOM-vs-schematic audit. Work top-to-bottom; check off per block.
**Sources of truth (this doc does not supersede them — it maps them onto sheets):** `bom-v1.md` (MPNs, packages, status), `signal-flow.md` (block structure + nets), `01-spec.md` (architecture).

**Schematic state when this was banked:** `SchindlerSchematic_V1.kicad_sch` is a single flat sheet containing ONLY the TE0720 SoM (U1, multi-unit) and the 12 V input-protection block (DC jack, P-MOS reverse-polarity FET ×2, polyfuse, TVS, shunt, caps, +12V/GND). No hierarchical sub-sheets exist yet. Everything in §2 below is uncaptured.

---

## 0. Fix-first — issues in already-drawn content

Resolve these in the existing block before adding more, so the corrections don't propagate.

- [ ] **Reverse-polarity FET — duplicate instance + wrong base symbol.** Two P-MOS symbols are placed; the BOM calls for one (Q1 = `DMP3098L-7`, P-channel −30 V, 31 mΩ, SO-8). One instance is on KiCad's generic `Transistor_FET:Q_PMOS_GSD`; the other is on an imported `Transistor_FET:DMP3099L` symbol. Both have their **Value** field overridden to `DMP3098L-7`, but (a) the `DMP3099L` base symbol's **Datasheet** field still points to the 3099L part, and (b) neither base symbol is guaranteed to match the real 3098L-7 SO-8 pin map (paralleled source/drain pins). Action: confirm whether the 2nd FET is intentional (separate role) or a leftover placeholder; delete the extra; bind the surviving Q1 to a symbol whose pin/footprint actually maps to DMP3098L-7 SO-8; fix the datasheet field.
- [ ] **TE0720 SoM — three disagreeing variant fields.** Value = `TE0720-04-31C33MA` (bench −1 commercial), but Footprint and MP fields both = `TE0720-03-61C33FAS` (a different −03/61 part). BOM production target = `TE0720-04-62I33MA`; BOM bench part = `TE0720-04-31C33MA`. Reconcile all three fields to whichever variant you're laying out before footprints lock. SnapEDA import artifact — the symbol came in carrying the demo-board's part identity.

---

## 1. Proposed hierarchical sheet structure

Suggested breakdown (~13 sheets; merge/split to taste — memory had this as ~12). Status: ✅ drawn · ◐ partial · ☐ to-do.

| # | Sheet | Holds | Status |
|---|---|---|---|
| 0 | Root / top | sheet symbols, inter-sheet buses, global power flags | ☐ |
| 1 | Power input + protection | DC jack, Q1 FET, polyfuse, TVS, shunt, INA226, bulk caps | ◐ |
| 2 | Power rails | 5 V / 3.3 V / 1.8 V / 1.35 V / 1.0 V bucks + VAUX LDOs | ☐ |
| 3 | TE0720 SoM | SoM connector, decoupling, I/O-bank net assignment | ◐ (placed) |
| 4 | HDMI input | TPD12S016, **LT8619C** | ☐ |
| 5 | Analog video input | **ADV7280**, input conditioning | ☐ |
| 6 | Analog video output | **ADV7393**, **OPA2350**, **LMH6643**, output network | ☐ |
| 7 | HDMI output | TPD12S016 (TX is FPGA-internal) | ☐ |
| 8 | SDI in/out (broadcast tier) | GS3470, GS2962 — footprints on every carrier | ☐ |
| 9 | Genlock front-end | conditioning, **LTC6912**, **AD9204** | ☐ |
| 10 | Clock + slow control | Si5351A-B-GT (genlock) + 25 MHz xtal, RP2040 | ☐ |
| 11 | Sync OUT | 2× 12-bit DAC + 2× 75 Ω cable driver | ☐ |
| 12 | Panel/status interface | 3× TLC59116F, rear LCD, front-mezzanine connector | ☐ |

Bold parts are the eight you handed me to verify. They live in sheets 4, 5, 6, and 9.

---

## 2. Per-block capture checklist

**General workflow per chip:** drop symbol → set Value = exact MPN → assign footprint → **verify pin map against datasheet** → wire nets. For complex ICs (ADI / Lontium / Linear), import from SnapEDA or Ultra Librarian and **verify the Footprint + MP fields on import** — that is exactly how the SoM picked up the wrong variant identity. For the dual op-amps, KiCad's generic dual-op-amp symbol + a SOIC-8 footprint with Value/MPN overridden is acceptable; no vendor symbol needed.

Packages below: where the ADI/Linear ordering-code suffix implies a package it's stated with **(verify)** — confirm lead count on symbol import. Pin-level nets reference `signal-flow.md` diagrams 1 and 2.

### Sheet 4 — HDMI Input  *(contains LT8619C)*
| Ref | MPN | Package | Symbol src | Notes |
|---|---|---|---|---|
| J? | HDMI Type A panel-mount | — | KiCad/conn | TMDS + DDC + HPD + 5 V cable power |
| U? | `TPD12S016PWR` (TI) | (verify) | SnapEDA | ESD clamps + DDC/HPD level shift + 5 V cable-power switch |
| U? | `LT8619C` (Lontium) | (verify — QFN) | SnapEDA/vendor | HDMI 1.4 RX; HDCP 1.4 keys embedded |

Nets: HDMI connector TMDS pairs → TPD12S016 → LT8619C; LT8619C parallel RGB[23:0] + PCLK + DE/HSYNC/VSYNC → TE0720 FPGA I/O (sheet 3 bank); LT8619C config I²C; DDC I²C + HPD via TPD; rails per sheet 2.

### Sheet 5 — Analog Video Input  *(contains ADV7280)*
| Ref | MPN | Package | Symbol src | Notes |
|---|---|---|---|---|
| J?×4 | BNC 75 Ω panel-mount | — | KiCad/conn | 1× CVBS + 3× YPbPr |
| U? | `ADV7280AWBCPZ-M-RL` (ADI) | LFCSP (verify lead count) | SnapEDA | SD analog decoder → 8-bit BT.656 YCbCr 4:2:2 |
| — | input conditioning | — | — | clamp diodes, switchable 75 Ω term, AC-coupling, anti-alias LPF |

Nets: BNCs → conditioning → ADV7280 analog ins; ADV7280 BT.656 parallel + LLC clock → FPGA; I²C control; 1.8 V analog + digital rails + VAUX LDO (sheet 2).

### Sheet 6 — Analog Video Output  *(contains ADV7393 + OPA2350 + LMH6643)*
| Ref | MPN | Package | Symbol src | Notes |
|---|---|---|---|---|
| U? | `ADV7393BCPZ-REEL` (ADI) | LFCSP-64 (verify) | SnapEDA | video DAC/encoder; composite/S-Video OR component, I²C mode-switched |
| U? | `OPA2350UA/2K5` (TI) | SOIC-8 | KiCad generic dual | SDTV buffers — composite + S-Video |
| U? | `LMH6643MAX/NOPB` (TI) | SOIC-8 | KiCad generic dual | HD buffers — component (+ SDI-adjacent) |
| J?×4 | BNC 75 Ω panel-mount | — | KiCad/conn | 1× CVBS + 3× YPbPr |

Nets: FPGA parallel video → ADV7393; ADV7393 I²C mode select; ADV7393 current-output DAC channels → op-amp buffer stage → 75 Ω series → BNC out. Composite-mode output also taps to the RF modulator board header. **Build the output stage around the ADV7393's own DAC outputs (per ADI ref design)** — do *not* import the 0.606 divider + AC-couple topology from `opamp-stage.md`/`r2r-dac.md`; that stage belongs to the FPGA Pmod R-2R *first-light* path (Phase 2 bring-up), not the production ADV7393 output.

> **MCP6022 is not a carrier line item.** `opamp-stage.md` lists it only as an acceptable *substitute* op-amp for the R-2R first-light board (10 MHz, "marginal for burst, OK for sync-only first test"). Do not place it on the carrier unless deliberately substituting for OPA2350 during bring-up.

### Sheet 9 — Genlock Front-End  *(contains LTC6912 + AD9204)*
| Ref | MPN | Package | Symbol src | Notes |
|---|---|---|---|---|
| J?×2 | BNC 75 Ω panel-mount | — | KiCad/conn | REF IN + REF LOOP (passive loop-through) |
| U? | `LTC6912CGN-2#PBF` (ADI/Linear) | SSOP-16 | SnapEDA | 2-ch PGA, AGC driven by classifier |
| U? | `AD9204BCPZ-20` (ADI) | LFCSP (verify — ~48) | SnapEDA | dual 10-bit 20 MSPS ADC; pin-upgrade path to AD9231/9251/9258/9268 |
| — | input conditioning | — | — | clamp diodes, switchable 75 Ω term, AC-couple, switchable analog LPF |

Nets: REF IN → conditioning → LTC6912 → AD9204 → 10-bit parallel + data clock → FPGA autosense classifier (signal-flow diagram 2); REF LOOP passive off REF IN; AD9204 sample clock source — confirm (Si5351 vs FPGA-derived); 1.8 V analog rail + VAUX LDO.

> **Verify control interface:** `signal-flow.md` diagram 2 shows `RP2040 -->|I2C| PGA`, but the LTC6912 uses an **SPI-style 3-wire serial interface** (CS / SCK / DIN), not I²C. Confirm and correct the net plan (and the signal-flow note) before wiring the slow-control bus.

### Remaining sheets (no parts from your list — captured here for completeness)
- **Sheet 7 HDMI out:** 2nd `TPD12S016PWR` + HDMI Type A; TX core is FPGA-internal (Xilinx free HDMI 1.4 TX IP), no separate chip.
- **Sheet 8 SDI:** `GS3470` (RX, also feeds genlock) + `GS2962` (TX), Semtech — footprints on every carrier, populated on broadcast-tier units only. BNCs.
- **Sheet 10 Clock/slow-control:** `Si5351A-B-GT` + 25 MHz xtal (genlock clock gen) + `RP2040` slow control. NOTE: the RF modulator board carries its **own separate** Si5351 — do not share the net.
- **Sheet 11 Sync OUT:** 2× 12-bit DAC (AD9744-class, specific part TBD) + 2× 75 Ω cable driver (ADV3000 / EL5170 / THS6212 class, TBD) + 2 BNC.
- **Sheet 2 Power rails:** 5 / 3.3 / 1.8 / 1.35 / 1.0 V bucks (TI TPS / ADI LTC family TBD) + VAUX LDOs (AD9204 1.8 V analog, ADV7280 analog, op-amp supplies). INA226 already in the protection block on sheet 1.
- **Sheet 12 Panel/status:** 3× `TLC59116F` I²C LED drivers, rear status LCD (ST7789-class SPI), front-panel mezzanine connector (UART + power to RP2040/BT817Q board). May be split to a separate board file rather than a carrier sheet.

---

## 3. Excluded from schematic — bench eval boards only

Not carrier components; they're bench-characterization tools for the corresponding production chips:
- `AD9204-80EBZ` — eval board for the AD9204 (80 MSPS bench variant vs production -20).
- `ADV7393EBZ` (EVAL-ADV7393) — eval board for the ADV7393.
- `MIKROE-2555` ×2 (LTC6912 click), `Adafruit 2045` ×2 (Si5351 breakout), `LT8619C-EVB`, `STM32H735G-DK` — likewise eval/dev hardware, not BOM placements.

---

## 4. Suggested capture order

1. **§0 fix-first** (FET + SoM variant fields).
2. **Sheet 2 power rails** — everything downstream needs defined rails; pick the buck/LDO families now.
3. **Sheet 3 SoM I/O** — assign FPGA bank pins so the signal-path sheets have real net targets.
4. **Sheets 4–7** video path (HDMI in → analog in → analog out → HDMI out).
5. **Sheets 9–11** sync/genlock + clock + sync out.
6. **Sheet 8** SDI (broadcast tier).
7. **Sheet 12** panel/status (or branch to its own board).

---

## 5. Open verifications (flag, don't guess)

- [ ] LTC6912 control bus: SPI-style 3-wire, not I²C as drawn in signal-flow (see sheet 9 note).
- [ ] AD9204 sample-clock source (Si5351 channel vs FPGA-derived).
- [ ] All packages marked **(verify)** — confirm lead counts on symbol import (LFCSP variants especially).
- [ ] DMP3098L-7 symbol pin/footprint mapping (see §0).
- [ ] TE0720 variant decision: bench `-04-31C33MA` vs production `-04-62I33MA` for the laid-out footprint (see §0).
