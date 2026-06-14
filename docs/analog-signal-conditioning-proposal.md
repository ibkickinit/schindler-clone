# Schindler 2.0 Carrier — Analog Signal-Path Conditioning (PROPOSE-AND-RATIFY)

**Status:** PROPOSAL 2026-06-13d — values + topology for sign-off. **Nothing wired yet**; on ratification the agent wires per-sheet (component values from the ✅/🧮/🔧 columns), PL data buses stay flagged for the placement pass.
**Confidence flags:** ✅ standard video practice / datasheet typical-app · 🧮 computed/datasheet-constant — verify the eqn/constant · 🔧 starting value — bench-tune · ❓ genuine design decision — your call.
**Sources:** `refdes-map.md`, `signal-flow.md`, ADI/TI/Semtech reference designs + datasheets in `KiCad/Reference Files/`. Carrier video impedance = **75 Ω** throughout. Op-amp buffers (LMH6643) single **+5 V**, AC-coupled at the BNC.

> Ratify per row (or edit values), and the agent wires it. Anything left ❓ stays flagged in the schematic until you call it.

---

## 1. Sheet 5 — Analog video IN (ADV7280, J500 CVBS + J501–503 component)

Each BNC input → **fixed 75 Ω term** (end-of-line) → AC-couple → anti-alias → IC-side clamp → ADV7280 AINx. Front bidirectional low-cap TVS at the BNC = primary ESD. *(Wired 2026-06-13e.)*

| Block | Proposed | Flag |
|---|---|---|
| 75 Ω termination | **Fixed** 75 Ω 1% to GND at each BNC (analog video inputs are end-of-line — no loop-through). **U501 TS5A23159 term-switch dropped** (2026-06-13e). The switchable-term I²C GPIO expander (§7-3) now serves only the loop-capable input — REF (Sheet 8); SDI is internally terminated by the GS3470, so it needs no external switch either. | ✅ fixed term (§7-3 sanctions fixed for end-of-line inputs) |
| Input clamp | **2-rail** BAV99 (D5xx): signal at the series midpoint, **cathode → ADV7280 AVDD (1.8 V, `AVDD_DEC`)**, anode → GND. Clamp to **AVDD, not +3V3** — the AINx pins are AVDD-referenced, so a +3V3 clamp wouldn't protect them. Front bidirectional low-cap TVS is the primary connector ESD; this is the IC-side backstop. *(Or omit the IC-side BAV99 and lean on the TVS + ADV7280 internal ESD — also defensible.)* **NOTE 2026-06-13e:** agent wired it GND-side-only — fix to 2-rail-to-AVDD (or drop). | 🔧 confirm AINx abs-max vs the AVDD clamp |
| AC-couple | series **0.1 µF** + ADV7280 internal bias (ADV7280 AC-couples on-chip; ref design uses 0.1 µF series + 0.1 µF to GND) | 🧮 confirm vs ADV7280 ref design |
| Anti-alias LPF | 1st-order RC, fc ≈ 9–10 MHz (SD): series **75 Ω** + shunt **220 pF** (≈9.6 MHz) | 🔧 bench-tune corner |
| ADV7280 supplies | DVDDIO→+3V3, **DVDD→`+1V8_D`** (digital, re-homed 2026-06-13e — was +1V8_A), AVDD/PVDD→`AVDD_DEC` (U308, 1.8 V analog); 28.636 MHz xtal **Y500**; 0.1 µF/pin decoupling | ✅ |
| I²C | SDATA/SCLK → `I2C_VID`; ALSB strap → addr 0x20 (GND) | ✅ |

Refdes: R5xx (term 75 Ω ×4, anti-alias 75 Ω ×4), C5xx (AC-couple 0.1 µF, anti-alias 220 pF, decoupling), D500–D503 (front bidirectional TVS + IC-side BAV99 ×4), **Y500** (28.636 MHz xtal). **TVS-vs-BAV99 split RESOLVED (§7-4):** front low-cap bidirectional TVS (primary ESD) + IC-side BAV99 2-rail clamp. U501 dropped (fixed term).

---

## 2. Sheet 6 — Analog video OUT (ADV7393 + LMH6643, J600 CVBS + J601–603 component)

