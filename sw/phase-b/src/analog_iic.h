/* analog_iic.h — Engine-B analog leg (G1+): shared I2C bus for Si5351 (0x60) + ADV7393 (0x2A),
 * Si5351 27 MHz bring-up, ADV7393 NTSC bring-up, and the BUFG'd-27MHz freq counter (G2).
 *
 * Gated by ANALOG_BUILD (the BD adds axi_iic + the clock-in + reset GPIO only in the analog build).
 * Every routine bakes in the hard-won bench lessons (see the .c header): XIic LIBRARY (never hand-rolled
 * — the 2026-05-21 byte-drop discovery), Si5351 SYS_INIT poll, NO mid-transaction printf/delays.
 */
#ifndef ANALOG_IIC_H
#define ANALOG_IIC_H
#ifdef ANALOG_BUILD

int      analog_iic_init(void);             /* XIic init the shared bus once at boot. 0 = ok. */
int      si5351_bringup_27mhz(void);        /* probe + SYS_INIT poll + 27.000 MHz on CLK0. 0 = ok. */
int      adv7393_bringup_ntsc(void);        /* RESET pulse + probe + NTSC-M SD config + device-ID. 0 = ok. */
unsigned si5351_clk_measure_hz(void);       /* measured freq of the BUFG'd Si5351 clock (G2 sanity). */
void     analog_iic_cmd(const char *args);  /* UART 'A ...' sub-commands (init/clk/adv/scan/freq). */

#endif /* ANALOG_BUILD */
#endif /* ANALOG_IIC_H */
