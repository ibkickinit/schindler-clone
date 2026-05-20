/*
 * main.c — Phase B.1 bare-metal VDMA + VTC init for Schindler 2.0.
 *
 * Boots on the Zynq-7020 PS, configures the AXI VDMA to write incoming video
 * frames to a 3-frame ring buffer in DDR3 (S2MM channel), reads them back to
 * drive the HDMI TX (MM2S channel), and configures the Video Timing Controller
 * to generate 1920x1080@60p sync downstream of the VDMA.
 *
 * No interrupts. No DMA controller scatter-gather. Once configured, the VDMA
 * runs autonomously in circular-buffer mode; the PS is idle in a WFI loop.
 *
 * Frame format: RGB888 with one pixel-per-clock; VDMA AXIS data width 24-bit;
 * memory data width 64-bit (one pixel per 32-bit word — VDMA pads RGB888 to
 * 32-bit; verify against your axi_vdma config).
 */

#include <stdio.h>
#include <string.h>
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "sleep.h"
#include "xparameters.h"
#include "xaxivdma.h"
#include "xvtc.h"
#include "xtime_l.h"   /* Phase D iter-4a: SCU timer for precise rate measurement */
#include "xuartps_hw.h" /* Phase E1 Phase 1: non-blocking UART rx for q/p commands */

// Phase C.1 (pivoted to 720p): output is 720p (1280×720) — scaler downscales
// 1080p → 720p before storage. DDR3 holds 1280×720 frames. 480p was infeasible
// because rgb2dvi IP only supports pixel clocks ≥40 MHz (480p needs 27 MHz).
#define FRAME_W           1280
#define FRAME_H           720
/* AXIS data width on the VDMA is 24-bit (RGB888, one pixel-per-clock with no
 * padding). Memory stride must therefore be 3 bytes/pixel, NOT 4 — using 4
 * was the actual reason v_axi4s_vid_out couldn't lock and S2MM was reporting
 * EOLEarly/EOLLate framing errors. Confirmed via UART diag dumps. */
#define BYTES_PP          3
#define STRIDE            (FRAME_W * BYTES_PP)
#define FRAME_BYTES       (STRIDE * FRAME_H)
#define NUM_FRAMES        3
#define FRAME_BUF_BASE    0x10000000U

static XAxiVdma vdma;
static XVtc    vtc;

static int vdma_setup_channel(int direction, UINTPTR *frame_addrs)
{
    XAxiVdma_DmaSetup cfg;
    int status;

    cfg.VertSizeInput     = FRAME_H;
    cfg.HoriSizeInput     = STRIDE;
    cfg.Stride            = STRIDE;
    /* Phase D iter-4d-3: MM2S as genlock slave with FrameDelay=1 — slave
     * trails master by 1 frame in the 3-FB ring, hardware-enforced (PG020:
     * "Slave follows the Master by the frames set in Frame Delay register
     * either by skipping or repeating frames"). S2MM stays at 0 since it's
     * the master and free-runs at source rate.
     *
     * Replaces iter-4d-2's firmware PARK loop. That approach (PARK mode +
     * per-vsync PARK_PTR_REG writes from firmware) was non-atomic at MM2S
     * SOF; the writes landed mid-burst and produced 2-3 horizontal seams
     * per frame. Xilinx never intended PARK + firmware for live video — the
     * documented FRC path is Dynamic Genlock master/slave (iter-4d-3 step 2
     * upgrades from plain to Dynamic), and even plain genlock + FrameDelay=1
     * should kill the seams that PARK was hand-rolling badly. */
    cfg.FrameDelay        = (direction == XAXIVDMA_READ) ? 1 : 0;
    cfg.EnableCircularBuf = 1;
    /* EnableSync=1 on MM2S asserts DMACR bit 3, which enables slave-mode
     * frame-pointer following (required for FrameDelay/genlock to apply).
     * It is NOT the per-frame fsync gate we were treating it as in iter-4d-2. */
    cfg.EnableSync        = (direction == XAXIVDMA_READ) ? 1 : 0;
    cfg.PointNum          = 0;
    cfg.EnableFrameCounter = 0;
    cfg.FixedFrameStoreAddr = 0;

    status = XAxiVdma_DmaConfig(&vdma, direction, &cfg);
    if (status != XST_SUCCESS) {
        xil_printf("VDMA DmaConfig %s failed: %d\r\n",
                   (direction == XAXIVDMA_WRITE) ? "S2MM" : "MM2S", status);
        return status;
    }

    status = XAxiVdma_DmaSetBufferAddr(&vdma, direction, frame_addrs);
    if (status != XST_SUCCESS) {
        xil_printf("VDMA SetBufferAddr %s failed: %d\r\n",
                   (direction == XAXIVDMA_WRITE) ? "S2MM" : "MM2S", status);
        return status;
    }

    status = XAxiVdma_DmaStart(&vdma, direction);
    if (status != XST_SUCCESS) {
        xil_printf("VDMA DmaStart %s failed: %d\r\n",
                   (direction == XAXIVDMA_WRITE) ? "S2MM" : "MM2S", status);
        return status;
    }

    return XST_SUCCESS;
}

/* Phase D iter-3 — firmware-side VTC alignment.
 *
 * The AXI GPIO at XPAR_AXI_GPIO_0_BASEADDR exposes two synchronized inputs:
 *   bit 0 = dvi2rgb pLocked (2-FF synced from pclk_in to FCLK_CLK0)
 *   bit 1 = dvi2rgb vid_pVSync (2-FF synced)
 * Polling these from the PS at ~666 MHz gives us microsecond-tight detection
 * of source events. Calling vtc_setup_720p immediately after this returns
 * aligns the generator's first frame to within ~1 µs of source vsync.
 */
#define VSYNC_GPIO_PLOCKED_MASK      0x1   /* dvi2rgb source HDMI lock        */
#define VSYNC_GPIO_VSYNC_MASK        0x2   /* dvi2rgb source vsync             */
#define VSYNC_GPIO_VSYNC_OUT_MASK    0x4   /* VTC output vsync (iter-4d-1)     */
#define VSYNC_GPIO_PCLK_LOCKED_MASK  0x8   /* clk_wiz_pixclk_out MMCM lock     */

/* Vitis names this macro inconsistently across versions / BD hierarchies.
 * Match whichever one the generated xparameters.h actually emits. */
#if defined(XPAR_AXI_GPIO_0_BASEADDR)
#  define VSYNC_GPIO_BASEADDR XPAR_AXI_GPIO_0_BASEADDR
#elif defined(XPAR_AXI_GPIO_0_S_AXI_BASEADDR)
#  define VSYNC_GPIO_BASEADDR XPAR_AXI_GPIO_0_S_AXI_BASEADDR
#elif defined(XPAR_PHASE_B_BD_AXI_GPIO_0_BASEADDR)
#  define VSYNC_GPIO_BASEADDR XPAR_PHASE_B_BD_AXI_GPIO_0_BASEADDR
#else
#  error "AXI GPIO base address not found in xparameters.h"
#endif

static inline u32 vsync_gpio_read(void)
{
    return Xil_In32(VSYNC_GPIO_BASEADDR);
}

/* =========================================================================
 * Phase E1 Phase 1 — vsync_timestamp measurement instrument.
 *
 * 48-bit free-running counter at 100 MHz (10 ns/tick) and two edge-capture
 * timestamps (ts_ref, ts_out) inside the FPGA. Read-only AXI-Lite slave.
 * Register layout matches hdl/vsync_timestamp.v:
 *   +0x00  counter[31:0]
 *   +0x04  {16'h0, counter[47:32]}
 *   +0x08  ts_ref[31:0]
 *   +0x0C  {16'h0, ts_ref[47:32]}
 *   +0x10  ts_out[31:0]
 *   +0x14  {16'h0, ts_out[47:32]}
 *   +0x18  ts_ref_count (32-bit edge tally)
 *   +0x1C  ts_out_count (32-bit edge tally)
 * ========================================================================= */
#if defined(XPAR_VSYNC_TIMESTAMP_0_BASEADDR)
#  define VTS_BASEADDR XPAR_VSYNC_TIMESTAMP_0_BASEADDR
#elif defined(XPAR_VSYNC_TIMESTAMP_0_S_AXI_BASEADDR)
#  define VTS_BASEADDR XPAR_VSYNC_TIMESTAMP_0_S_AXI_BASEADDR
#elif defined(XPAR_PHASE_B_BD_VSYNC_TIMESTAMP_0_BASEADDR)
#  define VTS_BASEADDR XPAR_PHASE_B_BD_VSYNC_TIMESTAMP_0_BASEADDR
#else
#  error "vsync_timestamp base address not found in xparameters.h"
#endif

#define VTS_CNT_LO     (VTS_BASEADDR + 0x00)
#define VTS_CNT_HI     (VTS_BASEADDR + 0x04)
#define VTS_TS_REF_LO  (VTS_BASEADDR + 0x08)
#define VTS_TS_REF_HI  (VTS_BASEADDR + 0x0C)
#define VTS_TS_OUT_LO  (VTS_BASEADDR + 0x10)
#define VTS_TS_OUT_HI  (VTS_BASEADDR + 0x14)
#define VTS_REF_COUNT  (VTS_BASEADDR + 0x18)
#define VTS_OUT_COUNT  (VTS_BASEADDR + 0x1C)

/* Coherent 48-bit read of the free-running counter.
 * Read MSB→LSB→MSB; if MSB matches, the pair is coherent (LSB didn't roll
 * over between reads). MSB advances every 2^32 ticks = 42.95 s. Loop almost
 * always terminates first iteration. */
static u64 vts_read_counter(void)
{
    u32 msb1, msb2, lsb;
    do {
        msb1 = Xil_In32(VTS_CNT_HI) & 0xFFFF;
        lsb  = Xil_In32(VTS_CNT_LO);
        msb2 = Xil_In32(VTS_CNT_HI) & 0xFFFF;
    } while (msb1 != msb2);
    return ((u64)msb2 << 32) | lsb;
}

/* Coherent 48-bit read of a captured timestamp + its edge counter.
 * Read (count, lsb, msb, count); if count matches, the timestamp didn't
 * change mid-read. Returns count via the out param. */
static u64 vts_read_ts(u32 lo_addr, u32 hi_addr, u32 cnt_addr, u32 *count_out)
{
    u32 c1, c2, lsb, msb;
    do {
        c1  = Xil_In32(cnt_addr);
        lsb = Xil_In32(lo_addr);
        msb = Xil_In32(hi_addr) & 0xFFFF;
        c2  = Xil_In32(cnt_addr);
    } while (c1 != c2);
    if (count_out) *count_out = c2;
    return ((u64)msb << 32) | lsb;
}

/* Pretty-print a 48-bit value in hex as two 32-bit halves. xil_printf has no
 * %llx, so we split. */
static void print_u48_hex(u64 v)
{
    xil_printf("0x%04x%08x", (u32)((v >> 32) & 0xFFFF), (u32)(v & 0xFFFFFFFF));
}

/* Print signed phase delta `ts_out - ts_ref` in ticks and ns. Uses 64-bit
 * signed arithmetic to handle wrap correctly across the 48-bit counter. */
static void print_phase_delta(u64 ts_out, u64 ts_ref)
{
    /* 48-bit wrap-aware delta: extend to 64-bit signed two's-complement of
     * the lower 48 bits. */
    u64 d = (ts_out - ts_ref) & 0x0000FFFFFFFFFFFFULL;
    if (d & 0x0000800000000000ULL) d |= 0xFFFF000000000000ULL;
    s64 sd = (s64)d;
    s64 ns = sd * 10;   /* 100 MHz counter -> 10 ns/tick */
    char sign = (sd < 0) ? '-' : '+';
    if (sd < 0) { sd = -sd; ns = -ns; }
    /* xil_printf %d takes a 32-bit int; for typical sub-second deltas the
     * value fits comfortably. Cap display at 32-bit signed range and flag
     * if exceeded. */
    if (sd > 0x7FFFFFFFLL) {
        xil_printf("(phase delta exceeds 32-bit range: ticks=");
        print_u48_hex((u64)sd);
        xil_printf(" sign=%c)\r\n", sign);
    } else {
        xil_printf("phase = %c%u ticks  =  %c%u ns\r\n",
                   sign, (u32)sd, sign, (u32)ns);
    }
}