Per ADI ADV7393 ref design (NOT the opamp-stage.md R-2R divider). Triple current-output DAC → buffer → 75 Ω back-term → BNC.

| Block | Proposed | Flag |
|---|---|---|
| DAC load | ADV7393 DAC1/2/3 → **300 Ω to GND** (low-drive RL). Datasheet-confirmed pairing with RSET = 4.12 kΩ → ~4.3 mA × 300 Ω ≈ 1.3 V full-scale (≈ 1.0 Vpp active video) at the **buffer input**. **NOT 37.5 Ω** — that's the *full-drive* RL (pairs with RSET = 510 Ω) for direct doubly-terminated line drive with **no** buffer. | ✅ datasheet Rev. K Table 4 (corrected 2026-06-13e — was 37.5 Ω, ~8× low) |
| RSET | **RSET → 4.12 kΩ to GND = low-drive mode** (~4.3 mA FS). Correct for the buffered chain (DAC → 300 Ω → ×2 buffer → 75 Ω back-term → line). Set the ADV7393 **drive-mode register (subaddr 0x0D) to low-drive** to match the hardware (note: the chip's low-power auto-shutdown isn't available in low-drive — fine for a mains box). VOC compliance = 1.4 V; 1.3 V FS is within. | ✅ datasheet |
| Buffer | LMH6643 (U601 ch A/B, U602 ch A) — non-inverting ×2 or unity per level plan; +5 V single, AC-coupled | ❓ gain (×2 doubly-term vs unity) — your call |
| Back-term | **75 Ω series** at each buffer output → BNC | ✅ |
| AC-couple at BNC | **220 µF** (or DC-couple w/ bias) — SD video LF response needs large cap | 🔧 cap vs DC-couple decision ❓ |
| ADV7393 supplies | VDD_IO→+3V3, VDD/PVDD→+1V8_A, VAA→+3V3_A; CLKIN from clock-gen | ✅ |
| Composite tap → RF | CVBS buffer output also feeds the u.FL (J1200, Sheet 12) per refdes-map | ✅ |

> CVBS buffer output is shared to the RF daughter-board u.FL (Sheet 12) — single buffer drives both BNC + u.FL tap (confirm fan-out/level).

---

## 3. Sheet 8 — Genlock REF front-end (LTC6912 PGA + AD9204) — *structurally wired §11; values here*

