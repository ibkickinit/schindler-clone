# Schindler 2.0 — TE0720 PL I/O Pin Budget & I²C Bus Architecture

**Status:** Draft 2026-05-20
**Purpose:** Quantify carrier PL I/O demand against the TE0720's supply, define the I²C bus segmentation, and serve as the input artifact for the next analysis — bank-by-bank voltage allocation. Decision narrative lives in [`01-spec-changelog.md`](01-spec-changelog.md) (2026-05-20 entry). Architecture SSOT is [`01-spec.md`](01-spec.md).

**Scope:** Pro v2 stuffing (worst case). Mini v1 drops the rows marked **[Pro]** (SDI, dual SYNC OUT driver chain, RF mode-mux, per-connector LED drivers, rear LCD), freeing ≈ 30+ PL pins.

> **This budget is pre-allocation.** Pin *count* closes (≈ 129–138 of 152). Whether the buses *fit* the four user banks at compatible Vcco voltages is **not yet proven** — that is the next analysis and it requires the Trenz Pinout/Tracelength table. A pin count that closes but does not bank-pack is still a board that fails. Do not treat "count closes" as "schematic-safe."

---

## 1. Chip-role map (freeze this — recurring naming confusion)

The six near-identically-named video chips, fixed to their roles. (ADV7393 is the SD video **encoder** — *not* SDI. SDI is the Semtech GS-parts.)

| Role | Chip | SKU |
|---|---|---|
| HDMI in | Lontium **LT8619C** | All |
| Analog in (CVBS / YPbPr / S-Video) | ADI **ADV7280** | All |
| Analog out (CVBS / S-Video / component) | ADI **ADV7393** | All |
| HDMI out | ADI **ADV7511** | All |
| SDI in | Semtech **GS3470** | **[Pro]** |
| SDI out | Semtech **GS2962** | **[Pro]** |
| Genlock / LTC reference digitizer | ADI **AD9204** (+ LTC6912 PGA) | All |

---

## 2. PL I/O supply (Z-7020 on TE0720)

Confirmed against the Trenz TE0720 I/O assignment table. 152 single-ended user PL I/O across four banks, each with one user-supplied Vcco:

| Bank | Single-ended I/O | LVDS pairs | Vcco range |
|---|---:|---:|---|
| B13 | 50 | 24 | 1.2–3.3 V (user adj.) |
| B33 | 18 | 9 | 1.2–3.3 V (user adj.) |
| B34 | 36 | 18 | 1.5–3.3 V (user adj.) |
| B35 | 48 | 24 | 1.2–3.3 V (user adj.) |
| **Total** | **152** | | per-bank single Vcco |

Notes:
- GbE (GEM0) runs on dedicated **MIO16–27 at 1.8 V HSTL on-module** — does **not** consume PL I/O.
- DDR3L is entirely on-module (1.35 V) — no carrier impact.
- **B34 portability caveat:** on transceiver-equipped TE07xx modules, some B34 pins are dedicated GT pins. Irrelevant for the -62I (no transceivers), but avoid them if the carrier is ever to host a GT-equipped SOM (e.g. a Z-7030 LED-Processor migration). See 2026-05-15 changelog (second-GbE / LED Processor open question).

---

## 3. Pin demand by class (Pro stuffing)

### 3.1 Video parallel buses (~96 pins — the bulk)

| Bus | Pins | Carries | Constant use? |
|---|---:|---|---|
| LT8619C → PL (HDMI in) | ~28 | 24-bit RGB + HS + VS + DE + PCLK | Only when HDMI is selected source |
| ADV7280 → PL (analog in) | ~10 | 8-bit BT.656 YCbCr 4:2:2 + clock | Only when analog is selected source |
| PL → ADV7511 (HDMI out, **split, dedicated**) | ~28 | Full 24-bit | Whenever HDMI OUT live |
| PL → ADV7393 (analog out, **split, narrowed**) | ~20 | 16-bit muxed YCbCr 4:2:2 | Whenever analog out live |
| GS3470 → PL (SDI in) **[Pro]** | ~20 | 20-bit parallel SDI + clock | Only when SDI is selected source |
| PL → GS2962 (SDI out) **[Pro]** | ~20 | 20-bit parallel SDI + clock | Whenever SDI OUT live |

