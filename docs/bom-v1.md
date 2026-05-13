# Schindler 2.0 — Bill of Materials

**Status:** Draft 2026-05-13
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
- **Chip 1:** `TPD12S016PWR` — HDMI ESD clamps + DDC/HPD level shift + 5V cable-power switch — TI — ~$1.50 — ✅
- **Chip 2:** `LT8619C` — HDMI 1.4 RX, parallel RGB out, embedded HDCP 1.4 keys — Lontium — ~$2 — ✅ (raw chip + LT8619C-EVB)
- **Connector:** HDMI Type A panel-mount — ❓

### SDI Input *(broadcast tier — factory-populated option)*
- **Chip 1:** `GS3470` — SDI receiver (3G-SDI); recovers clock + VITC; feeds video path AND genlock subsystem — Semtech — ~$15 — 📋
- **Connector:** BNC 75 Ω panel-mount — ❓ production part; `0731711900` (straight) / `0731010401` (right-angle) on order for prototype — 🔬

### Composite + Component Input
- **Chip 1:** `ADV7280AWBCPZ-M-RL` — multi-format analog decoder (CVBS / YPbPr / S-Video → BT.656 YCbCr 4:2:2 over parallel bus); AEC-Q100 auto grade; `-M` variant adds MIPI option — Analog Devices — ~$19 — ✅
- **Connectors:** 4× BNC 75 Ω panel-mount (1× CVBS + 3× YPbPr) — ❓ production part
- **Passives:** input clamp diodes, switchable 75 Ω terminations, AC-coupling caps, anti-alias LPF — schematic-phase

### FPGA Fabric (Zynq-7020)
All compute / pipeline blocks run inside the Zynq-7020 silicon carried on the TE0720 SOM.

- **SoC module:** Trenz **TE0720-04-62I33MA** — production target (Zynq-7020 -2I industrial, 1 GB DDR3L, 8 GB eMMC, 32 MB QSPI, GbE PHY on-module, 152 FPGA I/O via Samtec Razor Beam) — ~$300 — 📋
- **SoC module (bench):** Trenz **TE0720-04-31C33MA** — commercial -1 speed grade, same memory config, identical pinout — ~$230 — 📋
- **Heatsink:** Trenz **33337** springloaded — passive thermal — ✅
- **HDL blocks** (Xilinx IP, free): AXI VDMA, HDMI 1.4 TX
- **HDL blocks** (custom, in `hdl/`): polyphase scaler (8-tap H / 4-tap V), color pipeline (1024-entry gamma LUT + 3×3 matrix + per-channel trim), geometry (pincushion / keystone / 4-corner warp), test pattern generator (`sample_gen.v`), NTSC raster (`vid_timing.v` + `vbi_gen.v`), NTSC chroma (`chroma_gen.v`), luma+chroma combiner (inline in `top.v`)

### Analog Video Output (Composite + Component + S-Video)
- **Chip 1:** `ADV7393BCPZ-REEL` — output DAC/encoder; one chip serves composite/S-Video OR component, runtime mode-switched via I²C — Analog Devices — ~$16 — ✅
- **Chip 2 (SDTV buffers):** `OPA2350UA/2K5` — dual op-amp, 38 MHz GBW, rail-to-rail, for composite + S-Video buffer stages — TI — ~$5/dual — ✅ (5× prototype stock)
- **Chip 3 (HD buffers):** `LMH6643MAX/NOPB` — voltage-feedback op-amp, 130 MHz BW, low distortion, for component + SDI-adjacent stages — TI — ~$1.50/dual — ✅ (10× prototype stock)
- **Connectors:** 4× BNC 75 Ω panel-mount (1× CVBS + 3× YPbPr) — ❓ production part
- **Note:** S-Video out is generated free from ADV7393 in composite mode (Y + C on two DAC channels) but the mini-DIN connector was dropped from V1 panel.

### SDI Output *(broadcast tier — factory-populated option)*
- **Chip 1:** `GS2962` — SDI transmitter (3G-SDI); processed output, not passive loop-through — Semtech — ~$17 — 📋
- **Connector:** BNC 75 Ω panel-mount — ❓ production part

