# Schindler 2.0 — Bill of Materials

**Status:** Draft 2026-05-13 · **Production part-lock pass 2026-06-12** (all connector / switch / LED / MCU placeholders resolved to specific MPNs)
**Scope:** all silicon, modules, connectors, mechanical, and bench-eval boards. **One BOM covers both SKUs** — Pro v2 is the full stuffing; Mini v1 omits the Pro-tier silicon (SDI, RF modulator, dual SYNC OUT driver chain, per-connector LED drivers, rear LCD circuitry, Pro front-panel mezzanine). SKU stuffing matrix lives in [`packaging-skus.md`](packaging-skus.md).
**Detailed tracker:** `Parts List.xlsx` (authoritative for procurement state, notes, supplier links). This doc is the markdown-readable summary mapping parts onto the architecture in [`signal-flow.md`](signal-flow.md) + [`panel-layout.md`](panel-layout.md) + [`01-spec.md`](01-spec.md).

## Status legend

- ✅ **On order / received** — placed via DigiKey / Mouser / vendor
- 📋 **Banked / planned** — part selected and recorded in spec, not yet ordered
- 🔬 **Bench eval** — eval board on order or in use, production variant pending
- ❓ **TBD** — placeholder, selection deferred to carrier-schematic phase

---

## 1. Signal Path

Block-level breakdown of the video signal path per `signal-flow.md` diagram 1.

### HDMI Input
- **Chip 1 (HDMI IN ESD — sink-side, reworked 2026-06-14):** **2× TPD4E05U06DQA** (4-ch ultra-low-cap <0.5 pF TMDS ESD) + **1× TPD3E001DRLR** (DDC/HPD ESD); DDC/HPD/EDID handled natively by the LT8619C (no level-shifter on a sink). TI — ~$0.80 — 📋. *(Replaces the IN-side TPD12S016 — that part is source-side; kept only on the HDMI OUTPUT.)*
- **Chip 2:** `LT8619C` — HDMI 1.4 RX, parallel RGB out, embedded HDCP 1.4 keys — Lontium — ~$2 — ✅ (raw chip + LT8619C-EVB)
- **Connector:** HDMI Type A R/A PCB receptacle — Amphenol ICC **10029449-001RLF** — ~$1.20 — 📋

### SDI Input *(broadcast tier — factory-populated option)*
- **Chip 1:** `GS3470` — SDI receiver (3G-SDI); recovers clock + VITC; feeds video path AND genlock subsystem — Semtech — ~$15 — 📋
- **Connector:** 2× BNC 75 Ω R/A PCB bulkhead — Molex **73101-0120** (IN + IN LOOP, board-locks) — 📋 (prototype `0731010401` = same 73101 family — 🔬)

### Composite + Component Input
- **Chip 1:** `ADV7280AWBCPZ-M-RL` — multi-format analog decoder (CVBS / YPbPr / S-Video → BT.656 YCbCr 4:2:2 over parallel bus); AEC-Q100 auto grade; `-M` variant adds MIPI option — Analog Devices — ~$19 — ✅
- **Connectors:** 4× BNC 75 Ω — Molex **73101-0120** (1× CVBS + 3× YPbPr) — 📋
- **Passives:** input clamp = **BAV99** dual diode + input TVS; switchable 75 Ω term = TI **TS5A23159** analog switch + 75 Ω; AC-coupling + anti-alias LPF — values set at schematic — 📋

### FPGA Fabric (Zynq-7020)
All compute / pipeline blocks run inside the Zynq-7020 silicon carried on the TE0720 SOM.

- **SoC module:** Trenz **TE0720-04-62I33MA** — production target (Zynq-7020 -2I industrial, 1 GB DDR3L, 8 GB eMMC, 32 MB QSPI, GbE PHY on-module, 152 FPGA I/O via Samtec Razor Beam) — ~$300 — 📋
- **SoC module (bench):** Trenz **TE0720-04-31C33MA** — commercial -1 speed grade, same memory config, identical pinout — ~$230 — 📋
- **Heatsink:** Trenz **33337** springloaded — passive thermal — ✅
- **Carrier-side SoM sockets:** 2× Samtec **LSHM-150** (2×50, 100-pin → JM1/JM2 = refdes **J200 / J201**) + 1× Samtec **LSHM-130** (2×30, 60-pin → JM3 = **J202**) Razor Beam, 8 mm mating — ~$30/set — 📋. The TE0720 module mates to these three sockets; the $300 SoM line above is a mechanical/module BOM item with **no schematic refdes of its own** (the 3 sockets are its carrier interface). *(KiCad 2026-06-13: J200/J201 placed with a synthesized `Conn_02x50_Odd_Even` placeholder in `CarrierGen.kicad_sym`; swap to the real LSHM-150 symbol at layout for correct body/pin-1.)*
- **HDL blocks** (Xilinx IP, free): AXI VDMA. *(The Xilinx HDMI 1.4 TX IP is the **dev-board/Zybo** direct-TMDS path; production HDMI out is the external ADV7511 fed by an FPGA parallel video bus — see HDMI Output below + §3.2.)*
- **HDL blocks** (custom, in `hdl/`): polyphase scaler (8-tap H / 4-tap V), color pipeline (1024-entry gamma LUT + 3×3 matrix + per-channel trim), geometry (pincushion / keystone / 4-corner warp), test pattern generator (`sample_gen.v`), NTSC raster (`vid_timing.v` + `vbi_gen.v`), NTSC chroma (`chroma_gen.v`), luma+chroma combiner (inline in `top.v`)

