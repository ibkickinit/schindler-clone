/* analog_iic.c — Engine-B analog leg G1+ : Si5351 (0x60) + ADV7393 (0x2A) on one I2C bus.
 *
 * EVERY routine here is written against the hard-won 2026-05-20/21 bench discoveries (memory:
 * axi_iic_dynsend_pattern, axi_iic_dynamic_mode_atomicity, si5351_sys_init_poll, i2c_pullup_rule,
 * si5351_chip_missing_restart, schindler_phase_g_iter1p5_state, bench_diagnostic_heisenbug):
 *
 *   1. USE THE XIic LIBRARY, never hand-rolled register pokes. (2026-05-21: a full session was lost to
 *      a hand-rolled driver silently dropping the 3rd byte of multi-byte writes — 18 SCL pulses where 27
 *      were needed. The library frames dynamic mode + RESTART reads correctly. We use the low-level
 *      polled xiic_l.h XIic_Send/XIic_Recv, the same path the iter1.5 ADV7393 probe used safely.)
 *   2. Si5351 SYS_INIT POLL: reg0 bit7 must read 0 BEFORE any RAM write. The address probe ACKs before
 *      the chip is ready -> writes during SYS_INIT silently fail. (Cost hours of false AXI-IIC debug.)
 *   3. NO mid-transaction printf or delays. Diagnostics perturbed the bus and CAUSED the NAKs
 *      (Heisenbug). All logging is deferred to AFTER a sequence completes; scope, not IP-snapshot.
 *   4. ADV7393 needs DVDD=1.8V (external supply on the bare breakout) or its I2C state machine is DEAD
 *      — the likely cause of the old "chip not detected". Probe ACK is the live-chip gate; if it NAKs,
 *      check the 1.8V rail + the 2.2k pull-ups (Si5351 breakout has none; ADV7393 breakout does).
 *   5. Pull-ups: external 2.2k (or 1k) on SDA/SCL — internal FPGA ~50k is not a real bus pull-up.
 */
#include "xil_printf.h"
#include "xil_io.h"
#include "xparameters.h"

#ifdef ANALOG_BUILD
#include "xiic_l.h"     /* low-level polled XIic_Send/XIic_Recv (dynamic mode, correct framing) */

typedef unsigned char  u8;
typedef unsigned int   u32;
typedef int            s32;

#define SI5351_ADDR   0x60
#define ADV7393_ADDR  0x2A

#if   defined(XPAR_AXI_IIC_0_BASEADDR)
#  define IIC_BASE    XPAR_AXI_IIC_0_BASEADDR
#elif defined(XPAR_AXI_IIC_0_BASEADDRESS)
#  define IIC_BASE    XPAR_AXI_IIC_0_BASEADDRESS
#endif

/* GPIO that drives ADV7393 RESET (active-low) bit0, and reads the Si5351-clock freq counter.
 * (BD: axi_gpio_adv = ch1[0] reset out ; freq counter -> ch2 read.) Names resolved at build time. */
#if   defined(XPAR_AXI_GPIO_ADV_BASEADDR)
#  define ADV_GPIO_BASE XPAR_AXI_GPIO_ADV_BASEADDR
#elif defined(XPAR_AXI_GPIO_20_BASEADDR)
#  define ADV_GPIO_BASE XPAR_AXI_GPIO_20_BASEADDR
#endif

static void busy_us(int us) { for (volatile int i = 0; i < us * 80; i++) { } }  /* ~us at 650MHz A9 */

/* ---- I2C primitives (XIic library, polled). reg-first write; RESTART read. ----------------------- */
static int iic_write(u8 addr, const u8 *buf, int n)   /* buf[0]=reg, then data; ONE atomic transaction */
{
#ifdef IIC_BASE
    int sent = XIic_Send(IIC_BASE, addr, (u8 *)buf, n, XIIC_STOP);
    return (sent == n) ? 0 : -1;
#else
    (void)addr; (void)buf; (void)n; return -100;
#endif
}
static int iic_read(u8 addr, u8 reg, u8 *out, int n)
{
#ifdef IIC_BASE
    if (XIic_Send(IIC_BASE, addr, &reg, 1, XIIC_REPEATED_START) != 1) return -1;   /* RESTART, no STOP */
    int got = XIic_Recv(IIC_BASE, addr, out, n, XIIC_STOP);
    return (got == n) ? 0 : -2;
#else
    (void)addr; (void)reg; (void)out; (void)n; return -100;
#endif
}
static int iic_w1(u8 addr, u8 reg, u8 val) { u8 b[2] = { reg, val }; return iic_write(addr, b, 2); }
static int iic_probe(u8 addr) { u8 z = 0; return (XIic_Send(IIC_BASE, addr, &z, 0, XIIC_STOP) == 0) ? 0 : -1; }

int analog_iic_init(void)
{
#ifdef IIC_BASE
    /* low-level XIic needs no CfgInitialize; it operates directly on the base. One DynInit is implicit
     * in XIic_Send's dynamic path. Nothing to do here but confirm the base exists. */
    return 0;
#else
    return -100;
#endif
}

/* ================================ Si5351 — 27.000 MHz on CLK0 ===================================== *
 * 25 MHz xtal. PLLA = 648 MHz (a=25, b=23, c=25 -> 25.92x), MS0 = 24 (integer) -> 648/24 = 27.000 MHz.
 * AN619 register math (P1/P2/P3) precomputed below; the G2 freq counter is the on-bench verification
 * (if it doesn't read 27.000, the values get nudged — not guessed-perfect on paper).                 */