### HDMI Output (Monitoring/Analysis)
- **Chip 1:** `TPD12S016PWR` — HDMI ESD + level shift (same part as input) — TI — ~$1.50 — ✅
- **HDMI TX core:** Xilinx free HDMI 1.4 TX IP — FPGA-internal, no separate chip
- **Connector:** HDMI Type A panel-mount — ❓

### Section subtotal (silicon only, per V1 unit)

| Item | Base | Broadcast |
|---|---:|---:|
| TPD12S016 ×2 | $3 | $3 |
| LT8619C ×1 | $2 | $2 |
| ADV7280 ×1 | $19 | $19 |
| ADV7393 ×1 | $16 | $16 |
| Output buffers (mix OPA2350 + LMH6643) | ~$12 | ~$12 |
| GS3470 ×1 | — | $15 |
| GS2962 ×1 | — | $17 |
| **Signal-path silicon** | **~$52** | **~$84** |

---

## 2. Sync Subsystem

Per `signal-flow.md` diagram 2 — genlock + dual SYNC OUT.

### Reference Input (Genlock Front-End)
- **Chip 1:** `LTC6912CGN-2#PBF` — 2-channel programmable gain amplifier; AGC loop driven by classifier — Analog Devices (Linear Tech) — ~$8 — ✅
- **Chip 2:** `AD9204BCPZ-20` — dual 10-bit 20 MSPS ADC; pin-compatible upgrade path to AD9231/9251/9258/9268 for 12/14/14/16-bit if future need — Analog Devices — ~$16 — ✅
- **Eval boards:** **MIKROE-2555** ×2 (LTC6912 GainAMP click, ~$25 ea) + **AD9204-80EBZ** (AD9204 eval, ~$278, 80 MSPS bench variant) — 🔬
- **Connectors:** 2× BNC 75 Ω panel-mount (REF IN + REF LOOP) — ❓ production part
- **Passives:** clamp diodes, switchable 75 Ω term, AC-coupling, switchable analog LPF — schematic-phase

### Slow Control + Clock Generation
- **Chip 1:** RP2040 — microcontroller for autosense slow-control, PGA gain commands, Si5351 register writes, status reporting to Zynq PS — Raspberry Pi — ~$1 — 📋 (verify on-hand from prior projects)
- **Chip 2:** **Si5351A-B-GT** (or similar) — 3-channel programmable clock generator; ch0 → FPGA master, ch1+ch2 reserved — Skyworks/Silicon Labs — ~$2 — 📋 production
- **Eval boards:** **Adafruit 2045** Si5351 breakout ×2 — 🔬

### Genlock Loop Core
All in FPGA fabric — no discrete chips. Listed for completeness.
- Autosense classifier (LTC biphase / BB 15.734 kHz / tri-level signature)
- Per-format decoders: LTC frame decoder, BB sync separator, tri-level decoder, SDI recovered clock+VITC (from GS3470)
- Reference selector mux (operator override + autosense priority)
- Digital PLL: phase/frequency detector, loop filter (~0.5 Hz default), NCO/integrator, lock detector (state machine + quality metric)

### Dual SYNC OUT Generation
- **Chip 1 (×2, one per OUT):** 12-bit DAC — `AD9744` class or PWM+LPF — Analog Devices — ❓ specific part pending evaluation
- **Chip 2 (×2, one per OUT):** 75 Ω cable driver — `ADV3000` / `EL5170` / `THS6212` class — ❓ specific part pending
- **Connectors:** 2× BNC 75 Ω panel-mount (SYNC OUT 1 + SYNC OUT 2) — ❓ production part
- **Per-OUT phase accumulator + waveform gen:** FPGA fabric, no discrete chip

### Section subtotal

| Item | Per unit |
|---|---:|
| LTC6912 ×1 | $8 |
| AD9204-20 ×1 | $16 |
| RP2040 ×1 | ~$1 |
| Si5351 ×1 | ~$2 |
| 12-bit DAC ×2 | ~$8 (est.) |
| 75 Ω cable driver ×2 | ~$6 (est.) |
| **Sync-subsystem silicon** | **~$41** |

---

## 3. Power

Per `01-spec.md` Power & safety section.

### AC Entry
- **Connector:** Schaffner **FN9260B-6-06** — IEC C14 + 6 A rating + integrated fuse holder + 1-stage EMI filter, panel-mount — ~$18 — ✅ (2 on order)
- **Fuse:** 2 A T (time-lag), 5×20 mm cartridge — generic — ~$1 — 📋