/* =========================================================================
 * UART non-blocking input + minimal command dispatcher.
 *
 * Polled from telemetry_loop's hot path. One-character commands fire
 * immediately on receipt (no newline required) — keeps the command set tiny.
 *
 * Commands:
 *   q   query: print counter, ts_ref, ts_out, ts_ref_count, ts_out_count
 *   p   phase: print signed (ts_out - ts_ref)
 *   ?   help
 * ========================================================================= */
#if defined(XPAR_PS7_UART_1_BASEADDR)
#  define UART_BASEADDR XPAR_PS7_UART_1_BASEADDR
#elif defined(XPAR_XUARTPS_0_BASEADDR)
#  define UART_BASEADDR XPAR_XUARTPS_0_BASEADDR
#elif defined(XPAR_PS7_UART_0_BASEADDR)
#  define UART_BASEADDR XPAR_PS7_UART_0_BASEADDR
#else
#  error "PS UART base address not found in xparameters.h"
#endif

static int uart_recv_nb(void)
{
    if (XUartPs_IsReceiveData(UART_BASEADDR)) {
        return (int)(XUartPs_ReadReg(UART_BASEADDR, XUARTPS_FIFO_OFFSET) & 0xFF);
    }
    return -1;
}

static void cmd_query(void)
{
    u32 ref_count, out_count;
    u64 cnt = vts_read_counter();
    u64 tsr = vts_read_ts(VTS_TS_REF_LO, VTS_TS_REF_HI, VTS_REF_COUNT, &ref_count);
    u64 tso = vts_read_ts(VTS_TS_OUT_LO, VTS_TS_OUT_HI, VTS_OUT_COUNT, &out_count);
    xil_printf("\r\n[Q] vsync_timestamp @ 0x%08x\r\n", (unsigned)VTS_BASEADDR);
    xil_printf("    counter = "); print_u48_hex(cnt); xil_printf(" (%u ticks ~ %u ms)\r\n",
                                                                  (u32)(cnt & 0xFFFFFFFFU),
                                                                  (u32)(cnt / 100000U));
    xil_printf("    ts_ref  = "); print_u48_hex(tsr); xil_printf("  edges = %u\r\n", (unsigned)ref_count);
    xil_printf("    ts_out  = "); print_u48_hex(tso); xil_printf("  edges = %u\r\n", (unsigned)out_count);
}

static void cmd_phase(void)
{
    u32 ref_count, out_count;
    u64 tsr = vts_read_ts(VTS_TS_REF_LO, VTS_TS_REF_HI, VTS_REF_COUNT, &ref_count);
    u64 tso = vts_read_ts(VTS_TS_OUT_LO, VTS_TS_OUT_HI, VTS_OUT_COUNT, &out_count);
    xil_printf("\r\n[P] ts_out="); print_u48_hex(tso);
    xil_printf(" (edges=%u)  ts_ref=", (unsigned)out_count); print_u48_hex(tsr);
    xil_printf(" (edges=%u)\r\n    ", (unsigned)ref_count);
    if (ref_count == 0) {
        xil_printf("phase: ref_count=0 — ref_vsync not yet wired (Phase 2 adds it). "
                   "Showing ts_out raw:\r\n    ");
    }
    print_phase_delta(tso, tsr);
}

/* Phase 2 capture: emit N consecutive ts_ref edges as CSV rows. Blocks the
 * telemetry loop until done (~16 s at 60 Hz for N=1000). Output format is
 * CSV with header line so the host can ingest directly:
 *
 *   # phase2_capture N=1000 base_count=<x>
 *   idx,ref_count,ts_ref_lo32,ts_ref_hi16
 *   0,<count>,<lsb>,<msb>
 *   ...
 *
 * Phase 3 will reuse this CSV format and add ts_out columns.
 */
static void cmd_capture(unsigned n)
{
    u32 last_count, this_count;
    u64 ts;
    if (n == 0 || n > 5000) n = 1000;

    /* Establish baseline. */
    ts = vts_read_ts(VTS_TS_REF_LO, VTS_TS_REF_HI, VTS_REF_COUNT, &last_count);
    (void)ts;
    if (last_count == 0) {
        xil_printf("\r\n[C] WARNING: ts_ref_count=0 at start — Phase 2 reference may not be wired.\r\n");
    }
    xil_printf("\r\n# phase2_capture N=%u base_count=%u\r\n"
               "idx,ref_count,ts_ref_lo32,ts_ref_hi16\r\n",
               n, (unsigned)last_count);

    for (unsigned i = 0; i < n; ++i) {
        /* Wait for the next edge: ts_ref_count must advance. Tight polling
         * loop — each tick is a 32-bit AXI read, ~10 cycles of PS overhead.
         * At 60 Hz events ≈ 16.7 ms apart, we burn cycles but the host bus
         * is dedicated to this for the duration of the capture.
         *
         * Phase E1.7 (2026-05-19): hard timeout to prevent the firmware
         * from hanging forever when ref edges aren't coming (e.g., ref_mux
         * in mask mode, synth_vsync_gen not running, or host typeahead
         * accidentally triggers capture in a degraded state). Before the
         * timeout was added, a stray 'c' character in the UART buffer
         * could lock the firmware in an infinite poll. */
        XTime t_start; XTime_GetTime(&t_start);
        const u64 timeout_ticks = COUNTS_PER_SECOND / 5;  /* 200 ms */
        int timed_out = 0;
        do {
            ts = vts_read_ts(VTS_TS_REF_LO, VTS_TS_REF_HI, VTS_REF_COUNT, &this_count);
            XTime t_now; XTime_GetTime(&t_now);
            if ((u64)(t_now - t_start) > timeout_ticks) { timed_out = 1; break; }
        } while (this_count == last_count);
        if (timed_out) {
            xil_printf("# phase2_capture ABORT i=%u — no ref edge in 200 ms\r\n", i);
            return;
        }
        last_count = this_count;

        xil_printf("%u,%u,%u,%u\r\n",
                   i,
                   (unsigned)this_count,
                   (u32)(ts & 0xFFFFFFFFU),
                   (u32)((ts >> 32) & 0xFFFFU));
    }
    xil_printf("# phase2_capture done N=%u\r\n", n);
}

/* Phase 3 drift capture: trigger on each ts_out edge, emit a CSV row with
 * (idx, out_count, ts_out, ref_count, ts_ref) pairs. The host analyzer
 * computes phase_delta = ts_out - ts_ref per sample, unwraps any 48-bit
 * wraps, fits a line to phase_delta vs out_count, converts slope to ppm.
 *
 * Sample budget: at 50 Hz output, 3000 samples = 60 s of data. UART
 * emission per row (~50 bytes) at 115200 baud = ~4.3 ms. That fits within
 * the 20 ms output period; the dispatcher reads the next edge before
 * emitting, so any emission overrun shows up as a skipped out_count rather
 * than corrupting the timestamps.
 */
static void cmd_drift(unsigned n)
{
    u32 last_out_count, this_out_count, ref_count;
    u64 ts_out, ts_ref;
    if (n == 0 || n > 5000) n = 3000;

    /* Establish baseline on the next output edge. */
    ts_out = vts_read_ts(VTS_TS_OUT_LO, VTS_TS_OUT_HI, VTS_OUT_COUNT, &last_out_count);
    (void)ts_out;
    if (last_out_count == 0) {
        xil_printf("\r\n[R] WARNING: ts_out_count=0 — output vsync not yet running.\r\n");
        return;
    }

    /* Header. */
    xil_printf("\r\n# phase3_capture N=%u base_out_count=%u\r\n"
               "idx,out_count,ts_out_lo32,ts_out_hi16,ref_count,ts_ref_lo32,ts_ref_hi16\r\n",
               n, (unsigned)last_out_count);

    for (unsigned i = 0; i < n; ++i) {
        /* Wait for the next output edge. Phase E1.7 timeout — see cmd_capture
         * above for rationale. */
        XTime t_start; XTime_GetTime(&t_start);
        const u64 timeout_ticks = COUNTS_PER_SECOND / 5;  /* 200 ms */
        int timed_out = 0;
        do {
            ts_out = vts_read_ts(VTS_TS_OUT_LO, VTS_TS_OUT_HI, VTS_OUT_COUNT, &this_out_count);
            XTime t_now; XTime_GetTime(&t_now);
            if ((u64)(t_now - t_start) > timeout_ticks) { timed_out = 1; break; }
        } while (this_out_count == last_out_count);
        if (timed_out) {
            xil_printf("# phase3_capture ABORT i=%u — no out edge in 200 ms\r\n", i);
            return;
        }
        last_out_count = this_out_count;

        /* Snapshot the most-recent ref edge (whatever happened most recently
         * before this row — may lag behind or even-with the output edge
         * depending on phase relationship). */
        ts_ref = vts_read_ts(VTS_TS_REF_LO, VTS_TS_REF_HI, VTS_REF_COUNT, &ref_count);

        xil_printf("%u,%u,%u,%u,%u,%u,%u\r\n",
                   i,
                   (unsigned)this_out_count,
                   (u32)(ts_out & 0xFFFFFFFFU),
                   (u32)((ts_out >> 32) & 0xFFFFU),
                   (unsigned)ref_count,
                   (u32)(ts_ref & 0xFFFFFFFFU),
                   (u32)((ts_ref >> 32) & 0xFFFFU));
    }
    xil_printf("# phase3_capture done N=%u\r\n", n);
}

/* =========================================================================
 * Phase E1 Phase 4 — MMCM psincdec rate actuator.
 *
 * The actuator HDL implements a Bresenham accumulator at FCLK_CLK0 (100 MHz):
 * every cycle, accumulator += |phase_step|; on overflow, one PSEN pulse with
 * PSINCDEC = sign(phase_step). Each PSEN pulse shifts the MMCM CLKOUT1 phase
 * by ~1/56 of the VCO period (~15.04 ps at Fvco=1187.5 MHz). Stream of
 * pulses produces an apparent rate offset on the output clock.
 *
 * Register map (matches hdl/mmcm_psincdec_actuator.v):
 *   +0x00  phase_step (signed RW). 0 = no shifting.
 *   +0x04  status (RO): bit0=psdone live, bit1=pulse_in_flight,
 *                      bits[31:16]=pulse_count since reset
 *
 * Calibration:
 *   ppm = (phase_step / 2^32) * Fclk * (1 / (56 * Fvco)) * 1e6
 *       = phase_step * 100e6 / 2^32 / (56 * 1187.5e6) * 1e6
 *       = phase_step * ~3.50e-7 ppm/step
 *   ⇒ phase_step per +1 ppm ≈ 2,857,143  (coincidence with the Phase 2
 *     divisor for FCLK_CLK1 — same arithmetic family.)
 * Phase 5 will refine this number empirically via plant sweep.
 * ========================================================================= */
#if defined(XPAR_MMCM_PSINCDEC_ACTUATOR_0_BASEADDR)
#  define ACT_BASEADDR XPAR_MMCM_PSINCDEC_ACTUATOR_0_BASEADDR
#elif defined(XPAR_MMCM_PSINCDEC_ACTUATOR_0_S_AXI_BASEADDR)
#  define ACT_BASEADDR XPAR_MMCM_PSINCDEC_ACTUATOR_0_S_AXI_BASEADDR
#elif defined(XPAR_PHASE_B_BD_MMCM_PSINCDEC_ACTUATOR_0_BASEADDR)
#  define ACT_BASEADDR XPAR_PHASE_B_BD_MMCM_PSINCDEC_ACTUATOR_0_BASEADDR
#else
#  error "mmcm_psincdec_actuator base address not found in xparameters.h"
#endif

#define ACT_PHASE_STEP  (ACT_BASEADDR + 0x00)
#define ACT_STATUS      (ACT_BASEADDR + 0x04)

/* Phase-step value that produces +1 ppm of output-clock rate offset.
 * Theoretical default = 2,857,143 (from Fvco=1187.5 MHz, Fclk=100 MHz,
 * 1/56 phase step). Phase 5's plant sweep measured the actual gain at
 * 1.0796× across ±50 ppm; the meta-fit suggests dividing the theoretical
 * value by 1.0796 → 2,646,448 for a unit-gain calibration. */
#define ACT_STEP_PER_PPM   2646448