**Input/output asymmetry:** input buses are mutually exclusive in *use* (source mux picks one) but **not** in *pin cost* — all are routed because selection is runtime. Output buses can all be live simultaneously (the concurrent-output feature), so each is potentially constant.

**HDMI-out bus split (adopted 2026-05-20):** the ADV7511 and ADV7393 previously shared one parallel bus (saving ~16 pins, but forcing "HDMI out tracks analog out"). Split into a dedicated full-width HDMI-out bus + a narrowed 16-bit analog-out bus → **+16 pins**, buys independent cadence on HDMI vs analog. The analog DAC path doesn't need 24 bits, so it gets the narrow bus; HDMI gets full width.

**SDI reduced-width optimization (candidate, not yet adopted):** GS3470/GS2962 support reduced-width interfaces. Running SDI at 10-bit DDR instead of 20-bit halves SDI pin cost (~−10 pins on each of in/out). Largest untapped lever; interrogate at schematic phase.

### 3.2 Control / serial buses (~14–18 pins after consolidation)

| Interface | Pins | Devices | Constant use? |
|---|---:|---|---|
| I²C segment A | 2 | Video config (see § 4) | Bursty — config at mode-change |
| I²C segment B | 2 | Clock + LED (see § 4) | Near-constant (LED refresh, lock-tracking) |
| UART — genlock RP2040 | 2 | Slow-control status/command | Constant |
| UART — mezzanine RP2040 **[Pro]** | 2 | UI state sync | Constant while UI active |
| SPI — rear status LCD **[Pro]** | ~4 | NHD-1.5 (ST7789) | Bursty (~1 s refresh) |
| AD9204 ADC → PL | ~10–12 | Genlock sample stream | **Constant** — loop runs continuously |

The **AD9204 stream** is an easily-overlooked always-on wide parallel bus. Treat it as a first-class video-class bus in bank allocation, not an afterthought.

### 3.3 Discrete GPIO / misc (~14 pins after consolidation)

| Function | Pins | Notes |
|---|---:|---|
| Boot-mode straps | 0 (was ~3) | Tie to rails via resistors, not live GPIO |
| PS_POR + PL reset | 2 | Keep live |
| ADV/LT chip resets | 1 (was ~4) | Share one reset line |
| HDMI HPD / CEC (in + out) | ~4 | Pass through TPD12S016; land on PL GPIO |
| RF mode-mux gates **[Pro]** | ~3 | ADG419 + ERA-3 bias FET + ADV mode |
| Degauss trigger | 1 | GPIO/relay |
| Si5351 reference clock return | 1 | **Constant** — master clock into PL |
| Board status LEDs | 2 | A few direct; rest via TLC59116F |

### 3.4 Roll-up

| | Pins |
|---|---:|
| Video parallel buses | ~96 |
| Control / serial | ~16 |
| Discrete GPIO | ~14 |
| **As-specified Pro demand** | **~138 of 152** |
| with I²C consolidation (−10) | ~128 |
| with HDMI-out split (+16) | ~144 |
| with SDI reduced-width (−10) | ~134 |
| with boot/reset consolidation (−5) | **~129** |

At ~129–138 on Pro, free PL pins = **~14–23**, not the 40 the § 18 expansion-header language implies. Re-scope the header as bus-tap-primary (I²C/SPI taps cost no new pins). Mini stuffing frees ~30+ and the fuller header promise holds there.

---

## 4. I²C address map & two-segment plan

7-bit addresses. ADV chips each consume a **cluster** of map addresses, most reprogrammable at the board level to dodge conflicts.