### PSU Module
- **Module (primary):** Mean Well **LRS-50-12** — 50 W / 12 V single output, 85–264 VAC universal, enclosed aluminum case, convection-cooled, UL 62368-1, EN 55032 Class B — ~$15–20 — ✅
- **Module (alternate / lower-noise swap-in):** TDK-Lambda **HWS50A-12/A** — same form factor, lower switching noise for pro-audio-adjacent applications if bench characterization shows the Mean Well noise floor as audible — ~$50 — 📋
- **PSU → Carrier connector:** Molex **Mini-Fit Jr.** 2-pin locking, 9 A rated — ~$0.80 — ❓ production part

### Carrier 12 V Input Protection Chain
- **Q1 (reverse-polarity FET):** Diodes Inc **DMP3098L-7** — P-channel, −30 V, R<sub>DS(on)</sub> 31 mΩ, SO-8 — ~$0.60 — 📋
- **Gate pulldown:** 100 kΩ standard resistor
- **F1 (polyfuse):** Bourns **MF-MSMF200-2** — I<sub>hold</sub> 2 A / I<sub>trip</sub> 4 A, 16 V, SMD — ~$0.40 — 📋
- **D1 (TVS):** Littelfuse **SMBJ12A** — unidirectional, V<sub>WM</sub> 12 V, V<sub>C</sub> 19.9 V peak, 600 W, SMB — ~$0.30 — 📋
- **U1 (power monitor):** TI **INA226** — I²C 16-bit current+voltage monitor — ~$1.50 — 📋
- **Sense resistor:** 5 mΩ, 1 % — generic — ~$0.20 — 📋
- **C bulk:** 3× Murata **GRM32** 22 µF 25 V X7R MLCC in parallel (~66 µF total) — ~$2.40 — 📋

### Per-Rail Regulators (Downstream of 12 V)
Selected at carrier-schematic time. Placeholders:
- **5 V buck** (~3 A) — TBD (USB host power, fan, analog op-amps) — ❓
- **3.3 V buck** (~2 A) — TBD (most digital I/O, LEDs, low-power analog) — ❓
- **1.8 V buck** (~3 A) — TBD (FPGA bank Vcco, DDR3L Vddq) — ❓
- **1.35 V buck** (~1 A) — TBD (DDR3L Vdd) — ❓
- **1.0 V buck** (~3 A) — TBD (FPGA Vccint) — ❓
- **VAUX LDOs** — TBD (AD9204 1.8 V analog, ADV7280 analog, op-amp ±supplies) — ❓

### Section subtotal

| Item | Per unit |
|---|---:|
| FN9260B-6-06 ×1 | $18 |
| Fuse | $1 |
| PSU module (LRS-50-12 primary / HWS50A-12/A alternate) | $15–50 |
| Carrier protection chain | ~$6 |
| Per-rail regulators (est.) | ~$15 |
| **Power subsystem total** | **~$60–90** |

---

## 4. UX / Panel I/O

### Front Panel
- **TFT display:** 2.8" or 3.5" color TFT, ILI9341 SPI (prototype) → LTDC parallel (production) — ❓ specific module
- **Encoders:** 2× Alps **EC11E18244AU** — 36 detents / 18 PPR, integrated push switch, -40 to +85°C industrial — ~$3 ea — ✅ (5 on order)
- **Encoder alternates for UX testing:** **3315Y-025-016L** ×2, **EC111012010H** ×1 — ✅
- **Knob options for evaluation:** CP34501, FC7229NML, CL178883, FC1611, 1202CY (production knob selection deferred) — ✅
- **Buttons:** 4× tactile (Home, Back, Menu, Confirm) + 2–3 quick-select (Output Mode, EDID Profile, Genlock Source) — ❓ specific tactile switch
- **Front status LED column:** mirrors rear per-connector LED state — driven by UI MCU GPIO via same TLC59116F state pushed from Zynq
- **Power button:** lighted soft button, lower-left — ❓
- **UI MCU:** STM32 **STM32H735IGT6** — LQFP176, 480 MHz Cortex-M7 — ~$8 — 📋 production
- **UI MCU eval board:** **STM32H735G-DK** ~$70 — 🔬
- **Knob shroud / guard:** mechanical, recessed encoder pocket (HARD REQUIREMENT — must survive face-down drop in road case) — schematic+chassis phase