static void cmd_nudge(s32 ppm)
{
    s32 step = ppm * ACT_STEP_PER_PPM;
    Xil_Out32(ACT_PHASE_STEP, (u32)step);
    u32 readback = Xil_In32(ACT_PHASE_STEP);
    u32 status   = Xil_In32(ACT_STATUS);
    xil_printf("\r\n[M] requested %d ppm  -> phase_step = %d (0x%08x)\r\n",
               (int)ppm, (int)step, (unsigned)readback);
    xil_printf("    status = 0x%08x  (psdone=%u pif=%u pulses=%u)\r\n",
               (unsigned)status,
               (unsigned)(status & 1),
               (unsigned)((status >> 1) & 1),
               (unsigned)((status >> 16) & 0xFFFF));
}

/* =========================================================================
 * Phase E1 Phase 6 — PI controller + lock state machine.
 *
 * Per output vsync edge:
 *   - Read (ts_out, ts_ref) atomically via the Phase 1 instrument.
 *   - Compute err_ticks = (ts_out - ts_ref) mod 2^48, sign-extended.
 *   - Run PI: cmd_milli_ppm = -Kp × err_lines - Ki × Σ err_lines.
 *   - Clamp integrator + total command to ±INTEGRATOR_CLAMP_MILLI_PPM
 *     (±200 ppm — leaves ~300 ppm of MMCM pull-range headroom over the
 *     post-Phase-5 baseline of +102 ppm).
 *   - Write phase_step = cmd_milli_ppm × ACT_STEP_PER_PPM / 1000.
 *   - Update lock state machine + per-second stats.
 *
 * 1 Hz UART summary line during lock; `S` toggles whether per-frame samples
 * also stream out (used for the 30-min soak).
 * ========================================================================= */
#define TICKS_PER_LINE_720P50          2667    /* 1980 px / 74.25 MHz @ 100 MHz ctr */
#define REF_PERIOD_TICKS            2000000    /* synth-ref period @ 100 MHz ctr */

/* Phase E2.2 — three-mode lock (SNAP / SMOOTH / FILM). Inspired by the
 * RT4K's Frame Lock / Gen Lock / Triple Buffer triplet plus the broader
 * pro-FRC pattern. The PI gains and acquire thresholds shift per mode so
 * the same loop can be tuned for different downstream priorities:
 *
 *   SNAP   — fastest acquire + tightest tracking. Suited for video games
 *            and interactive sources where input-to-display latency matters
 *            more than visible step-changes during lock. High Kp + Ki.
 *
 *   SMOOTH — the Phase 6/7 defaults. Balanced acquire + steady-state.
 *            Suitable for general-purpose desktop / media use.
 *
 *   FILM   — slowest acquire + lowest steady-state command jitter. Suited
 *            for 24p / cinema content where smooth motion is paramount and
 *            any per-frame actuator step is potentially visible. Low Kp,
 *            very low Ki, longer in-lock window before LOCKED is declared.
 *
 * Kp / Ki are in milli-ppm per line per (frame for Ki). Empirically the
 * SMOOTH defaults of Kp=10000, Ki=1000 are the Phase 6 calibration; SNAP
 * and FILM are scaled relative to that under the assumption the asymmetric
 * MMCM plant's dec-direction slowness is the binding constraint (so the
 * effective bandwidth is bounded above by ~3× SMOOTH for stability).
 *
 * Per-mode INTEGRATOR_CLAMP is kept fixed at ±500 ppm (full MMCM pull range)
 * — narrowing the clamp in SNAP would just rate-limit it during a large
 * initial step, which is the opposite of what SNAP wants. */

typedef struct {
    const char *name;
    s32         kp_mppm_per_line;
    s32         ki_mppm_per_line;
    u32         lock_threshold_ticks;       /* per-frame |err| below this → in-lock */
    u32         unlock_threshold_ticks;     /* per-frame |err| above this → unlock candidate */
    u32         lock_frames;                /* consecutive in-lock frames → LOCKED */
    u32         unlock_frames;              /* consecutive unlock-candidate frames → ACQUIRING */
} lock_mode_t;

static const lock_mode_t MODE_SNAP = {
    "SNAP",
    30000,    /* Kp = 30.0 ppm/line — aggressive proportional response */
    5000,     /* Ki = 5.0 ppm/line/frame — fast integrator wind-up */
    2667,     /* lock window = 1 line */
    13335,    /* unlock window = 5 lines */
    30,       /* declare LOCKED after 30 consecutive in-lock frames (~0.6 sec @ 50 Hz) */
    60        /* require 60 unlock-candidate frames before falling back */
};

static const lock_mode_t MODE_SMOOTH = {
    "SMOOTH",
    10000,    /* Kp = 10.0 ppm/line (Phase 6 calibration) */
    1000,     /* Ki = 1.0 ppm/line/frame */
    2667,     /* lock window = 1 line */
    13335,    /* unlock window = 5 lines */
    60,       /* Phase 6 default */
    60
};

static const lock_mode_t MODE_FILM = {
    "FILM",
    3000,     /* Kp = 3.0 ppm/line — minimum visible step change */
    300,      /* Ki = 0.3 ppm/line/frame — slow integrator */
    1333,     /* lock window = 0.5 line (tighter — film content is sensitive) */
    13335,    /* unlock window = 5 lines */
    150,      /* declare LOCKED after 150 frames (~3 sec @ 50 Hz) — patient */
    60
};

/* Active mode. Default = SMOOTH (Phase 6/7 baseline). */
static const lock_mode_t *g_active_mode = &MODE_SMOOTH;

/* Convenience macros that resolve to the active mode's fields. The existing
 * loop_tick code references these by their original names; this is a
 * drop-in indirection. */
#define KP_MILLI_PPM_PER_LINE     (g_active_mode->kp_mppm_per_line)
#define KI_MILLI_PPM_PER_LINE     (g_active_mode->ki_mppm_per_line)
#define LOCK_THRESHOLD_TICKS      ((s32)g_active_mode->lock_threshold_ticks)
#define UNLOCK_THRESHOLD_TICKS    ((s32)g_active_mode->unlock_threshold_ticks)
#define LOCK_FRAMES               (g_active_mode->lock_frames)
#define UNLOCK_FRAMES             (g_active_mode->unlock_frames)

#define INTEGRATOR_CLAMP_MILLI_PPM   500000    /* ±500 ppm — full MMCM pull range */
/* Baseline-cancellation pre-load. With synth_vsync_gen DIVISOR=2_857_143 (50
 * Hz exact synth ref) and MMCM auto-picked at 49.99490 Hz natural, the loop's
 * steady-state cmd is approximately -baseline / plant_gain ≈ -94 ppm. Preload
 * near this value to avoid the long initial saturation phase from acquire. */
#define INTEGRATOR_PRELOAD_MILLI_PPM  -94000   /* -94 ppm (Phase 7/8 value) */
/* LOCK_THRESHOLD_TICKS / UNLOCK_THRESHOLD_TICKS / LOCK_FRAMES /
 * UNLOCK_FRAMES are now per-mode (see lock_mode_t / MODE_SNAP/SMOOTH/FILM
 * structs above). Macros indirect through g_active_mode. */
#define STATS_PERIOD_FRAMES              50    /* ~1 sec at 50 Hz */

typedef enum {
    LOOP_OFF       = 0,
    LOOP_FREE_RUN  = 1,  /* Phase 7: ref_select=free, integrator forced 0 */
    LOOP_ACQUIRING = 2,
    LOOP_LOCKED    = 3,
    LOOP_HOLDOVER  = 4,  /* Phase 7: was LOCKED, ref edges stopped, freeze integrator */
} loop_state_t;

static volatile int  g_loop_enable    = 0;
static loop_state_t  g_lock_state     = LOOP_OFF;
static s32           g_integrator_mppm = 0;
static u32           g_last_out_count = 0;
static u32           g_last_ref_count = 0;
static int           g_frames_in_lock_range   = 0;
static int           g_frames_out_lock_range  = 0;
static int           g_frames_since_ref_edge  = 0;   /* Phase 7: holdover trigger */
static int           g_dump_per_frame = 0;     /* 1 = emit each-frame sample */
static int           g_stat_frames    = 0;
static s32           g_stat_err_min   = 0;
static s32           g_stat_err_max   = 0;
static s32           g_stat_err_sum   = 0;
static u32           g_total_locked_frames = 0;
static u32           g_unlock_events  = 0;
static u32           g_loop_enable_count_at_start = 0;

/* Phase 8 — dual-loop cadence cooperation. */
static s32           g_bias_mppm           = 0;     /* synthetic ref-rate bias (set by 'b') */
static s64           g_bias_accum_ticks    = 0;     /* cumulative bias-induced phase shift */
static s64           g_slip_offset_ticks   = 0;     /* total ref-side slip absorbed */
static int           g_frames_at_saturation = 0;    /* contiguous frames with cmd at clamp */
static u32           g_slip_count          = 0;     /* total slip events emitted */
#define SLIP_SAT_FRAMES_THRESHOLD  30   /* frames at clamp before emitting a slip */

static const char *state_label(loop_state_t s)
{
    switch (s) {
        case LOOP_OFF:       return "OFF";
        case LOOP_FREE_RUN:  return "FREE_RUN";
        case LOOP_ACQUIRING: return "ACQUIRING";
        case LOOP_LOCKED:    return "LOCKED";
        case LOOP_HOLDOVER:  return "HOLDOVER";
        default:             return "?";
    }
}

static s32 abs_s32(s32 v) { return v < 0 ? -v : v; }

static void cmd_lock_enable(void)
{
    if (g_loop_enable) {
        xil_printf("\r\n[L] already enabled (state=%s).\r\n", state_label(g_lock_state));
        return;
    }
    /* Snapshot the current out_count so loop_tick waits for the next edge. */
    u32 oc, dummy_rc;
    u64 dummy_ts;
    dummy_ts = vts_read_ts(VTS_TS_OUT_LO, VTS_TS_OUT_HI, VTS_OUT_COUNT, &oc);
    (void)dummy_ts;
    g_last_out_count = oc;
    g_loop_enable_count_at_start = oc;

    /* Reset state. Pre-load integrator near the expected steady-state to
     * shorten the saturation phase during initial acquire. */
    g_integrator_mppm = INTEGRATOR_PRELOAD_MILLI_PPM;
    g_frames_in_lock_range = 0;
    g_frames_out_lock_range = 0;
    g_stat_frames = 0;
    g_stat_err_min = g_stat_err_max = g_stat_err_sum = 0;
    g_total_locked_frames = 0;
    g_unlock_events = 0;
    g_bias_accum_ticks = 0;
    g_slip_offset_ticks = 0;
    g_frames_at_saturation = 0;
    g_slip_count = 0;

    /* Zero actuator before flipping the enable, so first correction starts clean. */
    Xil_Out32(ACT_PHASE_STEP, 0);

    g_lock_state  = LOOP_ACQUIRING;
    g_loop_enable = 1;

    /* Sanity-check Phase 2 ref is alive. */
    dummy_ts = vts_read_ts(VTS_TS_REF_LO, VTS_TS_REF_HI, VTS_REF_COUNT, &dummy_rc);
    (void)dummy_ts;
    xil_printf("\r\n[L] Phase 6 loop ENABLED  (ts_ref_count=%u, mode=%s)\r\n"
               "    Kp_milli=%d ppm/line  Ki_milli=%d ppm/line/frame\r\n"
               "    integrator_clamp_milli=%d  lock_frames=%u  lock_thresh_ticks=%d\r\n",
               (unsigned)dummy_rc,
               g_active_mode->name,
               (int)KP_MILLI_PPM_PER_LINE, (int)KI_MILLI_PPM_PER_LINE,
               (int)INTEGRATOR_CLAMP_MILLI_PPM, (unsigned)LOCK_FRAMES,
               (int)LOCK_THRESHOLD_TICKS);
}

/* Phase E2.2 — runtime mode selection. Switching mode resets the in-/out-
 * lock frame counters so the new mode's lock_frames count starts fresh,
 * but leaves the integrator value alone (the new mode's gains apply
 * starting on the next loop tick). Loop state stays whatever it was —
 * if currently LOCKED, the loop continues running with the new gains. */
