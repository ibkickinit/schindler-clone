# Schindler 2.0 — Pin-Lock Assignment (PL ↔ TE0720)

**Created 2026-06-18 (Claude).** Per-signal FPGA pin-lock for the carrier, built on [`pin-lock-substrate.md`](pin-lock-substrate.md). Clocks on reserved MRCC/SRCC `_P` pins; data buses fill the remaining pins of each bank in connector order. **JM pin = carrier connector pin** (J200=JM1, J201=JM2, J202=JM3). XDC seed: `schindler_plio.xdc`.

## What this is / isn't
- **Is:** which JM pin (and Zynq ball) each PL signal owns, by bank, clocks on clock-capable pins. This is what the schematic + XDC lock.
- **Isn't:** the exact PHY-pin↔bit pairing inside each block. Data bits are fungible within a bank, so the agent pairs each PHY's actual bus pins to the assigned JM block. Bit order is RTL-defined.

## Corrections folded in (vs. the old budget)
- **LTC6912 (U802) is OFF the PL pin-lock** — SPI already wired (RP2040-mastered); only analog pins deferred. B33 demand 15→12.
- **SDI = 10-bit DDR, not 20-bit SDR** — 2×20-bit (~42 pins) won't fit B34's 36; 10-bit DDR (11 each = 22) is the only fit. Upper DOUT/DIN[19:10] unused.
- **AD9742 in B35** (3.3 V, 2026-06-13e re-strap), 12 data + clk.

### B35 — JM1/J200 — LVCMOS33 — 42 assigned, 6 spare

| Signal | JM pin | Zynq ball | Trenz net | Mod len | |
|---|---|---|---|---:|---|
| HDMIRX_PCLK | JM1-61 | B19 | B35_L13_P | 4.8 | **CLK** |
| SYNC1_DAC_CLK | JM1-67 | D20 | B35_L14_P | 15.9 | **CLK** |
| ADV7280_LLC | JM1-77 | D18 | B35_L12_P | 3.4 | **CLK** |
| ADV7280_P0 | JM1-31 | C22 | B35_L16_N | 23.5 | data |
| ADV7280_P1 | JM1-33 | D22 | B35_L16_P | 13.8 | data |
| ADV7280_P2 | JM1-35 | G22 | B35_L24_N | 11.6 | data |
| ADV7280_P3 | JM1-36 | A19 | B35_L10_N | 8.8 | data |
| ADV7280_P4 | JM1-37 | H22 | B35_L24_P | 7.8 | data |
| ADV7280_P5 | JM1-38 | A18 | B35_L10_P | 7.8 | data |
| ADV7280_P6 | JM1-40 | A17 | B35_L9_N | 16.9 | data |
| ADV7280_P7 | JM1-41 | B22 | B35_L18_N | 13.9 | data |
| HDMIRX_D0 | JM1-42 | A16 | B35_L9_P | 14.5 | data |
| HDMIRX_D1 | JM1-43 | B21 | B35_L18_P | 14.1 | data |
| HDMIRX_D2 | JM1-45 | A22 | B35_L15_N | 14.4 | data |
| HDMIRX_D3 | JM1-46 | B15 | B35_L7_N | 15.2 | data |
| HDMIRX_D4 | JM1-47 | A21 | B35_L15_P | 13.8 | data |
| HDMIRX_D5 | JM1-48 | C15 | B35_L7_P | 13.5 | data |
| HDMIRX_D6 | JM1-49 | G21 | B35_L22_N | 15.3 | data |
| HDMIRX_D7 | JM1-50 | D17 | B35_L2_N | 16.0 | data |
| HDMIRX_D8 | JM1-51 | G20 | B35_L22_P | 15.1 | data |
| HDMIRX_D9 | JM1-52 | D16 | B35_L2_P | 15.5 | data |
| HDMIRX_D10 | JM1-55 | D21 | B35_L17_N | 3.1 | data |
| HDMIRX_D11 | JM1-56 | B17 | B35_L8_N | 3.4 | data |
| HDMIRX_D12 | JM1-57 | E21 | B35_L17_P | 3.1 | data |
| HDMIRX_D13 | JM1-58 | B16 | B35_L8_P | 3.6 | data |
| HDMIRX_D14 | JM1-59 | B20 | B35_L13_N | 4.9 | data |
| HDMIRX_D15 | JM1-60 | E20 | B35_L21_N | 2.6 | data |
| HDMIRX_DE | JM1-62 | E19 | B35_L21_P | 4.3 | data |
| HDMIRX_HS | JM1-65 | C20 | B35_L14_N | 15.7 | data |
| HDMIRX_VS | JM1-66 | C18 | B35_L11_N | 14.9 | data |
| SYNC1_DAC_DB0 | JM1-68 | C17 | B35_L11_P | 15.4 | data |
| SYNC1_DAC_DB1 | JM1-69 | G16 | B35_L4_N | 2.8 | data |
| SYNC1_DAC_DB2 | JM1-70 | F22 | B35_L23_N | 3.5 | data |
| SYNC1_DAC_DB3 | JM1-71 | G15 | B35_L4_P | 2.9 | data |
| SYNC1_DAC_DB4 | JM1-72 | F21 | B35_L23_P | 3.5 | data |
| SYNC1_DAC_DB5 | JM1-75 | C19 | B35_L12_N | 3.3 | data |
| SYNC1_DAC_DB6 | JM1-76 | E18 | B35_L5_N | 3.7 | data |
| SYNC1_DAC_DB7 | JM1-78 | F18 | B35_L5_P | 3.8 | data |
| SYNC1_DAC_DB8 | JM1-80 | D15 | B35_L3_N | 19.1 | data |
| SYNC1_DAC_DB9 | JM1-81 | F19 | B35_L20_N | 20.1 | data |
| SYNC1_DAC_DB10 | JM1-82 | E15 | B35_L3_P | 17.1 | data |
| SYNC1_DAC_DB11 | JM1-83 | G19 | B35_L20_P | 18.3 | data |
| — | JM1-86 | F17 | B35_L6_N | 24.8 | spare |
| — | JM1-88 | G17 | B35_L6_P | 15.9 | spare |
| — | JM1-94 | E16 | B35_L1_N | 27.4 | spare |
| — | JM1-96 | F16 | B35_L1_P | 32.8 | spare |
| — | JM1-98 | H20 | B35_L19_N | 27.2 | spare |
| — | JM1-100 | H19 | B35_L19_P | 16.4 | spare |

