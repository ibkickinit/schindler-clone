# Schindler 2.0 — Pin-Lock Substrate (TE0720 REV04 PL pin pool)

**Created 2026-06-18 (Claude).** Authoritative physical pin pool for the pin-lock pass, extracted from the Trenz **`4x5_series_teba0841_pinout_tracelength.xlsx`**, sheet **`RAW_m_TE0720_REV04`** (matches the production module TE0720-04-**62I33MA**, REV04). The B2B pin→Zynq-ball→bank mapping is fixed by the module and identical on any carrier (Trenz workbook note: "B2B connector pinout will normally not change"), so it applies directly to Schindler. **Module-side trace lengths** are TE0720-internal (for total length-match budgeting alongside the carrier-side lengths).

> **Schindler uses direct module pin numbering** (carrier symbol), so JM1 = **J200**, JM2 = **J201**, JM3 = **J202**. The JM pin numbers below are the carrier connector pins.

## Pool vs. demand — reconciled, feasible

| Bank | Connector | VCCO (Schindler) | Usable I/O | Budget demand | Headroom |
|---|---|---|---:|---:|---:|
| **B35** | JM1 / J200 | 3.3 V | 48 | 42 (HDMI-in 20 + ADV7280 9 + AD9742 13) | 6 |
| **B13** | JM2 / J201 | 3.3 V | 50 | 40 (ADV7511 20 + ADV7393 20) | 10 |
| **B34** | JM3 / J202 | 1.8 V | 36 | 22 (SDI RX 11 + SDI TX 11) | 14 |
| **B33** | JM2 / J201 | 1.8 V | 18 | 15 (AD9204 11 + LTC6912 3 + SYNC-2 1) | 3 |
| **Total** | | | **152** | **119** | **33** |

Matches `pin-budget.md` (119/152). Every bank is within capacity; B35 is fullest (42/48). No re-architecture needed.

**Correction (2026-06-18):** an initial extraction filtered only JM1/JM2 and reported B34 = 0 I/O — a false alarm. B34's 36 I/O are on **JM3** (the LSHM-130). Verified across all three connectors; pool reconciles to 152.

## Voltage / bank assignment (locked)
- **3.3 V:** B35 (VCCIO35→+3V3) + B13 (VCCIO13→+3V3) — HDMI-in (LT8619C), ADV7280, ADV7393, ADV7511*, AD9742, VIDEO_RESET_N. *(ADV7511 pixel bus is flex 1.8–3.3 V — placed in B13.)*
- **1.8 V:** B34 (VCCIO34→+1V8_D, boot-critical) + B33 (VCCIO33→+1V8_D) — SDI (GS3470/GS2962) on B34; AD9204 + LTC6912 SPI + SYNC-2 + SDI_RESET_N on B33.

## How to use this table
1. **Reserve clock-capable pins first** (recovered + synth clocks — see pin-lock-todo §D). CC identification = next step (map FPGA ball → Zynq-7020 CLG484 MRCC/SRCC list).
2. Place each fast bus within its bank; keep a bus on contiguous/low-skew pins and use the **module length** column with the carrier-side length for total intra-bus skew.
3. `_P`/`_N` denote the module's diff-pair routing; these are single-ended FPGA I/O — the pairing only matters for length-match grouping and for the (few) pins used as differential clocks.


### B35 — JM1 / J200 — 3.3 V (48 usable I/O)

