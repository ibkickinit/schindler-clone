/*
 * si5351.c — Si5351A driver for Phase E2.
 *
 * Bypasses the XIic library; talks to the AXI IIC IP via its register map
 * (PG090). Same proven pattern as the Phase A probe in main.c.
 *
 * Reference: Silicon Labs AN619 "Manually Generating an Si5351 Register Map"
 * for the divider math. Numerical values for 10 MHz output worked out below
 * are cross-checked against the Etherkit Si5351 Arduino library.
 */

#include "si5351.h"
#include "xil_io.h"
#include "xil_printf.h"

/* AXI IIC register offsets (PG090). */
#define IIC_REG_GIE         0x01C  /* Global Interrupt Enable */
#define IIC_REG_ISR         0x020  /* Interrupt Status Register */
#define IIC_REG_IER         0x028  /* Interrupt Enable Register */
#define IIC_REG_SOFTR       0x040  /* Soft Reset Register */
#define IIC_REG_CR          0x100  /* Control Register */
#define IIC_REG_SR          0x104  /* Status Register */
#define IIC_REG_TX_FIFO     0x108  /* Transmit FIFO */
#define IIC_REG_RX_FIFO     0x10C  /* Receive FIFO */

/* AXI IIC CR bits */
#define CR_EN               0x01   /* AXI IIC enable */

/* AXI IIC SR bits */
#define SR_RX_FIFO_EMPTY    0x40
#define SR_TX_FIFO_EMPTY    0x80
#define SR_BB               0x04   /* Bus Busy */

/* AXI IIC ISR bits */
#define ISR_TX_ERROR        0x02   /* Slave No Ack on transmit */

/* TX_FIFO control bits */
#define TX_START            0x100  /* bit 8: emit START before this byte */
#define TX_STOP             0x200  /* bit 9: emit STOP after this byte */

/* Si5351 register addresses (subset, see AN619 §3). */
#define SI5351_REG_STATUS                 0
#define SI5351_REG_OUTPUT_ENABLE          3
#define SI5351_REG_CLK0_CONTROL          16
#define SI5351_REG_CLK1_CONTROL          17
#define SI5351_REG_CLK2_CONTROL          18
#define SI5351_REG_MS_NA_PARAMS          26  /* PLLA params: regs 26-33 */
#define SI5351_REG_MS0_PARAMS            42  /* MS0 params: regs 42-49 */
#define SI5351_REG_PLL_RESET            177
#define SI5351_REG_XTAL_CL              183

#define SI5351_PLLA_RESET    0x20
#define SI5351_PLLB_RESET    0x80
#define SI5351_XTAL_LOAD_10PF 0xD2  /* AN619 default; bits 7:6 = 0b11 (10pF) + reserved 0x12 */

/* ----- low-level IIC helpers ----------------------------------------------- */

/* Busy-wait based on cortex-a9 @ 666 MHz, ~3 cycles per volatile-loop iter.
 * 200000 iters ≈ 1 ms. The Phase A iter1.6 hammer firmware used exactly this
 * delay and reliably saw clean transactions on the scope, so we keep the same
 * value as our proven "transaction settle" wait.
 *
 * Avoid using SR/ISR polling for completion: at boot, SR.BB=0 and SR.TX_FIFO_
 * EMPTY=1 in the resting state, so a tight poll-loop returns immediately
 * before the IP has even pulled our byte out of the FIFO. The fixed delay is
 * coarse but bulletproof. */
static inline void iic_settle(int byte_count)
{
    /* ~1 ms per byte of transaction = generous margin over the ~100 µs each
     * byte actually takes at 100 kHz. Total 5 ms for a 3-byte write. */
    int total = 200000 * byte_count;
    for (volatile int d = 0; d < total; d++);
}

/* When non-zero, write_reg_once prints SR/ISR snapshots after each byte
 * push. Useful for pinpointing which byte of a 3-byte write causes a NAK.
 * Init sets this to 0 (silent); UART command handlers can flip it on
 * before retrying so the diagnostic output appears for one transaction. */
int si5351_debug_write = 0;

