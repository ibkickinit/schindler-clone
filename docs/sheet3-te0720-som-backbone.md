# Schindler 2.0 Carrier — Sheet 3 (TE0720 SoM) Backbone & JM Pin Map

**Status:** v2 (2026-06-11). The load-bearing reference for the carrier↔SoM interface.
Every other sheet's nets terminate here. Pin assignments below are authoritative for power/config
(fixed by the module) and **proposed-permutable** for bank I/O (any single-ended signal may be
swapped to another free pin **in the same bank** during layout for routability — the XDC is
generated from the *final* schematic, so the schematic is the source of truth, not this draft).

> **v2 changes (2026-06-11):** Outputs are now **fully independent** — HDMI OUT, SDI OUT, and
> analog OUT each have their own FPGA read engine and parallel bus; the old shared ADV7511/ADV7393
> output bus is retired. Sync resolved to **one 12-bit DAC (SYNC 1, BB/tri/LTC selectable) + one
> LTC-only output (SYNC 2)**; PWM dropped. Analog OUT locked at **16-bit** (HD component). ADV7511 is
> the **KSTZ LQFP-100** (leaded, no BGA). Banks re-laid as **input bank (B35) / output bank (B13) /
> Pro bank (B34) / genlock (B33)**; ADV7280 moved B13→B35.

**Sources (authoritative):**
- `SCH-TE0720-04-31C33MA.pdf` — Trenz GigaZee schematic, REV04 (pinout-identical to production -04-62I33MA). B2B map = p5; bank↔ball = p6–8; power = p19–20.
- `4x5_series_teba0841_pinout_tracelength.xlsx`, sheet `RAW_m_TE0720_REV04` — machine-readable JM pin→net.
- `pin-budget.md`, `01-spec.md` — interface widths, MMCM ceiling.

---

## 1. Decisions locked (2026-06-11)

| Decision | Value |
|---|---|
| VCCIO13 / 35 | **3.3 V** (LVCMOS33). |
| **VCCIO33** | **1.8 V** (LVCMOS18) — re-strapped 2026-06-13 for the AD9204 1.8 V CMOS interface (DRVDD = 1.8 V; module allows VCCIO33 = 1.2–3.3 V on bank 33). Fed from a dedicated carrier **`+1V8_D`** digital LDO, separate from analog `+1V8_A`. |
| **VCCIO34** | **1.8 V** (LVCMOS18) — re-strapped 2026-06-13e: GS3470 SDI-RX I/O maxes at 2.5 V (1.8/2.5) and GS2962 SDI-TX does 1.8/3.3 — only common I/O voltage is **1.8 V**. AD9742 (3.3 V-only DAC) moved off B34 → B35 (see §5). Both GS chips set to 1.8 V I/O; module allows VCCIO34 = 1.5–3.3 V. Fed from `+1V8_D`. |
| **Output architecture** | **All three outputs independent** — HDMI OUT, SDI OUT, analog OUT each have their own FPGA read engine + parallel bus. **No bus sharing.** Retires the old shared ADV7511/ADV7393 bus. |
| HDMI IN | **LT8619C** PHY → parallel YCbCr 4:2:2 (16-bit) to PL |
| HDMI OUT | **ADV7511KSTZ (LQFP-100)** PHY ← its own 16-bit parallel bus |
| Analog OUT | **ADV7393** ← its own **16-bit** parallel bus (composite/S-Video SD + component SD/ED/HD) |
| SDI (Pro) | **GS3470 RX / GS2962 TX, parallel, 10-bit DDR** (both natively support it; PCLK 148.5 MHz, same as 20-bit SDR, half the pins) |
| SYNC OUT (Pro) | **SYNC 1 = 12-bit DAC** (runtime BB / tri-level / LTC, 13 pins) · **SYNC 2 = LTC-only** (1-bit → slew-limited op-amp, 1 pin). PWM dropped — can't reproduce BB colorburst / tri-level edges. |
| Genlock IN | **anything-in** (LTC / black burst / tri-level / SDI-VITC), autosensed, **fed to the SoM** — FPGA does the DSP. Sub-board hand-off considered and **rejected**. |
| Each PL bank lives on **one** connector | B35→JM1, B13→JM2, B33→JM2, B34→JM3 |