### Analog Video Output (Composite + Component + S-Video)
- **Chip 1 (composite/component/S-Video):** `ADV7393BCPZ-REEL` — **triple 10-bit** output DAC/encoder; one chip serves composite/S-Video OR component, runtime mode-switched via I²C; SD/ED/HD component — Analog Devices — ~$16 — ✅
- **Chip 2 (output buffers):** `LMH6643MAX/NOPB` ×2 — dual op-amp, 130 MHz BW, low distortion; one HD-capable channel per DAC output (4 ch, 3 used), serving composite + component modes, single +5 V AC-coupled — TI — ~$1.50/dual — ✅ (10× prototype stock). **Consolidated 2026-06-11** — replaces OPA2350 SDTV tier + single LMH6643 (3-ch HD component needs 3 HD buffers; all-LMH6643 = one part type). OPA2350 (5× stock) freed for other use.
- **Connectors:** 4× BNC 75 Ω — Molex **73101-0120** (1× CVBS + 3× YPbPr) — 📋
- **Output ESD (added 2026-06-13e):** low-cap **<3 pF video TVS** at each panel BNC (TPD1E10B06-class) — generic — 📋; **220 µF** AC-couple at each BNC (×2 doubly-terminated, 75 Ω back-term); DAC load 37.5 Ω + RSET 4.12 kΩ + ×2 buffer gain resistors (per ADV7393 ref design). All on Sheet 6.
- **Note:** S-Video out is generated free from ADV7393 in composite mode (Y + C on two DAC channels) but the mini-DIN connector was dropped from V1 panel.

### SDI Output *(broadcast tier — factory-populated option)*
- **Chip 1:** `GS2962` — SDI transmitter (3G-SDI); processed output, not passive loop-through — Semtech — ~$17 — 📋
- **Connector:** 2× BNC 75 Ω — Molex **73101-0120** (OUT + OUT MIRROR, GS2962 C10/D10) — 📋

### HDMI Output (Monitoring/Analysis)
- **Chip 1:** `TPD12S016PWR` — HDMI ESD + level shift (same part as input) — TI — ~$1.50 — ✅
- **Chip 2 (HDMI TX):** `ADV7511KSTZ` — HDMI 1.4 transmitter; parallel RGB/YCbCr 4:2:2 in from FPGA (own dedicated 16-bit bus) → TMDS out; **non-HDCP variant** (no encryption asserted on the output — monitoring/analysis posture per §3.5) — Analog Devices, LQFP-100 — ~$7 — 📋. *(Production TX. The Xilinx free HDMI 1.4 TX IP / direct-FPGA-TMDS is the **dev-board / Zybo** bring-up path only — not production; see §3.2 + the 2026-06-13 changelog entry.)*
- **Connector:** HDMI Type A R/A PCB receptacle — Amphenol ICC **10029449-001RLF** — 📋

### Section subtotal (silicon only, per V1 unit)

| Item | Base | Broadcast |
|---|---:|---:|
| TPD12S016 ×2 | $3 | $3 |
| LT8619C ×1 | $2 | $2 |
| ADV7511 ×1 (HDMI TX) | $7 | $7 |
| ADV7280 ×1 | $19 | $19 |
| ADV7393 ×1 | $16 | $16 |
| Output buffers (2× LMH6643) | ~$3 | ~$3 |
| GS3470 ×1 | — | $15 |
| GS2962 ×1 | — | $17 |
| **Signal-path silicon** | **~$50** | **~$82** |

---

## 2. Sync Subsystem

Per `signal-flow.md` diagram 2 — genlock + dual SYNC OUT.

### Reference Input (Genlock Front-End)
- **Chip 1:** `LTC6912CGN-2#PBF` — 2-channel programmable gain amplifier; AGC loop driven by classifier — Analog Devices (Linear Tech) — ~$8 — ✅
- **Chip 2:** `AD9204BCPZ-20` — dual 10-bit 20 MSPS ADC; pin-compatible upgrade path to AD9231/9251/9258/9268 for 12/14/14/16-bit if future need — Analog Devices — ~$16 — ✅
- **Eval boards:** **MIKROE-2555** ×2 (LTC6912 GainAMP click, ~$25 ea) + **AD9204-80EBZ** (AD9204 eval, ~$278, 80 MSPS bench variant) — 🔬
- **Connectors:** 2× BNC 75 Ω — Molex **73101-0120** (REF IN + REF LOOP) — 📋
- **REF carrier interconnect (Option A, banked 2026-06-13):** 2× **Hirose U.FL-R-SMT-1** carrier-side receptacles (50 Ω / 6 GHz, ~$0.65–1.30 ea) + 2× 75 Ω coax pigtails (panel BNC → u.FL) — 📋. Keeps continuous coax across the riser gap on the phase-critical sync lines; the few-cm 50 Ω u.FL segment is negligible at sync edge rates. **Upgrade path** (impedance-exact + serviceable): 75 Ω MMCX PCB jack, ~$3–6 ea. A 75 Ω blind-mate float-bullet was rejected — effectively custom (float catalogs are 50 Ω).
- **Passives:** clamp = BAV99 + TVS, switchable 75 Ω term (TS5A23159), AC-coupling, switchable analog LPF — values at schematic — 📋

### Slow Control + Clock Generation
- **Chip 1:** **RP2040** (bare QFN-56) + **W25Q128JVSIQ** QSPI flash + 12 MHz crystal — autosense slow-control, PGA gain commands, Si5351 register writes, status reporting to Zynq PS over UART — Raspberry Pi — ~$1.50 — 📋 (production = bare chip, not module; same pattern as mezzanine RP2040)
- **Chip 2:** **Si5351A-B-GTR** — 3-output I²C clock generator (MSOP-10); ch0 → FPGA master, ch1+ch2 reserved — Skyworks/Silicon Labs — ~$2 — 📋 production (confirmed variant)
- **Eval boards:** **Adafruit 2045** Si5351 breakout ×2 — 🔬

### Genlock Loop Core
All in FPGA fabric — no discrete chips. Listed for completeness.
- Autosense classifier (LTC biphase / BB 15.734 kHz / tri-level signature)
- Per-format decoders: LTC frame decoder, BB sync separator, tri-level decoder, SDI recovered clock+VITC (from GS3470)
- Reference selector mux (operator override + autosense priority)
- Digital PLL: phase/frequency detector, loop filter (~0.5 Hz default), NCO/integrator, lock detector (state machine + quality metric)

