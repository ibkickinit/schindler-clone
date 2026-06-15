# Schindler 2.0 — KiCad Symbol Sourcing Checklist

**Generated:** 2026-06-12 · **Against:** [`part-lock-2026-06-12.md`](part-lock-2026-06-12.md) / [`bom-v1.md`](bom-v1.md) · **Refdes:** [`refdes-map.md`](refdes-map.md)

**Purpose:** before any symbol-placement pass (Claude Code or hand), every part needs a KiCad **schematic symbol**. This sorts all locked parts into three tiers so the **ADD** list is your shopping list of symbols to import/build first.

## Tiers

- ✅ **STOCK** — in KiCad's standard symbol libraries (KiCad 9/10). Use as-is. Symbol name given is the expected `Library:Symbol`.
- 🔎 **VERIFY** — almost certainly in stock libs; confirm with one lookup in the Symbol Chooser. If absent, grab from SnapEDA.
- ⛔ **ADD** — not in stock. Download (SnapEDA / Ultra Librarian / SamacSys) or build from datasheet / vendor files. **These are the gaps.**

> Best symbol sources for the ADD list, in order: **vendor KiCad files** (Trenz, BridgeTek, Newhaven) → **SnapEDA** → **Ultra Librarian / SamacSys (ComponentSearchEngine)** → hand-build. ADI/TI/Semtech parts are nearly all on SnapEDA.

---

## ✓ Already in JustinLibrary (checked 2026-06-12)

`_PROJECTS/_KiCad/JustinLibrary.kicad_sym` already contains custom symbols for these — **no action needed** (Justin built them). Reconciled against the live file (17 at first check; **+4 added since** — LMH6643, TPS26600, LTC2954-1, ADL5391):

| In library as | Covers (refdes) |
|---|---|
| `AD9204BCPZ-20` | genlock ADC (U801) |
| `ADV7280AWBCPZ-M` | analog decoder (U500) |
| `ADV7393BCPZ` | analog enc/DAC (U600) |
| `ADV7511KSTZ` | HDMI TX (U403) |
| `ERA-3SM_` | RF MMIC amp (RF U3) |
| `GS2962-IBE3` | SDI TX (U701) |
| `GS3470-IBE3` | SDI RX (U700) |
| `INA226` | power monitor (U301) |
| `LT8619C` | HDMI RX (U402) |
| `LTC6912CGN-2#PBF` | genlock PGA (U800) |
| `RP2040` | both RP2040s (U900, mezz U1) — custom; stock also exists |
| `SI5351A-B-GT` | both Si5351s (U902, RF U2) — “GTR” is tape/reel of same die |
| `Sterling LWB5+` | WiFi/BT module (U1000) |
| `TE0720-03-61C33FAS` | Zynq SoM (J200–J202) — ⚠ **variant flag**, see below |
| `TLC59116FIPWR` | LED drivers (U1100–U1102) |
| `TPD12S016PWR` | HDMI ESD/level ×2 (U400/U401) |
| `LMH6643` *(added)* | video buffers ×3 (U601/U602/U904) — not in KiCad stock |
| `TPS26600` *(added)* | protection eFuse (U300) |
| `LTC2954-1` *(added)* | soft-power ctrl (U302) |
| `ADL5391` *(added)* | RF AM modulator (RF U1) |
| `DMP3098L-7` | ⚠ **legacy/unused** — the old reverse-polarity FET, superseded by the TPS26600 eFuse. Ignore; don't place. |

**⚠ TE0720 variant flag:** the library symbol is `TE0720-03-61C33FAS` (a **-03** module); production target is **-04-62I33MA**. Spec §1.1 calls the carrier pinout identical across TE0720 variants, so the symbol is reusable — but **confirm the -03 vs -04 Razor-Beam pin map matches before relying on it**, and consider renaming the symbol to a variant-agnostic `TE0720` to avoid confusion.

This collapses the original 20-item ADD list to the short set below.

---

## Pull-sheet corrections caught here

- **ADV7511KSTZ** (HDMI TX, `U403`) was missing from the part-lock active-silicon table — it's in the BOM §3.2 and refdes-map sheet 4. Added below.
- **Crystals**: 2× 25 MHz (Si5351 genlock + RF) and 2× 12 MHz (RP2040 genlock + mezz) aren't called out as line items. Stock symbol, but they need placing — added below.

---

## Generic / passive / connector (mostly STOCK)