---

## 2. Power architecture

**Carrier → module (mandatory inputs):**

| Net | JM pins | Notes |
|---|---|---|
| VIN | JM1-1, JM1-3, JM1-5, JM2-2, JM2-4, JM2-6, JM2-8 | **feed from carrier 5 V rail** (input range 3.3–5 V) |
| 3.3VIN | JM1-13, JM1-15, JM2-91 | 3.3 V |
| NOSEQ | JM1-7 | tie high → no-sequencing mode (VIN / 3.3VIN come up independently) |

> **VIN from 5 V (decided 2026-06-11):** VIN feeds the on-module DC-DCs that generate Vccint 1.0 V,
> 1.8 V, and DDR3L 1.35 V; 3.3VIN separately feeds the module's 3.3 V domains. Feeding VIN from the
> carrier **5 V** rail (not 3.3 V) keeps the heavy SoM current on the 5 V rail and runs the on-module
> bucks at lower duty (5→1.0 V), so the 3.3 V rail only carries 3.3VIN + VCCIO + carrier digital. NOSEQ
> high lets the two inputs come up independently.

**Carrier → module (VCCIO bank supplies):**

| Bank | VCCIO net | V | JM pins |
|---|---|---|---|
| 13 | VCCIO13 | 3.3 V | JM2-7, JM2-9 |
| 33 | VCCIO33 | **1.8 V** (`+1V8_D`) | JM2-5 |
| 34 | VCCIO34 | **1.8 V** (`+1V8_D`) | JM2-1, JM2-3 |
| 35 | VCCIO35 | 3.3 V | JM1-9, JM1-11 |

> **B33 = 1.8 V (re-strapped 2026-06-13):** the AD9204 runs DRVDD = 1.8 V (1.8 V CMOS outputs), which won't clear a 3.3 V LVCMOS bank's ~2.0 V VIH. VCCIO33 is carrier-supplied on JM2-5 and the module permits 1.2–3.3 V on bank 33, so it's fed **1.8 V** (`+1V8_D` digital LDO) — the ADC data + DCO land native LVCMOS18, no level translator. SYNC2_LTC out (the only B33 output) at 1.8 V drive is fine — the slew-limited op-amp sets the BNC amplitude. The LTC6912 PGA SPI is **not** in B33 (RP2040-mastered — see §7).

> **B34 = 1.8 V (re-strapped 2026-06-13e):** the GS3470 SDI-RX I/O is selectable **1.8 V or 2.5 V** (no 3.3 V), the GS2962 SDI-TX is **1.8 V or 3.3 V** — the only I/O voltage both share is **1.8 V**. The original 3.3 V VCCIO34 would not have interoperated with the GS3470. So VCCIO34 is re-strapped to **1.8 V** (module allows 1.5–3.3 V on B34; 1.8 V > the 1.5 V floor), both GS chips strapped to 1.8 V I/O, native LVCMOS18 to the FPGA — no translator. The **AD9742 SYNC-1 DAC can't run ≤1.8 V** (2.7–3.6 V single-supply part), so it **moves off B34 → B35** (3.3 V) — see §5. Fed from `+1V8_D` (resized to cover B33 + B34). SDI parallel + DAC-clock at LVCMOS18 / ~148 MHz-class is SI-sensitive — short/matched at layout.

> VCCIO34 lives on **JM2** even though bank-34 signals are on **JM3** — route VCCIO34 across to the
> bank-34 decoupling near JM3.

**Module → carrier (outputs you may tap, ~1 A each):**