static int si5351_wait_sys_init(void)            /* GUARDRAIL 2: poll reg0 bit7 == 0 before any write */
{
    u8 st;
    for (int i = 0; i < 2000; i++) {
        if (iic_read(SI5351_ADDR, 0, &st, 1) == 0 && !(st & 0x80)) return 0;
        busy_us(500);
    }
    return -1;   /* SYS_INIT never cleared -> chip absent / not ready (NOT an AXI-IIC bug) */
}
int si5351_bringup_27mhz(void)
{
    /* PLLA (a=25 b=23 c=25): P1=2805(0x0AF5) P2=19 P3=25 ; MS0(int 24): P1=2560(0x0A00) P2=0 P3=1 */
    static const u8 plla[8] = { 0x00,0x19, 0x00,0x0A,0xF5, 0x00,0x00,0x13 }; /* regs 26..33 */
    static const u8 ms0 [8] = { 0x00,0x01, 0x00,0x0A,0x00, 0x00,0x00,0x00 }; /* regs 42..49 */
    int rc;
    if (iic_probe(SI5351_ADDR) != 0) return -10;       /* no ACK -> chip/pull-ups/wiring (scope SDA) */
    if (si5351_wait_sys_init()   != 0) return -11;      /* not ready */
    if ((rc = iic_w1(SI5351_ADDR, 3,   0xFF)) != 0) return -12;   /* disable all outputs */
    for (u8 r = 16; r <= 23; r++) iic_w1(SI5351_ADDR, r, 0x80);   /* power down all CLK */
    iic_w1(SI5351_ADDR, 183, 0xD2);                              /* xtal load cap 10pF */
    for (int i = 0; i < 8; i++) iic_w1(SI5351_ADDR, 26 + i, plla[i]);   /* PLLA params */
    for (int i = 0; i < 8; i++) iic_w1(SI5351_ADDR, 42 + i, ms0 [i]);   /* MS0 params  */
    iic_w1(SI5351_ADDR, 16,  0x4F);   /* CLK0: PDN=0, MS0_INT=1, src=PLLA, MS0, 8mA */
    iic_w1(SI5351_ADDR, 177, 0xA0);   /* reset PLLA (+PLLB) */
    iic_w1(SI5351_ADDR, 3,   0xFE);   /* enable CLK0 only */
    return 0;
}

/* ============================ ADV7393 — G1 reset + probe + comms check ============================ *
 * Full NTSC-M composite register config is G3 (first-light color bars); G1 proves the chip is ALIVE
 * (DVDD=1.8V present, I2C comms good). RESET via GPIO (active-low, 1k series on JE6), then probe 0x2A,
 * then a write/read-back round-trip to confirm the bus path.                                          */
static void adv7393_reset_pulse(void)
{
#ifdef ADV_GPIO_BASE
    Xil_Out32(ADV_GPIO_BASE + 0x00, 0x0);   /* RESET low  */
    busy_us(2000);
    Xil_Out32(ADV_GPIO_BASE + 0x00, 0x1);   /* RESET high (release) */
    busy_us(5000);
#endif
}
int adv7393_bringup_ntsc(void)
{
    u8 rb = 0;
    adv7393_reset_pulse();
    if (iic_probe(ADV7393_ADDR) != 0) return -20;   /* NAK -> check DVDD=1.8V rail + pull-ups FIRST */
    /* comms round-trip: write a scratch (SD Hue, reg 0x8C) then read it back. Confirms SDA/SCL path. */
    if (iic_w1(ADV7393_ADDR, 0x8C, 0x5A) != 0) return -21;
    if (iic_read(ADV7393_ADDR, 0x8C, &rb, 1) != 0) return -22;
    if (rb != 0x5A) return -23;                      /* readback mismatch -> SI / wrong reg */
    /* TODO G3: full NTSC-M composite config (soft-reset 0x17, power 0x00, SD mode 0x80.., DAC route). */
    return 0;
}

/* ============================ Si5351 clock freq counter (G2 sanity) =============================== *
 * BD: a counter on the BUFG'd Si5351 clock domain, sampled vs a known FCLK gate -> Hz, read via GPIO. */
unsigned si5351_clk_measure_hz(void)
{
#ifdef ADV_GPIO_BASE
    return (unsigned)Xil_In32(ADV_GPIO_BASE + 0x08);   /* ch2 = measured Hz (BD computes count*scale) */
#else
    return 0;
#endif
}

/* ================================ UART 'A ...' analog sub-commands ================================ */
void analog_iic_cmd(const char *args)
{
    while (*args == ' ') args++;
    char sub = *args ? *args : '?';
    int rc;
    switch (sub) {
        case 'i': rc = analog_iic_init();      xil_printf("ANALOG iic_init rc=%d\r\n", rc); break;
        case 'c': rc = si5351_bringup_27mhz(); xil_printf("ANALOG si5351 27MHz rc=%d (scope CLK0)\r\n", rc); break;
        case 'f': xil_printf("ANALOG si5351 clk = %u Hz (BUFG counter)\r\n", si5351_clk_measure_hz()); break;
        case 'a': rc = adv7393_bringup_ntsc(); xil_printf("ANALOG adv7393 rc=%d %s\r\n", rc,
                      rc==-20 ? "(NAK: check DVDD=1.8V + pull-ups!)" : ""); break;
        case 's': { /* bus scan */
            xil_printf("ANALOG i2c scan:");
            for (u8 a = 0x08; a < 0x78; a++) if (iic_probe(a) == 0) xil_printf(" 0x%02x", a);
            xil_printf("\r\n"); break; }
        default:
            xil_printf("ANALOG: A i=init c=si5351-27MHz f=freq a=adv7393 s=scan\r\n");
    }
}

#endif /* ANALOG_BUILD */