| Part (refdes) | KiCad symbol | Tier |
|---|---|---|
| Resistors / caps / inductors | `Device:R` / `Device:C` / `Device:L` | ✅ |
| Ferrite bead (FB, BLM21) | `Device:Ferrite_Bead` | ✅ |
| Crystal 25 MHz / 12 MHz (Y9xx, Y1) | `Device:Crystal_GND24` (or `Crystal`) | ✅ |
| Trim pot (Bourns 3224W, RV1/RV2) | `Device:R_Potentiometer_Trim` | ✅ |
| BAV99 clamp (D5xx/D7xx/D8xx) | `Diode:BAV99` | ✅ |
| Input TVS / PESD3V3L1BA (D1, ESD) | `Device:D_TVS` | ✅ |
| Fuse (F300) | `Device:Fuse` | ✅ |
| Fan (Noctua, PWM 4-pin) | `Device:Fan` | ✅ |
| Status LED bi-color CA (L-3VEGW-CA, D11xx) | `Device:LED_Dual_ACA` (common-anode dual) | 🔎 confirm CA pin order |
| BNC 75 Ω (Molex 73101-0120, J*) | `Connector_Coaxial:BNC` | ✅ |
| SMA / RP-SMA (Linx CONREVSMA001, J100x) | `Connector_Coaxial:SMA` | ✅ |
| u.FL (RF board J1, carrier J1200) | `Connector_Coaxial:U.FL` | ✅ |
| HDMI Type A (Amphenol 10029449, J400/J401) | `Connector:HDMI_A` | ✅ |
| USB-C 2.0 (GCT USB4085, J1001) | `Connector:USB_C_Receptacle_USB2.0` | ✅ |
| RJ45 magjack (Pulse JXD1-0001NL, J1000) | `Connector:RJ45` + magnetics | 🔎 generic stock; magjack-with-magnetics pinout may need the specific symbol |
| Mini-Fit Jr 2-ckt (Molex 0039291028, J301) | `Connector:Conn_01x02` / `Connector_Molex` | ✅ |
| Pin headers (6-pin RF, expansion, JTAG, UART) | `Connector_Generic:Conn_*` | ✅ |
| Antenna (Linx ANT-DB1) | `Device:Antenna` | ✅ |
| F-connector (Amphenol 82-4421, RF J3) | `Connector_Coaxial:F_*` | 🔎 |
| Rotary encoder (Alps EC11, SW1/SW2) | `Device:Rotary_Encoder_Switch` | ✅ |
| Tactile (C&K PTS645, SW3–SW9) | `Switch:SW_Push` | ✅ |
| Power button illum. (E-Switch PV6, SW10) | `Switch:SW_Push_LED` | ✅ |
| FFC for NHD displays (J1101, mezz J2) | `Connector:Conn_01xNN` (per panel pinout) | 🔎 |

---

## ICs — STOCK / VERIFY / in-library

*(✓lib = in JustinLibrary; ✅ = confirmed in KiCad stock. **Update 2026-06-12: this table is fully resolved.** Every 🔎 was checked — stock libs cover them; LMH6643 was the one exception, not in stock, now added to JustinLibrary.)*

| Part (refdes) | KiCad symbol | Status |
|---|---|---|
| RP2040 ×2 (U900, mezz U1) | `JustinLibrary:RP2040` (or stock `MCU_RaspberryPi:RP2040`) | ✓lib |
| INA226 (U301) | `JustinLibrary:INA226` | ✓lib |
| TLC59116F ×3 (U1100–U1102) | `JustinLibrary:TLC59116FIPWR` | ✓lib |
| Si5351A-B-GTR ×2 (U902, RF U2) | `JustinLibrary:SI5351A-B-GT` | ✓lib |
| TPD12S016PWR ×2 (U400/U401) | `JustinLibrary:TPD12S016PWR` | ✓lib |
| LMH6643 ×3 (U601/U602/U904) | `JustinLibrary:LMH6643` *(added — not in stock)* | ✓lib |
| W25Q128JVSIQ ×2 (U901, mezz U2) | `Memory_Flash:W25Q128JVSxIQ` | ✅ |
| TS5A23159 (U501/U802) | `Analog_Switch:TS5A23159` | ✅ |
| LMR33640 ×2 (U303/U304) | `Regulator_Switching` family | ✅ |
| TLV62568 (U305) | `Regulator_Switching:TLV62568` | ✅ |
| TPS7A2018 (U306) | `Regulator_Linear:TPS7A20*` | ✅ |
| ADP7142 ×3 (U307–U309) | `Regulator_Linear:ADP7142` | ✅ |
| TPS61040 (mezz U4) | `Regulator_Switching:TPS61040` | ✅ |
| TPD4S014 (U1001) | `Power_Protection:TPD4S014` | ✅ |

---

## ICs — ⛔ ADD — CLEARED

**Update 2026-06-12 (final): zero symbol gaps.** Every part has a symbol — stock, in JustinLibrary, or built into `Schindler.kicad_sym`.

