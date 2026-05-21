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
#include "xiic_l.h"   /* XIic_Send / XIic_Recv polled */

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

/* AXI IIC ISR bit definitions (PG090 §"Interrupt Status Register"). */
#define ISR_BNB             0x10   /* Bus Not Busy edge */
#define ISR_TX_FIFO_EMPTY   0x04   /* TX FIFO became empty */

/* Wait for transaction completion via IISR.BNB poll. BNB is edge-triggered,
 * fires when bus transitions busy→not-busy (i.e., after STOP is driven).
 * This is the canonical XIic_DynSend completion-detection bit — far more
 * reliable than fixed-delay iic_settle which can return before clock-stretching
 * slaves finish. Returns 0 on completion, -1 on timeout.
 *
 * Timeout chosen large (50ms) to accommodate worst-case clock-stretching
 * during Si5351 SYS_INIT — chip may stretch SCL for hundreds of µs per ACK
 * cycle while NVM→RAM copy is in progress. */
static int wait_for_bnb(u32 base)
{
    const int LIMIT = 25000000;  /* ~50 ms at cortex-a9 666MHz with volatile-loop overhead */
    for (int i = 0; i < LIMIT; i++) {
        u32 isr = Xil_In32(base + IIC_REG_ISR);
        if (isr & ISR_BNB) {
            Xil_Out32(base + IIC_REG_ISR, ISR_BNB);  /* W1C the BNB latch */
            return 0;
        }
    }
    return -1;
}

/* Library-based write — replaces broken hand-rolled register pokes.
 * Bench evidence 2026-05-21: hand-rolled si5351_write_reg_once only put
 * 2 bytes on the wire (addr+W, reg pointer) — data byte was dropped.
 * Chip ACKed both bytes, returned "OK", but internal RAM never updated.
 * XIic_Send is bench-validated to push all 3 bytes correctly and chip
 * reads back the written value. */
static int si5351_lib_write_reg(u32 base, u8 reg, u8 data)
{
    u8 buf[2] = {reg, data};
    int sent = XIic_Send(base, SI5351_I2C_ADDR_7B, buf, 2, XIIC_STOP);
    return (sent == 2) ? 0 : -2;
}

static int si5351_write_reg_once(u32 base, u8 reg, u8 data)
{
    /* Per-transaction full-IP-reset prologue (SOFTR). This is the SAME
     * pattern that si5351_scan_bus() uses and that bench-validated as
     * reliable on 2026-05-20.
     *
     * The "canonical no-SOFTR" prologue (CR=0x03 → CR=0x01 → W1C ISR)
     * was tried twice (commits 1ddfa4c and post-1ddfa4c CR=0x03 fix) and
     * failed both times: TX_FIFO never drains, BNB poll exits with
     * TX_ERROR=1, chip NAKs. Whatever IP/bus state the SOFTR clears,
     * the no-SOFTR pattern is leaving behind on THIS hardware (JESSINIE
     * Si5351A breakout + Zybo Z7-20 AXI IIC IP).
     *
     * Theoretical concern about per-transaction SOFTR is "if chip is
     * mid-frame, SOFTR releases without STOP and confuses slave." That
     * concern doesn't apply here — failing transactions never get past
     * the address byte, so there's no mid-frame to corrupt. Root-cause
     * for why no-SOFTR fails is a TODO but does not block control. */
    Xil_Out32(base + IIC_REG_SOFTR, 0x0A);
    for (volatile int d = 0; d < 1000; d++);
    Xil_Out32(base + IIC_REG_CR, CR_EN);

    /* Push all 3 bytes back-to-back with NO delay between them. Critical:
     * inter-byte gaps in dynamic mode hold the bus busy waiting for the
     * next byte — the Si5351 has an inter-byte timeout and NAKs the next
     * byte if we delay >~500 µs. Earlier per-byte diagnostic snapshots
     * inserted 1 ms gaps and caused ~70% NAK rate; with back-to-back
     * pushes the same firmware achieved zero-NAK init. */
    Xil_Out32(base + IIC_REG_TX_FIFO, TX_START | (SI5351_I2C_ADDR_7B << 1));
    Xil_Out32(base + IIC_REG_TX_FIFO, reg);
    Xil_Out32(base + IIC_REG_TX_FIFO, TX_STOP | data);

    /* Poll BNB for true transaction completion (not fixed delay).
     * If we return before STOP is driven, the IP keeps clocking SCL trying
     * to drain the FIFO — that's the "SCL squarewave forever" bug. */
    int wait_rc = wait_for_bnb(base);

    u32 sr_final  = Xil_In32(base + IIC_REG_SR);
    u32 isr_final = Xil_In32(base + IIC_REG_ISR);

    if (si5351_debug_write) {
        xil_printf("  diag reg=0x%02x data=0x%02x: "
                   "wait_rc=%d sr=0x%02x isr=0x%02x\r\n",
                   reg, data, wait_rc, (unsigned)sr_final, (unsigned)isr_final);
    }

    if (wait_rc != 0) {
        /* Transaction never completed — chip clock-stretched past our timeout
         * or IP is wedged. Force-reset IP for next attempt. */
        Xil_Out32(base + IIC_REG_SOFTR, 0x0A);
        return -1;
    }

    if (isr_final & ISR_TX_ERROR) {
        Xil_Out32(base + IIC_REG_ISR, ISR_TX_ERROR);  /* W1C */
        return -2;
    }

    return 0;
}