| Device | Base 7-bit | Extra maps | Strappable / reprog? | Segment |
|---|---|---|---|---|
| ADV7280 (analog in) | 0x20 / 0x21 (ALSB) | + VPP (reprog, rec. 0x42), + CSI on -M | main via ALSB pin | A |
| ADV7393 (analog out) | 0x2A / 0x2B | single | strap | A |
| ADV7511 (HDMI out) | 0x39 / 0x3D (PD/AD strap; 0x72/0x7A 8-bit) | +3 maps (packet/EDID/CEC), reprog | main strap; others software | A |
| LT8619C (HDMI in) | **VERIFY** (NDA datasheet) | DDC maps | likely strappable | A |
| INA226 (power monitor) | 0x40 → **move to 0x41+** | — | 16 via A0/A1 | A |
| Si5351 #1 (genlock) | 0x60 | — | B-variant: factory 0x60 only | B |
| Si5351 #2 (RF) **[Pro]** | **0x61** (A-16QFN, A0→high) | — | A-variant: A0 pin selects 0x60/0x61 | B |
| TLC59116F ×3 **[Pro]** | 0x60 / 0x61 / 0x62 (addr pins) | + all-call 0x68 | 16 via 4 pins | B |

**Segment A (video config):** 0x20–0x41 range, bursty. **Segment B (clock + LED):** 0x60–0x62 range, near-constant. Two segments = 4 PL pins, vs ~12+ for per-device segments, vs the collision risk of one shared bus.

### Live items
- **Si5351 collision (BUG):** spec lists both as `Si5351A-B-GT` → both 0x60. Fix: RF chip → Si5351A 16-QFN, A0 strapped high = 0x61. Genlock chip held as B at 0x60 (see VCXO park). Two-segment plan also resolves it independently.
- **LT8619C address (OPEN):** confirm against register manual before schematic; public brief omits it.
- **INA226:** place off 0x40 to avoid any clash; A0/A1 give 16 options.

---

## 5. Parked / open (carried from 2026-05-20 changelog)

- **Genlock steering method (PARKED):** I²C-register-write-only vs Si5351B analog VCXO. Decide by bench-measuring I²C-only loop residual jitter once the AD9204 genlock chain is up (Phase G). Hold genlock Si5351 = B-variant @ 0x60 until then (asymmetric-risk-safe). If I²C-only proves clean, both chips → A-16QFN (0x60/0x61).
- **Power sequencing (TO WEIGH):** six PL-Vcco-feeding rails need correct power-on order vs the SOM rails — sequencer IC or RC soft-start ordering. Name it as a schematic-phase line item.
- **Rail PGOOD daisy-chain (TO WEIGH):** optional; closes the INA226 input-only blind spot.
- **§ 18 expansion header (TO RE-SCOPE):** bus-tap-primary; PL-pin count stuffing-dependent.

---

## 6. Next step

**Bank-by-bank voltage allocation.** Assign every bus above to B13 / B33 / B34 / B35 at a specific Vcco, grouping by logic level (3.3 V LVCMOS for the ADV/HDMI/level-shift chips vs any 1.8 V consumers) so each bank's single Vcco serves its occupants. Requires the **Trenz TE0720 Pinout/Tracelength table** (pull at the Mac). Output: a per-bank allocation table that converts "count closes" into "schematic-safe."

---

## Cross-references
- Decision narrative: [`01-spec-changelog.md`](01-spec-changelog.md) (2026-05-20)
- Architecture SSOT: [`01-spec.md`](01-spec.md) (§ 1.2 carrier, § 3 subsystems, § 18 expansion header)
- BOM: [`bom-v1.md`](bom-v1.md) (§ 2 Si5351 lines)
- SKU stuffing: [`packaging-skus.md`](packaging-skus.md)
- Signal flow: [`signal-flow.md`](signal-flow.md)