### B13 — JM2/J201 — LVCMOS33 — 40 assigned, 10 spare

| Signal | JM pin | Zynq ball | Trenz net | Mod len | |
|---|---|---|---|---:|---|
| HDMITX_PCLK | JM2-46 | Y9 | B13_L12_P | 26.8 | **CLK** |
| VIDOUT_CLKIN | JM2-56 | Y6 | B13_L13_P | 25.7 | **CLK** |
| HDMITX_D0 | JM2-32 | U12 | B13_L5_P | 21.9 | data |
| HDMITX_D1 | JM2-34 | U11 | B13_L5_N | 32.0 | data |
| HDMITX_D2 | JM2-36 | U10 | B13_L6_P | 26.6 | data |
| HDMITX_D3 | JM2-38 | U9 | B13_L6_N | 28.3 | data |
| HDMITX_D4 | JM2-41 | AA12 | B13_L7_P | 24.7 | data |
| HDMITX_D5 | JM2-42 | V10 | B13_L1_P | 24.8 | data |
| HDMITX_D6 | JM2-43 | AB12 | B13_L7_N | 25.1 | data |
| HDMITX_D7 | JM2-44 | V9 | B13_L1_N | 23.8 | data |
| HDMITX_D8 | JM2-45 | AA11 | B13_L8_P | 25.9 | data |
| HDMITX_D9 | JM2-47 | AB11 | B13_L8_N | 14.7 | data |
| HDMITX_D10 | JM2-48 | Y8 | B13_L12_N | 14.2 | data |
| HDMITX_D11 | JM2-51 | AA9 | B13_L11_P | 24.7 | data |
| HDMITX_D12 | JM2-52 | AA7 | B13_L14_P | 24.1 | data |
| HDMITX_D13 | JM2-53 | AA8 | B13_L11_N | 21.9 | data |
| HDMITX_D14 | JM2-54 | AA6 | B13_L14_N | 22.9 | data |
| HDMITX_D15 | JM2-55 | AB10 | B13_L9_P | 25.7 | data |
| HDMITX_DE | JM2-57 | AB9 | B13_L9_N | 11.8 | data |
| HDMITX_HS | JM2-58 | Y5 | B13_L13_N | 12.2 | data |
| HDMITX_VS | JM2-61 | T4 | B13_L20_P | 10.4 | data |
| VIDOUT_P0 | JM2-62 | V12 | B13_L4_P | 10.4 | data |
| VIDOUT_P1 | JM2-63 | U4 | B13_L20_N | 8.3 | data |
| VIDOUT_P2 | JM2-64 | W12 | B13_L4_N | 14.5 | data |
| VIDOUT_P3 | JM2-65 | AB7 | B13_L17_P | 14.1 | data |
| VIDOUT_P4 | JM2-66 | W11 | B13_L3_P | 0.2 | data |
| VIDOUT_P5 | JM2-67 | AB6 | B13_L17_N | 0.2 | data |
| VIDOUT_P6 | JM2-68 | W10 | B13_L3_N | 51.3 | data |
| VIDOUT_P7 | JM2-71 | AB5 | B13_L16_P | 50.0 | data |
| VIDOUT_P8 | JM2-72 | Y11 | B13_L10_P | 51.5 | data |
| VIDOUT_P9 | JM2-73 | AB4 | B13_L16_N | 49.5 | data |
| VIDOUT_P10 | JM2-74 | Y10 | B13_L10_N | 48.8 | data |
| VIDOUT_P11 | JM2-75 | Y4 | B13_L18_P | 51.7 | data |
| VIDOUT_P12 | JM2-76 | V8 | B13_L2_P | 54.0 | data |
| VIDOUT_P13 | JM2-77 | AA4 | B13_L18_N | 49.5 | data |
| VIDOUT_P14 | JM2-78 | W8 | B13_L2_N | 51.5 | data |
| VIDOUT_P15 | JM2-81 | AB2 | B13_L15_P | 52.4 | data |
| VIDOUT_HSYNC | JM2-82 | V7 | B13_L23_P | 52.3 | data |
| VIDOUT_VSYNC | JM2-83 | AB1 | B13_L15_N | 51.6 | data |
| VIDOUT_SFL | JM2-84 | W7 | B13_L23_N | 49.7 | data |
| — | JM2-85 | V5 | B13_L21_P | 50.3 | spare |
| — | JM2-86 | W6 | B13_L24_P | 52.2 | spare |
| — | JM2-87 | V4 | B13_L21_N | 43.7 | spare |
| — | JM2-88 | W5 | B13_L24_N | 48.7 | spare |
| — | JM2-89 | U7 | B13_IO25 | 48.2 | spare |
| — | JM2-92 | R6 | B13_L19_P | 11.3 | spare |
| — | JM2-94 | T6 | B13_L19_N | 13.2 | spare |
| — | JM2-96 | U6 | B13_L22_P | 15.0 | spare |
| — | JM2-98 | U5 | B13_L22_N | 17.2 | spare |
| — | JM2-100 | R7 | B13_IO0 | 18.9 | spare |