### Dual SYNC OUT Generation
- **SYNC OUT 1 DAC:** `AD9742` — 12-bit, 210 MSPS TxDAC, current-output — Analog Devices — ~$7 — 📋 (pin-compatible to AD9744 14-bit; serves BB / tri-level / LTC, 13 PL pins)
- **SYNC OUT 2:** LTC-only — 1-bit FPGA biphase → slew-limited op-amp, **no DAC** (1 PL pin)
- **Cable drivers (both OUTs):** `LMH6643` dual op-amp — reused from the analog-output HD buffer; one dual covers SYNC 1 + SYNC 2 into 75 Ω — TI — ~$1.50 — 📋
- **Connectors:** 2× BNC 75 Ω — Molex **73101-0120** (SYNC OUT 1 + SYNC OUT 2) — 📋
- **Per-OUT phase accumulator + waveform gen:** FPGA fabric, no discrete chip

### Section subtotal

| Item | Per unit |
|---|---:|
| LTC6912 ×1 | $8 |
| AD9204-20 ×1 | $16 |
| RP2040 ×1 | ~$1 |
| Si5351 ×1 | ~$2 |
| AD9742 12-bit DAC ×1 (SYNC 1) | ~$7 |
| LMH6643 dual driver ×1 (both OUTs) | ~$1.50 |
| **Sync-subsystem silicon** | **~$35** |

---

## 3. Power

Per `01-spec.md` Power & safety section.

### AC Entry
- **Connector:** Schaffner **FN9260B-6-06** — IEC C14 + 6 A rating + integrated fuse holder + 1-stage EMI filter, panel-mount — ~$18 — ✅ (2 on order)
- **Fuse:** Littelfuse **0213002.MXP** — 2 A T (time-lag), 5×20 mm cartridge — ~$1 — 📋

### PSU Module
- **Module (primary):** Mean Well **LRS-50-12** — 50 W / 12 V single output, 85–264 VAC universal, enclosed aluminum case, convection-cooled, UL 62368-1, EN 55032 Class B — ~$15–20 — ✅
- **Module (alternate / lower-noise swap-in):** TDK-Lambda **HWS50A-12/A** — same form factor, lower switching noise for pro-audio-adjacent applications if bench characterization shows the Mean Well noise floor as audible — ~$50 — 📋
- **PSU → Carrier connector:** Molex Mini-Fit Jr. **0039291028** (2-ckt vertical PCB header) + 5557-02R receptacle housing — 9 A — ~$0.80 — 📋

### Carrier 12 V Input Protection Chain
- **U1 (protection eFuse):** TI **TPS26601** — 60 V integrated FET; reverse-polarity + reverse-current, adjustable OVP + OCP (precise current limit, no thermal derate), controlled inrush; EN = soft-power gate; I<sub>LIM</sub> ≈ 2.5 A. Replaces the DMP3098L + polyfuse + TVS chain — ~$2.50 — 📋 *(swapped from TPS26600 2026-06-13b: the '601's MODE-open default is circuit-breaker-with-**latch**, matching the chosen latch-off posture — MODE left open, no strap. Pinout identical to the '600; KiCad symbol reused, set value to '601.)*
- **U2 (power monitor):** TI **INA226** — I²C 16-bit current+voltage telemetry alongside the eFuse — ~$1.50 — 📋
- **Sense resistor:** 5 mΩ, 1 % — generic — ~$0.20 — 📋
- **C bulk:** 3× Murata **GRM32** 22 µF 25 V X7R MLCC in parallel (~66 µF nominal, ~35 µF effective at 12 V bias) — ~$2.40 — 📋
- **U3 (soft-power controller):** ADI **LTC2954-1** — pushbutton on/off controller in the always-on 12 V domain (2.7–26.4 V, 6 µA standby — no standby LDO). Debounced front-panel button → drives the eFuse EN gate; **INT** → Zynq GPIO (orderly-shutdown request), **KILL** ← Zynq GPIO (clean power-down), **PDT** watchdog (~5 s) force-off if Linux hangs. 8-pin ThinSOT — ~$2.50 + ~$0.30 timing/PB passives — 📋. Resolves the "RP2040 is downstream of the rails it would gate" chicken-and-egg.

### Per-Rail Regulators (Downstream of 12 V)
Committed 2026-06-11. VIN fed from the 5 V rail; Vccint 1.0 V / 1.8 V / DDR3L 1.35 V are generated **on-module** (not carrier-supplied).
- **5 V buck** (~3 A) — TI **LMR33640 (4 A)** (12→5 V; module VIN + USB host + analog op-amps; op-amps single +5 V, AC-coupled at BNCs) — ~$1.30 — 📋
- **3.3 V buck** (~2.5 A) — TI **LMR33640 (4 A)** (12→3.3 V; module 3.3VIN + all VCCIO banks + carrier digital), same part 2nd instance — ~$1.30 — 📋
- **1.2 V buck** (~0.4 A) [Pro] — TI **TLV62568** (5→1.2 V; GS3470 ~0.15 A + GS2962 ~0.25 A on 1.2 V core/analog — verified ~0.3–0.4 A, GS2962 cable driver sits on 3.3 V) — ~$0.40 — 📋
- **1.8 V analog LDO** (~0.3 A) — TI **TPS7A2018PDBVR** low-noise (3.3→1.8 V; AD9204 AVDD + ADV7280 analog) — ~$1 — 📋
- **Clean analog LDOs** — ADI **ADP7142** (adjustable, ultra-low-noise), one per ADC/decoder, output set at schematic — ~$1 — 📋
- **1.8 V digital LDO (`+1V8_D`)** — small 1.8 V LDO off the 3.3 V rail (~0.1 A) for **VCCIO33 (PL bank 33) + AD9204 DRVDD**; added 2026-06-13c when B33 was re-strapped to 1.8 V for the AD9204 1.8 V CMOS interface — kept off the analog 1.8 V so DRVDD switching doesn't couple into the ADC AVDD — ~$0.30 — 📋 (U310)

### Section subtotal

| Item | Per unit |
|---|---:|
| FN9260B-6-06 ×1 | $18 |
| Fuse | $1 |
| PSU module (LRS-50-12 primary / HWS50A-12/A alternate) | $15–50 |
| Carrier protection + soft-power | ~$10 |
| Per-rail regulators | ~$5 |
| **Power subsystem total** | **~$49–84** |

---