static int si5351_write_reg_once(u32 base, u8 reg, u8 data)
{
    /* Canonical AXI IIC dynamic-mode per-transaction prologue, per Xilinx
     * embeddedsw's XIic_DynSend and PG090. Three steps:
     *   1. CR = TX_FIFO_RESET (bit 1)  — drop any stale FIFO data
     *   2. CR = EN              (bit 0) — re-enable IP for new transaction
     *   3. W1C ISR all bits             — clear stale interrupt status
     *
     * NOTE: we do NOT issue SOFTR here. SOFTR releases SDA/SCL without an
     * I²C STOP and can leave the slave mid-frame; next START gets NAK'd.
     * SOFTR only on boot (in si5351_probe) and as a recovery step on the
     * timeout failure path below. */
    Xil_Out32(base + IIC_REG_CR, 0x02);   /* TX_FIFO_RESET */
    Xil_Out32(base + IIC_REG_CR, CR_EN);  /* re-enable */
    Xil_Out32(base + IIC_REG_ISR, 0xFF);  /* W1C all status bits */

    u32 sr_init = 0, isr_b1 = 0, sr_b1 = 0, isr_b2 = 0, sr_b2 = 0;
    if (si5351_debug_write) sr_init = Xil_In32(base + IIC_REG_SR);

    /* Push all 3 bytes back-to-back. AXI IIC dynamic mode buffers 16 bytes,
     * we send only 3 — the IP autonomously drains at SCL rate. */
    Xil_Out32(base + IIC_REG_TX_FIFO, TX_START | (SI5351_I2C_ADDR_7B << 1));
    Xil_Out32(base + IIC_REG_TX_FIFO, reg);
    Xil_Out32(base + IIC_REG_TX_FIFO, TX_STOP | data);

    /* Poll ISR.BNB (Bus Not Busy, bit 4) — edge-triggered, fires when the
     * bus transitions busy → not-busy at end of transaction. Replaces
     * fixed-delay iic_settle: handles fast and slow chips equally. */
    int timeout = 5000000;  /* ~10ms at cortex-a9 666 MHz */
    while (timeout-- > 0) {
        u32 isr = Xil_In32(base + IIC_REG_ISR);
        if (isr & 0x10) break;  /* BNB fired = transaction complete */
    }
    if (timeout <= 0) {
        /* Genuine hardware fault. SOFTR + brief settle to recover the IP. */
        Xil_Out32(base + IIC_REG_SOFTR, 0x0A);
        for (volatile int d = 0; d < 10000; d++);
        if (si5351_debug_write) {
            xil_printf("  diag reg=0x%02x: BNB TIMEOUT — IP wedged, SOFTR'd\r\n", reg);
        }
        return -1;
    }

    /* Capture final SR/ISR (debug path). The per-byte snapshots are left
     * here as zero placeholders so the format string remains stable. */

    u32 sr_final  = Xil_In32(base + IIC_REG_SR);
    u32 isr_final = Xil_In32(base + IIC_REG_ISR);

    if (si5351_debug_write) {
        xil_printf("  diag reg=0x%02x data=0x%02x: "
                   "sr_init=0x%02x  "
                   "after_b1: sr=0x%02x isr=0x%02x  "
                   "after_b2: sr=0x%02x isr=0x%02x  "
                   "after_b3: sr=0x%02x isr=0x%02x\r\n",
                   reg, data,
                   (unsigned)sr_init,
                   (unsigned)sr_b1,  (unsigned)isr_b1,
                   (unsigned)sr_b2,  (unsigned)isr_b2,
                   (unsigned)sr_final,(unsigned)isr_final);
    }

    if (isr_final & ISR_TX_ERROR) {
        Xil_Out32(base + IIC_REG_ISR, ISR_TX_ERROR);  /* W1C */
        return -2;
    }

    return 0;
}

