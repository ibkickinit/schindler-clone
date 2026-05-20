/*
 * si5351.h — minimal Si5351A driver for Phase E2 Schindler clock-pull loop.
 *
 * Direct AXI IIC register access (bypassing XIic library — same approach as
 * the iter1.6 ADV7393 probe). The library proved fragile on the previous
 * bench session; PG090 register pokes are predictable and what we need is
 * narrow enough that a thin direct driver is cleaner.
 *
 * Bench bring-up phases (per docs/si5351-bench-bringup.md):
 *   A. Chip alive at 0x60                  — si5351_probe()
 *   B. Synth 10 MHz on CLK0 (this driver)  — si5351_init_10mhz_clk0()
 *   C. Drive FPGA clock through clk_wiz    — same init, just different scope point
 *   D. Open-loop pullability sweep         — adds si5351_set_offset_ppm()
 *   E. Closed-loop swap                    — same set_offset_ppm, called from PI controller
 */

#ifndef SI5351_H
#define SI5351_H

#include "xil_types.h"

/* Default I²C address; JESSINIE boards strap ADDR low → 0x60 (7-bit). */
#define SI5351_I2C_ADDR_7B  0x60

/* Single-byte probe at 0x60.
 *   Returns 0 if chip ACKs, negative on NAK / timeout. */
int si5351_probe(u32 iic_base);

/* Bench-debug: probe every 7-bit address 0x03..0x77 (skipping I²C reserved
 *   ranges 0x00-0x02 and 0x78-0x7F). Prints a line for each address that
 *   ACKs. Useful when the chip's expected address (0x60) is unreachable. */
void si5351_scan_bus(u32 iic_base);

/* Cold-init the chip and bring up CLK0 at exactly 10.000 MHz.
 *   Crystal = 25 MHz (JESSINIE breakout), PLLA × 24 → 600 MHz,
 *   Multisynth 0 ÷ 60 → 10 MHz. Integer mode, 8 mA drive, no invert.
 *   CLK1 and CLK2 left powered down.
 *   Returns 0 on success, negative on any register-write NAK. */
int si5351_init_10mhz_clk0(u32 iic_base);

/* Cold-init the chip and bring up CLK0 at exactly 25.000 MHz.
 *   Crystal × PLLA × MS = 25 × 24 / 24 = 25 MHz. Picked because Zynq-7020's
 *   PLLE2_ADV (used by clk_wiz_si5351 in Phase C) has a 19 MHz minimum input
 *   frequency — 10 MHz is below spec. CLK1 and CLK2 left powered down.
 *   Returns 0 on success, negative on any register-write NAK. */
int si5351_init_25mhz_clk0(u32 iic_base);

#endif
