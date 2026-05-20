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

static int si5351_write_reg(u32 base, u8 reg, u8 data)
{
    /* Soft-reset the IP between transactions. The library wedge we saw in
     * the ADV7393 session was specific to its state machine; resetting
     * before each transaction is the bulletproof pattern. SOFTR also clears
     * ISR, so the post-transaction TX_ERROR check is reliable. */
    Xil_Out32(base + IIC_REG_SOFTR, 0x0A);
    for (volatile int d = 0; d < 100; d++);
    Xil_Out32(base + IIC_REG_CR, CR_EN);

    /* Three-byte write: START+addr_W, reg, STOP+data. */
    Xil_Out32(base + IIC_REG_TX_FIFO, TX_START | (SI5351_I2C_ADDR_7B << 1));
    Xil_Out32(base + IIC_REG_TX_FIFO, reg);
    Xil_Out32(base + IIC_REG_TX_FIFO, TX_STOP | data);

    iic_settle(3);

    u32 isr = Xil_In32(base + IIC_REG_ISR);
    if (isr & ISR_TX_ERROR) {
        u32 sr = Xil_In32(base + IIC_REG_SR);
        Xil_Out32(base + IIC_REG_ISR, ISR_TX_ERROR);  /* W1C */
        xil_printf("si5351_write_reg: NAK on reg 0x%02x  (SR=0x%02x ISR=0x%02x)\r\n",
                   reg, (unsigned)sr, (unsigned)isr);
        return -2;
    }

    return 0;
}

/* ----- public API ---------------------------------------------------------- */

int si5351_probe(u32 iic_base)
{
    /* Single-byte probe: send addr+W with both START and STOP set, then wait
     * out the transaction (~1 ms is generous for one byte at 100 kHz) and
     * check ISR.TX_ERROR. Retry a few times: on cold boot the chip's I²C
     * state machine sometimes needs a few SCL ticks before it ACKs the very
     * first transaction. Status (SR + ISR) is printed for each attempt to
     * make any future failure easier to diagnose. */
    for (int attempt = 1; attempt <= 5; attempt++) {
        Xil_Out32(iic_base + IIC_REG_SOFTR, 0x0A);
        for (volatile int d = 0; d < 100; d++);
        Xil_Out32(iic_base + IIC_REG_CR, CR_EN);

        Xil_Out32(iic_base + IIC_REG_TX_FIFO,
                  TX_START | TX_STOP | (SI5351_I2C_ADDR_7B << 1));

        iic_settle(1);

        u32 sr  = Xil_In32(iic_base + IIC_REG_SR);
        u32 isr = Xil_In32(iic_base + IIC_REG_ISR);
        xil_printf("si5351_probe attempt %d: SR=0x%02x ISR=0x%02x\r\n",
                   attempt, (unsigned)sr, (unsigned)isr);

        if (!(isr & ISR_TX_ERROR)) {
            return 0;  /* ACK */
        }

        /* NAK on this attempt — clear and retry. */
        Xil_Out32(iic_base + IIC_REG_ISR, ISR_TX_ERROR);
        for (volatile int d = 0; d < 200000; d++);  /* ~1 ms before retry */
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