### Analog/genlock conditioning parts (added 2026-06-13e/14, sheets 4/5/6/8)
- **BAV99S** (series dual diode, SOT-363) — IC-side **2-rail clamp** to AVDD/GND on analog-in (ADV7280) + genlock (LTC6912 PGA) inputs — generic — 📋. (Replaces the common-anode BAV99 for proper 2-rail clamping.)
- **Low-cap <3 pF video TVS** (TPD1E10B06-class) at every external analog/genlock panel BNC — generic — 📋.
- **ADV7280 crystal** — 28.63636 MHz + 18 pF loads (Y500) — generic — 📋 (required by the decoder; was missing from the parts list).
- **PCA9555** I²C GPIO expander (on I2C_HK) — drives the switchable 75 Ω termination ground-leg switches (REF/SDI loop-through inputs) — NXP/TI — ~$1 — 📋.
- HDMI: 2.2 kΩ DDC/I²C pull-ups, CT_HPD + supply decoupling (TPD12S016) — generic — 📋.
  - **TPD12S016 (U401, HDMI OUT) supply decoupling (2026-06-14):** VCC5V (pin 11) = **C405 1 µF bulk + C406 0.1 µF X7R** (C406 added directly in the wired sheet 4); VCCA (pin 24) = **C403 0.1 µF X7R** (already present). All X7R, to GND — generic — 📋.
  - **LT8619C (U402, HDMI RX) decoupling — added 2026-06-14, standard multi-supply HDMI-RX practice (no exhaustive per-pin table in datasheet):**
    - **14× 0.1 µF X7R 0402** — one per supply pin to GND: **C407/C408** (VCCA18 p1/p13 → +1V8_A), **C409** (PVCC18 PLL p59 → +1V8_A), **C410/C411/C412** (VDD18 p25/p58/p67 → +1V8_D), **C413** (VCCA33 p7), **C414/C415** (VCC33 p20/p64), **C416/C417** (VCC33_TTL p36/p57), **C418** (VCCA33_XTAL clock p62), **C419/C420** (VTERM TMDS-term p4/p10) — all → +3V3.
    - **3× 10 µF X7R/X5R 0805 bulk** — one per rail near chip: **C421** (+1V8_A), **C422** (+1V8_D), **C423** (+3V3).
    - **Optional PLL/clock ferrite isolation (jitter):** **FB400** (+1V8_A→+1V8_A_PLL, C409 moves there), **FB401** (+3V3→+3V3_XTAL, C418 moves there) — generic — 📋.
- Output stage (ADV7393 low-drive): 300 Ω DAC loads, 4.12 kΩ RSET, ×2 buffer gain resistors, 75 Ω back-term, **220 µF AC-couple** at BNC — generic — 📋.

## 4. UX / Panel I/O

### Front Panel — Pro mezzanine board (RP2040 + EVE)
Separate mezzanine behind the front-panel aluminium, UART + power to the carrier. Per spec §15.2 / §17.1.
- **Front TFT:** Newhaven **NHD-2.9-376960AF-ASXP** — 2.9" 376×960 IPS (mounted landscape, 960×376), ST7701SN, 24-bit parallel RGB, 1050 cd/m² — ~$30 — 📋 (bezel cutout 69×28 mm)
- **Graphics controller:** BridgeTek **BT817Q** EVE 4 — drives NHD-2.9 over 24-bit RGB, 1 MB RAM_G, command-list rendering from RP2040 over SPI — ~$10–13 — 📋
- **TFT backlight boost:** TI **TPS61040** class 6.0 V boost on mezzanine — ~$0.50 — 📋
- **UI MCU:** **RP2040** (bare QFN-56, mezzanine; separate from the genlock RP2040) + **W25Q128JVSIQ** flash + 12 MHz xtal — reads encoders/buttons, streams EVE command lists over SPI, syncs to Zynq PS over UART — ~$1.50 — 📋
- **Encoders:** 2× Alps **EC11E18244AU** — 36 detents / 18 PPR, integrated push switch, -40 to +85°C industrial — ~$3 ea — ✅ (5 on order)
- **Encoder alternates for UX testing:** **3315Y-025-016L** ×2, **EC111012010H** ×1 — ✅
- **Knob options for evaluation:** CP34501, FC7229NML, CL178883, FC1611, 1202CY (production knob selection deferred) — ✅
- **Buttons:** 4× tactile (Home, Back, Menu, Confirm) + 2–3 quick-select (BLACK / MONO / Proc-Amp bypass) — C&K **PTS645SM43SMTR92LFS** (6 mm SMT) + panel actuator/cap (cap at mech) — 📋
- **Front status LED column:** mirrors rear per-connector LED state
- **Power button:** **E-Switch PV6** series 16 mm anti-vandal ring-illuminated momentary, lower-left — gated by the **LTC2954-1** soft-power controller (see §3 Power); LED off EN / RP2040 — 📋 (color/voltage suffix at mech)
- **Knob shroud / guard:** mechanical, recessed encoder pocket (HARD REQUIREMENT — must survive face-down drop in road case) — schematic+chassis phase

*(Reconciled 2026-06-11 from the stale STM32H735 + ILI9341 entry to the committed RP2040 + BT817Q EVE + NHD-2.9 mezzanine per spec §15.2/§17.1. STM32H735IGT6 UI MCU + STM32H735G-DK eval dropped — superseded by the EVE/RP2040 path.)*

### Rear Panel — Status Display
- **LCD:** Newhaven **NHD-1.5-240240AF-CSXP** — 1.5" 240×240 IPS square, ST7789VI + frame RAM, 32.52 × 35.32 mm module (~28×28 mm active), 1200 cd/m² — ~$15 — 📋. **4-wire SPI** (strap IM0=0/IM1=1/IM2=1).
- **Backlight:** 3.0 V / 100 mA small LDO from 3.3 V — ~$0.20 — 📋
- **Mounting:** recessed bezel cutout with anti-glare film
- **Owner:** Zynq PS via dedicated SPI port, ~1 s refresh, read-only status grid

*(Reconciled 2026-06-11 from the "2.4 16:9" placeholder to the committed NHD-1.5 on SPI per spec §16.3.)*