static void cmd_lock_mode(const char *arg)
{
    while (*arg == ' ') ++arg;
    const lock_mode_t *new_mode = NULL;
    if (arg[0] == 's' || arg[0] == 'S') {
        if (arg[1] == 'm' || arg[1] == 'M') new_mode = &MODE_SMOOTH;
        else                                new_mode = &MODE_SNAP;
    } else if (arg[0] == 'f' || arg[0] == 'F') {
        new_mode = &MODE_FILM;
    }
    if (new_mode == NULL) {
        xil_printf("\r\n[O] usage: o <snap|smooth|film>. Got '%s'.\r\n"
                   "     Active: %s (Kp=%d, Ki=%d, lock_frames=%u)\r\n",
                   arg, g_active_mode->name,
                   (int)KP_MILLI_PPM_PER_LINE, (int)KI_MILLI_PPM_PER_LINE,
                   (unsigned)LOCK_FRAMES);
        return;
    }
    g_active_mode = new_mode;
    g_frames_in_lock_range  = 0;
    g_frames_out_lock_range = 0;
    xil_printf("\r\n[O] lock mode = %s  (Kp=%d.%03d, Ki=%d.%03d, lock_frames=%u, lock_thresh=%d t)\r\n",
               g_active_mode->name,
               g_active_mode->kp_mppm_per_line / 1000,
               g_active_mode->kp_mppm_per_line % 1000,
               g_active_mode->ki_mppm_per_line / 1000,
               g_active_mode->ki_mppm_per_line % 1000,
               (unsigned)g_active_mode->lock_frames,
               (int)g_active_mode->lock_threshold_ticks);
}

static void cmd_unlock(void)
{
    g_loop_enable = 0;
    g_integrator_mppm = 0;
    Xil_Out32(ACT_PHASE_STEP, 0);
    g_lock_state = LOOP_OFF;
    xil_printf("\r\n[U] loop disabled, actuator zeroed.\r\n");
}

static void cmd_toggle_dump(void)
{
    g_dump_per_frame = !g_dump_per_frame;
    xil_printf("\r\n[S] per-frame dump = %d  (1 Hz summary line always emits)\r\n",
               g_dump_per_frame);
}

/* =========================================================================
 * Phase E1 Phase 7 — reference selector and ref-mask.
 *
 * axi_gpio_refsel is an output-only 4-bit GPIO at one of the IC slots
 * (varies by build; resolved via XPAR_*). The bits map to ref_mux's ctrl:
 *   bit 0: sel[0]  — together with sel[1] selects which source feeds ref
 *   bit 1: sel[1]
 *      sel=00: free-run (1'b0)
 *      sel=01: synthetic reference (Phase 2 FCLK_CLK1 divider)
 *      sel=10, 11: reserved (future external refs)
 *   bit 2: mask  — when 1, force ref to 0 (used to simulate ref loss)
 *   bit 3: reserved
 *
 * AXI GPIO data register is at base+0x00; tri-state at base+0x04 (default
 * 0=output). We never read this GPIO; we only write the control word.
 * ========================================================================= */
#if defined(XPAR_AXI_GPIO_REFSEL_BASEADDR)
#  define REFSEL_BASEADDR XPAR_AXI_GPIO_REFSEL_BASEADDR
#elif defined(XPAR_AXI_GPIO_REFSEL_S_AXI_BASEADDR)
#  define REFSEL_BASEADDR XPAR_AXI_GPIO_REFSEL_S_AXI_BASEADDR
#elif defined(XPAR_PHASE_B_BD_AXI_GPIO_REFSEL_BASEADDR)
#  define REFSEL_BASEADDR XPAR_PHASE_B_BD_AXI_GPIO_REFSEL_BASEADDR
#else
#  error "axi_gpio_refsel base address not found in xparameters.h"
#endif
#define REFSEL_DATA (REFSEL_BASEADDR + 0x00)
#define REFSEL_TRI  (REFSEL_BASEADDR + 0x04)

#define REFSEL_FREE   0x0    /* sel=00 mask=0 */
#define REFSEL_SYNC   0x1    /* sel=01 mask=0 */
#define REFSEL_EXT0   0x2    /* sel=10 — reserved (Si5351 / analog recovery) */
#define REFSEL_SRC    0x3    /* sel=11 — Phase E2.1 src_vsync_divider output */
#define REFSEL_MASK_BIT 0x4  /* OR with current to mask the output */

/* Phase E2.1 — src_vsync_divider M/N control via axi_gpio_srcdiv.
 * ch0 (offset +0x00) = M (numerator, 8 bits)
 * ch1 (offset +0x08) = N (denominator, 8 bits)
 * Output rate = source_rate × M / N. M=N=0 selects HDL parameter defaults
 * (M=1, N=1 — passthrough). */
#if defined(XPAR_AXI_GPIO_SRCDIV_BASEADDR)
#  define SRCDIV_BASEADDR XPAR_AXI_GPIO_SRCDIV_BASEADDR
#elif defined(XPAR_AXI_GPIO_SRCDIV_S_AXI_BASEADDR)
#  define SRCDIV_BASEADDR XPAR_AXI_GPIO_SRCDIV_S_AXI_BASEADDR
#elif defined(XPAR_PHASE_B_BD_AXI_GPIO_SRCDIV_BASEADDR)
#  define SRCDIV_BASEADDR XPAR_PHASE_B_BD_AXI_GPIO_SRCDIV_BASEADDR
#else
#  error "axi_gpio_srcdiv base address not found in xparameters.h"
#endif
#define SRCDIV_M_DATA (SRCDIV_BASEADDR + 0x00)
#define SRCDIV_M_TRI  (SRCDIV_BASEADDR + 0x04)
#define SRCDIV_N_DATA (SRCDIV_BASEADDR + 0x08)
#define SRCDIV_N_TRI  (SRCDIV_BASEADDR + 0x0C)

/* Phase P1-3 (2026-05-19): widened from u8 to u16 to support NTSC's
 * irreducible 2500/2997 ratio (and similar). axi_gpio_srcdiv now 16 bits
 * per channel. */
static u16 g_srcdiv_m = 1;  /* default: passthrough 1:1 */
static u16 g_srcdiv_n = 1;

static void srcdiv_write(u16 m, u16 n)
{
    Xil_Out32(SRCDIV_M_TRI, 0);
    Xil_Out32(SRCDIV_N_TRI, 0);
    Xil_Out32(SRCDIV_M_DATA, (u32)m);
    Xil_Out32(SRCDIV_N_DATA, (u32)n);
}

static u8 g_ref_select = REFSEL_FREE;   /* boot: free-run (safe — no edges) */
static int g_ref_masked = 0;
static u32 g_last_loop_baseline_ppm_mppm = 0;   /* for the HOLDOVER message */

static void refsel_write(u8 sel, int masked)
{
    /* Tri-state register defaults to 0 (output) at reset for axi_gpio in
     * all-outputs mode. Make it explicit anyway for safety. */
    Xil_Out32(REFSEL_TRI, 0);
    u32 word = (sel & 0x3) | (masked ? REFSEL_MASK_BIT : 0);
    Xil_Out32(REFSEL_DATA, word);
}

static void cmd_ref_select(const char *arg)
{
    while (*arg == ' ') ++arg;
    if (arg[0] == 'f' || arg[0] == 'F') {
        g_ref_select = REFSEL_FREE;
        /* In FREE-RUN mode: integrator forced to zero, no edges arrive,
         * loop is effectively passive. Reset state machine. */
        g_integrator_mppm = 0;
        Xil_Out32(ACT_PHASE_STEP, 0);
        g_lock_state = LOOP_FREE_RUN;
        g_frames_in_lock_range = 0;
        g_frames_out_lock_range = 0;
        g_frames_since_ref_edge = 0;
        refsel_write(g_ref_select, g_ref_masked);
        xil_printf("\r\n[R] reference = FREE_RUN (integrator zeroed, actuator zeroed)\r\n");
    } else if (arg[0] == 's' && (arg[1] == 'y' || arg[1] == 'Y' || arg[1] == ' ' || arg[1] == '\0' || arg[1] == '\r' || arg[1] == '\n')) {
        g_ref_select = REFSEL_SYNC;
        refsel_write(g_ref_select, g_ref_masked);
        /* If the loop is enabled, transition state machine to ACQUIRING. */
        if (g_loop_enable) {
            g_lock_state = LOOP_ACQUIRING;
            g_frames_in_lock_range = 0;
            g_frames_out_lock_range = 0;
            g_frames_since_ref_edge = 0;
            /* Re-prime the integrator near the steady-state operating point. */
            g_integrator_mppm = INTEGRATOR_PRELOAD_MILLI_PPM;
        }
        xil_printf("\r\n[R] reference = SYNC (synthetic Phase 2)\r\n");
    } else if (arg[0] == 's' && (arg[1] == 'r' || arg[1] == 'R')) {
        /* Phase E2.1 — source-vsync-derived reference. The ref_mux selects
         * src_vsync_divider's output (sel=11), which is a stream of pulses
         * at source_rate × M / N. Default M=N=1 is 1:1 passthrough — use
         * with output VTC mode that matches source rate (720p60 from
         * 720p60 source). For 60→50 FRC: set M=5, N=6 via 'n' command. */
        g_ref_select = REFSEL_SRC;
        refsel_write(g_ref_select, g_ref_masked);
        if (g_loop_enable) {
            g_lock_state = LOOP_ACQUIRING;
            g_frames_in_lock_range = 0;
            g_frames_out_lock_range = 0;
            g_frames_since_ref_edge = 0;
            g_integrator_mppm = INTEGRATOR_PRELOAD_MILLI_PPM;
        }
        xil_printf("\r\n[R] reference = SRC (source vsync × %u/%u via src_vsync_divider)\r\n",
                   (unsigned)g_srcdiv_m, (unsigned)g_srcdiv_n);
    } else {
        xil_printf("\r\nUART: 'r <free|sync|src>' — got '%s'\r\n", arg);
    }
}

/* Phase E2.3 — current output target rate, in milli-Hz. Hardcoded to 720p50
 * for the spike (matches vtc_setup(&MODE_720P50) in main). When firmware
 * grows runtime output-mode switching, this global gets updated alongside
 * vtc_setup. */
static u32 g_output_target_mhz = 50000;  /* 50.000 Hz */

/* Forward declaration — defined later in the file (Phase D iter-4a section). */
static u32 measure_source_rate_mhz(int target_edges);

/* Phase E2.3 — Euclidean GCD for reducing M/N to lowest terms. */
static u32 frc_gcd(u32 a, u32 b)
{
    while (b != 0) {
        u32 t = b;
        b = a % b;
        a = t;
    }
    return a;
}

/* Phase E2.3 — compute reduced M/N where output_rate = source × M/N.
 * Returns 1 if a valid (M ≤ N, both fit in 8 bits) ratio exists.
 * Returns 0 if source rate would require up-conversion (M > N — not
 * supported by src_vsync_divider's current HDL) or if reduced terms
 * exceed 8 bits. */
static int compute_frc_ratio(u32 src_mhz, u32 out_mhz, u16 *m_out, u16 *n_out)
{
    if (src_mhz == 0 || out_mhz == 0) return 0;
    if (out_mhz > src_mhz) return 0;  /* up-conversion not supported */
    u32 g = frc_gcd(out_mhz, src_mhz);
    u32 m = out_mhz / g;
    u32 n = src_mhz / g;
    /* Phase P1-3 (2026-05-19): widened cap from 255 to 65535 — divider's
     * GPIO is now 16 bits per channel. NTSC's 2500/2997 fits. */
    if (m == 0 || m > 65535 || n == 0 || n > 65535) return 0;
    *m_out = (u16)m;
    *n_out = (u16)n;
    return 1;
}

/* Phase E2.3 — auto-FRC: measure source rate, derive M/N for the configured
 * output, apply via src_vsync_divider, and switch the loop reference to
 * source-vsync mode. One-shot; firmware doesn't auto-retrigger on source
 * rate change (manual 'a' refresh covers that for now). */