| Block | Proposed | Flag |
|---|---|---|
| 75 Ω term | R800 = 75 Ω, switchable via U802 TS5A23159 (one SPDT section) on the term-resistor **ground leg**, IN1 driven by the PCA9555 expander. **U802 pinout — confirm vs TI datasheet (symbol pins unnamed):** wire **one switch** — IN1 (control), COM1, NO1, NC1 (TI numbering: IN1=1, NC1=2, COM1=3, NO1=4, GND=5; switch 2 = NO2/COM2/NC2/IN2 = 6–9, V+=10). **Do NOT mix switches** — the wired COM=2 / NO=9 / IN=1 is wrong: pin 9 = IN2 (the *other* switch's control), not a signal pin. | 🔧 name symbol pins from datasheet before lock |
| Clamp | D800 **BAV99S 2-rail** at the PGA input: cathode → +5V (PGA supply), anode → GND (PGA input is +5V-referenced) + <3 pF TVS at both REF BNCs (primary ESD) | ✅ (wired 2026-06-13e) |
| AC-couple | C800 = **0.1 µF** into PGA INA | 🔧 |
| Anti-alias LPF | before ADC: fc ≈ 8 MHz (AD9204 @ 20 MSPS, genlock BW ≪) — series R + shunt C | 🔧 |
| PGA→ADC | LTC6912 OUT_A → AD9204 VIN+A; VIN-A → VCM; **confirm PGA output swing fits AD9204 FS (2 Vpp) after AC-couple** | 🧮 ❓ |
| ADC ref | VREF bypass 470 nF X5R (set §13), SENSE→GND internal ref, RBIAS per datasheet | 🧮 |

---

## 4. Sheet 9 — SYNC OUT (AD9742 12-bit DAC → LMH6643 → BNC J900/J901)

| Block | Wired 2026-06-13e (verified) | Flag |
|---|---|---|
| FS_ADJ | **R900 = 3.83 kΩ** (E96) on FS_ADJ → IOUTFS ≈ 10 mA. Datasheet-verified: IOUTFS = 32 × IREF, IREF = VREFIO/RSET, VREFIO = 1.2 V (internal bandgap) → 32 × 1.2 / 3830 ≈ 10.0 mA; range 2–20 mA, 10 mA mid-range (headroom). | ✅ datasheet (Rev. C) |
| DAC I-V | **IOUTA → 100 Ω to GND** → 1.0 V swing (10 mA × 100 Ω); IOUTB → matched 100 Ω (balance). Single-ended IOUTA into the buffer (sync gen is baseband — no diff-amp needed). Within AD9742 output compliance (≈ −1.0 to +1.25 V). | ✅ single-ended endorsed |
| Buffer | LMH6643 ×2 (Rf=Rg=1k): 1.0 V → 2.0 Vpp → 75 Ω back-term + 75 Ω line ÷2 → **1.0 Vpp black-burst at the load**. Tri-level ±300 mV = 600 mVpp = 60% FS via codes. | ✅ |
| SYNC2 (LTC) | 1-bit FPGA biphase (B33, 1.8 V) → slew RC → LMH6643 ch B → 75 Ω → 220 µF → J901. **Slew RC CORRECTED:** target **~40 µs** edge per **SMPTE 12M** (spec ≈ 25–50 µs), not 2.2 µs — the wired R906=1k + C902=1nF (τ≈1µs, ~2.2µs edge) is ~20× too fast. Bump to **τ≈18µs** (e.g., 1k + ~18nF) for a compliant ~40µs 10–90% edge; buffer gain to ~1 Vpp LTC. | 🔧 bench-tune ~40 µs (was 2.2 µs) |
| AC-couple | 220 µF at BNC (per §7-1) | ✅ |

---

## 5. Sheet 4 — HDMI (J400 IN / J401 OUT, TPD12S016 + LT8619C / ADV7511)

| Block | Proposed | Flag |
|---|---|---|
| TMDS RX term | LT8619C **internal 50 Ω to VTERM** (VTERM = 3.3 V) — no external term | ✅ datasheet |
| TMDS TX | ADV7511 drives TMDS directly to J401; series 0 Ω/AC-couple per ADV7511 ref | 🧮 |
| ESD | TPD12S016 on TMDS + DDC + HPD (U400/U401) — pass-through, no values | ✅ |
| HDMI +5V | **CORRECTED 2026-06-13e — was backwards.** HDMI convention: the **source** drives +5V (pin 18), the **sink** receives it. So **OUT (J401, we're the source): carrier sources +5V to the downstream sink via TPD `5V_OUT`** (U401.5V_OUT → J401 pin 18). **IN (J400, we're the sink): +5V is an INPUT from the upstream source** — sense it for cable-detect into the LT8619C; do **not** drive it. **TPD12S016 is a source-side companion** (its 5V_OUT *sources* 5V) — correct on the OUTPUT (U401), **wrong on the INPUT** (U400 would back-drive the source's own 5V). The input needs a sink-side approach: a low-cap HDMI ESD array + LT8619C-native DDC/HPD/EDID referenced to the source's 5V (or a sink companion, e.g. TPD12S521-class). **Check the LT8619C input reference design.** | ⚠ Sheet 4 input-protection part needs rework |
| I²C | DDC (LT8619C DSDA/DSCL, ADV7511 DDCSDA/SCL) → HDMI connector DDC pins; config (CSDA/CSCL, SDA/SCL) → `I2C_VID`. **Pull-ups: 2.2 kΩ to +3V3** on each I²C/DDC | ✅ / 🔧 pull value |
| HPD | LT8619C RX_HPD, ADV7511 HPD → via TPD level-shift | ✅ |

---

## 6. Sheet 7 — SDI (GS3470 RX / GS2962 TX, J700/702 IN+loop, J701/703 OUT+mirror)

> **PARALLEL-WIDTH FLAG — RESOLVED 2026-06-13e (datasheet-confirmed):** the GS2962 (and GS2972 sister) **support 10-bit DDR @ 148.5 MHz for 3G** — datasheet: *“in 3G 10-bit mode the device operates in DDR mode… data sampled on both rising and falling edges of PCLK… reduces the I/O speed requirements of downstream devices.”* So strap **20BIT/10BIT = 10-bit (LOW)** and our **B34 11-pin/chip allocation HOLDS — no rework** (B34=1.8 V, AD9742→B35, pin budget all stand). Data Stream 2 on PCLK rising edge, Stream 1 on falling; H/V/F pulses optional (chip can insert TRS), so 10 data + PCLK = 11 pins suffices. FPGA: ODDR on the GS2962 TX bus, IDDR on the GS3470 RX bus (confirm GS3470 RX mirrors 10-bit DDR — same family, near-certain). The Fig 5-1 reference drew the 20-bit option; we use 10-bit DDR.

| Block | Proposed | Flag |
|---|---|---|
| SDI RX in | J700 → **AC-couple 4.7 µF** → GS3470 (internal adaptive EQ + 75 Ω term) | ✅ (4.7 µF standard SDI couple) |
| SDI ESD | **3G-SDI is in spec** → use **<0.3 pF** SDI ESD (e.g. 0.2–0.3 pF) on **all SDI BNCs** (GS3470 inputs + TX outputs J701/J703) — swap off the 0.5 pF TPD1E05U06 for return-loss margin at 2.97 Gbps. | 🔧 select <0.3 pF 3G part |
| SDI loop (J702) — U702 LMH0302 | **DECIDED (Justin): loop-out + cable driver.** GS3470 DDO (differential) → U702 **SDI/SDI̅** (100 Ω diff, self-biased → AC-couple OK) → **SDO** → 4.7 µF AC-couple → **J702** (SDO̅ terminated into 75 Ω). **LMH0302-specific wiring (≠ GS2962 — verify pinout vs TI datasheet, 16-WQFN, exposed pad→GND):** **RREF = 750 Ω to VCC** (the *only* allowed value; close to pin, clear copper below — NOT the GS2962's 75 Ω/CD_VDD); **SD/HD = LOW** for 3G (ST 424/292 slew — HIGH = 259M/SD, wrong for 3G; recheck the "~SD from +3V3" wiring); **ENABLE = HIGH** to enable (or GPIO); VCC = +3V3_SDIDRV. Use the LMH0302's own output network (RREF + AC-couple per SD302 eval), not the GS2962 5.6/75/10 nF net. No FPGA-pin impact. | 🔧 RREF 750→VCC, SD/HD=LOW(3G), ENABLE=HIGH; verify pinout |
| SDI TX out (J701 + J703) | GS2962 drives **two BNCs** per Fig 5-1: **SDO (C10) → J701**, **SDŌ (~D10) → J703**, identical per leg. **Return-loss network (corrected topology, Justin from datasheet):** output node → **5.6 nH ∥ 75 Ω** (inductor *parallel* resistor — note **nH, not Ω**) → **4.6 µF** AC-couple (≈ 4.7 µF std) → BNC; **and** output node → **75 Ω → CD_VDD** with **10 nF** CD_VDD→GND_A bypass. Both legs share a **common CD_VDD**; **BNC shells → GND_A**. SDI polarity-insensitive (NRZI+scrambling) → SDŌ is a valid mirror; no fanout driver. Both BNC traces 75 Ω controlled-impedance, 3G-rated. | ✅ datasheet topology |
| Cable driver supply | GS2962 CD_VDD → `+3V3_SDIDRV` (FB303 branch, set §2.8) | ✅ |
| 27 MHz ref | **RESOLVED (GS3470 datasheet):** 27 MHz **crystal** on XTAL/XTAL pins — spec **≤±100 ppm** freq variation, **≤50 Ω ESR**. Y700 = 9 pF-CL + 8 pF loads (self-consistent w/ ~5 pF stray) ✅. Crystal is used only for **frequency acquisition — no impact on output jitter once locked to incoming data**, so a standard crystal is fine (no low-jitter premium). Alt: 27 MHz external clock into XTAL, **DC-coupled, ≤1.2 V**. Only the GS3470 RX needs it; GS2962 TX is FPGA-parallel-clocked. | ✅ ±100 ppm / ≤50 Ω ESR |
| Supplies | **GS2962 (per Fig 5-1):** CORE→+1V2; **analog rails ferrite-bead-isolated** — **+1V2_A** (ferrite off +1V2) + **+3V3_A** (ferrite off +3V3), each 10 nF+1 µF+1 µF decoupled to a separate **GND_A** analog ground, placed close to the chip; **IO_VDD→+1V8** (B34); **CD_VDD→`+3V3_SDIDRV`**. Use **ferrite isolation + GND_A partition** (not the earlier 10 Ω RC). **GS3470 (datasheet Rev. 9):** CORE→+1V2 digital; **analog = 1.2 V + 1.8 V** (both); **I/O = 1.8 V** (selectable 1.8/2.5, *not* 1.2 — confirms B34 = 1.8 V). **DDI/DDO rails (datasheet-confirmed):** DDI (equalizer) → filtered **+1V2_A** (eq output stage = 1.2 V); **DDO_VDD (serial-output 50 Ω buffer) → 1.2 V *or* 1.8 V analog**, so the agent's filtered +1V8 (FB700) is **valid**. | ✅ DDI→+1V2_A, DDO 1.2/1.8 OK; add +1V2_A/+3V3_A + GND_A |

---

## 7. RATIFIED 2026-06-13e (Justin) — wire to these

1. **AC-couple** the analog/sync outputs (sheets 6 + 9). 220 µF series at the BNC; CRT/PVM clamp restores DC (consistent with `opamp-stage.md` intent). 470 µF acceptable for extra APL margin. Not DC-couple — that's the deferred DC-accurate variant only.
2. **×2 gain, doubly-terminated** (buffer 2.0 Vpp source → 75 Ω back-term + 75 Ω load → 1.0 Vpp). Set the ADV7393/AD9742 full-scale so the **load** lands standard levels (1.0 Vpp composite / 700 mV component). Re-check the "1.4 Vpp" 🧮 against the ADV7393 datasheet under this gain.
3. **Per-input switchable term, driven from an I²C GPIO expander on `I2C_HK`** (not dedicated MCU pins — kills the pin-count concern). The loop-through inputs (REF, SDI) *require* it; composite/component inputs may be fixed 75 Ω (end-of-line) if you'd rather save switches. Switch sits on the term-resistor **ground leg** → SI-clean (not in the signal path).
4. **Low-cap (<3 pF) video TVS at every external panel BNC + BAV99 as the IC-side rail clamp.** **SDI is the exception** — GS3470 inputs need an **ultra-low-cap (<0.5 pF) SDI ESD** device, **not** BAV99 (1.5 pF is too much at 3G). No standard high-cap TVS on any video line.
5. **SDI rails (datasheet-confirmed):** **GS2962** (TX) — 1.2 V core, **PLL/VCO = 1.2 V analog (RC-filtered)**, **sensitive AVDD = 3.3 V analog**, I/O = 1.8 V (per the B34 re-strap), cable driver on `+3V3_SDIDRV`. **GS3470** (RX) — 1.2 V core, **1.2 V + 1.8 V analog (RC/ferrite-filtered)**, I/O = 1.8 V, **needs an external 27 MHz reference clock** (feed from clock-gen). Derive the analog sub-rails off `+1V2` / `+1V8` via dedicated RC/ferrite filters (like the ADC POLs).

**B34 follow-on (Option A, ratified same day):** B34 → 1.8 V LVCMOS18 for GS3470 + GS2962 (both 1.8 V I/O); **AD9742 SYNC-1 DAC relocated B34 → B35** (3.3 V; the AD9742 is a 2.7–3.6 V part). Folded into `sheet3-te0720-som-backbone.md`, `pin-budget.md`, `power-tree-design.md`, `refdes-map.md`, changelog.

> Wiring notes for the agent: (a) the digital-1.8 V pins (ADV7280 DVDD, ADV7393 VDD, LT8619C VDD18) belong on **`+1V8_D`** (digital), not the precision analog `+1V8_A` — re-home in the power-budget pass. (b) New parts to add at wiring: per-input I²C GPIO expander (TERM_EN) on `I2C_HK`; low-cap video TVS at the BNCs; ultra-low-cap SDI ESD at the GS3470 inputs; BAV99 IC-side clamps. Reconcile these into `bom-v1.md` as they're placed.