### B34 — JM3/J202 — LVCMOS18 — 22 assigned, 14 spare

| Signal | JM pin | Zynq ball | Trenz net | Mod len | |
|---|---|---|---|---:|---|
| SDIRX_PCLK | JM3-31 | L18 | B34_L12_P | 10.2 | **CLK** |
| SDITX_PCLK | JM3-32 | M19 | B34_L13_P | 48.5 | **CLK** |
| SDIRX_D0 | JM3-7 | J18 | B34_L7_P | 14.1 | data |
| SDIRX_D1 | JM3-8 | J15 | B34_L1_P | 13.9 | data |
| SDIRX_D2 | JM3-9 | K18 | B34_L7_N | 12.7 | data |
| SDIRX_D3 | JM3-10 | K15 | B34_L1_N | 9.6 | data |
| SDIRX_D4 | JM3-13 | J16 | B34_L2_P | 12.9 | data |
| SDIRX_D5 | JM3-14 | P20 | B34_L18_P | 13.7 | data |
| SDIRX_D6 | JM3-15 | J17 | B34_L2_N | 14.7 | data |
| SDIRX_D7 | JM3-16 | P21 | B34_L18_N | 15.9 | data |
| SDIRX_D8 | JM3-19 | L17 | B34_L4_P | 14.1 | data |
| SDIRX_D9 | JM3-20 | P17 | B34_L20_P | 13.3 | data |
| SDITX_D0 | JM3-21 | M17 | B34_L4_N | 14.0 | data |
| SDITX_D1 | JM3-22 | P18 | B34_L20_N | 16.8 | data |
| SDITX_D2 | JM3-25 | N17 | B34_L5_P | 13.5 | data |
| SDITX_D3 | JM3-26 | L21 | B34_L10_P | 10.9 | data |
| SDITX_D4 | JM3-27 | N18 | B34_L5_N | 11.3 | data |
| SDITX_D5 | JM3-28 | L22 | B34_L10_N | 15.9 | data |
| SDITX_D6 | JM3-33 | L19 | B34_L12_N | 45.6 | data |
| SDITX_D7 | JM3-34 | M20 | B34_L13_N | 44.2 | data |
| SDITX_D8 | JM3-37 | J21 | B34_L8_P | 26.6 | data |
| SDITX_D9 | JM3-38 | T16 | B34_L21_P | 0.3 | data |
| — | JM3-39 | J22 | B34_L8_N | 50.3 | spare |
| — | JM3-40 | T17 | B34_L21_N | 14.4 | spare |
| — | JM3-41 | J20 | B34_L9_P | 17.8 | spare |
| — | JM3-42 | M21 | B34_L15_P | 9.4 | spare |
| — | JM3-43 | K21 | B34_L9_N | 9.6 | spare |
| — | JM3-44 | M22 | B34_L15_N | 24.2 | spare |
| — | JM3-48 | R20 | B34_L17_P | 26.8 | spare |
| — | JM3-50 | R21 | B34_L17_N | 26.8 | spare |
| — | JM3-52 | R18 | B34_L23_P | 17.3 | spare |
| — | JM3-54 | T18 | B34_L23_N | 13.4 | spare |
| — | JM3-57 | R19 | B34_L22_P | 15.8 | spare |
| — | JM3-58 | N19 | B34_L14_P | 17.3 | spare |
| — | JM3-59 | T19 | B34_L22_N | 112.4 | spare |
| — | JM3-60 | N20 | B34_L14_N | 74.2 | spare |