| Net | JM pin | Use |
|---|---|---|
| 3.3V | JM2-10, JM2-12 | light housekeeping / pull-ups |
| 1.8V | JM1-39 | light housekeeping only — **not** the analog 1.8 V (AD9204/ADV7280 get their own clean LDO) |
| 1.5V (DDR_PWR) | JM2-19 | spare |
| VREF_JTAG | (=3.3 V) | JTAG level ref |
| VBAT_IN | JM1-79 | RTC coin cell (optional) |

**TE0720 module pin electrical ranges (datasheet, for reference — logged 2026-06-13):**

| Pin | Dir | Range | Domain |
|---|---|---|---|
| VIN | IN | 3.3–5 V ±5% | micromodule power (carrier feeds from 5 V) |
| 3.3VIN | IN | 3.3 V ±5% | micromodule power |
| VCCIO13 | IN | 1.2–3.3 V | HR I/O bank 13 |
| VCCIO33 | IN | 1.2–3.3 V | HR I/O bank 33 *(→ strapped 1.8 V, see above)* |
| VCCIO34 | IN | **1.5–3.3 V** | HR I/O bank 34 — **mandatory** *(→ strapped 1.8 V, see above)* |
| VCCIO35 | IN | 1.2–3.3 V | HR I/O bank 35 |
| VBAT_IN | IN | 2.5–5 V | RTC coin cell |
| 1.8V | OUT | 1.8 V ±5% | carrier periphery (light housekeeping) |
| 3.3V | OUT | 3.3 V | carrier periphery |
| DDR_PWR | OUT | 1.5 V | carrier periphery |
| VREF_JTAG | OUT | 3.3 V ±5% | tied to 3.3VIN |

Note: **VCCIO34 floors at 1.5 V** (not 1.2 V like the other HR banks) and is mandatory-powered; banks 13/33/35 accept 1.2–3.3 V. The 1.5 V floor still permits **B34 = 1.8 V** (the SDI re-strap), and the 1.2 V floor on B33 permits **B33 = 1.8 V** (the AD9204 re-strap).

**Corrected carrier power tree (Sheet 2):** 5 V, **3.3 V (now the big rail — feeds the whole SoM, size ~2–3 A)**, **1.8 V analog (`+1V8_A` — AD9204 AVDD / ADV7280 / ADV7393 PLL)**, **1.8 V digital (`+1V8_D`, new 2026-06-13 — VCCIO33 + VCCIO34 + AD9204 DRVDD; LDO off 3.3 V, kept off the analog 1.8 V; resized 2026-06-13e for the B34 output load)**, 1.2 V (GS3470/GS2962 core), analog LDOs. **1.0 V and 1.35 V are deleted — they are on-module.**

---

## 3. Config / debug / strap pins

| Function | Net | JM pin | Handling |
|---|---|---|---|
| Module power-enable | EN1 | JM1-28 | drive from front-panel soft-power logic (or tie high to auto-start) |
| Module power-good | PGOOD | JM1-30 | status input to carrier housekeeping |
| Boot-source strap | MODE | JM1-32 | to on-module SC — sets QSPI/SD/JTAG boot |
| JTAG-mode strap | JTAGMODE | JM1-89 | to on-module SC |
| Reset in | RESIN | JM2-18 | carrier reset / POR button |
| JTAG TMS | X_TMS | JM2-93 | 10-pin Xilinx header |
| JTAG TDI | X_TDI | JM2-95 | " |
| JTAG TDO | X_TDO | JM2-97 | " |
| JTAG TCK | X_TCK | JM2-99 | " |
| PHY magnetics center tap | PHY_COM | JM1-14 | to RJ45 magjack center tap |

> Boot select on the TE0720 is **SC-strapped via MODE + JTAGMODE**, not raw Zynq MODE[3:0]. §19's
> "boot DIP switch" implements as straps on these two pins.

---

## 4. Fixed PS buses (off-bank, terminate at other sheets)

**Gigabit Ethernet (copper) → RJ45 magjack (Sheet 13):**

| Pair | JM pins |
|---|---|
| PHY_MDI0 P/N | JM1 (MDI0_P / MDI0_N) |
| PHY_MDI1 P/N | JM1 |
| PHY_MDI2 P/N | JM1 |
| PHY_MDI3 P/N | JM1 |