### Per-Connector Status LEDs
- **LED:** Lumex **SSF-LXH409SISUGW** — 3 mm bi-color red (636 nm) / green (574 nm) **common-anode**, **one-piece right-angle PCB indicator** (housed RA CBI — emits parallel to the board → faces the rear panel; no separate holder or light pipe), 3-lead offset-cathode, 60° dome — qty ~21 (one per rear connector) — ~$0.60–1.00 ea (housed RA CBI; confirm at procurement) — 📋. Common-anode suits the TLC59116 current-sink (2 ch/LED → 42 of 48 ch). **Selected 2026-06-13c** over the bare Kingbright L-3VEGW-CA (vertical-emit — would have needed a holder or light pipe) and the Dialight 551-3513F (common-*cathode* — wrong polarity for a sink driver). Amber = R+G; **balance the two channels in TLC59116 PWM** (red 350 mcd > green 130 mcd at equal current). Internal die = SSL-LX3059SISUGW.
- **Driver chips:** 3× TI **TLC59116F** — 16-channel constant-current with per-channel PWM dimming — ~$1.50 ea — 📋
- **Bus:** I²C from Zynq PS

### Section subtotal

| Item | Per unit |
|---|---:|
| Front TFT (NHD-2.9) | ~$30 |
| BT817Q EVE + 6 V boost | ~$13 |
| Mezzanine RP2040 | ~$1 |
| 2× Alps EC11 encoder | $6 |
| 4 tactile + 3 quick-select buttons | ~$3 |
| Power button (lighted soft) | ~$3 |
| Rear LCD (NHD-1.5) + backlight LDO | ~$15 |
| 21× tricolor LEDs (Lumex SSF-LXH409 RA CBI) | ~$13–16 (confirm) |
| 3× TLC59116F | $4.50 |
| Knob hardware | ~$10 (est.) |
| **UX/Panel subsystem total (Pro)** | **~$90** |

---

## 5. Control + Networking

### Wired Control
- **GbE PHY:** integrated on TE0720 SOM (no external PHY needed) — 📋
- **RJ45 jack with magnetics:** Pulse **JXD1-0001NL** — Gigabit integrated-magnetics magjack with LEDs — ~$3 — 📋
- **USB-C service port:** GCT **USB4085-GF-A** (USB 2.0 Type-C, R/A SMT) + ESD **TI TPD4S014DBVR** — ~$3 — 📋. USB 2.0 only (gadget console + ethernet-over-USB); no PD/SS.

### Wireless
- **WiFi/BT module:** Laird Sterling **LWB5+** — pre-certified, 88W8997 chipset, dual-band a/b/g/n/ac + BT5.0. WiFi on **SDIO0 (PS MIO40–45, 1.8 V strap — direct, no level shifter)**; BT on a separate PS UART — ~$30 — 📋
- **Antennas:** 2× Linx **CONREVSMA001** RP-SMA bulkhead jack + Linx **ANT-DB1** dual-band 2.4/5 GHz stub — ~$5 ea — 📋. **Must be on the LWB5+ FCC grant's permitted-antenna list — confirm before order.**

### Compute (Linux Side)
- **Zynq PS** — dual Cortex-A9 on TE0720 SOM under PetaLinux; hosts web UI, REST API, EDID, mDNS, OTA, config persistence, color pipeline runtime (Screenie port), I/O state aggregator. Listed under Signal Path; no separate silicon.

### Section subtotal

| Item | Per unit |
|---|---:|
| LWB5+ WiFi/BT module | $30 |
| RJ45 mag jack | ~$3 |
| USB-C connector + ESD | ~$3 |
| 2× RP-SMA + antennas | ~$10 |
| **Control/networking total** | **~$46** |

---

## 6. Chassis + Mechanical

### Enclosure
- **Chassis:** 1RU full-rack 19" extruded aluminum body — **Hammond** (RM1U-series, exact model at mech) — ~$50–80 — 📋
- **Front panel:** Front Panel Express milled aluminum, anodised, silkscreened — fab deliverable from `panel-layout.md` — ~$40 — 📋
- **Rear panel:** Front Panel Express milled aluminum, panel cutouts for all rear I/O (incl. RF daughter-board F-conn cutout) — fab deliverable from `panel-layout.md` — ~$60 — 📋
- **Rack ears:** integrated with the Hammond 1U chassis — ~$10 — 📋

### Thermal
- **Fan:** Noctua **NF-A4x20 PWM** — 40 mm, ~14 dB low RPM, conditional/silent (only spins on SOM temp threshold) — ~$15 — 📋
- **SOM thermal pad:** silicone gap pad between Zynq SOM and chassis top cover (top acts as primary heatsink for fanless operation at typical 14–16 W load) — ~$2 — 📋

### Hardware
- **M3 standoffs** for PSU mounting (×4) and carrier PCB mounting (×6–8) — generic brass M3 — ~$3 total — 📋
- **Earth bonding stud** for chassis ground — M4 brass stud — ~$1 — 📋
- **Mounting screws** (mix of M3 panhead + M2.5 for board mounts) — generic — ~$3 — 📋

### Mechanical Reservations
- **Knob shroud / encoder guard** on front panel (HARD REQUIREMENT) — milled into front panel or separate bezel piece — schematic+chassis phase
- **Spare panel space** ~67 mm on right side of rear panel — reserved for V1.x expansion (potential XLR return, 10 MHz GPSDO BNCs, or vented airflow grille)

### Section subtotal

| Item | Per unit |
|---|---:|
| Chassis | ~$70 (est.) |
| Front panel | ~$40 |
| Rear panel | ~$60 |
| Rack ears | ~$10 |
| Noctua fan | $15 |
| Thermal pad | $2 |
| Hardware (standoffs/screws/stud) | ~$7 |
| **Chassis/mechanical total** | **~$200** |

---

## 7. RF Modulator Output *(RF daughter-board — separate shielded assembly)*

**Partition committed 2026-06-11:** the RF modulator is a standalone, shielded, panel-mounted **daughter board**, not carrier-resident. It connects to the carrier by 1× u.FL coax (baseband composite in) + a 6-pin header (DC + I²C). Adds an RF modulated output on NTSC Ch3 or Ch4 (operator-selectable) for 1970s consumer CRTs with antenna-only inputs. The RF *chain* parts below are unchanged from the prior bake-in spec — they relocate onto the daughter board. Partition + physical-build spec: [`rf-modulator-daughter-board-option.md`](rf-modulator-daughter-board-option.md). Chain architecture: [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md).