| JM pin | Trenz net | FPGA ball | Module len (mm) |
|---|---|---|---:|
| JM1-31 | B35_L16_N | C22 | 23.5 |
| JM1-33 | B35_L16_P | D22 | 13.8 |
| JM1-35 | B35_L24_N | G22 | 11.6 |
| JM1-36 | B35_L10_N | A19 | 8.8 |
| JM1-37 | B35_L24_P | H22 | 7.8 |
| JM1-38 | B35_L10_P | A18 | 7.8 |
| JM1-40 | B35_L9_N | A17 | 16.9 |
| JM1-41 | B35_L18_N | B22 | 13.9 |
| JM1-42 | B35_L9_P | A16 | 14.5 |
| JM1-43 | B35_L18_P | B21 | 14.1 |
| JM1-45 | B35_L15_N | A22 | 14.4 |
| JM1-46 | B35_L7_N | B15 | 15.2 |
| JM1-47 | B35_L15_P | A21 | 13.8 |
| JM1-48 | B35_L7_P | C15 | 13.5 |
| JM1-49 | B35_L22_N | G21 | 15.3 |
| JM1-50 | B35_L2_N | D17 | 16.0 |
| JM1-51 | B35_L22_P | G20 | 15.1 |
| JM1-52 | B35_L2_P | D16 | 15.5 |
| JM1-55 | B35_L17_N | D21 | 3.1 |
| JM1-56 | B35_L8_N | B17 | 3.4 |
| JM1-57 | B35_L17_P | E21 | 3.1 |
| JM1-58 | B35_L8_P | B16 | 3.6 |
| JM1-59 | B35_L13_N | B20 | 4.9 |
| JM1-60 | B35_L21_N | E20 | 2.6 |
| JM1-61 | B35_L13_P | B19 | 4.8 |
| JM1-62 | B35_L21_P | E19 | 4.3 |
| JM1-65 | B35_L14_N | C20 | 15.7 |
| JM1-66 | B35_L11_N | C18 | 14.9 |
| JM1-67 | B35_L14_P | D20 | 15.9 |
| JM1-68 | B35_L11_P | C17 | 15.4 |
| JM1-69 | B35_L4_N | G16 | 2.8 |
| JM1-70 | B35_L23_N | F22 | 3.5 |
| JM1-71 | B35_L4_P | G15 | 2.9 |
| JM1-72 | B35_L23_P | F21 | 3.5 |
| JM1-75 | B35_L12_N | C19 | 3.3 |
| JM1-76 | B35_L5_N | E18 | 3.7 |
| JM1-77 | B35_L12_P | D18 | 3.4 |
| JM1-78 | B35_L5_P | F18 | 3.8 |
| JM1-80 | B35_L3_N | D15 | 19.1 |
| JM1-81 | B35_L20_N | F19 | 20.1 |
| JM1-82 | B35_L3_P | E15 | 17.1 |
| JM1-83 | B35_L20_P | G19 | 18.3 |
| JM1-86 | B35_L6_N | F17 | 24.8 |
| JM1-88 | B35_L6_P | G17 | 15.9 |
| JM1-94 | B35_L1_N | E16 | 27.4 |
| JM1-96 | B35_L1_P | F16 | 32.8 |
| JM1-98 | B35_L19_N | H20 | 27.2 |
| JM1-100 | B35_L19_P | H19 | 16.4 |

### B13 — JM2 / J201 — 3.3 V (50 usable I/O)

| JM pin | Trenz net | FPGA ball | Module len (mm) |
|---|---|---|---:|
| JM2-32 | B13_L5_P | U12 | 21.9 |
| JM2-34 | B13_L5_N | U11 | 32.0 |
| JM2-36 | B13_L6_P | U10 | 26.6 |
| JM2-38 | B13_L6_N | U9 | 28.3 |
| JM2-41 | B13_L7_P | AA12 | 24.7 |
| JM2-42 | B13_L1_P | V10 | 24.8 |
| JM2-43 | B13_L7_N | AB12 | 25.1 |
| JM2-44 | B13_L1_N | V9 | 23.8 |
| JM2-45 | B13_L8_P | AA11 | 25.9 |
| JM2-46 | B13_L12_P | Y9 | 26.8 |
| JM2-47 | B13_L8_N | AB11 | 14.7 |
| JM2-48 | B13_L12_N | Y8 | 14.2 |
| JM2-51 | B13_L11_P | AA9 | 24.7 |
| JM2-52 | B13_L14_P | AA7 | 24.1 |
| JM2-53 | B13_L11_N | AA8 | 21.9 |
| JM2-54 | B13_L14_N | AA6 | 22.9 |
| JM2-55 | B13_L9_P | AB10 | 25.7 |
| JM2-56 | B13_L13_P | Y6 | 25.7 |
| JM2-57 | B13_L9_N | AB9 | 11.8 |
| JM2-58 | B13_L13_N | Y5 | 12.2 |
| JM2-61 | B13_L20_P | T4 | 10.4 |
| JM2-62 | B13_L4_P | V12 | 10.4 |
| JM2-63 | B13_L20_N | U4 | 8.3 |
| JM2-64 | B13_L4_N | W12 | 14.5 |
| JM2-65 | B13_L17_P | AB7 | 14.1 |
| JM2-66 | B13_L3_P | W11 | 0.2 |
| JM2-67 | B13_L17_N | AB6 | 0.2 |
| JM2-68 | B13_L3_N | W10 | 51.3 |
| JM2-71 | B13_L16_P | AB5 | 50.0 |
| JM2-72 | B13_L10_P | Y11 | 51.5 |
| JM2-73 | B13_L16_N | AB4 | 49.5 |
| JM2-74 | B13_L10_N | Y10 | 48.8 |
| JM2-75 | B13_L18_P | Y4 | 51.7 |
| JM2-76 | B13_L2_P | V8 | 54.0 |
| JM2-77 | B13_L18_N | AA4 | 49.5 |
| JM2-78 | B13_L2_N | W8 | 51.5 |
| JM2-81 | B13_L15_P | AB2 | 52.4 |
| JM2-82 | B13_L23_P | V7 | 52.3 |
| JM2-83 | B13_L15_N | AB1 | 51.6 |
| JM2-84 | B13_L23_N | W7 | 49.7 |
| JM2-85 | B13_L21_P | V5 | 50.3 |
| JM2-86 | B13_L24_P | W6 | 52.2 |
| JM2-87 | B13_L21_N | V4 | 43.7 |
| JM2-88 | B13_L24_N | W5 | 48.7 |
| JM2-89 | B13_IO25 | U7 | 48.2 |
| JM2-92 | B13_L19_P | R6 | 11.3 |
| JM2-94 | B13_L19_N | T6 | 13.2 |
| JM2-96 | B13_L22_P | U6 | 15.0 |
| JM2-98 | B13_L22_N | U5 | 17.2 |
| JM2-100 | B13_IO0 | R7 | 18.9 |