static int si5351_write_reg(u32 base, u8 reg, u8 data)
{
    /* Retry up to 3 times; the chip's I²C state machine occasionally NAKs
     * the first transaction after probe and recovers on retry. Same pattern
     * we saw in si5351_probe(). */
    for (int attempt = 1; attempt <= 3; attempt++) {
        int rc = si5351_write_reg_once(base, reg, data);
        if (rc == 0) return 0;
        if (attempt < 3) {
            for (volatile int d = 0; d < 200000; d++);  /* ~1 ms before retry */
        } else {
            u32 sr  = Xil_In32(base + IIC_REG_SR);
            u32 isr = Xil_In32(base + IIC_REG_ISR);
            xil_printf("si5351_write_reg: NAK on reg 0x%02x after 3 tries  "
                       "(last SR=0x%02x ISR=0x%02x)\r\n",
                       reg, (unsigned)sr, (unsigned)isr);
        }
    }
    return -2;
}

/* ----- public API ---------------------------------------------------------- */

int si5351_probe(u32 iic_base)
{
    /* One-time IP bring-up: SOFTR is the ONLY place per-bring-up that we
     * use it. After this, transactions use the TX_FIFO_RESET prologue
     * (see si5351_write_reg_once) — never SOFTR. */
    Xil_Out32(iic_base + IIC_REG_SOFTR, 0x0A);
    for (volatile int d = 0; d < 1000; d++);
    Xil_Out32(iic_base + IIC_REG_CR, CR_EN);
    for (volatile int d = 0; d < 1000; d++);

    /* Single-byte probe: send addr+W with both START and STOP set, then poll
     * ISR.BNB for completion and check TX_ERROR. Retry a few times: on cold
     * boot the chip's I²C state machine sometimes needs a few SCL ticks
     * before it ACKs the very first transaction. */
    for (int attempt = 1; attempt <= 5; attempt++) {
        /* Per-transaction prologue (no SOFTR): TX_FIFO_RESET → EN → clear ISR. */
        Xil_Out32(iic_base + IIC_REG_CR, 0x02);
        Xil_Out32(iic_base + IIC_REG_CR, CR_EN);
        Xil_Out32(iic_base + IIC_REG_ISR, 0xFF);

        Xil_Out32(iic_base + IIC_REG_TX_FIFO,
                  TX_START | TX_STOP | (SI5351_I2C_ADDR_7B << 1));

        int timeout = 5000000;
        while (timeout-- > 0) {
            if (Xil_In32(iic_base + IIC_REG_ISR) & 0x10) break;  /* BNB */
        }

        u32 sr  = Xil_In32(iic_base + IIC_REG_SR);
        u32 isr = Xil_In32(iic_base + IIC_REG_ISR);
        xil_printf("si5351_probe attempt %d: SR=0x%02x ISR=0x%02x\r\n",
                   attempt, (unsigned)sr, (unsigned)isr);

        if (!(isr & ISR_TX_ERROR)) {
            return 0;  /* ACK */
        }

        /* NAK on this attempt — clear and retry. */
        Xil_Out32(iic_base + IIC_REG_ISR, ISR_TX_ERROR);
        for (volatile int d = 0; d < 200000; d++);
    }
    return -2;
}