### B33 — JM2/J201 — LVCMOS18 — 12 assigned, 6 spare

| Signal | JM pin | Zynq ball | Trenz net | Mod len | |
|---|---|---|---|---:|---|
| GENADC_DCO | JM2-25 | Y18 | B33_L12_P | 19.1 | **CLK** |
| GENADC_D0 | JM2-11 | AA22 | B33_L7_P | 12.4 | data |
| GENADC_D1 | JM2-13 | AB22 | B33_L7_N | 13.0 | data |
| GENADC_D2 | JM2-14 | W20 | B33_L4_P | 32.1 | data |
| GENADC_D3 | JM2-15 | AA21 | B33_L8_P | 10.7 | data |
| GENADC_D4 | JM2-16 | W21 | B33_L4_N | 10.7 | data |
| GENADC_D5 | JM2-17 | AB21 | B33_L8_N | 18.8 | data |
| GENADC_D6 | JM2-21 | Y19 | B33_L11_P | 20.6 | data |
| GENADC_D7 | JM2-22 | W17 | B33_L13_P | 20.4 | data |
| GENADC_D8 | JM2-23 | AA19 | B33_L11_N | 23.8 | data |
| GENADC_D9 | JM2-24 | W18 | B33_L13_N | 23.8 | data |
| SYNC2_BIPHASE | JM2-26 | W16 | B33_L14_P | 19.5 | data |
| — | JM2-27 | AA18 | B33_L12_N | 27.7 | spare |
| — | JM2-28 | Y16 | B33_L14_N | 27.4 | spare |
| — | JM2-31 | AA17 | B33_L17_P | 21.5 | spare |
| — | JM2-33 | AB17 | B33_L17_N | 31.4 | spare |
| — | JM2-35 | AA16 | B33_L18_P | 28.1 | spare |
| — | JM2-37 | AB16 | B33_L18_N | 27.2 | spare |

## Per-chip wiring notes (for the agent) — PL-facing pins only

The netlist `unconnected-` lists mix PL pins with non-PL (TMDS/SDI-serial/analog/NC/audio) — wire **only** the PL-facing pins below; leave the rest (they go to the HDMI/SDI/RCA connectors or are unused).