**Operator picks one of three analog output modes** via UI: composite (BNC live), RF Ch3 / RF Ch4 (F-connector on the daughter board live; ADV7393 stays in composite mode; carrier feeds composite to the board over u.FL), or component (3× component BNC live, ADV7393 in component mode). **RF mute** = disable the daughter-board Si5351 output over I²C (no amp-enable pin needed). HDMI and SDI remain independently live. F-connector lives on the daughter board's own rear-panel edge, beside the composite BNC.

### Modulator + carrier generation
- **AM modulator (primary):** `ADL5391ACPZ-R7` — Analog Devices, DC–2.0 GHz analog multiplier, modern symmetric-core architecture, 16-LFCSP, 7" reel cut for single qty — ~$15 single qty / ~$18 at qty 100 — 📋
- **AM modulator:** committed to **ADL5391** (2026-06-07). `AD835ARZ` head-to-head **dropped, not ordered**; if a cheap second-topology bench comparison is ever wanted, the MC1496 balanced modulator (~$1) is the option, not another precision multiplier.
- **RF carrier gen:** **Si5351A-B-GTR** — dedicated to RF subsystem (separate from genlock Si5351 to avoid cross-coupling) + 25 MHz crystal — Skyworks/Silicon Labs — ~$2 — 📋
- **Si5351 channel allocation:** ch1 = video carrier (Ch3 61.25 MHz / Ch4 67.25 MHz), ch2 = audio pilot CW (Ch3 65.75 MHz / Ch4 71.75 MHz), ch0 free.

### RF chain
- **RF amp:** Mini-Circuits **ERA-3SM+** — MMIC, DC–3 GHz, ~22 dB gain, SOT-89, 50 Ω native — ~$3.50 — 📋
- **Output bandpass filter:** **5th-order Butterworth** LC, centered ~64 MHz, passband 56–73 MHz (covers Ch3 + Ch4 carriers; suppresses 2nd harmonics at 122.5–134.5 MHz) — Coilcraft 0805CS-class inductors + C0G caps, ~9 parts — ~$1.50 — 📋. **Butterworth committed** (tolerance-insensitive across 100 units; ~1-octave 2H separation gives ample rejection without Chebyshev ripple). Nominal L/C captured at schematic; final values bench-tuned on the prototype.
- **50→75 Ω MLP (minimum-loss pad):** 43.2 Ω series + 86.6 Ω shunt resistors (off-the-shelf 43 Ω + 82 Ω 1% is close enough). Two 1% resistors total. 5.7 dB insertion loss — mathematically optimal for resistive 50↔75 Ω conversion. Broadband DC-to-GHz, no tuning, no drift. ERA-3SM+ has 22 dB gain headroom so pad loss is rounding error. **Replaces prior transformer option** (TC4-1W+/MABAES0061 are 1:4 ratio = 50↔200 Ω, NOT 50↔75 — confirmed by datasheet 2026-05-11 PM). — ~$0.10 — 📋
- **Audio combiner:** 3-resistor resistive combiner that sums Si5351 ch2 audio pilot CW with ADL5391 output before bandpass filter — generic resistors — ~$0.50 — 📋