### Rear Panel — Status Display
- **LCD:** 2.4" 16:9 IPS TFT, ~50 × 30 mm bezel-to-bezel, SPI driver — ❓ specific module (ILI9341 / ST7789 class)
- **Mounting:** recessed bezel cutout with anti-glare film
- **Owner:** Zynq PS via dedicated SPI port, ~1 s refresh, read-only status grid

### Per-Connector Status LEDs
- **LED:** Tricolor R/A/G, 3 mm body, recessed bezel — qty ~21 (one per rear connector) — ~$0.20 ea — ❓ specific part
- **Driver chips:** 3× TI **TLC59116F** — 16-channel constant-current with per-channel PWM dimming — ~$1.50 ea — 📋
- **Bus:** I²C from Zynq PS

### Section subtotal

| Item | Per unit |
|---|---:|
| Front TFT | ~$15 (est.) |
| 2× Alps EC11 encoder | $6 |
| 4 tactile + 3 quick-select buttons | ~$3 |
| Power button | ~$3 |
| STM32H735IGT6 | $8 |
| Rear LCD 2.4" | ~$15 (est.) |
| 21× tricolor LEDs | ~$4 |
| 3× TLC59116F | $4.50 |
| Knob hardware | ~$10 (est.) |
| **UX/Panel subsystem total** | **~$70** |

---

## 5. Control + Networking

### Wired Control
- **GbE PHY:** integrated on TE0720 SOM (no external PHY needed) — 📋
- **RJ45 jack with magnetics:** chassis-mount — ❓
- **USB-C service port:** USB Type-C panel-mount + protection (ESD + overcurrent) — ❓

### Wireless
- **WiFi/BT module:** Laird Sterling **LWB5+** — pre-certified, 88W8997 chipset, dual-band a/b/g/n/ac + BT5.0, SDIO interface to Zynq PS — ~$30 — 📋
- **Antennas:** 2× RP-SMA panel-mount + stub antennas — ❓ specific part — ~$5 ea

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
- **Chassis:** 1RU full-rack 19" extruded aluminum body — Hammond or similar — ~$50–80 — ❓
- **Front panel:** Front Panel Express milled aluminum, anodised, silkscreened — per playbook Ch. 10 pattern — ~$40 — ❓
- **Rear panel:** Front Panel Express milled aluminum, panel cutouts for all rear I/O — ~$60 — ❓
- **Rack ears:** integrated with chassis or aftermarket — ~$10 — ❓

### Thermal
- **Fan:** Noctua **NF-A4x20 PWM** — 40 mm, ~14 dB low RPM, conditional/silent (only spins on SOM temp threshold) — ~$15 — 📋
- **SOM thermal pad:** silicone gap pad between Zynq SOM and chassis top cover (top acts as primary heatsink for fanless operation at typical 14–16 W load) — ~$2 — 📋

### Hardware
- **M3 standoffs** for PSU mounting (×4) and carrier PCB mounting (×6–8) — generic — ~$3 total — ❓
- **Earth bonding stud** for chassis ground — M4 brass stud — ~$1 — ❓
- **Mounting screws** (mix of M3 panhead + M2.5 for board mounts) — generic — ~$3 — ❓

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

## 7. RF Modulator Output *(built-in, all V1 SKUs)*

Built into every V1 carrier as a standard subsystem. Adds an RF modulated output on NTSC Ch3 or Ch4 (operator-selectable) for 1970s consumer CRTs with antenna-only inputs. Replaces the earlier daughter-card framing per 2026-05-11 PM commit. Full architecture spec in [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md); spec entry in [`01-spec.md`](01-spec.md) under "RF modulator output (built-in)".

**Operator picks one of three analog output modes** via UI: composite (BNC live), RF Ch3 / RF Ch4 (F-connector live, ADV7393 stays in composite mode), or component (3× component BNC live, ADV7393 in component mode). HDMI and SDI remain independently live. F-connector lives beside the composite BNC on the rear panel.