- **ADV7280 (U500) → B35:** `P0..P7`→`ADV7280_P0..7`; `LLC`→`ADV7280_LLC` (JM1-77). Embedded BT.656 sync → no HS/VS to PL. `INTRQ*`=interrupt (PS-EMIO/I²C); `RESET*`/`PWRDWN*`=VIDEO_RESET_N net.
- **LT8619C (U402) → B35:** `D0..D15`→`HDMIRX_D0..15`; `DE/HS/VS`→`HDMIRX_DE/HS/VS`; `PCLK`→`HDMIRX_PCLK` (JM1-61). ⚠ confirm which 16 of D0–D23 carry the 16-bit YCbCr 4:2:2 word (D16–D23 TMDS-shared, unused). TMDS/XTAL/IIS-SPDIF = not PL.
- **AD9742 (U903) → B35:** `DB0..DB11`→`SYNC1_DAC_DB0..11`; `CLOCK`→`SYNC1_DAC_CLK` (JM1-67). ⚠ deferred shows DB1–DB10 only — confirm DB0/DB11 on the symbol (12-bit).
- **ADV7511 (U403) → B13:** 16 of `D0..D35`→`HDMITX_D0..15`; `DE/HSYNC/VSYNC`→`HDMITX_DE/HS/VS`; `CLK`→`HDMITX_PCLK` (JM2-46). ⚠ pick the 16 D-pins per the chosen 16-bit YCbCr 4:2:2 input ID. TMDS/HEAC, DSD/I²S/SPDIF, ISO/CEC = not PL.
- **ADV7393 (U600) → B13:** `P0..P15`→`VIDOUT_P0..15`; `*HSYNC/*VSYNC/SFL`→`VIDOUT_HSYNC/VSYNC/SFL`; `CLKIN`→`VIDOUT_CLKIN` (JM2-56). `COMP`/`EXT_LF`=analog DAC (not PL); `*RESET`=VIDEO_RESET_N.
- **GS3470 (U700) → B34 (10-bit DDR):** `DOUT0..9`→`SDIRX_D0..9`; recovered clock `PCLK`(A8)→`SDIRX_PCLK` (JM3-31). `DOUT10..19` unused. `STAT*`/`AOUT*/ACLK/AMCLK`(audio)/JTAG/`~RESET`(=SDI_RESET_N) = not this block.
- **GS2962 (U701) → B34 (10-bit DDR):** `DIN0..9`→`SDITX_D0..9`; `PCLK`(B4)→`SDITX_PCLK` (JM3-32). `DIN10..19` unused. `STANDBY`(pull-down)/`~RESET`(=SDI_RESET_N)/RSV/JTAG = not this block.
- **AD9204 (U801) → B33:** 10-bit capture port→`GENADC_D0..9`; `DCO`→`GENADC_DCO` (JM2-25). ⚠ dual-channel — confirm interleaved single-port vs channel-A; deferred shows D1A–D8A/D1B–D8B (resolve D9/D10 vs symbol). `CLK+/CLK−`=differential sample-clock **input** from genlock source (not FPGA). `OR*`/`NC`=not PL.
- **SYNC2_BIPHASE → B33 (JM2-26):** single FPGA output to the SYNC-2 slew-limited op-amp input (not a PHY chip).
- **LTC6912 (U802):** no action — SPI already connected.

## Layout notes
- **SDI DDR (B34) length-match:** `SDITX_PCLK` landed on JM3-32 (M19, 48.5 mm) while its data sit ~10–17 mm → ~38 mm module skew. GS2962 word clock is an FPGA **output**, so it needn't stay on a CC pin — layout may move it to a data-adjacent pin or compensate on the carrier. `SDIRX_PCLK` (JM3-31, 10.2 mm) is well-matched to its data.
- Final intra-bus skew is a carrier-routing task (Mod-len + carrier length). Low-rate buses (ADV7393 27 MHz, ADV7280 BT.656) are skew-tolerant; HDMI-out + SDI-DDR are the ones to match.

## Source / next
- Built on `pin-lock-substrate.md`; widths from `pin-budget.md` §2 (with corrections above). XDC seed `schindler_plio.xdc`. **Next:** agent wires each PHY's PL bus to its JM block (resolving the ⚠ symbol questions), re-ERC, reconcile; then Justin pushes.