**Built by Claude → `_PROJECTS/_KiCad/Schindler.kicad_sym`** (validated: parses clean, pin counts correct):
- `NHD-2.9-376960AF-ASXP` — 40-pin 0.5 mm FFC, full pinout (R0–R7/G0–G7/B0–B7, PCLK/HS/VS/DE, RESETX, CSX/DCX/SCL/SDA, LED-A/K, VDD/GND). Ref `J`.
- `NHD-1.5-240240AF-CSXP` — 28-pin 0.5 mm FFC, full pinout (IM0-2, RESX/CSX/DCX/WRX/RDX/SDA/SDO/TE, DB0–DB7, LED_A/K, VDD/GND). Ref `J`. Driver = ST7789VI; 4-wire SPI for our use (IM0=0/IM1=1/IM2=1).
- `FN9260B-6-06` — 6-terminal power-entry block (L/N/PE in → L'/N'/PE' out). Ref `J`. *(B = medical, no Y-caps.)*
- `NFM21_Feedthrough` — generic 3-terminal feedthrough (IN/OUT/GND). Ref `FC`. Value per instance: `NFM21PC104R1E3D` (0.1 µF DC) / `NFM21CC102R1H3D` (1 nF I²C).

**Resolved earlier this pass (by Justin):**
- **AD9742 (U903)** → found + added. *(Note: AD9742/AD9744 are pin-compatible 12/14-bit TxDACs — if the symbol Justin added is the AD9744, it's electrically fine; just confirm the value field reads the part actually being ordered.)*
- **BridgeTek BT817Q** (mezz U3, QFN-64) → found + added.
- **TPS26600, LTC2954-1, ADL5391** → added to JustinLibrary.

Already in JustinLibrary (no action): TE0720, LT8619C, ADV7280/7393/7511, GS3470/GS2962, LTC6912, AD9204, ERA-3SM, LWB5+, INA226, Si5351, TLC59116, TPD12S016, RP2040, LMH6643, TPS26600, LTC2954-1, ADL5391, **AD9742, BT817Q**.

**Not a symbol (mechanical / no schematic part):**
- Masach **MS643** shield can → footprint/mechanical only.
- Mean Well **LRS-50-12** → off-board; represented by the Mini-Fit input connector `J301` + power flags, no IC symbol.
- Trenz **33337** heatsink, gap pad, chassis, FPE panels, standoffs → mechanical.

---

## Footprint note (separate pass)

Symbols are done; **footprints** are the next pass. Assignments for the four built symbols:

| Symbol | Footprint to assign | Source |
|---|---|---|
| `NHD-2.9-376960AF-ASXP` | **Molex 54104-4031** — 40-ckt, 0.5 mm, **top-contact** FFC/FPC connector (this is what solders to the board; the panel flex plugs into it) | KiCad `Connector_FFC-FPC` (Molex 54104) if present, else SnapEDA |
| `NHD-1.5-240240AF-CSXP` | **Molex 5051102891** — 28-ckt, 0.5 mm FFC/FPC connector | KiCad `Connector_FFC-FPC` (Molex 505110) if present, else SnapEDA |
| `FN9260B-6-06` | **No PCB footprint** — chassis/panel-mount IEC inlet with 6.3×0.8 mm fast-on spade tabs. Wired, not soldered. Mark **exclude-from-board** (same treatment as the LRS-50 PSU). | n/a |
| `NFM21_Feedthrough` | Murata **NFM21 3-terminal feedthrough** land (2012/0805 body, signal IN/OUT + ground castellations) — **not** a 2-pad 0805 | Murata land pattern / SnapEDA |

**FFC note:** the symbol pin numbers map 1:1 to the FFC connector pads. Top- vs bottom-contact determines which way the panel flex folds — confirm the Molex contact side matches the mechanical layout before ordering.

Still-custom footprints elsewhere (separate from symbols): TE0720 Razor Beam land (Samtec LSHM), Molex 73101-0120 BNC, Amphenol 10029449 HDMI, Masach MS643 can outline, LWB5+ castellated module. Stock footprints cover generic passives, headers, SOT/SOIC/QFN ICs, USB-C, SMA/u.FL.

---

## Suggested order of operations

1. **All symbols resolved.** Custom builds live in `_PROJECTS/_KiCad/Schindler.kicad_sym` (4 symbols); the rest are in JustinLibrary or stock.
2. **Confirm the 🔎 VERIFY list** in the Symbol Chooser (fast); SnapEDA-fill any misses. **Point the project lib-table at JustinLibrary** so the ✓lib parts resolve.
3. **Confirm the ⚠ TE0720 -03 vs -04 pinout** before trusting the existing symbol on the live carrier.
4. ✅ STOCK parts need nothing.
5. Only then run a placement pass — every symbol must resolve to a library entry or KiCad drops it.

Once the ADD list is filled, capture (or any scripted placement) has a complete symbol set to resolve against.