### B34 — JM3 / J202 — 1.8 V (36 usable I/O)

| JM pin | Trenz net | FPGA ball | Module len (mm) |
|---|---|---|---:|
| JM3-7 | B34_L7_P | J18 | 14.1 |
| JM3-8 | B34_L1_P | J15 | 13.9 |
| JM3-9 | B34_L7_N | K18 | 12.7 |
| JM3-10 | B34_L1_N | K15 | 9.6 |
| JM3-13 | B34_L2_P | J16 | 12.9 |
| JM3-14 | B34_L18_P | P20 | 13.7 |
| JM3-15 | B34_L2_N | J17 | 14.7 |
| JM3-16 | B34_L18_N | P21 | 15.9 |
| JM3-19 | B34_L4_P | L17 | 14.1 |
| JM3-20 | B34_L20_P | P17 | 13.3 |
| JM3-21 | B34_L4_N | M17 | 14.0 |
| JM3-22 | B34_L20_N | P18 | 16.8 |
| JM3-25 | B34_L5_P | N17 | 13.5 |
| JM3-26 | B34_L10_P | L21 | 10.9 |
| JM3-27 | B34_L5_N | N18 | 11.3 |
| JM3-28 | B34_L10_N | L22 | 15.9 |
| JM3-31 | B34_L12_P | L18 | 10.2 |
| JM3-32 | B34_L13_P | M19 | 48.5 |
| JM3-33 | B34_L12_N | L19 | 45.6 |
| JM3-34 | B34_L13_N | M20 | 44.2 |
| JM3-37 | B34_L8_P | J21 | 26.6 |
| JM3-38 | B34_L21_P | T16 | 0.3 |
| JM3-39 | B34_L8_N | J22 | 50.3 |
| JM3-40 | B34_L21_N | T17 | 14.4 |
| JM3-41 | B34_L9_P | J20 | 17.8 |
| JM3-42 | B34_L15_P | M21 | 9.4 |
| JM3-43 | B34_L9_N | K21 | 9.6 |
| JM3-44 | B34_L15_N | M22 | 24.2 |
| JM3-48 | B34_L17_P | R20 | 26.8 |
| JM3-50 | B34_L17_N | R21 | 26.8 |
| JM3-52 | B34_L23_P | R18 | 17.3 |
| JM3-54 | B34_L23_N | T18 | 13.4 |
| JM3-56 | B34_VREF *(VREF — reserved)* | M16 | 25.9 |
| JM3-57 | B34_L22_P | R19 | 15.8 |
| JM3-58 | B34_L14_P | N19 | 17.3 |
| JM3-59 | B34_L22_N | T19 | 112.4 |
| JM3-60 | B34_L14_N | N20 | 74.2 |

### B33 — JM2 / J201 — 1.8 V (18 usable I/O)

| JM pin | Trenz net | FPGA ball | Module len (mm) |
|---|---|---|---:|
| JM2-11 | B33_L7_P | AA22 | 12.4 |
| JM2-13 | B33_L7_N | AB22 | 13.0 |
| JM2-14 | B33_L4_P | W20 | 32.1 |
| JM2-15 | B33_L8_P | AA21 | 10.7 |
| JM2-16 | B33_L4_N | W21 | 10.7 |
| JM2-17 | B33_L8_N | AB21 | 18.8 |
| JM2-21 | B33_L11_P | Y19 | 20.6 |
| JM2-22 | B33_L13_P | W17 | 20.4 |
| JM2-23 | B33_L11_N | AA19 | 23.8 |
| JM2-24 | B33_L13_N | W18 | 23.8 |
| JM2-25 | B33_L12_P | Y18 | 19.1 |
| JM2-26 | B33_L14_P | W16 | 19.5 |
| JM2-27 | B33_L12_N | AA18 | 27.7 |
| JM2-28 | B33_L14_N | Y16 | 27.4 |
| JM2-29 | B33_VREF *(VREF — reserved)* | V15 | 23.2 |
| JM2-31 | B33_L17_P | AA17 | 21.5 |
| JM2-33 | B33_L17_N | AB17 | 31.4 |
| JM2-35 | B33_L18_P | AA16 | 28.1 |
| JM2-37 | B33_L18_N | AB16 | 27.2 |

