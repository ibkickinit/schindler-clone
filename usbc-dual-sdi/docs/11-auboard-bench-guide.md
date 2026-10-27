# 11 — AUBoard 15P Bench Guide

> **Status: bench reference, banked 2026-10-13.** Board facts are from the Tria
> **AUB-15P-DK-UG v1.0** user guide (50 pp). Items marked *verify* are not in the
> guide or conflict between sources. Board is **ordered**; nothing below has been
> powered on yet.

## The board in one table

| Item | Detail (UG v1.0) |
|---|---|
| FPGA | **XCAU15P-2FFVB676E** (-2 speed grade) |
| DDR4 | **1 GB, x32** (ISSI IS43QR16512A) — marketing pages say 2 GB; the UG says 1 GB *(verify on arrival)* |
| Config flash | 64 MB QSPI (IS25WP512M); default boot **Master SPI** (M[2:0]=001) |
| Power | **12 V / 5 A brick** → 2.5 mm barrel **J51**; slide switch **SW1**; also PCIe card-edge 12 V, or J2 6-pin Mini-Fit (**not populated — never plug a PC/PCIe 6-pin into J2**) |
| Debug | **micro-USB J9** → FTDI-class U21 = **JTAG + USB-UART** (UART on FPGA AF15 TX / AF14 RX); 2 mm JTAG header **J10** for a Platform Cable |
| Ethernet | 10/100 only (KSZ8091, MII), RJ-45 **J12** |
| HDMI | **RX J24 / TX J28**, HDMI 2.0 via 6 Gb/s TMDS retimers on **GTH Quad 226 lanes 0–2**; 4K60 8-bit |
| SFP+ | Cage **J13/J14** on **GTH Quad 226 lane 3**; kit ships a TE optical module (1888247-1); TX_DISABLE jumper **J17**, rate-select **J15/J16**, LOS LED **D28**; SFP I²C via mux PCA9544 ch 0 |
| FMC | **HPC-size connector (CON1)**, wired as **LPC GPIO (LA00–LA33) + 4 GTH (DP0–DP3, Quad 225)** + GBTCLK0/1; **VADJ = 1.2 V or 1.8 V** (banks 66/86) *(how it's selected: verify in schematic)*; FMC JTAG jumper **J11** (1-2 = FPGA only); 12 V @ 1 A and 3.3 V to the mezzanine |
| PCIe | Gen4 x4 edge (Quad 224); lane-width jumper J22 — not used by us |
| Clocks | **X1** 300 MHz LVDS sys clock (AD21/AE21); **U57** Renesas 8T49N241 (I²C 0x7C, FPGA pins B9/A9): 156.25 MHz → **Quad 224** REFCLK1, 300 MHz GP, 150 MHz EMCCLK; **U56** 8T49N241 **jitter attenuator**: FPGA forwards a clock out on P25/P26 → U56 → **Quad 226** REFCLK0 (I²C on HDMI_CTL bus R23/R22; RST_N on G22 must be driven high) |
| User I/O | 4 red LEDs, 2 RGB LEDs, 4-pos DIP SW2, 4 push buttons, PL reset button, PROGRAM_B button, MikroE Click site |
| Status LEDs | **D18** green = power good, **D19** blue = DONE, D23/D24 UART activity, D28 SFP LOS, D29 FMC PG, D37 temp alert |
| Thermal | Tested with **Boyd EA-270-H245-T710** heatsink + clip; **J3** 3-pin fan header (5 V on pin 2; 12 V needs FB1 populated) |

## ⚠️ Three findings that matter for our build

1. **SFP SDI clocking — U56 is the only practical reference.** The SFP lane is in
   **Quad 226**. A quad can only borrow a refclk from the quad directly above/below,
   so U57's "SFP_156.25M" output (on **Quad 224**) **cannot reach the SFP lane**. Quad
   226's refclks are **U56** (REFCLK0) and the HDMI-RX TMDS clock (REFCLK1); Quad 225's
   FMC GBTCLK0/1 are also reachable. → Program **U56 to 148.5 MHz** (and use QPLL
   fractional-N or a second ref for 148.5/1.001). **Bonus:** U56 is a jitter
   attenuator fed by an FPGA-forwarded clock — the *exact* source-locked clocking
   architecture v1 needs (`10` "v1 vs Pro"; Si5392 role on the product). **Conflict:**
   HDMI TX also uses U56, so don't run HDMI TX and SFP-SDI on different clocks at the
   same time.
2. **FMC LVDS must land on HP-bank pairs at VADJ = 1.8 V.** The LA pairs are split
   between **HP** banks (most of them) and **HD** banks (LA08, 22, 25, 27, 29, 31,
   CLK1). HD banks can't do high-speed LVDS deserialization, so the LT7911UXC's
   ~1.2 Gb/s/lane LVDS (or MIPI D-PHY) must map to **HP** LA pairs, and VADJ must be
   set to **1.8 V**. Count the needed lanes against the LT7911UXC datasheet (4K60
   10-bit 4:2:2 ≈ 12 Gb/s → ≥10 LVDS lanes + clocks, or 4-lane MIPI at ~2.5 Gb/s).
3. **DDR4 is 1 GB x32** per the UG — fine for v1 (no frame buffer) and the bench, but
   note it for the Pro DDR-bandwidth budget (`10`).

## What else to get (beyond the 12G SFP module)

| Need | Why | Notes |
|---|---|---|
| **Heatsink** (Boyd EA-270-H245-T710 or equal) + optional 5 V fan on J3 | Tria's tested thermal solution; 12G GTH + HDMI runs warm | *verify whether the kit includes one* |
| **micro-USB (B) data cable** | JTAG + UART on J9 | kit-contents lists conflict |
| **FMC breakout — buy ONE:** AMD **HW-FMC-XM105** debug card (eBay open-box ~$150, no returns) *or* Terasic **F2G** (P0551, new) | I²C/GPIO to the LT7911UXC EVB, STM32 hookup, probing, **low-rate** LVDS/MIPI bring-up | See "Breakout notes" below — not a 4K60 data path |
| **LT7911UXC EVB** (+ datasheet under NDA) | The DP-RX chip under test (`06` Q13) | Request via Lontium FAE / US channel |
| **SFP-to-BNC adapter cable** | Most SFP SDI modules are HD-BNC or DIN 1.0/2.3 | Match the module; 12G-rated |
| **12G-rated coax** (Belden 4794R / 1694A-class) + full BNC | SDI to analyzer / monitor | — |
| **HDMI 2.0 cables** (×2, 18 Gb/s rated) | MeLE → J24, J28 → monitor | — |
| **USB-C ↔ DP / USB-C cable** | Mac / PC DP Alt source → LT7911UXC EVB | depends on EVB connector |
| **4K60 HDMI monitor** | HDMI passthrough check | — |
| **12G-SDI monitor / analyzer** | Format, lock, payload ID, eye | rent / borrow; SC1221 as reference |
| Bench PSU with current readout (optional) | Feed 12 V to J51 and log board power | nice to have |

Not needed: anything for PCIe, SFP fiber, or the Click site.

## Software / licenses

- **Vivado** (+ **Vitis** for MicroBlaze apps used by AMD example designs). *Verify the
  free edition covers XCAU15P.*
- **Board files:** `github.com/Avnet/bdf` → copy into Vivado `data/boards/board_files`.
  Known forum issue: the **300 MHz sys clock may be missing from the board tab** (seen
  on 2023.2–2025.1) — copy the BDF manually and/or constrain AD21/AE21 by hand.
- **Avnet/hdl** repo + the board's element14 page for reference designs / schematics.
- **FTDI VCP driver** on the host for the UART.
- **Renesas Timing Commander** for 8T49N241 (U56/U57) register plans.
- **AMD eval licenses** (hardware-timeout): HDMI 2.1/2.0 RX/TX Subsystem (bench only),
  SMPTE UHD-SDI TX. **IBERT is free** — use it for first GTH/SFP checks.

## Basic bring-up — connection by connection

> **Board received 2026-10-27.** Step 3 ("blinky") is ready to run: [`../fpga/auboard/`](../fpga/auboard/README.md)
> (Vivado 2025.2 batch build, same flow as Schindler). Simulated, not yet built in Vivado.

**0. Before power**
- Fit the heatsink. Check jumpers: mode = Master SPI (default), **J11 = 1-2** (FPGA only
  in JTAG), **J17** fitted (SFP enabled), leave J22 at default. Nothing in the FMC yet.

**1. Power**
- 12 V brick → **J51**, **SW1** on → **D18 green** (sequencing done). If the QSPI holds a
  factory demo, **D19 blue** (DONE) follows. No D18 → stop; check supply.

**2. Host link**
- micro-USB → **J9**. Install the VCP driver; open a serial terminal on the new COM
  port *(baud per the demo — verify; 115200 is typical)*. Vivado **Hardware Manager →
  auto-connect** should list `xcau15p`.

**3. First bitstream ("blinky")**
- From the board file: SYS_CLK 300 MHz (AD21/AE21) → counter → user LEDs (A10/B10/B11/C11);
  DIP/push buttons echo to the RGB LEDs; UART "hello" at AF15/AF14. Proves toolchain,
  board files, JTAG, UART.

**4. Clock chips**
- Small MicroBlaze or I²C-master design: drive **U56 RST_N (G22) high**; read/write U56 on
  the HDMI_CTL bus (R23/R22) and U57 at 0x7C (B9/A9). Program U56 for **148.5 MHz** on
  Quad 226 REFCLK0 and confirm with a frequency counter in fabric (ILA).

**5. HDMI passthrough (eval license)**
- MeLE / 4K60 source → **J24**; **J28** → 4K monitor. Build AMD's HDMI RX→TX example for
  the AUBoard (U56 in jitter-attenuator mode). Validates Quad 226, the retimers, and U56
  locking to a source — the same mechanism v1 SDI uses.

**6. SFP 12G-SDI out**
- SFP SDI module → **J13**; adapter → coax → SDI monitor/analyzer (SC1221 alongside as
  reference). **IBERT** first on Quad 226 lane 3 (QPLL lock at 11.88 Gb/s, TX running);
  then UHD-SDI TX fed by the ported Schindler **`pg_tsg`**: 3G → 6G → 12G; check ST 352,
  lock, eye. (`05` Phase 2.)

**7. HDMI in → SDI out, source-locked**
- J24 HDMI RX → color/4:2:2 → UHD-SDI TX on the SFP; U56 locked to the forwarded source
  clock. Check zero drop/repeat across the frame-rate list. (`05` Phase 3.)

**8. DP path (Mac support) — LT7911UXC on the FMC**
- **Set VADJ = 1.8 V.** LT7911UXC EVB ↔ FMC breakout ↔ CON1 on **HP** LA pairs; I²C to the
  chip from FPGA (or STM32 on a Click/Pmod-style header). Mac/PC USB-C DP → EVB. LVDS (or
  MIPI) deserializer in fabric → same color → SDI path. **Confirm the chip's HDCP is
  disabled** (`06` Q11). (`05` Phase 4.)

## Breakout notes (XM105 vs F2G)

- **Both fit physically.** The AUBoard's CON1 is an HPC-size connector wired as LPC (LA00–LA33) + 4 GTH.
  - **XM105:** LA headers live; its HA/HB headers are dead on this board. AMD-native, Xilinx pin maps,
    ID EEPROM on the FMC I²C bus. Passive → fine at VADJ 1.8 V.
  - **F2G:** four 2×20 GPIO headers, **only GPIO0/GPIO1 live** on LPC-wired hosts (Terasic note);
    no level shifting (I/O = VADJ); VCC_GPIO selectable. Intel/Terasic-first — build our own pin map.
- **Header + jumper-wire limit:** LVDS lane rate = 7× the per-port pixel clock, so **1080p60 is already
  ~1.04 Gb/s/lane** — unreliable over 0.1" headers/ribbons. Bring up at **720p60 / 1080p30
  (~520 Mb/s/lane)**; full 4K60 (LVDS ~1.04 Gb/s × ~24 pairs, or MIPI 2 ports × 4 lanes) needs a
  **small FMC → EVB adapter PCB** with length-matched pairs on **HP-bank** LA pins.
- **HD-bank LA pairs** (LA08, 22, 25, 27, 29, 31, CLK1) are for slow signals only.
- Set **J11 = 1-2** (FPGA-only JTAG) unless the card passes TDI→TDO.

## Open items for this guide

- [ ] Confirm kit contents (heatsink? USB cable?) on arrival.
- [ ] Confirm DDR4 size (1 GB per UG vs 2 GB marketing).
- [ ] Find how VADJ is selected (jumper/resistor) in the schematic.
- [ ] Get the AUBoard schematic + element14 reference designs.
- [ ] Buy one FMC breakout (XM105 or F2G) for I²C/low-rate bring-up.
- [ ] Decide on the FMC → EVB adapter PCB once the LT7911UXC EVB connector/pinout is known.
- [ ] Lontium: sample request + account application submitted 2026-10-13 — awaiting review (`05` Phase 0).
- [ ] Confirm U56 output plan covers both 1.000 and 1.001 SDI families.
