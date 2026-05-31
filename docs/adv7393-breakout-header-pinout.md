# ADV7393 Breakout Board — Header-to-Chip Pin Mapping

**Status:** field-traced by Justin during the 2026-05-20 bench session. Vendor
did not document this. Keep this file current — without it, re-deriving the
mapping costs a multimeter-continuity session per pin.

## What this is

The bare ADV7393 breakout PCB has a 40-pin header along its edge. The header's
pin numbers (1..40) do **not** map 1:1 to the chip's pin numbers (1..40 per
ADV7392/ADV7393 LFCSP, Figure 19 of the datasheet). The PCB router chose its
own header order. This doc records the header-to-chip mapping so we can wire
to the header (which is what we physically touch) while reasoning about the
chip (which is what the datasheet describes).

**Chip variant on this breakout:** ADV7393 (40-pin LFCSP, Figure 19).

**How the mapping was derived:** continuity-beep from each header pin to the
chip's pads, on the bench, 2026-05-20.

## Header → Chip mapping

Legend:
- **HDR**: pin number on the breakout's 40-pin header
- **Chip**: chip pin per Figure 19 (40-pin LFCSP)
- **Signal**: datasheet signal name
- **Color**: jumper-wire color in use on Justin's bench
- **Wired to**: where the other end of the jumper currently lands

| HDR | Chip | Signal | Color | Wired to | Notes |
|----:|-----:|--------|-------|----------|-------|
| 1   | 25   | VAA (3.3V analog)   | _____ | Bench PSU 3.3V Ch | |
| 3   | 1    | VDD_IO (3.3V I/O)   | _____ | Bench PSU 3.3V Ch | |
| 5   | 6 or 35 | VDD (1.8V digital) | _____ | Bench PSU 1.8V Ch | which chip pin? VDD is dual-bonded |
| 7   | 23   | PVDD (1.8V PLL)     | _____ | Bench PSU 1.8V Ch | |
| 11  | 13   | SDA                 | Yellow | Zybo JD7 (U14)   | I²C data |
| 12  | 14   | SCL                 | Orange | Zybo JD8 (U15)   | I²C clock |
| 14  | 33   | HSYNC               | Gray   | _____            | not currently driven |
| 15  | 32   | VSYNC               | Violet | _____            | not currently driven |
| 17  | 34   | P0                  | Blue   | _____            | parallel video data |
| 19  | 37   | P1                  | _____  | _____            | |
| 21  | 38   | P2                  | Orange | _____            | |
| 23  | 39   | P3                  | Yellow | _____            | |
| 25  | 2    | P4                  | Green  | _____            | |
| 27  | 3    | P5                  | Blue   | _____            | |
| 29  | 4    | P6                  | Violet | _____            | |
| 31  | 5    | P7                  | _____  | _____            | jumper removed/TBD |
| 37  | ?    | GND                 | _____  | Bench PSU GND     | which chip-pin GND? |
| 38  | 20   | RESET (active low)  | Brown  | Zybo JE6 (3.3V)  | **NO series resistor — see warning** |
| 39  | 19   | CLKIN (27 MHz)      | _____  | Zybo JD1 (T14)   | 3.3V CMOS |

### Pins not yet traced

Header pins **2, 4, 6, 8, 9, 10, 13, 16, 18, 20, 22, 24, 26, 28, 30, 32–36, 40**
have not been verified yet. Fill in as you trace them. Likely candidates by
chip-pin elimination:

- Remaining digital data pins: P8, P9, P10, P11, P12, P13, P14, P15
- Remaining grounds: DGND (chip 7 or 36), AGND (chip 24), PGND (chip 21), GND_IO (chip 40)
- Analog outputs: DAC1 (chip 28), DAC2 (chip 27), DAC3 (chip 26), COMP (chip 29), RSET (chip 30)
- Misc: ALSB (chip 12, currently strapped low on the board), SFL (chip 31), EXT_LF (chip 22)

## Onboard passives present (confirmed 2026-05-20)

- **EXT_LF (chip pin 22):** capacitor populated. PLL loop filter OK.
- **RSET (chip pin 30):** resistor populated. DAC current-set OK.
- **ALSB (chip pin 12):** strapped to GND on-board → I²C address = 0x2A (7-bit).
- **SDA/SCL pull-ups:** 2.2 kΩ each, on-board.

## Warnings

- **RESET (HDR 38 → chip pin 20) has no series resistor on the breakout.**
  Grounding the chip-side pin while it's wired to JE6 (Zybo 3.3V rail) will
  short 3.3V → GND and reset the Zybo. Either disconnect the JE6 end before
  pulsing reset, or add a 1 kΩ series resistor between JE6 and HDR 38.
  Recommended: solder a 1 kΩ resistor inline before the next bench session.

- **Power-up order:** apply 3.3V *before* 1.8V (per Analog Devices reference;
  prevents latch-up on digital pads).

## How to apply

- When firmware references "chip pin 13 = SDA", that's the **chip** datasheet
  pin; physically wire to **header pin 11** on this breakout.
- The XDC at `constraints/zybo_z7_20_phase_b.xdc:86-87,93` documents Zybo →
  chip-pin destinations directly (skipping the header layer). That's the
  authoritative side; this doc just records the breakout's intermediate
  numbering so the bench jumpers are connectable.
- Update this table whenever a new header pin gets traced or a jumper moves.