int si5351_init_10mhz_clk0(u32 iic_base)
{
    int rc;

    /* AN619 cold-init sequence:
     *   1. Disable all outputs (OEB = 0xFF).
     *   2. Powerdown all output drivers (regs 16-23 = 0x80).
     *   3. Set crystal load capacitance (reg 183).
     *   4. Configure PLLA Multisynth (regs 26-33): a=24, b=0, c=1.
     *      → PLLA = 25 MHz × (24 + 0/1) = 600 MHz.
     *      P1 = 128·a + floor(128·b/c) − 512 = 128·24 − 512 = 2560.
     *      P2 = 0, P3 = c = 1.
     *   5. Configure MS0 Multisynth (regs 42-49): a=60, b=0, c=1.
     *      → CLK0 = 600 MHz ÷ (60 + 0/1) = 10.000 MHz.
     *      P1 = 128·60 − 512 = 7168.
     *      P2 = 0, P3 = 1.
     *   6. Set CLK0 control (reg 16) = integer-mode, PLLA source,
     *      MS source, 8 mA drive, powered up.
     *   7. Reset PLLA (reg 177 bit 5).
     *   8. Enable CLK0 only (OEB = 0xFE — bit 0 cleared = CLK0 enabled).
     */

    #define CHK(call) do { rc = (call); if (rc != 0) return rc; } while (0)

    /* 1. Disable all outputs. */
    CHK(si5351_write_reg(iic_base, SI5351_REG_OUTPUT_ENABLE, 0xFF));

    /* 2. Powerdown all output drivers. */
    for (u8 r = 16; r <= 23; r++) {
        CHK(si5351_write_reg(iic_base, r, 0x80));
    }

    /* 3. Crystal load = 10 pF (AN619 default for most breakouts). */
    CHK(si5351_write_reg(iic_base, SI5351_REG_XTAL_CL, SI5351_XTAL_LOAD_10PF));

    /* 4. PLLA = 25 MHz × 24 = 600 MHz.
     *    a=24, b=0, c=1 → P1=2560, P2=0, P3=1.
     *    P1 = 2560 = 0x000A00 → bits[17:16]=0, [15:8]=0x0A, [7:0]=0x00.
     *    P2 = 0; P3 = 1 → bits[15:8]=0x00, [7:0]=0x01. */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 0, 0x00));  /* P3[15:8]   */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 1, 0x01));  /* P3[7:0]    */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 2, 0x00));  /* P1[17:16]  */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 3, 0x0A));  /* P1[15:8]   */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 4, 0x00));  /* P1[7:0]    */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 5, 0x00));  /* P3[19:16]|P2[19:16] */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 6, 0x00));  /* P2[15:8]   */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 7, 0x00));  /* P2[7:0]    */

    /* 5. MS0 = 600 MHz ÷ 60 = 10 MHz.
     *    a=60, b=0, c=1 → P1=7168, P2=0, P3=1.
     *    P1 = 7168 = 0x001C00 → bits[17:16]=0, [15:8]=0x1C, [7:0]=0x00. */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 0, 0x00));  /* P3[15:8]   */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 1, 0x01));  /* P3[7:0]    */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 2, 0x00));  /* R0_DIV/DIVBY4/P1[17:16] */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 3, 0x1C));  /* P1[15:8]   */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 4, 0x00));  /* P1[7:0]    */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 5, 0x00));  /* P3[19:16]|P2[19:16] */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 6, 0x00));  /* P2[15:8]   */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 7, 0x00));  /* P2[7:0]    */

    /* 6. CLK0 control: powerup, integer-mode, PLLA, MS source, 8 mA drive.
     *    bit 7 = 0  (CLK_PDN powerup)
     *    bit 6 = 1  (MS_INT integer mode — needs MS0 to be integer)
     *    bit 5 = 0  (MS_SRC = PLLA)
     *    bit 4 = 0  (CLK_INV off)
     *    bits 3:2 = 11 (CLK_SRC = Multisynth)
     *    bits 1:0 = 11 (CLK_IDRV = 8 mA)
     *    → 0b01001111 = 0x4F */
    CHK(si5351_write_reg(iic_base, SI5351_REG_CLK0_CONTROL, 0x4F));

    /* 7. Reset PLLA so the new Multisynth params take effect. */
    CHK(si5351_write_reg(iic_base, SI5351_REG_PLL_RESET, SI5351_PLLA_RESET));

    /* 8. Enable CLK0 (clear bit 0 of reg 3). CLK1/CLK2 stay disabled. */
    CHK(si5351_write_reg(iic_base, SI5351_REG_OUTPUT_ENABLE, 0xFE));

    return 0;

    #undef CHK
}