static void cmd_auto_frc(void)
{
    xil_printf("\r\n[A] auto-FRC: measuring source rate (~1 s) ...\r\n");
    u32 src_mhz = measure_source_rate_mhz(60);
    if (src_mhz == 0) {
        xil_printf("[A] FAILED: source rate measurement returned 0 (pLocked dropped or no edges).\r\n");
        return;
    }
    xil_printf("[A] source = %u.%03u Hz; output target = %u.%03u Hz\r\n",
               src_mhz / 1000, src_mhz % 1000,
               g_output_target_mhz / 1000, g_output_target_mhz % 1000);

    u16 m = 0, n = 0;
    if (!compute_frc_ratio(src_mhz, g_output_target_mhz, &m, &n)) {
        xil_printf("[A] FAILED: cannot derive M/N (src < out, or reduced terms > 255).\r\n"
                   "    Current divider supports M ≤ N (down-conversion only). For\r\n"
                   "    src=%u.%03u → out=%u.%03u, set output mode lower than source\r\n"
                   "    or wait for Mackin up-conversion (Phase E3).\r\n",
                   src_mhz/1000, src_mhz%1000,
                   g_output_target_mhz/1000, g_output_target_mhz%1000);
        return;
    }
    /* Apply M/N to the divider, then point the ref mux at the source path. */
    g_srcdiv_m = m;
    g_srcdiv_n = n;
    srcdiv_write(m, n);
    g_ref_select = REFSEL_SRC;
    refsel_write(g_ref_select, g_ref_masked);
    if (g_loop_enable) {
        g_lock_state = LOOP_ACQUIRING;
        g_frames_in_lock_range  = 0;
        g_frames_out_lock_range = 0;
        g_frames_since_ref_edge = 0;
        g_integrator_mppm = INTEGRATOR_PRELOAD_MILLI_PPM;
    }
    xil_printf("[A] APPLIED: M/N = %u/%u → ref = source × %u/%u (= %u.%03u Hz target)\r\n"
               "    ref_mux now in SRC mode. Send 'L' to engage loop if not already.\r\n",
               (unsigned)m, (unsigned)n, (unsigned)m, (unsigned)n,
               g_output_target_mhz/1000, g_output_target_mhz%1000);
}

/* Phase E2.1 — set source-divider M/N ratio. Output rate = source × M/N.
 * Constraints (enforced here): both > 0, M ≤ N (down-conversion only;
 * src_vsync_divider's HDL doesn't support M > N). */
static void cmd_srcdiv_set(const char *arg)
{
    unsigned m = 0, n = 0;
    while (*arg == ' ') ++arg;
    while (*arg >= '0' && *arg <= '9') { m = m * 10 + (*arg - '0'); ++arg; }
    while (*arg == ' ') ++arg;
    while (*arg >= '0' && *arg <= '9') { n = n * 10 + (*arg - '0'); ++arg; }

    if (m == 0 || n == 0 || m > 65535 || n > 65535) {
        xil_printf("\r\n[N] usage: n <M> <N>  (1..65535 each). Got M=%u N=%u\r\n", m, n);
        return;
    }
    if (m > n) {
        xil_printf("\r\n[N] reject: M (%u) > N (%u). Divider is down-conversion only.\r\n", m, n);
        return;
    }
    g_srcdiv_m = (u16)m;
    g_srcdiv_n = (u16)n;
    srcdiv_write(g_srcdiv_m, g_srcdiv_n);
    xil_printf("\r\n[N] src_vsync_divider M/N = %u/%u  (ref rate = source × %u/%u)\r\n",
               m, n, m, n);
}

static void cmd_toggle_ref_mask(void)
{
    g_ref_masked = !g_ref_masked;
    refsel_write(g_ref_select, g_ref_masked);
    xil_printf("\r\n[s] reference mask = %d  (1 = force ref to 0, simulate ref loss)\r\n",
               g_ref_masked);
}

static void loop_tick(void)
{
    if (!g_loop_enable) return;

    u32 out_count, ref_count;
    u64 ts_out, ts_ref;

    ts_out = vts_read_ts(VTS_TS_OUT_LO, VTS_TS_OUT_HI, VTS_OUT_COUNT, &out_count);
    if (out_count == g_last_out_count) return;   /* no new output edge yet */
    g_last_out_count = out_count;

    ts_ref = vts_read_ts(VTS_TS_REF_LO, VTS_TS_REF_HI, VTS_REF_COUNT, &ref_count);
    if (ref_count == 0) return;   /* ref not yet running */

    /* Phase 7 — track ref-edge liveness. If ref_count doesn't advance for
     * ~3 ref periods, treat as ref-loss. */
    if (ref_count == g_last_ref_count) {
        g_frames_since_ref_edge++;
    } else {
        g_frames_since_ref_edge = 0;
    }
    g_last_ref_count = ref_count;

    /* Compute the shortest-path signed phase error in counter ticks.
     * phase_delta = (ts_out - ts_ref) mod 2^48 is naturally in [0, ref_period)
     * during normal operation (ts_ref updates with each ref edge). But when
     * the ref is masked or lost (HOLDOVER), ts_ref freezes while ts_out keeps
     * advancing — the raw difference grows unbounded. Use a proper modular
     * reduction (not a single-iteration if/else) so the normalization
     * survives ref-loss intervals. C99 % for negative dividends truncates
     * toward zero, so the conditional touch-ups handle the sign.
     *
     * Phase 8 — accumulate ref-rate bias each frame and subtract the running
     * slip offset, BEFORE the modular reduction. Bias of B ppm produces
     * 2B ticks of accumulated extra phase per frame at 50 Hz / 100 MHz ctr.
     * (ppm × frame_period × counter_freq = ppm × 0.02 × 1e8 / 1e6 = ppm × 2.)
     * Bias and slip both operate as "virtual ts_ref adjustment" — they make
     * the loop SEE a different ref relationship without touching the actual
     * synth_vsync_gen output. */
    g_bias_accum_ticks += (s64)g_bias_mppm * 2 / 1000;  /* 2 ticks per ppm per frame, mppm → ppm */
    u64 diff = (ts_out - ts_ref) & 0x0000FFFFFFFFFFFFULL;
    if (diff & 0x0000800000000000ULL) diff |= 0xFFFF000000000000ULL;
    s64 err64 = (s64)diff + g_bias_accum_ticks - g_slip_offset_ticks;
    err64 = err64 % REF_PERIOD_TICKS;
    if (err64 >  (REF_PERIOD_TICKS / 2)) err64 -= REF_PERIOD_TICKS;
    else if (err64 < -(REF_PERIOD_TICKS / 2)) err64 += REF_PERIOD_TICKS;
    s32 err = (s32)err64;

    /* Phase 7 — state-machine transitions for FREE_RUN / HOLDOVER triggered
     * by ref-edge liveness. State entry from FREE_RUN/UNLOCKED is handled
     * by cmd_lock_enable / cmd_ref_select; the in_lock/out_unlock transitions
     * for ACQUIRING ↔ LOCKED happen further down based on |err|. */
    int ref_lost = (g_frames_since_ref_edge > 150);  /* ~3 ref periods @ 50 Hz */
    if (ref_lost) {
        if (g_lock_state == LOOP_LOCKED || g_lock_state == LOOP_ACQUIRING) {
            g_lock_state = LOOP_HOLDOVER;
            g_last_loop_baseline_ppm_mppm = g_integrator_mppm;
            xil_printf(">>> HOLDOVER engaged at out_count=%u (integrator frozen at %d mppm)\r\n",
                       (unsigned)out_count, (int)g_integrator_mppm);
        }
    } else if (g_lock_state == LOOP_HOLDOVER) {
        g_lock_state = LOOP_ACQUIRING;
        g_frames_in_lock_range = 0;
        g_frames_out_lock_range = 0;
        xil_printf(">>> HOLDOVER released at out_count=%u — re-acquiring\r\n",
                   (unsigned)out_count);
    }

    /* Compute command per current state. */
    s32 cmd_mppm = 0;
    if (g_lock_state == LOOP_FREE_RUN) {
        g_integrator_mppm = 0;
        cmd_mppm = 0;
    } else if (g_lock_state == LOOP_HOLDOVER) {
        /* Freeze integrator at last value; do not update on err. */
        cmd_mppm = g_integrator_mppm;
    } else {
        /* ACQUIRING or LOCKED: standard PI controller. Sign convention: negative
         * feedback — positive err pushes cmd negative (output faster). Use s64
         * for the multiply (KP × |err near half-period| overflows s32). */
        s32 p_term = (s32)(-((s64)KP_MILLI_PPM_PER_LINE * (s64)err) / TICKS_PER_LINE_720P50);
        s32 i_step = (s32)(-((s64)KI_MILLI_PPM_PER_LINE * (s64)err) / TICKS_PER_LINE_720P50);

        /* Conditional-integration anti-windup: don't push the integrator deeper
         * into saturation when cmd is already saturated. */
        s32 cmd_pre = p_term + g_integrator_mppm;
        int sat_hi = (cmd_pre >  INTEGRATOR_CLAMP_MILLI_PPM);
        int sat_lo = (cmd_pre < -INTEGRATOR_CLAMP_MILLI_PPM);
        int allow_integrate = 1;
        if (sat_hi && i_step > 0) allow_integrate = 0;
        if (sat_lo && i_step < 0) allow_integrate = 0;
        if (allow_integrate) {
            g_integrator_mppm += i_step;
            if (g_integrator_mppm >  INTEGRATOR_CLAMP_MILLI_PPM) g_integrator_mppm =  INTEGRATOR_CLAMP_MILLI_PPM;
            if (g_integrator_mppm < -INTEGRATOR_CLAMP_MILLI_PPM) g_integrator_mppm = -INTEGRATOR_CLAMP_MILLI_PPM;
        }
        cmd_mppm = p_term + g_integrator_mppm;
        if (cmd_mppm >  INTEGRATOR_CLAMP_MILLI_PPM) cmd_mppm =  INTEGRATOR_CLAMP_MILLI_PPM;
        if (cmd_mppm < -INTEGRATOR_CLAMP_MILLI_PPM) cmd_mppm = -INTEGRATOR_CLAMP_MILLI_PPM;
    }

    /* Apply: phase_step = cmd × ACT_STEP_PER_PPM / 1000. */
    s64 step64 = (s64)cmd_mppm * ACT_STEP_PER_PPM / 1000;
    Xil_Out32(ACT_PHASE_STEP, (u32)(s32)step64);

    /* Phase 8 — cadence-cooperation slip event. The spec calls for the
     * controller to "release a frame slip" when the rate offset exceeds
     * what fine PS can compensate. Trigger conditions:
     *   (a) loop is LOCKED (this is steady-state behavior, not initial
     *       acquire saturation)
     *   (b) cmd has been at ±clamp for ≥SLIP_SAT_FRAMES_THRESHOLD frames
     *       (proves the MMCM is genuinely out of range, not just transient)
     *   (c) the unbounded bias accumulator has crossed ±REF_PERIOD_TICKS
     *       since the last slip — this gates the slip RATE to match
     *       bias_ppm × frame_rate / 1e6 slips/sec, the spec's prediction.
     *
     * The slip itself is a controller-counter event for the spike: real
     * VDMA frame-slip semantics (actually drop/repeat a frame in the
     * framestore ring) are production plumbing. We track slips and prove
     * the rate matches; the SOF-atomic VDMA park-pointer write is left
     * for production. */
    int at_clamp_hi = (cmd_mppm >=  INTEGRATOR_CLAMP_MILLI_PPM);
    int at_clamp_lo = (cmd_mppm <= -INTEGRATOR_CLAMP_MILLI_PPM);
    if (at_clamp_hi || at_clamp_lo) g_frames_at_saturation++;
    else                            g_frames_at_saturation = 0;

    /* Trigger condition: bias accumulator has crossed ±REF_PERIOD AND
     * the loop is saturated (confirming the over-range condition).
     * Decoupled from lock state — under heavy bias the loop alternates
     * between LOCKED, ACQUIRING, and saturated, and slips should fire
     * throughout. This counts "controller would have commanded a VDMA
     * frame slip"; real VDMA park-pointer manipulation is left for
     * production. */
    if (g_bias_mppm != 0 && (at_clamp_hi || at_clamp_lo)) {
        s64 net_bias = g_bias_accum_ticks - g_slip_offset_ticks;
        s32 slip_dir = 0;
        if (net_bias >=  REF_PERIOD_TICKS) slip_dir = +1;
        else if (net_bias <= -REF_PERIOD_TICKS) slip_dir = -1;
        if (slip_dir != 0) {
            g_slip_offset_ticks += (s64)slip_dir * REF_PERIOD_TICKS;
            g_slip_count++;
            xil_printf(">>> SLIP %u dir %d frame %u sat_frames %d net_bias_post %d\r\n",
                       (unsigned)g_slip_count, (int)slip_dir,
                       (unsigned)out_count,
                       (int)g_frames_at_saturation,
                       (int)(net_bias - (s64)slip_dir * REF_PERIOD_TICKS));
        }
    }

    /* In ACQUIRING / LOCKED only: update the |err|-based lock detection. */
    if (g_lock_state == LOOP_ACQUIRING || g_lock_state == LOOP_LOCKED) {
        int in_lock    = (err >= -LOCK_THRESHOLD_TICKS) && (err <= LOCK_THRESHOLD_TICKS);
        int out_unlock = (err < -UNLOCK_THRESHOLD_TICKS) || (err > UNLOCK_THRESHOLD_TICKS);
        if (in_lock) {
            g_frames_in_lock_range++;
            g_frames_out_lock_range = 0;
            if (g_lock_state == LOOP_ACQUIRING && g_frames_in_lock_range >= LOCK_FRAMES) {
                g_lock_state = LOOP_LOCKED;
                xil_printf(">>> LOCKED at frame %u\r\n",
                           (unsigned)(out_count - g_loop_enable_count_at_start));
            }
            if (g_lock_state == LOOP_LOCKED) g_total_locked_frames++;
        } else {
            g_frames_in_lock_range = 0;
            if (g_lock_state == LOOP_LOCKED && out_unlock) {
                g_frames_out_lock_range++;
                if (g_frames_out_lock_range >= UNLOCK_FRAMES) {
                    g_lock_state = LOOP_ACQUIRING;
                    g_unlock_events++;
                    xil_printf(">>> UNLOCK event #%u at frame %u\r\n",
                               (unsigned)g_unlock_events,
                               (unsigned)(out_count - g_loop_enable_count_at_start));
                }
            } else {
                g_frames_out_lock_range = 0;
            }
        }
    }

    /* Stats accumulation. */
    if (g_stat_frames == 0 || err < g_stat_err_min) g_stat_err_min = err;
    if (g_stat_frames == 0 || err > g_stat_err_max) g_stat_err_max = err;
    g_stat_err_sum += err;
    g_stat_frames++;

    if (g_dump_per_frame) {
        xil_printf("F,%u,%d,%d,%d\r\n",
                   (unsigned)(out_count - g_loop_enable_count_at_start),
                   (int)err, (int)cmd_mppm, (int)g_integrator_mppm);
    }

    if (g_stat_frames >= STATS_PERIOD_FRAMES) {
        s32 mean = g_stat_err_sum / g_stat_frames;
        /* bias_accum/slip_offset are s64 — print only the low 32 bits.
         * For the +1000 ppm validation case the accumulator never exceeds
         * a few minutes' worth of ticks (well under 2^31). */
        xil_printf("LOCK mode=%s state=%s err=%d/%d/%d cmd=%d int=%d locked=%u unlocks=%u ref_idle=%d bias=%d slips=%u sat=%d acc=%d slip_off=%d\r\n",
                   g_active_mode->name,
                   state_label(g_lock_state),
                   (int)mean, (int)g_stat_err_min, (int)g_stat_err_max,
                   (int)cmd_mppm, (int)g_integrator_mppm,
                   (unsigned)g_total_locked_frames, (unsigned)g_unlock_events,
                   (int)g_frames_since_ref_edge,
                   (int)g_bias_mppm,
                   (unsigned)g_slip_count,
                   (int)g_frames_at_saturation,
                   (int)(g_bias_accum_ticks & 0xFFFFFFFF),
                   (int)(g_slip_offset_ticks & 0xFFFFFFFF));
        g_stat_frames = 0;
        g_stat_err_sum = 0;
    }
}