static int si5351_write_reg(u32 base, u8 reg, u8 data)
{
    /* Routes through XIic library — see si5351_lib_write_reg comment for
     * why hand-rolled register pokes were abandoned. */
    int rc = si5351_lib_write_reg(base, reg, data);
    if (rc != 0) {
        xil_printf("si5351_write_reg: XIic_Send failed for reg 0x%02x\r\n", reg);
    }
    return rc;
}

/* ----- public API ---------------------------------------------------------- */

int si5351_probe(u32 iic_base)
{
    /* Library-based probe via 1-byte read of Device Status (reg 0).
     * If chip ACKs and returns a byte → present. Avoids mixing hand-rolled
     * register pokes with XIic library init, which causes IP-state conflicts. */
    u8 dev_status = 0;
    for (int attempt = 1; attempt <= 5; attempt++) {
        u8 reg = 0;
        int sent = XIic_Send(iic_base, SI5351_I2C_ADDR_7B, &reg, 1, XIIC_REPEATED_START);
        if (sent == 1) {
            int recvd = XIic_Recv(iic_base, SI5351_I2C_ADDR_7B, &dev_status, 1, XIIC_STOP);
            if (recvd == 1) {
                xil_printf("si5351_probe attempt %d: ACK  Device Status=0x%02x "
                           "(SYS_INIT=%d LOL_A=%d LOS=%d REVID=%d)\r\n",
                           attempt, dev_status,
                           (dev_status >> 7) & 1, (dev_status >> 5) & 1,
                           (dev_status >> 4) & 1, dev_status & 0x03);
                return 0;
            }
        }
        xil_printf("si5351_probe attempt %d: sent=%d  NAK/no-data\r\n", attempt, sent);
        for (volatile int d = 0; d < 200000; d++);
    }
    return -2;
}

int si5351_read_reg(u32 iic_base, u8 reg, u8 *out_data)
{
    /* Library-based read. Same rationale as si5351_lib_write_reg:
     * hand-rolled register pokes didn't actually do the RESTART path
     * (only 2 bytes on wire instead of 4). XIic library handles the
     * full read sequence correctly. */
    int sent  = XIic_Send(iic_base, SI5351_I2C_ADDR_7B, &reg, 1, XIIC_REPEATED_START);
    if (sent != 1) return -2;
    int recvd = XIic_Recv(iic_base, SI5351_I2C_ADDR_7B, out_data, 1, XIIC_STOP);
    return (recvd == 1) ? 0 : -3;
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

    /* Skip the AN619-recommended "powerdown all drivers" loop (regs 16-23 = 0x80).
     * Etherkit, Adafruit, and other community libraries omit this — the chip
     * disabled via reg 3 = 0xFF is already silent, and writing 0x80 then 0x4F
     * to reg 16 is a redundant double-write. On bench 2026-05-21 the powerdown
     * write to reg 0x10 reliably NAK'd (10/10) while reg 3 succeeded; going
     * direct to the real CLK_CTRL value avoids the issue entirely. */

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