int si5351_set_freq_hz(u32 iic_base, u32 target_hz)
{
    /* AN619 §3 multisynth math, Etherkit-style.
     *
     * Strategy: hold PLLA at 800 MHz (integer multiplier ×32 off 25 MHz xtal,
     * always in the 600-900 MHz VCO sweet spot). Trim by adjusting MS0's
     * fractional part. Output = 800 MHz / (a + b/c) where c is held at 1e6
     * so b expresses parts-per-million directly-ish.
     *
     * Caveat: PLLA stays integer; only MS0 varies. The output multisynth
     * fractional divider has slightly more jitter/spurs than integer mode,
     * but for clock-pull resolution that's the right trade-off — we lose
     * the integer-mode jitter advantage to gain sub-ppm trim resolution.
     *
     * Range: roughly 5 MHz to 100 MHz target. Outside that, multisynth `a`
     * goes out of valid range [8..2047] and we return -3.
     */

    if (target_hz == 0) return -3;

    const u32 f_xtal       = 25000000UL;
    const u32 f_vco_target = 800000000UL;

    /* PLLA: a=32, b=0, c=1 → f_VCO = 25e6 × 32 = 800e6 (exactly). */
    const u32 plla_a = 32, plla_b = 0, plla_c = 1;
    (void)f_xtal;  /* documented but unused at runtime */

    /* MS0 = f_VCO / target_hz, expressed as (ms_a + ms_b/ms_c) with
     * ms_c = 1_000_000. ms_scaled has units of micro-multisynth-counts:
     *   ms_scaled = f_VCO × 1e6 / target_hz   (held in u64 to avoid overflow)
     *   ms_a = ms_scaled / 1e6
     *   ms_b = ms_scaled - ms_a × 1e6
     *   ms_c = 1e6 */
    u64 ms_scaled = ((u64)f_vco_target * 1000000ULL) / (u64)target_hz;
    u32 ms_a = (u32)(ms_scaled / 1000000ULL);
    u32 ms_b = (u32)(ms_scaled - (u64)ms_a * 1000000ULL);
    u32 ms_c = 1000000UL;

    if (ms_a < 8 || ms_a > 2047) return -3;
    if (ms_b >= ms_c)            return -4;

    /* PLLA P1/P2/P3 (regs 26..33). For integer a=32, b=0, c=1:
     *   P1 = 128×32 − 512 = 3584
     *   P2 = 0, P3 = 1 */
    u32 plla_floor = (128UL * plla_b) / plla_c;
    u32 plla_p1 = 128UL * plla_a + plla_floor - 512UL;
    u32 plla_p2 = 128UL * plla_b - plla_c * plla_floor;
    u32 plla_p3 = plla_c;

    /* MS0 P1/P2/P3 (regs 42..49). Need 128*ms_b to fit in u32:
     *   max ms_b = ms_c − 1 = 999_999
     *   128 × 999_999 = 127_999_872 (well under 2^32) */
    u32 ms_floor = (128UL * ms_b) / ms_c;
    u32 ms_p1 = 128UL * ms_a + ms_floor - 512UL;
    u32 ms_p2 = 128UL * ms_b - ms_c * ms_floor;
    u32 ms_p3 = ms_c;

    int rc;
    #define CHK(call) do { rc = (call); if (rc != 0) return rc; } while (0)

    /* PLLA params */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 0, (u8)((plla_p3 >> 8) & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 1, (u8)(plla_p3 & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 2, (u8)((plla_p1 >> 16) & 0x03)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 3, (u8)((plla_p1 >> 8) & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 4, (u8)(plla_p1 & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 5,
                         (u8)(((plla_p3 >> 12) & 0xF0) | ((plla_p2 >> 16) & 0x0F))));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 6, (u8)((plla_p2 >> 8) & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 7, (u8)(plla_p2 & 0xFF)));

    /* MS0 params */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 0, (u8)((ms_p3 >> 8) & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 1, (u8)(ms_p3 & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 2, (u8)((ms_p1 >> 16) & 0x03)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 3, (u8)((ms_p1 >> 8) & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 4, (u8)(ms_p1 & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 5,
                         (u8)(((ms_p3 >> 12) & 0xF0) | ((ms_p2 >> 16) & 0x0F))));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 6, (u8)((ms_p2 >> 8) & 0xFF)));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 7, (u8)(ms_p2 & 0xFF)));

    /* CLK0 control: powerup, FRACTIONAL mode (MS_INT=0 — REQUIRED so the
     * b/c fractional component takes effect; integer-mode 0x4F would silently
     * round to ms_a), PLLA src, MS src, 8 mA drive.
     *   0b00001111 = 0x0F */
    CHK(si5351_write_reg(iic_base, SI5351_REG_CLK0_CONTROL, 0x0F));

    /* PLL_RESET — the canonical Si5351 bring-up bug if omitted. Forces
     * PLLA to re-lock with the new divider config; without it, dividers
     * change but the output stays at the old frequency until something
     * else perturbs the chip. */
    CHK(si5351_write_reg(iic_base, SI5351_REG_PLL_RESET, SI5351_PLLA_RESET));

    /* Re-enable CLK0 (idempotent — Phase B/C inits already cleared bit 0). */
    CHK(si5351_write_reg(iic_base, SI5351_REG_OUTPUT_ENABLE, 0xFE));

    return 0;
    #undef CHK
}