static int parse_signed(const char *s, s32 *out)
{
    int neg = 0;
    s32 v = 0;
    while (*s == ' ') ++s;
    if (*s == '-') { neg = 1; ++s; }
    else if (*s == '+') { ++s; }
    if (*s < '0' || *s > '9') return 0;
    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (*s - '0');
        ++s;
    }
    *out = neg ? -v : v;
    return 1;
}

/* Phase 8 — synthetic reference-rate bias injector + slip counter reset.
 * The bias is added to the loop's perceived err each frame, simulating a
 * reference that's running at the *commanded ppm offset* from the actual
 * synth_vsync_gen rate. Used to drive the loop past its MMCM pull range
 * (±500 ppm) and exercise the cadence-cooperation handoff (frame slips). */
static void cmd_bias(s32 ppm)
{
    g_bias_mppm = ppm * 1000;          /* store as milli-ppm */
    g_bias_accum_ticks = 0;            /* reset bias accumulator on new cmd */
    g_slip_offset_ticks = 0;           /* clear prior slip tally */
    g_frames_at_saturation = 0;
    g_slip_count = 0;
    xil_printf("\r\n[B] reference-rate bias = %d ppm (mppm=%d)\r\n"
               "    accumulator + slip tally reset.\r\n",
               (int)ppm, (int)g_bias_mppm);
}

static void cmd_help(void)
{
    xil_printf("\r\nPhase E1 UART commands:\r\n"
               "  q             query: counter, ts_ref, ts_out, edge counts\r\n"
               "  p             phase: signed (ts_out - ts_ref) in ticks/ns\r\n"
               "  c             Phase 2: capture 1000 ts_ref samples as CSV\r\n"
               "  C             Phase 2: capture 100 ts_ref samples (quick jitter)\r\n"
               "  d             Phase 3: capture 3000 drift pairs (~60 s)\r\n"
               "  D             Phase 3: capture 300 drift pairs (quick drift sanity)\r\n"
               "  m <ppm>       Phase 4: nudge MMCM output by signed ppm (e.g. m +20)\r\n"
               "  m0  (or M)    Phase 4: zero the nudge (return to nominal)\r\n"
               "  L             Phase 6: enable PI loop (closed-loop lock)\r\n"
               "  U             Phase 6: disable loop, zero actuator (free-run)\r\n"
               "  S             Phase 6: toggle per-frame CSV dump\r\n"
               "  r <free|sync|src> Phase 7 + E2.1: select reference source\r\n"
               "  s             Phase 7: toggle ref-mask (simulate ref loss)\r\n"
               "  n <M> <N>     E2.1: src_vsync_divider ratio (output = src×M/N)\r\n"
               "  a             E2.3: auto-FRC (measure source, set M/N, ref=src)\r\n"
               "  o <snap|smooth|film> E2.2: select lock mode (default SMOOTH)\r\n"
               "  B <ppm>       Phase 8: inject ref-rate bias (saturation/slip test)\r\n"
               "  ?             this help\r\n");
}

static void uart_poll_and_dispatch(void)
{
    int c = uart_recv_nb();
    if (c < 0) return;
    switch (c) {
        case 'q': case 'Q': cmd_query(); break;
        case 'p': case 'P': cmd_phase(); break;
        case 'c':           cmd_capture(1000); break;
        case 'C':           cmd_capture(100);  break;
        case 'd':           cmd_drift(3000);   break;
        case 'D':           cmd_drift(300);    break;
        case 'M':           cmd_nudge(0);      break;
        case 'L':           cmd_lock_enable(); break;
        case 'U':           cmd_unlock();      break;
        case 'S':           cmd_toggle_dump(); break;
        case 's':           cmd_toggle_ref_mask(); break;
        case 'B': {
            /* B <signed_ppm> — Phase 8 reference-rate bias injection */
            char buf[16];
            unsigned bi = 0;
            int timeout_ticks = 100000000;
            while (bi + 1 < sizeof(buf) && timeout_ticks > 0) {
                int ch = uart_recv_nb();
                if (ch < 0) { --timeout_ticks; continue; }
                if (ch == '\r' || ch == '\n') break;
                buf[bi++] = (char)ch;
                xil_printf("%c", ch);
            }
            buf[bi] = '\0';
            s32 ppm;
            if (parse_signed(buf, &ppm)) {
                cmd_bias(ppm);
            } else {
                xil_printf("\r\nUART: 'B <signed_ppm>' (e.g. 'B +1000'). Got '%s'\r\n", buf);
            }
            break;
        }
        case 'r': {
            /* r <free|sync|src>  — Phase 7 + E2.1 reference selector */
            char buf[16];
            unsigned bi = 0;
            int timeout_ticks = 100000000;
            while (bi + 1 < sizeof(buf) && timeout_ticks > 0) {
                int ch = uart_recv_nb();
                if (ch < 0) { --timeout_ticks; continue; }
                if (ch == '\r' || ch == '\n') break;
                buf[bi++] = (char)ch;
                xil_printf("%c", ch);
            }
            buf[bi] = '\0';
            cmd_ref_select(buf);
            break;
        }
        case 'n': case 'N': {
            /* n <M> <N>  — E2.1 src_vsync_divider M/N ratio. */
            char buf[24];
            unsigned bi = 0;
            int timeout_ticks = 100000000;
            while (bi + 1 < sizeof(buf) && timeout_ticks > 0) {
                int ch = uart_recv_nb();
                if (ch < 0) { --timeout_ticks; continue; }
                if (ch == '\r' || ch == '\n') break;
                buf[bi++] = (char)ch;
                xil_printf("%c", ch);
            }
            buf[bi] = '\0';
            cmd_srcdiv_set(buf);
            break;
        }
        case 'a': case 'A':       cmd_auto_frc();    break;
        case 'o': case 'O': {
            /* o <snap|smooth|film>  — E2.2 lock mode selection. */
            char buf[16];
            unsigned bi = 0;
            int timeout_ticks = 100000000;
            while (bi + 1 < sizeof(buf) && timeout_ticks > 0) {
                int ch = uart_recv_nb();
                if (ch < 0) { --timeout_ticks; continue; }
                if (ch == '\r' || ch == '\n') break;
                buf[bi++] = (char)ch;
                xil_printf("%c", ch);
            }
            buf[bi] = '\0';
            cmd_lock_mode(buf);
            break;
        }
        case 'm': {
            /* m <signed_ppm><newline> — read the argument synchronously
             * since the telemetry loop is paused for the duration of
             * subsequent commands anyway. ~1 s timeout on input. */
            char buf[16];
            unsigned bi = 0;
            int saw_digit = 0;
            int timeout_ticks = 100000000;  /* ~1 s at 100 MHz spin */
            while (bi + 1 < sizeof(buf) && timeout_ticks > 0) {
                int ch = uart_recv_nb();
                if (ch < 0) { --timeout_ticks; continue; }
                if (ch == '\r' || ch == '\n') break;
                buf[bi++] = (char)ch;
                if ((ch >= '0' && ch <= '9') || ch == '-' || ch == '+') saw_digit = 1;
                /* Echo so the user sees what was typed. */
                xil_printf("%c", ch);
            }
            buf[bi] = '\0';
            s32 ppm;
            if (saw_digit && parse_signed(buf, &ppm)) {
                cmd_nudge(ppm);
            } else {
                xil_printf("\r\nUART: 'm <signed_ppm>' (e.g. 'm +20'). Got '%s'\r\n", buf);
            }
            break;
        }
        case '?': case 'h': case 'H': cmd_help(); break;
        case '\r': case '\n': break;  /* silent on bare newline */
        default:
            xil_printf("UART: unknown cmd '%c' (0x%02x). Type ? for help.\r\n",
                       (c >= 0x20 && c < 0x7f) ? c : '?', (unsigned)c);
            break;
    }
}

static int wait_for_aligned_source_vsync(void)
{
    /* Wait for pLocked stable for ≥100 ms. Re-check every 1 ms; reset the
     * counter if it ever drops. Times out after 10 seconds if the source
     * never locks. */
    int stable_ms = 0;
    int total_ms  = 0;
    while (stable_ms < 100) {
        if (vsync_gpio_read() & VSYNC_GPIO_PLOCKED_MASK) {
            stable_ms++;
        } else {
            stable_ms = 0;
        }
        usleep(1000);
        if (++total_ms > 10000) {
            xil_printf("ERROR: pLocked never stable after 10s\r\n");
            return XST_FAILURE;
        }
    }

    /* Spin to a falling edge of vsync, then to the next rising edge.
     * Source vsync pulse is ~74 µs HIGH per frame, LOW for ~16.6 ms.
     * Each Xil_In32 takes a few hundred ns at 666 MHz PS clock.
     * 50M iterations ≈ 50ms × 2 = 100ms timeout — plenty for ≥3 frames.
     *
     * CRITICAL: no printf / function calls in this critical section. After
     * the polling exits, latency to vtc_setup_720p's CTL write must stay
     * under the vsync HIGH window (~74 µs) for tight alignment. */
    int timeout = 50000000;
    while ( vsync_gpio_read() & VSYNC_GPIO_VSYNC_MASK) {
        if (--timeout < 0) return XST_FAILURE;
    }
    timeout = 50000000;
    while (!(vsync_gpio_read() & VSYNC_GPIO_VSYNC_MASK)) {
        if (--timeout < 0) return XST_FAILURE;
    }

    return XST_SUCCESS;
}

