# Schindler 2.0 — Reference-Designator Map (carrier + sub-boards)

**Generated:** 2026-06-12 · **Source of truth for parts:** [`bom-v1.md`](bom-v1.md) · **Pin/bank source:** [`pin-budget.md`](pin-budget.md) + [`sheet3-te0720-som-backbone.md`](sheet3-te0720-som-backbone.md) §5.

## What this is (and the netlist relationship)

A BOM holds **MPN + function + pooled quantity** ("BNC 73101-0120 ×14"). A netlist holds **instances** — `J400`, `J401`, … each a distinct symbol with its own pin-level nets. This doc is the bridge: it assigns the **reference designator** for every locked part so schematic capture is data-entry, not decision-making.

**Direction of truth:** once you capture, **KiCad owns refdes** — you annotate, assign each symbol its MPN as a field, and KiCad *exports* the BOM with refdes+MPN already attached. Don't hand-maintain refdes in markdown long-term; use this map to seed capture, then **diff KiCad's exported BOM against this file** to catch drift. If they disagree after capture, KiCad wins.

## Three boards = three independent refdes namespaces

Each PCB is its own annotation domain and its own netlist. Don't share refdes across them.

| Assy | Board | Schematic/project | Refdes scope |
|---|---|---|---|
| **A1** | Main carrier | `schindler-carrier` (12-sheet hierarchy) | sheets 1–12 below |
| **A2** | Front mezzanine | `schindler-mezzanine` | own U1/R1/… (see §A2) |
| **A3** | RF daughter board | `schindler-rf` | own U1/R1/… (see §A3) |

The carrier connects to A2 over the mezzanine header (`J1100`) and to A3 over u.FL + 6-pin (`J1200`/`J1201`). Those connectors live on the carrier; everything *past* them is the sub-board's own namespace.

---

## Carrier (A1) — sheet block scheme

12-sheet hierarchy. Use **per-sheet hundreds blocks** so a refdes tells you its sheet at a glance. In KiCad: **Annotate Schematic → Numbering → "Use sheet number × 100"** start value. Sheet N → N00-series. Reserve the whole block per sheet; passives auto-number within it.

| # | Sheet | Block | Bank anchor (pin-budget) |
|---|---|---|---|
| 1 | Root / hierarchy | 100s (mounting, fiducials) | — |
| 2 | TE0720 SoM backbone | 200s | all banks fan out here |
| 3 | Power tree | 300s | — |
| 4 | HDMI in + out | 400s | B35 (in 20) / B13 (out 20) |
| 5 | Analog video in | 500s | B35 (9) |
| 6 | Analog video out | 600s | B13 (20) |
| 7 | SDI in/out *(Pro)* | 700s | B34 (11+11) |
| 8 | Genlock front-end | 800s | B33 (ADC 11 + PGA 3) |
| 9 | Clock + sync gen | 900s | **B35** (AD9742 13) + B33 (SYNC2 1) |
| 10 | Control + networking | 1000s | PS MIO/EMIO (off-PL) |
| 11 | Front-panel + LED | 1100s | PS SPI + I²C (off-PL) |
| 12 | RF interface + debug | 1200s | composite tap off sheet 6 |

---

### Sheet 1 — Root / hierarchy (100s)
Hierarchical sheet symbols only. Mechanical: `MP101–MP108` mounting holes, `FID101–FID103` fiducials, `TP1xx` global test points.

### Sheet 2 — TE0720 SoM backbone (200s)