void si5351_scan_bus(u32 iic_base)
{
    int found = 0;
    xil_printf("\r\nI²C bus scan (addrs 0x03..0x77):\r\n");
    for (u8 addr = 0x03; addr <= 0x77; addr++) {
        Xil_Out32(iic_base + IIC_REG_SOFTR, 0x0A);
        for (volatile int d = 0; d < 1000; d++);
        Xil_Out32(iic_base + IIC_REG_CR, CR_EN);

        Xil_Out32(iic_base + IIC_REG_TX_FIFO,
                  TX_START | TX_STOP | (addr << 1));

        iic_settle(1);

        u32 isr = Xil_In32(iic_base + IIC_REG_ISR);
        if (!(isr & ISR_TX_ERROR)) {
            xil_printf("  ACK at 0x%02x\r\n", addr);
            found++;
        }
        Xil_Out32(iic_base + IIC_REG_ISR, ISR_TX_ERROR);
    }
    xil_printf("Scan done: %d address(es) responded.\r\n", found);
}

int si5351_init_25mhz_clk0(u32 iic_base)
{
    /* Same architecture as the 10 MHz variant, retuned for 25 MHz output.
     *   PLLA = 25 MHz × 24 = 600 MHz (in 600-900 MHz range).
     *     a=24, b=0, c=1 → P1=2560, P2=0, P3=1 (identical to 10 MHz case).
     *   MS0  = 600 MHz ÷ 24 = 25 MHz.
     *     a=24, b=0, c=1 → P1=128·24 − 512 = 2560, P2=0, P3=1.
     *   CLK0 control + reset + enable identical.
     *
     * Output equals input crystal frequency — degenerate-looking but correct,
     * and the PLL is fully engaged (any small drift in the crystal is filtered
     * by the PLL loop). */

    int rc;
    #define CHK(call) do { rc = (call); if (rc != 0) return rc; } while (0)

    CHK(si5351_write_reg(iic_base, SI5351_REG_OUTPUT_ENABLE, 0xFF));

    for (u8 r = 16; r <= 23; r++) {
        CHK(si5351_write_reg(iic_base, r, 0x80));
    }

    CHK(si5351_write_reg(iic_base, SI5351_REG_XTAL_CL, SI5351_XTAL_LOAD_10PF));

    /* PLLA: P1=2560 → bits[15:8]=0x0A, [7:0]=0x00. Same as 10 MHz variant. */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 0, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 1, 0x01));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 2, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 3, 0x0A));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 4, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 5, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 6, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS_NA_PARAMS + 7, 0x00));

    /* MS0: a=24, b=0, c=1 → P1=2560 → bits[15:8]=0x0A, [7:0]=0x00. */
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 0, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 1, 0x01));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 2, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 3, 0x0A));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 4, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 5, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 6, 0x00));
    CHK(si5351_write_reg(iic_base, SI5351_REG_MS0_PARAMS + 7, 0x00));

    CHK(si5351_write_reg(iic_base, SI5351_REG_CLK0_CONTROL, 0x4F));
    CHK(si5351_write_reg(iic_base, SI5351_REG_PLL_RESET, SI5351_PLLA_RESET));
    CHK(si5351_write_reg(iic_base, SI5351_REG_OUTPUT_ENABLE, 0xFE));

    return 0;

    #undef CHK
}