/* Phase D iter-4a — passive source frame rate detection.
 *
 * Polls the synchronized vid_pVSync GPIO bit (bit 1 of axi_gpio_0) and counts
 * rising edges over a precisely-measured XTime interval. Returns the source
 * frame rate in milli-Hz (so 60000 = 60.000 Hz, 23976 = 23.976 Hz).
 *
 * `target_edges` controls measurement window length and precision:
 *   60 edges → ~1 sec window → millihertz precision is JPEG-MJPEG-stable
 *   12 edges → ~0.2 sec → 10 mHz precision, faster
 *
 * Blocks for ~target_edges/source_rate seconds. Call from idle code only
 * (not from inside the VTC-alignment critical section).
 *
 * Returns 0 if pLocked drops mid-measurement (source disconnected). */
static u32 measure_source_rate_mhz(int target_edges)
{
    /* Phase E1.8 followup (P0-1, 2026-05-19): edge-align the start of the
     * timing window. The previous implementation captured t_start BEFORE
     * the first rising edge, so the measured interval was (N-1) source
     * periods PLUS a startup wait X ∈ [0, T). The formula treated it as
     * N intervals, producing a systematic +X/(N×T) bias — expected
     * +1/(2N-1) on average, or +8400 ppm at N=60. Observed in practice
     * as a +2733 ppm reading against a known ~60 Hz source.
     *
     * Fix: wait for the first rising edge, THEN capture t_start. Count
     * `target_edges` more rising edges (i.e., target_edges intervals),
     * then capture t_end. The measured interval is now exactly N
     * periods, formula gives 1/T = correct rate. */
    int prev    = !!(vsync_gpio_read() & VSYNC_GPIO_VSYNC_MASK);
    int timeout = 200000000;  /* ~few seconds at PS clock */

    /* Synchronize to the first rising edge. */
    while (1) {
        u32 g = vsync_gpio_read();
        if (!(g & VSYNC_GPIO_PLOCKED_MASK)) return 0;  /* source dropped */
        int cur = !!(g & VSYNC_GPIO_VSYNC_MASK);
        if (cur && !prev) break;  /* first rising edge — measurement starts now */
        prev = cur;
        if (--timeout < 0) return 0;
    }

    XTime t_start, t_end;
    XTime_GetTime(&t_start);

    /* Count target_edges further rising edges (= target_edges intervals
     * from the edge we just locked onto). */
    int edges = 0;
    timeout = 200000000;
    while (edges < target_edges) {
        u32 g = vsync_gpio_read();
        if (!(g & VSYNC_GPIO_PLOCKED_MASK)) return 0;
        int cur = !!(g & VSYNC_GPIO_VSYNC_MASK);
        if (cur && !prev) edges++;
        prev = cur;
        if (--timeout < 0) return 0;
    }
    XTime_GetTime(&t_end);

    u64 ticks = (u64)(t_end - t_start);
    if (ticks == 0) return 0;
    /* rate_mHz = (edges * 1000 * COUNTS_PER_SECOND) / ticks  (all u64 math). */
    u64 rate = ((u64)edges * 1000ULL * COUNTS_PER_SECOND) / ticks;
    return (u32)rate;
}

/* Phase D iter-4d-1 — analog of measure_source_rate_mhz for OUTPUT vsync.
 * Drains the VTC's vsync_out edges (CDC-synced via axi_sync_inputs) so we can
 * confirm the free-running output PixelClk is actually at the expected
 * frequency (~59.97 Hz for 720p60). Returns 0 if pclk_locked drops. */
static u32 measure_output_rate_mhz(int target_edges)
{
    int prev    = !!(vsync_gpio_read() & VSYNC_GPIO_VSYNC_OUT_MASK);
    int edges   = 0;
    int timeout = 200000000;
    XTime t_start, t_end;
    XTime_GetTime(&t_start);
    while (edges < target_edges) {
        u32 g = vsync_gpio_read();
        if (!(g & VSYNC_GPIO_PCLK_LOCKED_MASK)) return 0;
        int cur = !!(g & VSYNC_GPIO_VSYNC_OUT_MASK);
        if (cur && !prev) edges++;
        prev = cur;
        if (--timeout < 0) return 0;
    }
    XTime_GetTime(&t_end);
    u64 ticks = (u64)(t_end - t_start);
    if (ticks == 0) return 0;
    u64 rate = ((u64)edges * 1000ULL * COUNTS_PER_SECOND) / ticks;
    return (u32)rate;
}

/* ====================================================================
 * Phase D iter-4d-3 — Frame Rate Conversion (FRC) regime classification.
 *
 * Step 1 (this commit): classify the source rate into a REGIME and print
 * the matching cadence pattern, but DON'T act on it from firmware. The
 * MM2S frame-pointer is now arbitrated entirely by VDMA's hardware
 * genlock (S2MM master, MM2S slave + FrameDelay=1) — see vdma_setup_channel.
 *
 * The cadence table is retained for step 2/3 (where the BD is upgraded to
 * Dynamic Genlock and firmware optionally schedules drop/repeat patterns
 * for 30p→60p and 24p→60p). For 60p→60p, pattern={1} = pass-through, which
 * Dynamic Genlock handles natively without any cadence logic.
 *
 * Pattern semantics:
 *   sum(pattern) = output frames per cadence cycle
 *   len(pattern) = source frames per cadence cycle (= FB advances)
 *   pattern[i]   = how many output frames to show source frame i for
 *
 * Examples:
 *   60p→60p:  pattern={1}      → 1 out / 1 src, advance each output vsync
 *   30p→60p:  pattern={2}      → 2 out / 1 src, advance every 2nd vsync
 *   24p→60p:  pattern={3,2}    → 5 out / 2 src, 3:2 pulldown
 * ==================================================================== */
typedef enum {
    REGIME_60P,
    REGIME_30P,
    REGIME_24P,
    REGIME_UNKNOWN,
    REGIME_COUNT
} src_regime_t;

#define MAX_PATTERN 4
typedef struct {
    int           len;
    int           pattern[MAX_PATTERN];
    const char   *name;
} cadence_t;

static const cadence_t CADENCES[REGIME_COUNT] = {
    [REGIME_60P]     = { 1, {1, 0, 0, 0}, "60p->60p (1:1 pass-through)" },
    [REGIME_30P]     = { 1, {2, 0, 0, 0}, "30p->60p (2:1 repeat)"       },
    [REGIME_24P]     = { 2, {3, 2, 0, 0}, "24p->60p (3:2 pulldown)"     },
    [REGIME_UNKNOWN] = { 1, {1, 0, 0, 0}, "passthrough (unknown rate)"  },
};

static int abs_i(int x) { return x < 0 ? -x : x; }

static src_regime_t classify_rate(u32 rate_mHz)
{
    if (rate_mHz == 0) return REGIME_UNKNOWN;
    /* ±1500 mHz tolerance covers crystal drift + 23.976 vs 24.000 etc. */
    if (abs_i((int)rate_mHz - 60000) < 1500) return REGIME_60P;
    if (abs_i((int)rate_mHz - 30000) < 1500) return REGIME_30P;
    if (abs_i((int)rate_mHz - 24000) < 1500) return REGIME_24P;
    return REGIME_UNKNOWN;
}

/* VDMA PARK_PTR_REG (0x28) layout (PG020) — kept for reference / future A/B:
 *   [4:0]   RDFRMPTRREF — MM2S park frame index
 *   [12:8]  WRFRMPTRREF — S2MM park frame index
 *   [20:16] RDFRMSTORE  — RO, current MM2S frame
 *   [28:24] WRFRMSTORE  — RO, current S2MM frame
 * iter-4d-3 step 1: PARK writes removed. MM2S in circular mode under genlock
 * slave control (DMACR bit 3 = 1, FrameDelay=1). Frame-pointer arbitration
 * is now hardware-enforced via internal frame_ptr wiring (BD parameter
 * c_include_internal_genlock=1). The helpers below are retained but unused. */
__attribute__((unused))
static inline void vdma_set_mm2s_park(UINTPTR vdma_base, int fb_idx)
{
    u32 v = Xil_In32(vdma_base + 0x28);
    v = (v & ~0x1Fu) | ((u32)fb_idx & 0x1Fu);
    Xil_Out32(vdma_base + 0x28, v);
}

__attribute__((unused))
static inline void vdma_mm2s_set_park_mode(UINTPTR vdma_base)
{
    u32 cr = Xil_In32(vdma_base + 0x00);
    Xil_Out32(vdma_base + 0x00, cr & ~0x2u);
}

/* iter-4d-3 step 1: telemetry-only loop. No PARK writes — VDMA handles the
 * MM2S frame-pointer atomically via internal genlock + FrameDelay=1. We only
 * read GPIO to count source vs output vsync edges, classify the source rate,
 * and print drift periodically so we can see whether the genlock alone keeps
 * the picture clean.
 *
 * If 60→60 is visibly seam-free, step 1 is sufficient and we ship iter-4d-3.
 * If seams persist, escalate to step 2 (BD reconfig to Dynamic Genlock:
 * S2MM mode 0→2, MM2S mode 1→3 — verified mapping in axi_vdma_v6_3
 * component.xml: 0=Master, 1=Slave, 2=Dynamic Master, 3=Dynamic Slave). */
static void telemetry_loop(UINTPTR vdma_base)
{
    (void)vdma_base;

    u32 rate_mHz = measure_source_rate_mhz(60);
    src_regime_t regime = classify_rate(rate_mHz);
    const cadence_t *cad = &CADENCES[regime];

    xil_printf("\r\nTELEMETRY: src=%u.%03u Hz -> regime %d [%s]\r\n",
               (unsigned)(rate_mHz / 1000), (unsigned)(rate_mHz % 1000),
               (int)regime, cad->name);
    xil_printf("TELEMETRY: MM2S in circular + genlock-slave, FrameDelay=1\r\n");

    int src_prev = !!(vsync_gpio_read() & VSYNC_GPIO_VSYNC_MASK);
    int out_prev = !!(vsync_gpio_read() & VSYNC_GPIO_VSYNC_OUT_MASK);
    int src_count = 0, out_count = 0;
    int status_every = 60;

    /* Print help once so the user sees the command set on first boot. */
    cmd_help();

    while (1) {
        /* Phase E1 Phase 1 — interleave UART poll. One-char commands fire
         * immediately; no newline required, no buffering. */
        uart_poll_and_dispatch();

        /* Phase E1 Phase 6 — PI controller. Polls ts_out_count; runs only
         * when a new output edge has occurred. ~20 µs per loop iteration. */
        loop_tick();

        u32 g = vsync_gpio_read();
        if (!(g & VSYNC_GPIO_PLOCKED_MASK)) {
            xil_printf("TELEMETRY: source dropped (pLocked=0), waiting...\r\n");
            while (!(vsync_gpio_read() & VSYNC_GPIO_PLOCKED_MASK)) { /* spin */ }
            return;
        }

        int src_cur = !!(g & VSYNC_GPIO_VSYNC_MASK);
        int out_cur = !!(g & VSYNC_GPIO_VSYNC_OUT_MASK);

        if (src_cur && !src_prev) src_count++;
        if (out_cur && !out_prev) {
            out_count++;
            if (out_count >= status_every) {
                u32 park = Xil_In32(vdma_base + 0x28);
                int rdstore = (int)((park >> 16) & 0x1F);
                int wrstore = (int)((park >> 24) & 0x1F);
                xil_printf("TELEMETRY: src=%d out=%d  RDFRMSTORE=%d WRFRMSTORE=%d\r\n",
                           src_count, out_count, rdstore, wrstore);
                src_count = 0;
                out_count = 0;
            }
        }
        src_prev = src_cur;
        out_prev = out_cur;
    }
}

/* VTC mode tables — CEA-861 timings for the 720p variants we care about.
 * Pixel clock is 74.25 MHz for all 720p modes; the rate difference is in
 * HTOTAL (longer blanking at 50p / 30p / 24p). 24p/30p are listed but
 * require an rgb2dvi kClkRange patch (40 MHz floor blocks pixel clocks
 * below ~29.7 MHz at 24p / ~37.1 MHz at 30p — currently the IP would
 * refuse the configuration). For 720p50 the same 74.25 MHz pixel clock
 * works with stock IP — only the V-frame-rate math changes via wider H. */
typedef struct {
    const char *name;
    u32 h_active;
    u32 v_active;
    u32 h_total;
    u32 v_total;
    u32 h_front;   /* HFront porch  */
    u32 h_sync;    /* HSync width   */
    u32 v_front;   /* VFront porch  */
    u32 v_sync;    /* VSync width   */
} vtc_mode_t;