### Modulator + carrier generation
- **AM modulator (primary):** `ADL5391ACPZ-R7` — Analog Devices, DC–2.0 GHz analog multiplier, modern symmetric-core architecture, 16-LFCSP, 7" reel cut for single qty — ~$15 single qty / ~$18 at qty 100 — 📋
- **AM modulator (fallback):** `AD835ARZ` — Analog Devices, 250 MHz four-quadrant multiplier, 8-SOIC, classic part with abundant reference designs — ~$25 at qty 100 — 📋 (order one of each for bench eval)
- **RF carrier gen:** `Si5351A-B-GT` — dedicated to RF subsystem (separate from genlock Si5351 to avoid cross-coupling) + 25 MHz crystal — Skyworks/Silicon Labs — ~$2 — 📋
- **Si5351 channel allocation:** ch1 = video carrier (Ch3 61.25 MHz / Ch4 67.25 MHz), ch2 = audio pilot CW (Ch3 65.75 MHz / Ch4 71.75 MHz), ch0 free.

### RF chain
- **RF amp:** Mini-Circuits **ERA-3SM+** — MMIC, DC–3 GHz, ~22 dB gain, SOT-89, 50 Ω native — ~$3.50 — 📋
- **Output bandpass filter:** 5th-order LC, centered ~64 MHz, passband 56–73 MHz (covers Ch3 + Ch4 video + audio carriers; naturally suppresses 2nd harmonics at 122.5–134.5 MHz) — Coilcraft 0805CS class inductors + C0G ceramic caps, ~9 parts — ~$1.50 — ❓ final topology (Chebyshev vs Butterworth) TBD bench-eval phase
- **50→75 Ω MLP (minimum-loss pad):** 43.2 Ω series + 86.6 Ω shunt resistors (off-the-shelf 43 Ω + 82 Ω 1% is close enough). Two 1% resistors total. 5.7 dB insertion loss — mathematically optimal for resistive 50↔75 Ω conversion. Broadband DC-to-GHz, no tuning, no drift. ERA-3SM+ has 22 dB gain headroom so pad loss is rounding error. **Replaces prior transformer option** (TC4-1W+/MABAES0061 are 1:4 ratio = 50↔200 Ω, NOT 50↔75 — confirmed by datasheet 2026-05-11 PM). — ~$0.10 — 📋
- **Audio combiner:** 3-resistor resistive combiner that sums Si5351 ch2 audio pilot CW with ADL5391 output before bandpass filter — generic resistors — ~$0.50 — 📋

### Mode-mux silicon (composite/RF/component selection)
- **Composite BNC gate:** `ADG419BRZ` — Analog Devices SPST analog switch, ~50 ns switching, ~30 Ω on-resistance — ~$1.50 — 📋 (driven by Zynq PS GPIO; open in RF mode + component mode, closed in composite mode)
- **RF amp gate:** small-signal FET on ERA-3 bias-inductor supply — ~$0.30 — 📋 (driven by separate Zynq PS GPIO; active in RF mode, off otherwise)
- **ADV7393 mode:** I²C-switched between composite mode (serves composite BNC + RF) and component mode (serves 3× component BNC) — no additional silicon, configuration only

### Output protection + connector
- **DC block on RF output:** C0G 0.1 µF 50 V MLCC — generic — ~$0.10 — 📋
- **ESD on F-conn:** `PESD3V3L1BA` low-cap TVS or equivalent — NXP — ~$0.20 — 📋
- **F-connector:** Amphenol RF **82-4421** class panel-mount 75 Ω, threaded — ~$1.50 — 📋

### Shielding
- **Shield can:** Wurth WE-SHC or Laird small-format (~25×25 mm) with frame, over modulator + amp + dedicated Si5351 + bandpass filter section — ~$2.50 — 📋 (required for FCC Part 15.119 compliance — not optional)

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

### Section subtotal (per V1 unit, all SKUs)

| Item | Per unit |
|---|---:|
| ADL5391ACPZ-R7 (primary modulator) | $18 |
| Si5351A-B-GT + 25 MHz crystal (RF-dedicated) | $2 |
| ERA-3SM+ RF amp | $3.50 |
| Output bandpass filter (LC passives) | $1.50 |
| 50→75 Ω MLP (2 resistors) | $0.10 |
| Audio combiner passives | $0.50 |
| Mode-mux (ADG419 + bias FET) | $1.80 |
| F-connector + ESD + DC block | $1.80 |
| Shield can + frame | $2.50 |
| Bypass / decoupling passives | $1 |
| **RF subsystem total** | **~$32** |