## Clock-capable pins — reserved (LOCKED 2026-06-18, Claude)

Verified against **`xc7z020clg484pkg.txt`** (AMD). In every HR bank the clock-capable pairs are **L11 (SRCC), L12 (MRCC), L13 (MRCC), L14 (SRCC)** — and **Trenz's `Lyy` == Xilinx's `Lxx`**, so CC pins read straight off the net name. A single-ended clock **must use the `_P` pin** (it's the master cell wired to BUFG/BUFR/MMCM; the `_N` side cannot be a single-ended clock and stays available as ordinary data I/O).

**CC `_P` pins available per bank:** B35 → JM1-77 (D18,L12,MRCC), JM1-61 (B19,L13,MRCC), JM1-68 (C17,L11,SRCC), JM1-67 (D20,L14,SRCC) · B13 → JM2-46 (Y9,L12,MRCC), JM2-56 (Y6,L13,MRCC), JM2-51 (AA9,L11,SRCC), JM2-52 (AA7,L14,SRCC) · B34 → JM3-31 (L18,L12,MRCC), JM3-32 (M19,L13,MRCC), JM3-58 (N19,L14,SRCC) *(L11 not bonded to JM3)* · B33 → JM2-25 (Y18,L12,MRCC), JM2-22 (W17,L13,MRCC), JM2-21 (Y19,L11,SRCC), JM2-26 (W16,L14,SRCC).

**Reservation (captured clocks → MRCC; output clocks → MRCC/SRCC, movable if ever needed):**

| Clock | Dir | Bank | JM pin (`_P`) | Ball | Trenz net | Type |
|---|---|---|---|---|---|---|
| ADV7280 LLC | in (capture) | B35 | **JM1-77** | D18 | B35_L12_P | MRCC |
| LT8619C HDMI-in pixel clk | in (capture) | B35 | **JM1-61** | B19 | B35_L13_P | MRCC |
| AD9742 sample clk | out | B35 | **JM1-67** | D20 | B35_L14_P | SRCC |
| ADV7511 PCLK (HDMI-out) | out | B13 | **JM2-46** | Y9 | B13_L12_P | MRCC |
| ADV7393 CLKIN (27 MHz) | out | B13 | **JM2-56** | Y6 | B13_L13_P | MRCC |
| GS3470 SDI recovered clk | in (capture) | B34 | **JM3-31** | L18 | B34_L12_P | MRCC |
| GS2962 word clk | out | B34 | **JM3-32** | M19 | B34_L13_P | MRCC |
| AD9204 DCO | in (capture) | B33 | **JM2-25** | Y18 | B33_L12_P | MRCC |

All four **captured** clocks (ADV7280 LLC, LT8619C, GS3470, AD9204 DCO) land on MRCC `_P` pins — best case, drive MMCM/BUFG/BUFR directly. Note: the **AD9204 sample-clock input** (CLK+/CLK−, pins 1/2) is differential and driven from the genlock clock source — it is *not* an FPGA-capture pin; **DCO** is the FPGA-facing capture clock (reserved above). The paired `_N` pins (e.g. B35_L12_N = JM1-75) remain free for data.

## Next steps (the allocation pass)
1. ~~Clock-capable pins~~ — **DONE** (above).
2. **Per-signal data-bus fill** — for each PHY, isolate its **PL-facing** pins (the parallel video/sync bus + the reserved clock) from its *non-PL* deferred pins (HDMI/SDI TMDS to the connectors, analog front-end, NC, and control that rides I²C/PS) — the netlist's `unconnected-` list mixes both. Then assign data bits to the remaining pins of each bus's bank, grouped for length-match (use the Module-len column + carrier-side length). Per-chip PL widths (from `pin-budget.md` §2): ADV7280 ~9, LT8619C 20, ADV7511 20, ADV7393 20, GS3470 11, GS2962 11, AD9204 11, AD9742 13, LTC6912 SPI 3, SYNC-2 1.
3. **Emit** (a) the schematic net list for the agent (PHY pin → JM pin), (b) a full Vivado XDC (ball + IOSTANDARD: LVCMOS33 for B35/B13, LVCMOS18 for B34/B33).
4. **Agent wiring** — hand the per-signal map to the KiCad agent; wire the deferred `unconnected-` PL bus pins to these JM pins in one pass.

## Source
- Workbook: `4x5_series_teba0841_pinout_tracelength.xlsx` → `RAW_m_TE0720_REV04`. Demand: `pin-budget.md` §2/§5. Scope/sequence: `pin-lock-todo.md`.