static const vtc_mode_t MODE_720P60 = {
    "720p60", 1280, 720, 1650, 750,  110, 40,  5, 5
};
static const vtc_mode_t MODE_720P50 = {
    "720p50", 1280, 720, 1980, 750,  440, 40,  5, 5
};

static int vtc_setup(const vtc_mode_t *m)
{
    /* Direct register writes to the VTC. We bypass the Xilinx XVtc driver here
     * because its XVtc_SetGenerator implementation does an internal GFENC
     * read-modify-write and writes that have caused Data Aborts on this config.
     *
     * Pixel clock = 74.25 MHz from clk_wiz_pixclk_out (unchanged across modes).
     * HSync + VSync polarity: POSITIVE per CEA-861 720p spec.
     */
    UINTPTR base = XPAR_VTC_0_BASEADDR;
    const u32 H_ACTIVE = m->h_active, V_ACTIVE = m->v_active;
    const u32 H_TOTAL  = m->h_total,  V_TOTAL  = m->v_total;
    const u32 H_SYNC_START   = H_ACTIVE + m->h_front;
    const u32 H_BACK_START   = H_SYNC_START + m->h_sync;
    const u32 V_SYNC_START   = V_ACTIVE + m->v_front;
    const u32 V_BACK_START   = V_SYNC_START + m->v_sync;

    xil_printf("VTC: configuring %s (HTOTAL=%u VTOTAL=%u)\r\n",
               m->name, (unsigned)H_TOTAL, (unsigned)V_TOTAL);

    /* Generator Active Size (active sizes, F0)         offset 0x60 */
    Xil_Out32(base + 0x60, (V_ACTIVE << 16) | H_ACTIVE);
    /* Generator Frame Horizontal Size (HTotal)         offset 0x70 */
    Xil_Out32(base + 0x70, H_TOTAL);
    /* Generator Frame Vertical Size (VTotal F0 + F1)   offset 0x74 */
    Xil_Out32(base + 0x74, (V_TOTAL << 16) | V_TOTAL);
    /* Generator Horizontal Sync (start | end)          offset 0x78 */
    Xil_Out32(base + 0x78, (H_BACK_START << 16) | H_SYNC_START);
    /* Generator Vertical Sync F0 (start | end)         offset 0x80 */
    Xil_Out32(base + 0x80, (V_BACK_START << 16) | V_SYNC_START);

    /* Generator Polarity (offset 0x6C, XVTC_GPOL):
     * 720p CEA-861 = HSync+VSync POSITIVE (active-high), active video active-high.
     *   bit 4 AVP=1, bit 3 HSP=1, bit 2 VSP=1, bit 1 HBP=1, bit 0 VBP=1 */
    Xil_Out32(base + 0x6C, 0x0000001F);

    /* Frame-sync 00 config (offset 0x100): pulse at line 480 col 0 = start
     * of vblank for 480p. Gives MM2S the full vblank period to start streaming. */
    Xil_Out32(base + 0x100, (V_ACTIVE << 16) | 0);

    /* Control register layout (offset 0x00):
     *   bit 0 = SW   — VTC core enable
     *   bit 1 = RU   — Register Update Enable (commits shadow regs to active)
     *   bit 2 = GE   — Generator enable
     *   bits 8-26    — source-select bits (route gen-side timing to outputs)
     *
     * RU=1 is CRITICAL. Without it, all register writes above sit in shadow
     * registers and never reach the active generator. Symptom: all outputs
     * stuck low → rgb2dvi sees no sync → monitor "No Signal". Found
     * 2026-05-14 by XSCT-poking CTL and seeing GE/sync come alive only after
     * adding bit 1. (The earlier comment claimed "bit 0 = REG_UPDATE" — that
     * was wrong; bit 0 is SW. Caused this latent bug to go undetected.) */
    Xil_Out32(base + 0x00,
              0x01             /* SW core enable                 */
            | 0x02             /* RU register-update enable      */
            | 0x04             /* GE generator enable            */
            | 0x07F7EF00);     /* source-select bits (all-from-gen) */

    return XST_SUCCESS;
}

int main(void)
{
    XAxiVdma_Config *vdma_cfg;
    UINTPTR          s2mm_frame_addrs[NUM_FRAMES];
    UINTPTR          mm2s_frame_addrs[NUM_FRAMES];
    int              i;
    int              status;

    xil_printf("\r\n=== Schindler 2.0 — Phase B.1 ===\r\n");
    xil_printf("VDMA + VTC bare-metal init\r\n");

    /* Phase E1.7 (2026-05-19): drain any typeahead garbage from the UART RX
     * FIFO before the main loop starts processing commands. Without this,
     * stale bytes from the host's send buffer (left over from previous JTAG
     * sessions or terminal experiments) fire commands at boot — most
     * dangerously a 'c' or 'C' triggering cmd_capture, which (pre-E1.7)
     * could spin forever waiting for ref edges. */
    while (XUartPs_IsReceiveData(UART_BASEADDR)) {
        (void)XUartPs_ReadReg(UART_BASEADDR, XUARTPS_FIFO_OFFSET);
    }

    /* Phase 7: boot with reference selector = SYNC (synthetic ref). This
     * keeps the Phase 6 'L' behavior unchanged — `L` engages a loop that's
     * locking to the Phase 2 divider. Use `r free` to switch to free-run
     * at runtime. */
    g_ref_select = REFSEL_SYNC;
    g_ref_masked = 0;
    refsel_write(g_ref_select, g_ref_masked);

    /* Compute frame addresses in DDR3 (triple buffer).
     *
     * MM2S read addresses are offset +STRIDE bytes so MM2S starts reading at
     * scaler emit row 1 instead of row 0. Reason: scaler_v's first emit row
     * still leaks 1 line of previous-frame bottom-PLUGE content into output's
     * row 0 (iter3i's lbuf_fresh gating reduces this to ~50% intensity but
     * doesn't fully eliminate). Shifting the MM2S window by +1 line hides
     * emit row 0 in the previous buffer's tail.
     *
     * To stop MM2S's TAIL read (now 1 line past the active-data region) from
     * scribbling into the NEXT buffer (which is either being mid-written by
     * S2MM or holds previous-frame content — producing an intermittent
     * flicker line at output row 719), each buffer slot is sized to
     * FRAME_BYTES + STRIDE: the last STRIDE bytes are a GUARD region that's
     * never written by S2MM, pre-filled with black at init. MM2S's tail
     * lands there and outputs a solid-black row instead of stale data. */
    const UINTPTR GUARD_BYTES = STRIDE;
    const UINTPTR SLOT_BYTES  = FRAME_BYTES + GUARD_BYTES;
    for (i = 0; i < NUM_FRAMES; i++) {
        s2mm_frame_addrs[i] = FRAME_BUF_BASE + (UINTPTR)(i * SLOT_BYTES);
        mm2s_frame_addrs[i] = s2mm_frame_addrs[i] + STRIDE;
        /* Pre-fill guard (last STRIDE bytes of slot) with 0 so MM2S's tail
         * row reads as solid black. Done by direct memory writes — cache
         * is disabled below so the writes hit DRAM directly. */
        volatile u8 *guard = (volatile u8 *)(s2mm_frame_addrs[i] + FRAME_BYTES);
        for (int g = 0; g < GUARD_BYTES; g++) guard[g] = 0;
    }
    UINTPTR *frame_addrs = s2mm_frame_addrs;  /* legacy alias for the diag loop */
    xil_printf("Frame buffers: 0x%08lx, 0x%08lx, 0x%08lx (each %d bytes)\r\n",
               (unsigned long)frame_addrs[0],
               (unsigned long)frame_addrs[1],
               (unsigned long)frame_addrs[2],
               FRAME_BYTES);

    /* Caches off in the DDR3 frame-buffer region so the VDMA sees fresh writes
     * without needing flush/invalidate dances. Simplest correct behavior for
     * Phase B.1; future phases that touch frames from the PS will revisit. */
    Xil_DCacheDisable();

    /* The video pipeline (VDMA AXIS sides + video adapters + VTC) runs on the
     * RX-recovered PixelClk from dvi2rgb. If we try to init the VDMA before
     * PixelClk is stable, the IP's reset state machine stalls waiting for
     * its AXIS clock domain to acknowledge reset → driver times out.
     *
     * Phase D iter-3: instead of a blind sleep(5), poll the AXI GPIO that
     * exposes dvi2rgb's pLocked and vid_pVSync (2-FF synced into FCLK_CLK0
     * domain). Wait for pLocked to be stable for ≥100 ms, then wait for the
     * NEXT rising edge of source vsync, then immediately run vtc_setup_720p.
     * The CTL register write at the end of vtc_setup_720p is what triggers
     * the generator's first frame; landing it within microseconds of source
     * vsync gives per-boot deterministic alignment. */
    xil_printf("Waiting for dvi2rgb lock + source vsync alignment...\r\n");
    if (wait_for_aligned_source_vsync() != XST_SUCCESS) return -1;

    /* CRITICAL: NO printfs between wait_for_aligned_source_vsync and the CTL
     * register write inside vtc_setup_720p. UART at 115200 baud is ~87 µs/char,
     * and source vsync is only HIGH for ~74 µs per frame. Any inter-line print
     * here would push the CTL write past the vsync window into a random phase.
     *
     * (Empirically the firmware-to-CTL latency does not shift the displayed
     * picture because alignment is driven by VDMA frame-buffer timing rather
     * than VTC vsync_out phase. The top-of-frame artifact iter3e showed is
     * actually scaler_v.v's cosmetic warmup — 3 rows of mixed previous-frame
     * data because the V-filter's tap rotation reads from BRAM lbufs that
     * haven't yet been refreshed with the new frame. A future HDL fix should
     * tackle this WITHOUT the iter3g-style conditional m_axis_tdata mux,
     * which mysteriously corrupted the B channel in synthesis.) */

    /* --- VTC first --- so fsync_out is pulsing when VDMA inits (its reset
     * state machine waits for fsync activity with c_use_mm2s_fsync=1).
     *
     * iter-4d-3-FRC-test: select 720p50 to drive Dynamic Master's down-FRC
     * skip behavior. Source stays 60p (ImagePro RGB), output is 50p, ratio
     * 6:5 means master drops one source frame every 6 to keep ahead of slave.
     * Switch to MODE_720P60 to revert. */
    if (vtc_setup(&MODE_720P50) != XST_SUCCESS) return -1;
    xil_printf("VTC aligned to source vsync\r\n");
    sleep(1);  /* give VTC time to start pulsing fsync before VDMA reset */

    /* --- VDMA ------------------------------------------------------------- */
    vdma_cfg = XAxiVdma_LookupConfig(XPAR_AXI_VDMA_0_DEVICE_ID);
    if (!vdma_cfg) {
        xil_printf("VDMA LookupConfig failed\r\n");
        return XST_FAILURE;
    }
    status = XAxiVdma_CfgInitialize(&vdma, vdma_cfg, vdma_cfg->BaseAddress);
    if (status != XST_SUCCESS) {
        xil_printf("VDMA CfgInitialize failed: %d\r\n", status);
        return status;
    }

    if (vdma_setup_channel(XAXIVDMA_WRITE, s2mm_frame_addrs) != XST_SUCCESS) return -1;
    if (vdma_setup_channel(XAXIVDMA_READ,  mm2s_frame_addrs) != XST_SUCCESS) return -1;

    xil_printf("VDMA running — S2MM + MM2S enabled, 3-frame ring\r\n");

    xil_printf("Pipeline live — entering diag loop (1 sec/dump)\r\n\r\n");

    /* Diagnostic loop: dump VDMA + VTC state + first bytes of frame buffer 0
     * every second. Goal: see whether S2MM is actually writing real pixel
     * data, whether MM2S is reading continuously, and whether either channel
     * is reporting AXIS framing errors. */
    UINTPTR vdma_base = XPAR_AXI_VDMA_0_BASEADDR;

    /* Phase D iter-4d-3 step 1 — telemetry-only. PARK loop removed; MM2S is
     * in circular mode under genlock-slave control (FrameDelay=1). The loop
     * just reports source/output edge counts and the IP's own RD/WR frame
     * stores so we can see whether genlock is doing the right thing without
     * any firmware help. Returns on source loss; outer while(1) re-engages. */
    while (1) {
        telemetry_loop(vdma_base);
    }

    return 0;
}