+ PHY_COM (JM1-14) center tap. The **SGMII pins SOUT/SIN P/N on JM3 (the 1000BASE-X / fiber path) are unused.**

**USB 2.0 OTG → USB-C service port (Sheet 13):** OTG-D_P (JM3-47), OTG-D_N (JM3-49), OTG-ID (JM3-51),
VBUS_V_EN (JM3-53), USB-VBUS (JM3-55). On-module ULPI PHY.

**User MIO:**

| Group | Voltage | Nets | JM | Use |
|---|---|---|---|---|
| MIO 500 | 3.3 V | MIO0, MIO9–15 (8) | JM1 | I²C ×2, RP2040 / mezzanine UART, BT UART, WiFi control (WL_REG_ON, host-wake), housekeeping |
| MIO 501 | 1.8 V | MIO40–45 (6) | JM1 | **SDIO0, 4-bit → LWB5+ WiFi** |

> **SDIO resolved (2026-06-11):** the on-module eMMC is on **SDIO1**; the carrier-facing **SDIO0** comes
> out on MIO40–45 (1.8 V, bank 501) — a *free* controller, not shared with eMMC. **LWB5+ WiFi** takes it,
> strapped to 1.8 V SDIO so it wires **directly to MIO40–45 with no level shifter**. BT is a separate UART
> on the 3.3 V MIO group. **microSD is dropped** — only one free SDIO controller exists, and eMMC +
> network + USB-C cover storage/transfer. The 3.3 V MIO group carries I²C, the UARTs, and WiFi control.

---

## 5. Bank allocation

| Bank | IO | Conn | VCCIO | SKU | Assigned bus | Pins |
|---|---:|---|---|---|---|---:|
| **B35** | 48 | JM1 | 3.3 V | all | **Input bank:** HDMI IN (LT8619C, 16-bit YCbCr 4:2:2 + clk + HS/VS/DE, ~20) **+** ADV7280 IN (BT.656 8-bit + LLC, ~9) **+** SYNC OUT 1 (12-bit DAC, 13) [Pro stuff] | ~42 |
| **B13** | 50 | JM2 | 3.3 V | all | **Output bank:** HDMI OUT (ADV7511, 16-bit + clk + sync, ~20) **+** Analog OUT (ADV7393, 16-bit + clk + sync, ~20) — **independent buses** | ~40 |
| **B34** | 36 | JM3 | **1.8 V** | Pro | **SDI bank (LVCMOS18):** SDI IN (GS3470, 10-bit DDR, 11) **+** SDI OUT (GS2962, 10-bit DDR, 11). Both GS chips at 1.8 V I/O. | ~22 |
| **B33** | 18 | JM2 | **1.8 V** | all | Genlock ADC (AD9204, ~11, LVCMOS18) **+** SYNC OUT 2 (LTC, 1). *(LTC6912 PGA SPI is RP2040-mastered — not in B33; see §7.)* | ~12 |

**Total PL ≈ 119 / 152** (heavy Pro: 16-bit analog + DAC sync, all SDI populated). ~33 spare.
Mini (no SDI/sync silicon) uses **B35 + B13 + B33**; Pro adds **B34** (SDI) and the **B35 SYNC-1 DAC stuff**. The SYNC-1 DAC (B35) and the lone SYNC-2 LTC pin (B33) are Pro-only and unpopulated on Mini.

> **Constraint note (revised 2026-06-13e):** Pins are not the binding limit — the **4-MMCM ceiling** is (see §8). Moving the SYNC-1 DAC off B34 → B35 (forced by the B34 = 1.8 V SDI re-strap; the AD9742 is 3.3 V-only) **relieves B34 from 35/36 → ~22/36** and lifts **B35 to ~42/48** (spending the 24-bit-HDMI-in reserve). No bank is tight now; B35 is the fullest at ~42/48.