Built into every V1 unit (Base + Broadcast). No daughter card, no mezzanine connector, no separate PCB.

### Open BOM questions
- **Final modulator chip:** ADL5391 vs AD835 — prototype-characterization decision after bench eval.
- **Output bandpass topology:** Chebyshev (steeper rolloff, more passband ripple) vs Butterworth (flat passband, gentler rolloff) — synthesize after measuring actual harmonic content from the prototype modulator.
- **Audio FM modulation in V1.x:** if customer evidence drives audible audio (Path B from 2026-05-11 audio analysis: discrete Colpitts VCO + FPGA-generated 1 kHz tone via PWM + LPF, ~$3 BOM, ~1 day HDL), it's documented as the next step. 2-channel BTSC stereo explicitly rejected for V1 (period sets are mono).
- **Channel-selection UI surface:** front-panel Ch3/Ch4 toggle button vs web-only — defer to UI spec phase.

---

## V1 Pro Full BOM Roll-Up (typical)

| Section | Base unit | Broadcast unit |
|---|---:|---:|
| 1. Signal Path silicon | ~$52 | ~$84 |
| 2. Sync Subsystem silicon | ~$41 | ~$41 |
| 3. Power | ~$75 | ~$75 |
| 4. UX / Panel I/O | ~$70 | ~$70 |
| 5. Control + Networking | ~$46 | ~$46 |
| 6. Chassis + Mechanical | ~$200 | ~$200 |
| 7. RF Modulator Output *(built-in)* | ~$32 | ~$32 |
| **Subtotal (parts only)** | **~$516** | **~$548** |
| TE0720 SOM (production grade) | $300 | $300 |
| **V1 unit total (parts)** | **~$816** | **~$848** |

**Excluded from this BOM:** carrier PCB fabrication + assembly cost (~$80–150 per board at qty 100 per playbook Ch. 10), labor / test / packaging / shipping, NRTL end-product certification cost amortization, software development, marketing — these all sit outside the parts roll-up.

**At Schindler's expected ~$2,500 retail / pro market positioning, parts cost of ~$800 = ~32 % BOM-to-retail ratio**, which is healthy for niche broadcast hardware (industry norm 25–40 %).

---

## Cross-references

- Architecture rationale + decision history: [`01-spec.md`](01-spec.md) + [`01-spec-changelog.md`](01-spec-changelog.md)
- Block-level signal flow: [`signal-flow.md`](signal-flow.md)
- Rear-panel physical layout: [`panel-layout.md`](panel-layout.md)
- Procurement tracker (authoritative for state, supplier links, lot codes): `Parts List.xlsx`

## Open BOM questions

- **Production BNC part** (75 Ω panel-mount) — current prototype uses Molex `0731711900` / `0731010401`. Pick a production-volume part once carrier mech is set.
- **HDMI panel-mount connector** — specific part TBD.
- **Per-rail buck converter family** — TI TPS / ADI LTC family TBD per carrier schematic.
- **12-bit DACs for SYNC OUT generation** — AD9744 class identified, specific part pending evaluation.
- **75 Ω cable drivers for SYNC OUT** — ADV3000 / EL5170 / THS6212 candidates, pick one at schematic phase.
- **Front TFT module** — 2.8" or 3.5" specific module TBD.
- **Rear LCD module** — 2.4" 16:9 SPI specific module TBD.
- **Power button** — lighted soft pushbutton, specific part TBD.
- **Tactile switches** for 4 fixed + 2-3 quick-select buttons — specific part TBD.
- **Rear status LED part** — tricolor R/A/G 3 mm, specific manufacturer TBD.
- **RJ45 mag jack** — specific part TBD (consider Pulse / Bel Fuse).
- **USB-C connector** — specific part TBD (consider Amphenol or Wurth).
- **Chassis vendor** — Hammond / Bud / Italtronic class — final selection TBD.
- **Si5351 production variant** vs `Si5351A-B-GT` placeholder — confirm at schematic phase.
- **RP2040 board form factor** — bare chip on carrier vs YD-RP2040 / SparkFun / Adafruit feather module — TBD.