| Refdes | MPN / part | Net group |
|---|---|---|
| J200, J201 | Samtec LSHM-150-… (2×) | PL banks B35/B13/B34/B33 + PS MIO/DDR carry |
| J202 | Samtec LSHM-130-… | balance of PL + PS |
| HS201 | Trenz 33337 heatsink | mech |
| ~~C200–C239~~ ⚠ | **NOT PRESENT — phantom bank (corrected 2026-06-15).** The decoupling audit found sheet 2 has **zero caps captured** — only J200/J201/J202 + a fiducial + 10 test points. Carrier-side SoM decoupling (bulk on the +5V/+3V3/+1V8_D feeds + distributed 0.1 µF across the connector supply pins) is **PROPOSED, not yet placed** — see [`decoupling-audit.md`](decoupling-audit.md) §Sheet 2 (~12 caps; ⚠ confirm count/bulk values against the **Trenz TE0720 carrier reference design** before placing — the module's main +5V input wants more bulk than generic scaffolding). Block C200+ reserved. | +5V / +3V3 / +1V8_D SoM feeds |
| TP201–TP210 | PL_DONE, PS_BOOT, rail probes | status |

JTAG/boot/reset live on sheet 12 (debug). The 152 PL pins fan from J200–J202 to sheets 4–9 by bank.

> **⚠ Decoupling caveat (2026-06-15):** the per-sheet `Cxxx` decoupling on this map reflected *intent*, not captured reality. The audit (`decoupling-audit.md`) found most signal/sync chips bare or near-bare of local bypass and sheet 2 fully bare. Treat any `Cxxx` decoupling range on this map as **proposed** until reconciled against KiCad's exported BOM post-placement. Sheet 3 regulator caps are the exception — those are real.

### Sheet 3 — Power tree (300s)

| Refdes | MPN | Net group |
|---|---|---|
| J300 | Schaffner FN9260B-6-06 (IEC + filter + fuse holder) | AC mains |
| F300 | Littelfuse 0213002.MXP (2 A T) | mains fuse |
| J301 | Molex 0039291028 (PSU → carrier, 2-ckt) | +12V_RAW / GND |
| U300 | TI TPS26601 (eFuse, latch default — MODE open) | +12V_RAW → +12V_PROT |
| U301 | TI INA226AIDGSR | I²C telemetry |
| R300 | 5 mΩ shunt | INA226 sense |
| U302 | ADI LTC2954-1 | PB → eFuse EN; INT/KILL ↔ PS GPIO |
| U303 | TI LMR33640 (5 V) | +12V_PROT → +5V |
| U304 | TI LMR33640 (3.3 V) | +12V_PROT → +3V3 |
| U305 | TI TLV62568 (1.2 V) | +5V → +1V2 |
| U306 | TI TPS7A2018 (1.8 V analog) | +3V3 → +1V8_A |
| U307–U309 | ADI ADP7142 (POL analog) | per-ADC clean rails |
| U310 | 1.8 V LDO (off +3V3) | `+1V8_D` — VCCIO33 (B33) + AD9204 DRVDD (digital 1.8 V) |
| L300, L301 | buck inductors | 5 V / 3.3 V |
| FB300–FB305 | analog-branch ferrites | +3V3_A, +1V8_A |
| C300–C349 | bulk (3× GRM32 22 µF) + decoupling | rails |
| R301–R330 | eFuse OVP/UVLO/ILIM/dVdt set, FB dividers, LTC2954 ONT/PDT, PB R-C | — |

### Sheet 4 — HDMI in + out (400s)

| Refdes | MPN | Net group |
|---|---|---|
| J400 | Amphenol ICC 10029449-001RLF (HDMI A, IN) | TMDS in |
| J401 | Amphenol ICC 10029449-001RLF (HDMI A, OUT) | TMDS out |
| U400 | TI TPD12S016PWR (in ESD/lvl) | — |
| U401 | TI TPD12S016PWR (out ESD/lvl) | — |
| U402 | Lontium LT8619C (HDMI RX) | → B35, HDMI_IN[15:0]+CLK+SYNC (20) |
| U403 | ADI ADV7511KSTZ (HDMI TX) | ← B13, HDMI_OUT[15:0]+CLK+HS/VS/DE (20) |
| R4xx/C4xx | I²C pulls, TMDS term, decoupling | I²C0 |

### Sheet 5 — Analog video in (500s)

| Refdes | MPN | Net group |
|---|---|---|
| J500 | Molex 73101-0120 (CVBS IN) | — |
| J501–J503 | Molex 73101-0120 ×3 (component IN) | — |
| U500 | ADI ADV7280AWBCPZ-M-RL | → B35, BT.656 8-bit + LLC (9) |
| Y500 | 28.63636 MHz crystal (ADV7280 ref) | added 2026-06-13e — ADV7280 needs it; was missing from the map |
| D500–D503 | <3 pF bidirectional video TVS (connector ESD, primary) + IC-side BAV99 clamp ×4 | see analog-conditioning §1 |
| R5xx/C5xx | 75 Ω **fixed** term ×4, 0.1 µF AC-couple, anti-alias 75 Ω + 220 pF | **U501 TS5A23159 term-switch dropped** (fixed term — inputs are end-of-line) |

### Sheet 6 — Analog video out (600s)

| Refdes | MPN | Net group |
|---|---|---|
| J600 | Molex 73101-0120 (CVBS OUT) | — |
| J601–J603 | Molex 73101-0120 ×3 (component OUT) | — |
| U600 | ADI ADV7393BCPZ-REEL | ← B13, 16-bit comp + CLK + ctrl (20) |
| U601, U602 | TI LMH6643MAX/NOPB ×2 (output buffers) | 3 ch used |
| R6xx | 75 Ω back-term | — |
| C6xx | AC-couple at BNC | — |

> The CVBS buffer output also feeds the RF u.FL tap on sheet 12 (`J1200`).

### Sheet 7 — SDI in/out *(Pro)* (700s)

| Refdes | MPN | Net group |
|---|---|---|
| J700 | Molex 73101-0120 (SDI IN) | — |
| J701 | Molex 73101-0120 (SDI OUT) | — |
| J702 | Molex 73101-0120 (SDI IN LOOP) | reclocked loop-through (GS3470 path) |
| J703 | Molex 73101-0120 (SDI OUT 2) | GS2962 **~SDO (D10)** routed out (SDO→J701, ~SDO→J703; each AC-coupled into own 75 Ω, no fanout) |
| U700 | Semtech GS3470 (RX) | → B34 (**1.8 V I/O**), SDI_IN parallel (11) |
| U701 | Semtech GS2962 (TX) | ← B34 (**1.8 V I/O**), SDI_OUT parallel (11) |
| U702 | LMH0302-class 3G-SDI cable driver (GS3470 loop-out) | GS3470 DDO → driver → return-loss → J702; pwr +3V3_SDIDRV |
| Y700 | 27 MHz **9 pF-CL** crystal (GS3470 ref, XTAL/~XTAL) + 8 pF loads | ⚠ confirm ppm |
| L700/L701 | 2× 5.6 nH RF inductor (GS2962 TX return-loss, **∥ 75 Ω**; SDO/~SDO legs) | ⚠ refdes class R→L (was R721/R724); MPN Murata LQW15AN5N6 / Coilcraft 0402HP-5N6, confirm SRF>3G |
| R7xx/C7xx/D7xx/FB700-702 | 4.7 µF SDI AC-couple; **<0.3 pF SDI ESD** (J700–703); **TX return-loss** (RSET 75→CD_VDD, 5.6 Ω, 75 Ω+10 nF per leg); **+1V2_A** (FB701) for PLL/VCO/DDI-equalizer, **GND_A** partition (FB702), GS3470 DDO on FB700 1.8 V branch; 10-bit straps. **No external term** (GS3470 internal 75 Ω). | — |

### Sheet 8 — Genlock front-end (800s)

| Refdes | MPN | Net group |
|---|---|---|
| J800 | Molex 73101-0120 (REF IN) | — |
| J801 | Molex 73101-0120 (REF LOOP) | passive loop-through |
| J802, J803 | Hirose U.FL-R-SMT-1 (REF IN / REF LOOP carrier-side) | **Option A interconnect (2026-06-13):** panel BNC → 75 Ω pigtail → these u.FL receptacles; no riser hop on phase-critical sync. Upgrade = 75 Ω MMCX. |
| U800 | ADI LTC6912CGN-2 (PGA) | ← B33 SPI (3) |
| U801 | ADI AD9204BCPZ-20 (ADC) | → B33, dual-10-bit + DCO (11) |
| U802 | TI TS5A23159 (REF term switch; **CarrierGen symbol, TI pinout**) | switchable 75 Ω term via PCA9555 |
| U803 | PCA9555 I²C GPIO expander (I2C_HK) | drives REF (and spare) term-enable; 0x?? addr |
| D800 | **BAV99S 2-rail clamp** (PGA in → +5V_PGA / GND) | — |
| D801, D802 | **<3 pF video TVS** at J800 / J801 | panel ESD |
| R8xx/C8xx | term, AC-couple (0.1 µF), anti-alias LPF, ADC ref (VREF 470 nF, RBIAS) | — |

### Sheet 9 — Clock + sync gen (900s)

| Refdes | MPN | Net group |
|---|---|---|
| U900 | RP2040 (genlock, bare QFN) | UART → PS; I²C → Si5351; SPI → PGA |
| U901 | Winbond W25Q128JVSIQ (U900 flash) | QSPI |
| Y900 | 12 MHz crystal (U900) | — |
| U902 | Si5351A-B-GTR (genlock clock gen) | ch0 → FPGA master clock |
| Y901 | 25 MHz crystal (U902) | — |
| U903 | ADI AD9742 (SYNC 1 DAC) | ← **B35**, 12-bit + clk (13) — moved B34→B35 2026-06-13e (3.3 V DAC off the 1.8 V SDI bank) |
| U904 | TI LMH6643MAX/NOPB (sync cable driver, both OUTs) | — |
| J900 | Molex 73101-0120 (SYNC OUT 1) | — |
| J901 | Molex 73101-0120 (SYNC OUT 2) | ← B33, 1-bit biphase (1) |
| J902 | SWD service header (RP2040 U900 reflash) | SWCLK/SWDIO + 3V3/GND (open-box service; added 2026-06-13d) |
| R9xx/C9xx | I-V, 75 Ω term, decoupling | — |

> U902 (Si5351) I²C is **RP2040-mastered (genlock bus, 0x60)** — NOT the PS `I2C_VID` video bus (corrected 2026-06-13d).

### Sheet 10 — Control + networking (1000s)

| Refdes | MPN | Net group |
|---|---|---|
| ~~U1000~~ | ~~Laird LWB5+~~ — **DROPPED 2026-06-13d** (radio → ESP32-S3 on A2) | — |
| J1000 | Pulse JXD1-0001NL (RJ45 Gig magjack) | GbE (on-SoM PHY) |
| J1001 | GCT USB4085-GF-A (USB-C) | PS USB0 (whole-box recovery host) |
| U1001 | TI TPD4S014DBVR (USB-C ESD) | — |
| J1002 | Linx CONREVSMA001 (RP-SMA) | **ESP32-S3 WiFi antenna** (A2 U.FL → coax → J1002); J1003 removed 2026-06-13d |
| R10xx/C10xx | pulls, decoupling | — |

### Sheet 11 — Front-panel + LED (1100s)

| Refdes | MPN | Net group |
|---|---|---|
| J1100 | mezzanine **FFC (10-pin)** → A2 | +5V/+3V3/GND + PS↔ESP32 UART(TX/RX) + PWR_BTN + ESP_EN + ESP_GPIO0 (PS-driven ESP32 serial-boot recovery; 2026-06-13d) |
| J1101 | FFC → NHD-1.5-240240AF-CSXP (rear LCD) | PS SPI (4-wire) |
| U1100–U1102 | TI TLC59116F ×3 (LED drivers) | I²C |
| U1103 | rear-LCD backlight LDO (3.0 V) | — |
| D1100–D1120 | Lumex SSF-LXH409SISUGW ×21 (RA bi-color CBI, common-anode) | TLC59116 sinks (42 ch of 48) |
| R11xx | TLC59116 Iref set, LCD term | — |

> The NHD-1.5 module and the 21 LEDs are physically on the rear panel/carrier; the **front** TFT, EVE, encoders, buttons, and power button are all on **A2** (§A2), reached through `J1100`.

### Sheet 12 — RF interface + debug (1200s)

| Refdes | MPN | Net group |
|---|---|---|
| J1200 | u.FL jack (carrier side) → A3 | CVBS baseband (tap off sheet 6) |
| J1201 | 6-pin header → A3 | +12V / +3V3 / GND×2 / SDA / SCL |
| J1202 | 10-pin JTAG (Xilinx std) | PS JTAG |
| J1203 | 3/4-pin UART debug | PS console |
| SW1200 | boot-mode DIP/jumper (QSPI/SD/JTAG) | boot strap |
| SW1201 | PS POR reset | — |
| SW1202 | PL reset (optional) | — |
| J1204 | 2×20 expansion header (unused PL + rails) | spare PL + I²C/SPI tap |
| D1200–D1204 | board status LEDs (PWR / PL_DONE / PS_BOOT / 2× user) | — |

---

## A2 — Front mezzanine (own namespace)

Separate schematic/PCB; refdes restart at 1. Connects to carrier via `A1:J1100`.

| Refdes | MPN | Notes |
|---|---|---|
| U1 | **ESP32-S3-WROOM-1U-N8R2** (module — production; **N16R8** in hand for bench) — UI MCU | SPI → BT817Q; UART → carrier PS; WiFi OTA; EN/IO0 ← PS via J1100 (recovery); U.FL → panel RP-SMA (J1002). Module = pre-certified, integrates ESP32-S3 + flash + PSRAM + 40 MHz xtal + RF + antenna connector. |
| ~~U2~~ | ~~Winbond W25Q128JVSIQ~~ — **REMOVED 2026-06-14** (8 MB flash is integral to the WROOM-1U module) | — |
| ~~Y1~~ | ~~12 MHz crystal~~ — **REMOVED 2026-06-14** (40 MHz reference integral to the module) | — |
| U3 | BridgeTek BT817Q (EVE 4) | drives NHD-2.9 over 24-bit RGB |
| U4 | TI TPS61040 (6.0 V backlight boost) | NHD-2.9 backlight |
| J1 | header → carrier (UART + power) | mates A1:J1100 |
| J2 | FFC → NHD-2.9-376960AF-ASXP | 24-bit parallel RGB |
| SW1, SW2 | Alps EC11E18244AU encoders ×2 | quadrature + push |
| SW3–SW6 | C&K PTS645… (Home/Back/Menu/Confirm) | tactile |
| SW7–SW9 | C&K PTS645… (quick-select) | tactile |
| SW10 | E-Switch PV6 (illuminated power button) | to A1 LTC2954 via J1 |
| D1–Dn | front status LED column (mirrors rear) | |

## A3 — RF daughter board (own namespace)

Separate 4-layer schematic/PCB; refdes restart at 1. Connects via `A1:J1200` (u.FL) + `A1:J1201` (6-pin). Full build spec in [`rf-modulator-daughter-board-option.md`](rf-modulator-daughter-board-option.md).

| Refdes | MPN | Notes |
|---|---|---|
| U1 | ADI ADL5391ACPZ-R7 (AM modulator) | Y-input = baseband CVBS |
| U2 | Si5351A-B-GTR (RF carrier gen) | ch1 video / ch2 audio pilot |
| Y1 | 25 MHz crystal | U2 |
| U3 | Mini-Circuits ERA-3SM+ (MMIC amp) | |
| J1 | u.FL jack → carrier | CVBS in |
| J2 | 6-pin header → carrier | DC + I²C |
| J3 | Amphenol RF 82-4421-RFX (F-connector) | RF out |
| FL1 | 5th-order Butterworth bandpass (L/C) | 56–73 MHz |
| RV1, RV2 | Bourns 3224W trims (GADJ / Z-bias) | outside the can |
| D1 | NXP PESD3V3L1BA (F-conn ESD) | |
| FC1–FC4 | Murata NFM21… feedthrough caps | at can wall |
| FB1, FB2 | Murata BLM21PG600SN1D (optional) | |
| (SH1) | Masach MS643-10F-NS frame + 10C-NS cover | shield can (mech) |
| R/C | MLP (43 Ω+82 Ω), audio combiner, DC block 1 nF C0G, decoupling | |

---

## Using this against the netlist

1. Capture each sheet; annotate with **sheet#×100** numbering → refdes match this map.
2. Put the **MPN** in each symbol's field (Value or a `MPN` field) from the BOM.
3. Export KiCad BOM (refdes + MPN) and **diff against `bom-v1.md` pooled quantities** — counts must reconcile (e.g. 16× `J*` carrying 73101-0120 across sheets 5/6/7/8/9 = the BOM's "BNC ×16" after the 2026-06-13 SDI IN-LOOP + OUT-MIRROR adds; the U.FL-R-SMT-1 REF interconnect jacks J802/J803 are a separate line, not 73101-0120).
4. Anything that doesn't reconcile is drift — fix in KiCad, never here.