**Clock-capable lanes per bank** (L11/L14 = SRCC, L12/L13 = MRCC) — every recovered/forwarded clock
must land here:

| Bank | MRCC (L12 / L13) | SRCC (L11 / L14) |
|---|---|---|
| B35 | L12 JM1-77/75, L13 JM1-61/59 | L11 JM1-68/66, L14 JM1-67/65 |
| B13 | L12 JM2-46/48, L13 JM2-56/58 | L11 JM2-51/53, L14 JM2-52/54 |
| B34 | L12 JM3-31/33, L13 JM3-32/34 | L14 JM3-58/60 (no L11) |
| B33 | L12 JM2-25/27, L13 JM2-22/24 | L11 JM2-21/23, L14 JM2-26/28 |

---

## 6. Per-bank pin assignment (v2 — clocks fixed, data permutable in-bank)

All single-ended LVCMOS33 **except B33 and B34 = LVCMOS18** (re-strapped 2026-06-13 / -13e, see §2); each B-lane P and N pin is an independent IO.

### B35 — Input bank: HDMI IN + ADV7280 IN + SYNC OUT 1 [DAC, Pro]
| Signal | Lane / JM pin | Note |
|---|---|---|
| HDMIIN_PCLK | **B35_L13_P / JM1-61** (MRCC) | recovered pixel clock — input, clock-capable required |
| HDMIIN_D[15:0] | B35_L1…L8 (P/N, 16 SE) | YCbCr 4:2:2 16-bit |
| HDMIIN_HS / VS / DE | B35_L9_P / L9_N / L10_P | |
| ADV7280_LLC | **B35_L12_P / JM1-77** (MRCC) | input LLC clock — clock-capable required |
| ADV7280_P[7:0] | B35_L10_N, L14…L17 (8 SE) | BT.656 4:2:2 in (embedded sync) |
| SYNC1_DAC_CLK | **B35_L11_P / JM1-68** (SRCC) | AD9742 sample clock (output, ODDR-forwarded); B35 SRCC, free. Pro-only. *(moved from B34 2026-06-13e — AD9742 is 3.3 V-only, can't sit on the 1.8 V SDI bank)* |
| SYNC1_DAC_D[11:0] | B35_L18…L23 (P/N, 12 SE) | 12-bit → BB / tri-level / LTC waveform. Pro-only; LVCMOS33 → AD9742 (DVDD 3.3 V) |
| spare | L17_N, L24 | (24-bit-HDMI-in reserve now spent by the SYNC-1 DAC — see §8) |

### B13 — Output bank: HDMI OUT + Analog OUT (independent)
| Signal | Lane / JM pin | Note |
|---|---|---|
| HDMIOUT_PCLK | **B13_L12_P / JM2-46** (MRCC) | FPGA-generated, ODDR-forwarded to ADV7511 |
| HDMIOUT_D[15:0] | B13_L1…L8 (P/N, 16 SE) | YCbCr 4:2:2 to ADV7511 |
| HDMIOUT_HS / VS / DE | B13_L9_P / L9_N / L10_P | |
| ANALOGOUT_PCLK | **B13_L13_P / JM2-56** (MRCC) | FPGA-generated, ODDR-forwarded to ADV7393 — **separate clock domain** from HDMI OUT |
| ANALOGOUT_D[15:0] | B13_L11…L18 (P/N, 16 SE) | 16-bit to ADV7393 (HD component) |
| ANALOGOUT_HS / VS / FIELD | B13_L10_N / L19_P / L19_N | external sync to ADV7393 (or embedded SAV/EAV) |
| spare | L20–L25, IO0 (JM2-100), IO25 (JM2-89) | |

### B34 — Pro bank: SDI [10-bit DDR] — **VCCIO = 1.8 V (LVCMOS18)**
| Signal | Lane / JM pin | Note |
|---|---|---|
| SDIRX_PCLK | **B34_L12_P / JM3-31** (MRCC) | GS3470 PCLK in — IDDR capture, clock-capable required |
| SDIRX_D[9:0] | B34_L1, L2, L4, L5, L7 (P/N, 10 SE) | DDR, Y/C time-muxed; **LVCMOS18** (GS3470 I/O = 1.8 V) |
| SDITX_PCLK | **B34_L13_P / JM3-32** (MRCC) | to GS2962 — ODDR forwarded |
| SDITX_D[9:0] | B34_L8, L9, L10, L15, L16 (P/N, 10 SE) | DDR; **LVCMOS18** (GS2962 I/O = 1.8 V) |
| spare | L3, L6, L11, L14, L17, L18 (~14 SE) | B34 relieved 35/36 → ~22/36 after SYNC-1 DAC moved to B35 (2026-06-13e) |
| SDI status/ctrl | GSPI (see §7) | GS3470 LOCKED/STD, GS2962 status — on shared SPI, not extra PL |

### B33 — Genlock [all SKUs] + SYNC OUT 2 [LTC] — **VCCIO = 1.8 V (LVCMOS18)**
| Signal | Lane / JM pin | Note |
|---|---|---|
| ADC_DCO | **B33_L12_P / JM2-25** (MRCC) | AD9204 data clock out (LVCMOS18) — clock-capable required |
| ADC_D[9:0] | B33_L4, L7, L8, L11, L17 (P/N, 10 SE) | AD9204 data, **LVCMOS18** (DRVDD = 1.8 V); see open item below |
| SYNC2_LTC_OUT | B33_L14_P | 1-bit biphase → slew-limited op-amp → BNC (Pro only; unpopulated on Mini). 1.8 V drive; op-amp sets amplitude |

> **LTC6912 PGA SPI is NOT in B33** — it's mastered by the genlock RP2040 (U900) over SPI (§7 + `refdes-map.md` Sheet 9 + spec §3.7). The L18 pins an earlier draft assigned to it are free in B33.

> The genlock loop runs on-SoM: AD9204 → FPGA (autosense + per-format decode + digital PLL) →
> RP2040 → Si5351. The sub-board hand-off (closing the loop off-chip and feeding the SoM a finished
> clock) was considered and rejected — feed-to-SoM keeps the burst-phase/multi-format DSP in fabric.

---

## 7. I²C / SPI / slow-control map

- **I²C bus A (video config):** LT8619C (×3 internal: control/DDC/EDID), ADV7280, ADV7393, ADV7511. **Master = Zynq PS, EMIO-routed.** 2 wires. *(Config bus only — the video data buses to ADV7393 and ADV7511 are independent, see §5. GS3470/GS2962 are **SPI/GSPI**, not on this bus — see the SPI line below; confirmed 2026-06-13. The **genlock Si5351 is NOT on this bus** — it's RP2040-mastered, see I²C bus C; corrected 2026-06-13.)*
- **I²C bus B (housekeeping):** INA226, TLC59116F ×3, front-panel GPIO expander, fan. 2 wires. **Master = Zynq PS.**
- **I²C bus C (genlock, RP2040-mastered):** Si5351 (U902, genlock clock gen) @ 0x60. The genlock RP2040 (U900) owns the Si5351 register writes (see the RP2040 line below + `refdes-map.md` Sheet 9 + spec §3.7); kept off the PS video-config bus A. *(Corrected 2026-06-13 — §7 previously listed the Si5351 on bus A.)*
- **SPI:** LTC6912 PGA (genlock); GS3470/GS2962 GSPI (SDI); rear status LCD (ST7789). Separate CS each.
- **RP2040 (genlock MCU):** owns the Si5351 register writes (over its own I²C bus C) + the LTC6912 PGA gain (over the genlock SPI); reports to PS over **UART**.
- I²C/UART prefer the 14 user MIO (§4); SPI/CS and the odd GPIO draw from spare lanes in whichever bank is local to the device, or from the §18 expansion-header tap.

---

## 8. Open items / TODO

1. ~~ADV7511 symbol — not yet in JustinLibrary.~~ **DONE** — `ADV7511KSTZ` (LQFP-100) in JustinLibrary, verified 100 pins.
2. **SDI 10-bit DDR HDL** — IDDR/ODDR primitives + IDELAY centering on RX; ODDR clock-forward on TX. Bounded but real.
3. ~~MIO40–45 eMMC/SDIO contention.~~ **RESOLVED** — eMMC on SDIO1; MIO40–45 = free SDIO0 → LWB5+ WiFi (1.8 V strap, no level shifter); microSD dropped.
4. **AD9204 output mode** (§6 B33) — single/interleaved 10-bit vs dual 20-bit decides B33 fit. Interleaved single 10-bit is the assumed implementation (only the active reference channel is digitized at a time).
5. **4-MMCM ceiling — now the binding constraint.** With three independent output engines, clock-gen demand is: HDMI-in recovery (1) + analog-out pixel (1) + sync reference (1) + **HDMI-out & SDI-out sharing one pixel domain** (1) = **4 MMCM, exactly full**. Input captures (ADV7280 LLC, SDI-RX PCLK, ADC DCO) ride **BUFR/BUFIO regional buffers or PLLE2**, not MMCM. If HDMI-out and SDI-out ever need *independent* rates, offload one pixel clock to the **Si5351** (external) to free the tile.
6. **VCCIO34 routing** — supply pins on JM2, bank signals on JM3; route across.
7. **HDMI-in width** — banked at 16-bit YCbCr 4:2:2. The B35 spare that was reserved for a 24-bit-RGB upgrade is **now spent by the relocated SYNC-1 DAC** (2026-06-13e); a future 24-bit upgrade would have to find lanes elsewhere or reclaim the DAC pins.
8. ~~B34 is the tight bank (35/36).~~ **RESOLVED 2026-06-13e** — the B34 = 1.8 V SDI re-strap (item #10) forced the SYNC-1 DAC (3.3 V-only AD9742) off B34 → B35, which **relieves B34 to ~22/36** and lifts **B35 to ~42/48**. B34 is no longer tight; B35 is now the fullest bank. The "B34 = all Pro silicon" depopulation story softens slightly (the Pro-only SYNC-1 DAC now sits in the all-SKU B35, unpopulated on Mini).
9. ~~B33 level mismatch (AD9204 1.8 V → 3.3 V bank).~~ **RESOLVED 2026-06-13 — B33 re-strapped to VCCIO33 = 1.8 V** (`+1V8_D` digital LDO; module allows 1.2–3.3 V on B33). AD9204 data lands native LVCMOS18, no translator. LTC6912 PGA SPI confirmed RP2040-mastered (removed from the B33 pin list, freeing the L18 pair). New `+1V8_D` rail added to the Sheet-2/3 power tree (small LDO off 3.3 V, separate from analog `+1V8_A`). AD9204 VREF bypass = 470 nF / 6.3 V / X5R.
10. ~~B34 SDI level mismatch (GS3470 I/O ≤ 2.5 V vs 3.3 V bank).~~ **RESOLVED 2026-06-13e — B34 re-strapped to VCCIO34 = 1.8 V** (Option A). GS3470 SDI-RX I/O = 1.8/2.5 V, GS2962 SDI-TX = 1.8/3.3 V → only common = **1.8 V**; both GS chips strapped to 1.8 V I/O, native LVCMOS18 to the FPGA. The **AD9742 SYNC-1 DAC is a 2.7–3.6 V part** (can't do 1.8 V), so it **relocated B34 → B35** (3.3 V, 13 pins) — see §5/§6 + `refdes-map.md` Sheet 9. `+1V8_D` resized to feed VCCIO33 + VCCIO34 + AD9204 DRVDD. **Layout flag:** SDI parallel bus + the relocated DAC clock as LVCMOS18 at ~148 MHz-class — keep short/matched, on clock-capable pins. (Module allows VCCIO34 = 1.5–3.3 V; 1.8 V clears the 1.5 V floor.)