### Mode selection (no RF-path switches)
- **RF mute:** disable the daughter-board Si5351 output via I²C (OEB / clock power-down) — no carrier, nothing to gate. **The ERA-3 bias FET gate was dropped 2026-06-11** with the move to a daughter board (amp is powered whenever the board is; mute happens upstream at the Si5351). No amp-enable pin on the interconnect.
- **ADV7393 mode:** I²C-switched between composite mode (serves composite BNC + the daughter board's u.FL feed) and component mode (serves 3× component BNC) — no additional silicon, configuration only.
- **Composite BNC gate (ADG419) dropped 2026-06-11** — a ~30 Ω SPST switch in series with the 75 Ω composite line degraded return loss/level for no benefit; the composite BNC stays live and the daughter board taps the same buffered signal over u.FL. See `rf-modulator-subsystem.md`.

### Output protection + connector
- **DC block on RF output:** C0G **1 nF** 50 V MLCC (`KGM21BCG1H102FT` class) — generic — ~$0.10 — 📋 (corrected 2026-06-07 from 0.1 µF: at 67 MHz a 0.1 µF cap is past self-resonance and goes inductive; 1 nF C0G is a clean block — applies to all RF-path blocks)
- **ESD on F-conn:** `PESD3V3L1BA` low-cap TVS or equivalent — NXP — ~$0.20 — 📋
- **F-connector:** Amphenol RF **82-4421** class panel-mount 75 Ω, threaded — ~$1.50 — 📋

### Shielding
- **Shield can:** Masach **MS643-10F-NS** frame + **MS643-10C-NS** cover — nickel-silver, two-piece, 64.3 × 20.3 × 6.7 mm, over the whole RF section (modulator + amp + dedicated Si5351 + bandpass) — ~$3.50 — 📋 (required for FCC Part 15 compliance — not optional). Two-piece for bench tuning; long-narrow footprint gives natural I/O isolation along the chain.
- **Feedthrough caps (at can wall):** 2× Murata `NFM21PC104R1E3D` 0.1 µF 25 V (DC lines) + 2× `NFM21CC102R1H3D` 1 nF 50 V (I²C) — ~$0.55 — 📋. Optional 2× `BLM21PG600SN1D` series ferrite (~600 Ω @ 100 MHz) — ~$0.20.

### Interconnect (daughter board ↔ carrier)
- **u.FL coax:** baseband composite in (carrier LMH6643 composite buffer → ADL5391 Y input). u.FL jack on daughter board + u.FL-to-u.FL cable — ~$1.40 (carrier-side u.FL jack counted under carrier interface) — 📋. Shielding + defined ground return, not impedance matching — the 4–5 MHz line is electrically tiny over the ~10–20 cm run.
- **6-pin header (board side):** +12 V, +3.3 V, 2× GND, SDA, SCL — ~$0.30 — 📋
- **4-layer daughter PCB** (~65×30 mm, qty 100) — required for the buried-stripline line entry under the can wall (continuous ground ring) — ~$2.50 — 📋
- **Production trims:** 2× Bourns `3224W` SMD multiturn (output-level GADJ + mod-depth Z-bias, mounted *outside* the can) — ~$1.50 — 📋 (replaces bench `3296W`)
- **Panel-mount hardware / standoffs / bracket** — ~$1.50 — 📋

### Carrier-side interface (only when RF populated)
- 1× u.FL jack at the composite buffer + 1× 6-pin header (fused +12 V tap post-eFuse, +3.3 V off carrier rail, GND×2, I²C) — ~$1 — 📋. Unpopulated footprints when RF is omitted; no carrier respin.

### Bypass / decoupling
- Generic 0.1 µF + 10 µF per power rail — ~$1 — 📋

### Bench eval parts (separate from production BOM)
- **EC Buying ADL5391 breakout board** — AliExpress / Amazon — ~$15–25 — 🔬 primary bench-eval platform
- **ADL5391ACPZ-R7** × 1 — DigiKey — $15 — 🔬 known-authentic backup against potential counterfeit silicon on Chinese board
- **AD835ARZ** × 1 — DigiKey — $25 — 🔬 architectural fallback
- **ERA-3SM+** × 5 — Mini-Circuits direct — ~$20 — 🔬
- **43 Ω + 82 Ω 1% resistors** — DigiKey — cents — 🔬 (the 50→75 Ω MLP)
- **F-connectors + F-to-BNC adapters** — DigiKey — ~$10 — 🔬
- **ADI ADL5391-EVALZ explicitly NOT ordered** — $300 at DigiKey, not worth the price premium vs Chinese-board + spare-chip approach.
- Bench eval starter total: **~$65–70**.

### Section subtotal (RF daughter-board assembly, per populated unit)

| Item | Per board |
|---|---:|
| ADL5391ACPZ-R7 (primary modulator) | $18 |
| Si5351A-B-GT + 25 MHz crystal (RF-dedicated) | $2 |
| ERA-3SM+ RF amp | $3.50 |
| Output bandpass filter (LC passives) | $1.50 |
| 50→75 Ω MLP (2 resistors) | $0.10 |
| Audio combiner passives | $0.50 |
| F-connector + ESD + DC block | $1.80 |
| Shield can + cover (MS643 NS, two-piece) | $3.50 |
| Feedthrough caps (NFM ×4) + optional ferrites | $0.75 |
| Bypass / decoupling passives | $1 |
| u.FL (board jack + cable) | $1.40 |
| 6-pin header (board side) | $0.30 |
| 4-layer daughter PCB (~65×30 mm) | $2.50 |
| Production trims (2× Bourns 3224W) | $1.50 |
| Panel hardware / standoffs / bracket | $1.50 |
| **RF daughter-board assembly total** | **~$38–40** |

Standalone shielded daughter board — a **Pro feature** (fitted on Pro, omitted on Mini per spec §0/§3.9; clean populate/omit, no carrier respin). **Carrier-side interface** (u.FL jack + 6-pin header) adds **~$1** to the Pro carrier BOM. The ERA-3 bias FET ($0.30) was dropped with the partition (mute via Si5351 I²C).

### Open BOM questions
- ~~**Final modulator chip:** ADL5391 vs AD835.~~ **RESOLVED 2026-06-07** — ADL5391 committed; AD835 dropped (not ordered). See `rf-modulator-subsystem.md` §1.
- ~~**Output bandpass topology:** Chebyshev vs Butterworth.~~ **RESOLVED 2026-06-12 — 5th-order Butterworth** (tolerance-insensitive across 100 units; ample 2H rejection). Nominal values captured at schematic, final tune at bench.
- **Audio FM modulation:** explicitly **out of V1** (deferred to V1.x; Colpitts VCO + FPGA 1 kHz tone path documented if customer evidence appears). Not on the V1 netlist.
- **Channel-selection UI surface:** UI-spec-phase item (front-panel Ch3/Ch4 toggle vs web). Does not affect the netlist.

---

### SDI TX/loop refinement (Sheet 7, Fig 5-1, added 2026-06-14b)
- **3G-SDI cable driver** (TI **LMH0302**-class) for the GS3470 reclocked loop-out (U702) — powered from +3V3_SDIDRV; ⚠ pinout placeholder, verify vs datasheet — 📋.
- **GS2962 TX return-loss network** (per leg, SDO→J701 / ~SDO→J703, per GS2962 datasheet): RSET 75 Ω→common CD_VDD, **5.6 nH inductor ∥ 75 Ω** (series-shunt return-loss), 4.7 µF (4.6 µF nom) AC-couple, 10 nF CD_VDD→GND_A bypass; output BNC shells (J701/J703)→GND_A.
  - **Inductors L700/L701 — 2× 5.6 nH RF/wideband, 0402** (was 5.6 Ω resistors). **Primary (LOCKED): Coilcraft 0402HP-5N6XJTW** (5.6 nH, SRF ≈ 10 GHz) — ~2× margin over the ~4.5 GHz harmonic band governing 3G-SDI return loss. **Cost-down alternate: Murata LQW15AN5N6G00D** (5.6 nH ±2%, SRF ≈ 5.5 GHz) — contingent on a later S-parameter / return-loss check confirming 5.5 GHz SRF is adequate (marginal — close to band edge).
  - Loop-driver (LMH0302) output network unchanged (5.6 Ω + 75 Ω + 10 nF). — generic — 📋.
- **Analog supply partition:** +1V2_A (FB701 ferrite off +1V2 → GS PLL/VCO + GS3470 DDI equalizer), +3V3_A (GS2962 AVDD), **GND_A** single-point bridge (FB702) — generic — 📋.
- **Y700:** 27 MHz **9 pF-CL** crystal + 8 pF loads (⚠ confirm ppm) — generic — 📋.

### SDI + sync conditioning parts (sheets 7/9, added 2026-06-14)
- **GS3470 27 MHz reference crystal** + 18 pF loads (Y700) — generic — 📋 (⚠ confirm crystal vs external XO per GS3470 datasheet).
- **SDI AC-couple:** 4.7 µF per SDI line (IN/LOOP/OUT, single-ended; complement AC-grounded) — generic — 📋.
- **SDI ESD:** **<0.3 pF** single-line (SP3010-01-class) on all 4 SDI BNCs (J700–703) — 📋 (3G-rated; replaces the 0.5 pF TPD1E05U06). J703 = GS2962 ~SDO split-out (SDO→J701, ~SDO→J703, each own 75 Ω). GS3470 DDI/DDO analog 1.8 V via FB700 ferrite branch.
- **GS PLL/VCO analog RC filters:** 10 Ω + 1 µF from +1V2 (GS3470 PLL/VCO; GS2962 PLL/VCO); GS2962 AVDD=+3V3, cable driver=+3V3_SDIDRV — generic — 📋.
- **AD9742 sync out:** FS_ADJ 3.83 kΩ (IOUTFS≈10 mA), 100 Ω I-V loads, ×2 LMH6643 buffer (1 k/1 k), 75 Ω back-term, 220 µF AC-couple, REFIO 0.1 µF; SYNC2 slew RC (1 k + 1 nF) — generic — 📋. (Sync levels: 1.0 Vpp BB / ±300 mV tri-level at load — verify vs AD9742 datasheet.)

## V1 Pro Full BOM Roll-Up (typical)

| Section | Base unit | Broadcast unit |
|---|---:|---:|
| 1. Signal Path silicon | ~$50 | ~$82 |
| 2. Sync Subsystem silicon | ~$35 | ~$35 |
| 3. Power | ~$52 | ~$52 |
| 4. UX / Panel I/O | ~$90 | ~$90 |
| 5. Control + Networking | ~$46 | ~$46 |
| 6. Chassis + Mechanical | ~$200 | ~$200 |
| 7. RF Modulator Output *(Pro daughter-board)* | ~$41 | ~$41 |
| **Subtotal (parts only)** | **~$514** | **~$546** |
| TE0720 SOM (production grade) | $300 | $300 |
| **V1 unit total (parts)** | **~$814** | **~$846** |

> **Refreshed 2026-06-11 (end-of-review cost pass):** Signal-path → $50/$82 (output-buffer consolidation + ADV7511 HDMI TX line reconciled 2026-06-13), Power → $52 (eFuse + LTC2954 soft-power, primary LRS-50), UX → $90 (NHD-2.9 + BT817Q EVE mezzanine), RF → $41 Pro daughter-board. Both columns are Pro stuffings (Base = no SDI / Broadcast = +SDI); Mini is lighter (OLED UI, no SDI/RF/dual-SYNC) — see `packaging-skus.md`.

**Excluded from this BOM:** carrier PCB fabrication + assembly cost (~$80–150 per board at qty 100 per playbook Ch. 10), labor / test / packaging / shipping, NRTL end-product certification cost amortization, software development, marketing — these all sit outside the parts roll-up.

**At Schindler's expected ~$2,500 retail / pro market positioning, parts cost of ~$800 = ~32 % BOM-to-retail ratio**, which is healthy for niche broadcast hardware (industry norm 25–40 %).

---

## Cross-references

- Architecture rationale + decision history: [`01-spec.md`](01-spec.md) + [`01-spec-changelog.md`](01-spec-changelog.md)
- Block-level signal flow: [`signal-flow.md`](signal-flow.md)
- Rear-panel physical layout: [`panel-layout.md`](panel-layout.md)
- Procurement tracker (authoritative for state, supplier links, lot codes): `Parts List.xlsx`

## Open BOM questions

**Part-lock pass complete — 2026-06-12.** Every placeholder below is resolved to a specific part; remaining items are deliberate deferrals, not gaps.

- ~~Production BNC (75 Ω).~~ **Molex 73101-0120** (R/A PCB bulkhead, board-locks) — all 13+ BNC. **Second source:** Amphenol RF **031-70352** (equivalent 75 Ω R/A TH bulkhead rear-mount) — drop-in, confirmed 2026-06-13.
- ~~HDMI panel-mount connector.~~ **Amphenol ICC 10029449-001RLF** (Type A R/A) ×2.
- ~~Per-rail buck family.~~ LMR33640 (5 V + 3.3 V), TLV62568 (1.2 V), TPS7A2018 / ADP7142 LDOs; **TPS26601** eFuse (swapped from '600 2026-06-13b — latch default). See §3.
- ~~12-bit SYNC DACs / cable drivers.~~ AD9742 (SYNC 1); LMH6643 driver (both OUTs); SYNC 2 LTC-only.
- ~~Front TFT module.~~ **Newhaven NHD-2.9-376960AF-ASXP** + BT817Q EVE (§4).
- ~~Rear LCD module.~~ **Newhaven NHD-1.5-240240AF-CSXP**, 4-wire SPI (§4).
- ~~Power button.~~ **E-Switch PV6** 16 mm illuminated momentary + LTC2954-1.
- ~~Tactile switches.~~ **C&K PTS645SM43SMTR92LFS** + caps.
- ~~Rear status LED.~~ **Lumex SSF-LXH409SISUGW** (3 mm bi-color R/G, **common-anode, one-piece right-angle PCB indicator** — faces the rear panel, no holder; selected 2026-06-13c, replaces the bare Kingbright L-3VEGW-CA).
- ~~RJ45 mag jack.~~ **Pulse JXD1-0001NL** (Gig).
- ~~USB-C connector.~~ **GCT USB4085-GF-A** + TPD4S014 ESD.
- ~~Chassis vendor.~~ **Hammond** 1U full-rack.
- ~~Si5351 variant.~~ **Si5351A-B-GTR** (confirmed, both instances).
- ~~RP2040 form factor.~~ **Bare RP2040 QFN + W25Q128JVSIQ flash + 12 MHz xtal** (production; both genlock + mezzanine).

**Remaining (deliberate, not netlist-blocking):**
- **FCC emissions class** — defaulting to **Class B** design margin (stricter, no market restriction); relax to Class A only if you want filter margin back. Decide pre-layout.
- **Antenna final MPN** — Linx ANT-DB1 pending confirmation against the **LWB5+ FCC grant antenna list**.
- **Production knob** — post-UX-eval aesthetic pick (5 eval knobs in hand); shaft-mount, no netlist impact.
- **Front/rear panel** — Front Panel Express fab deliverables from `panel-layout.md`, not catalog MPNs.
- **Procurement-final suffixes** — exact orderable suffixes (BNC packaging, E-Switch PV6 color/voltage) picked at order time.
