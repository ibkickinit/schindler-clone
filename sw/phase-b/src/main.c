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

// iter5-1080p-clean 720p re-validation (2026-05-17 evening): 1080p60 source
// scaled to 720p60 output (matched rate). Build with SCALER_MODULE=scaler_top
// env var. Tests row 2 of format-support-matrix on the production substrate
// (NUM_FRAMES=5, no iter4h additions).
#define FRAME_W           1280
#define FRAME_H           720
/* AXIS data width on the VDMA is 24-bit (RGB888, one pixel-per-clock with no
 * padding). Memory stride must therefore be 3 bytes/pixel, NOT 4 — using 4
 * was the actual reason v_axi4s_vid_out couldn't lock and S2MM was reporting
 * EOLEarly/EOLLate framing errors. Confirmed via UART diag dumps. */
#define BYTES_PP          3
#define STRIDE            (FRAME_W * BYTES_PP)
#define FRAME_BYTES       (STRIDE * FRAME_H)
/* iter5-bisect-720p: NUM_FRAMES 5 → 3 to isolate scroll cause. Bisect shows
 * 5 framestores is the only iter5 substrate change vs. clean iter4h; revert
 * to 3 to confirm. BD config c_num_fstores must also match (3 in TCL). */
/* iter5-1080p-clean: NUM_FRAMES 3 → 5 to give S2MM enough cycle headroom
 * to not lap MM2S during its 41.7 ms read window at 24p output. 5 × 16.7
 * = 83 ms cycle time vs. MM2S 41.7 ms read = 2× headroom. Addresses the
 * FRC tear-line-that-drifts symptom. BD c_num_fstores must match. */
#define NUM_FRAMES        5
#define FRAME_BUF_BASE    0x10000000U

static XAxiVdma vdma;
static XVtc    vtc;

static int vdma_setup_channel(int direction, UINTPTR *frame_addrs)
{
    XAxiVdma_DmaSetup cfg;
    int status;

    /* iter5-bisect FINAL (2026-05-17 evening): both channels VSIZE = FRAME_H.
     * Pure iter4d-3 substrate. Production-clean visually at matched rate
     * with laptop source. Bottom-bars artifact (if it reappears with other
     * sources) will need a non-over-allocate fix. */
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
    /* MM2S follows S2MM by 1 frame in Dynamic Genlock (the standard pairing).
     * Note: per iter4h FrameDelay observation, this register reads-as-zero
     * in our IP config — the value is set per spec but Xilinx's IP locks the
     * bits. We keep the assignment for documentation / matching reference
     * designs. See memory: xilinx-vdma-dmasr-bits + schindler-bottom-bars-artifact. */
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
#  error "AXI GPIO 0 base address not found in xparameters.h"
#endif

/* iter4e: AXI GPIO 1 — 32-bit output, drives scaler runtime IN_W/IN_H.
 *   bits [15:0]  = IN_W
 *   bits [31:16] = IN_H
 * Written once at startup after VTC detector reports DASIZE. */
#if defined(XPAR_AXI_GPIO_1_BASEADDR)
#  define SCALER_DIMS_GPIO_BASEADDR XPAR_AXI_GPIO_1_BASEADDR
#elif defined(XPAR_AXI_GPIO_1_S_AXI_BASEADDR)
#  define SCALER_DIMS_GPIO_BASEADDR XPAR_AXI_GPIO_1_S_AXI_BASEADDR
#elif defined(XPAR_PHASE_B_BD_AXI_GPIO_1_BASEADDR)
#  define SCALER_DIMS_GPIO_BASEADDR XPAR_PHASE_B_BD_AXI_GPIO_1_BASEADDR
#else
#  error "AXI GPIO 1 (scaler dims) base address not found in xparameters.h"
#endif

/* Color AXI GPIO 3 — dual-channel output, drives the color pipeline.
 *   Channel 1: [31:24]=saturation, [23:16]=black_b, [15:8]=black_g, [7:0]=black_r
 *   Channel 2: [31:24]=spare,      [23:16]=white_b, [15:8]=white_g, [7:0]=white_r
 * Saturation factor: 0 = grayscale, 255 ≈ identity (~0.4% error). */
#if defined(XPAR_AXI_GPIO_3_BASEADDR)
#  define COLOR_GPIO_BASEADDR XPAR_AXI_GPIO_3_BASEADDR
#elif defined(XPAR_AXI_GPIO_3_S_AXI_BASEADDR)
#  define COLOR_GPIO_BASEADDR XPAR_AXI_GPIO_3_S_AXI_BASEADDR
#elif defined(XPAR_PHASE_B_BD_AXI_GPIO_3_BASEADDR)
#  define COLOR_GPIO_BASEADDR XPAR_PHASE_B_BD_AXI_GPIO_3_BASEADDR
#else
#  error "AXI GPIO 3 (color correct) base address not found in xparameters.h"
#endif

/* Single combined writer for the full color pipeline state.
 *   sat:    0=grayscale, 255≈identity (color_saturation Rec.601 mix).
 *   black_*: per-channel offset (RGB code for "black"). 0 = true black.
 *   white_*: per-channel scale ceiling (RGB code for "white"). 255 = full white.
 * color_saturation runs first, then color_correct (black/white diagonal). */
static inline void color_set(u8 sat,
                             u8 black_r, u8 black_g, u8 black_b,
                             u8 white_r, u8 white_g, u8 white_b)
{
    u32 ch1 = ((u32)sat     << 24) | ((u32)black_b << 16) |
              ((u32)black_g <<  8) | (u32)black_r;
    u32 ch2 = ((u32)white_b << 16) | ((u32)white_g << 8) | (u32)white_r;
    Xil_Out32(COLOR_GPIO_BASEADDR + 0x00, ch1);  /* ch1 data */
    Xil_Out32(COLOR_GPIO_BASEADDR + 0x08, ch2);  /* ch2 data */
    xil_printf("COLOR: sat=%u  black=(%u,%u,%u)  white=(%u,%u,%u)\r\n",
               sat, black_r, black_g, black_b, white_r, white_g, white_b);
}

/* iter4g: AXI GPIO 2 — dual-channel input, exposes per-frame counter
 * snapshots from scaler_top (CDC'd to FCLK_CLK0 via axi_sync_inputs).
 *   GPIO  data1 reg (offset 0x00):
 *     [15:0]  = scaler_h input TLAST count per source frame
 *                (= v_vid_in_axi4s output TLAST count = source rows in)
 *     [31:16] = scaler_v input TLAST count per source frame
 *                (= scaler_h output TLAST count)
 *   GPIO2 data2 reg (offset 0x08):
 *     [15:0]  = scaler_v emit (v_cross) count per source frame
 *                (= scaler_top output TLAST count = rows delivered to S2MM)
 *
 * For a clean 1920x1080 source with scaler_top (production): expect 1080,
 * 1080, 720. With iter5 scaler_bypass_1080p: expect 0, 0, 0 (bypass ties
 * diag_counts to zero). Use mm2s pixel counter + DMASR bits instead. */
#if defined(XPAR_AXI_GPIO_2_BASEADDR)
#  define DIAG_GPIO_BASEADDR XPAR_AXI_GPIO_2_BASEADDR
#elif defined(XPAR_AXI_GPIO_2_S_AXI_BASEADDR)
#  define DIAG_GPIO_BASEADDR XPAR_AXI_GPIO_2_S_AXI_BASEADDR
#elif defined(XPAR_PHASE_B_BD_AXI_GPIO_2_BASEADDR)
#  define DIAG_GPIO_BASEADDR XPAR_PHASE_B_BD_AXI_GPIO_2_BASEADDR
#else
#  error "AXI GPIO 2 (diag counters) base address not found in xparameters.h"
#endif

static inline void diag_counters_read(u16 *h_in, u16 *v_in, u16 *v_emit, u16 *mm2s_tlast)
{
    u32 ch1 = Xil_In32(DIAG_GPIO_BASEADDR + 0x00);
    u32 ch2 = Xil_In32(DIAG_GPIO_BASEADDR + 0x08);
    if (h_in)       *h_in       = (u16)(ch1 & 0xFFFFu);
    if (v_in)       *v_in       = (u16)((ch1 >> 16) & 0xFFFFu);
    if (v_emit)     *v_emit     = (u16)(ch2 & 0xFFFFu);
    if (mm2s_tlast) *mm2s_tlast = (u16)((ch2 >> 16) & 0xFFFFu);
}

/* iter4e: v_tc_rx detector. Per PG016 register map:
 *   0x000 CTL    bit0=SW, bit1=RU, bit3=DE (Detector Enable)
 *   0x020 DASIZE bits[13:0]=HACTIVE, bits[29:16]=VACTIVE
 *   0x024 DTSTAT bit0=LOCKED
 *   0x02C DPOL   bit0=VBP, 1=HBP, 2=VSP, 3=HSP, 4=AVP, 5=ACP, 6=FIP
 *   0x030 DHSIZE detected H total
 *   0x034 DVSIZE detected V total */
#if defined(XPAR_V_TC_1_BASEADDR)
#  define VTC_RX_BASEADDR XPAR_V_TC_1_BASEADDR
#elif defined(XPAR_PHASE_B_BD_V_TC_RX_BASEADDR)
#  define VTC_RX_BASEADDR XPAR_PHASE_B_BD_V_TC_RX_BASEADDR
#elif defined(XPAR_V_TC_RX_BASEADDR)
#  define VTC_RX_BASEADDR XPAR_V_TC_RX_BASEADDR
#else
#  error "VTC RX (detector) base address not found in xparameters.h"
#endif

static inline u32 vsync_gpio_read(void)
{
    return Xil_In32(VSYNC_GPIO_BASEADDR);
}

/* Write 32-bit value to scaler dims GPIO. AXI GPIO data register is at
 * offset 0x00 from the IP base. */
static inline void scaler_dims_write(u32 in_w, u32 in_h)
{
    u32 v = ((in_h & 0xFFFFu) << 16) | (in_w & 0xFFFFu);
    Xil_Out32(SCALER_DIMS_GPIO_BASEADDR + 0x00, v);
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
    int prev    = !!(vsync_gpio_read() & VSYNC_GPIO_VSYNC_MASK);
    int edges   = 0;
    int timeout = 200000000;  /* ~few seconds at PS clock */
    XTime t_start, t_end;
    XTime_GetTime(&t_start);
    while (edges < target_edges) {
        u32 g = vsync_gpio_read();
        if (!(g & VSYNC_GPIO_PLOCKED_MASK)) return 0;  /* source dropped */
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
/* iter4h debug (2026-05-16): dump raw DDR3 bytes from a frame buffer slot to
 * verify what S2MM actually wrote. Cache is already disabled in DDR3 region
 * (Xil_DCacheDisable at top of main), so reads here are coherent with VDMA.
 *
 * Slot N base = FRAME_BUF_BASE + N * (FRAME_BYTES + GUARD_BYTES). For the
 * bottom-bars-artifact debug, dump slot 0 rows 690..720 (the artifact zone +
 * guard row) and slot 1 rows 0..8 (the "if frame N+1 leaked, this is what
 * we'd see in slot 0's tail" reference). */
static void dump_slot_bytes(u32 slot_idx, u32 row_start, u32 row_end)
{
    /* iter4h Path 2: slot stride matches new firmware layout = S2MM 747 active rows + 1 guard row. */
    const u32 S2MM_DATA_BYTES = (FRAME_H + 27) * STRIDE;
    const u32 SLOT_STRIDE_BYTES = S2MM_DATA_BYTES + STRIDE;
    volatile u8 *slot = (volatile u8 *)(FRAME_BUF_BASE + slot_idx * SLOT_STRIDE_BYTES);
    xil_printf("\r\nDDR3 DUMP: slot=%u rows=%u..%u  base=0x%08x\r\n",
               (unsigned)slot_idx, (unsigned)row_start, (unsigned)row_end,
               (unsigned)(FRAME_BUF_BASE + slot_idx * SLOT_STRIDE_BYTES));
    /* Sample 6 cols spaced across the active 1920 px width — one within each
     * of the first 6 SMPTE bars (~274 px / bar at 1080p). This distinguishes
     * "top of color bars" (each col = its own bar's color) from "PLUGE area"
     * (uniform gray-ish across cols) from "reverse bars" (different per-col
     * colors). iter5 widened from 1280→1920 columns. */
    static const u32 SAMPLE_COLS[6] = { 100, 400, 700, 1000, 1300, 1600 };
    for (u32 row = row_start; row <= row_end; row++) {
        u32 row_base = row * STRIDE;
        xil_printf("  row %3u  ", (unsigned)row);
        for (u32 i = 0; i < 6; i++) {
            u32 col = SAMPLE_COLS[i];
            u32 a = row_base + col * 3;
            xil_printf("col%4u=%02x%02x%02x  ", (unsigned)col,
                       (unsigned)slot[a + 0], (unsigned)slot[a + 1], (unsigned)slot[a + 2]);
        }
        xil_printf("\r\n");
    }
}

static void telemetry_loop(UINTPTR vdma_base)
{
    (void)vdma_base;
    int did_ddr_dump = 0;     /* iter4h: dump DDR3 once after steady state */

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

    /* Phase tracking telemetry (iter5 step 4, 2026-05-17 evening): on each
     * output vsync edge, capture the current cumulative source vsync count.
     * Deltas between consecutive captures = which source frames each output
     * frame represents. At 5:2 cadence (60→24), expected delta pattern is
     * 2,3,2,3,2,3,... (alternating); at 2:1 (60→30), expected 2,2,2,...
     * Ring is dumped every status_every output frames just before the
     * normal DIAG line. */
    #define PHASE_RING_LEN 12
    int phase_ring[PHASE_RING_LEN];
    int phase_ring_idx = 0;
    int phase_last_src = 0;

    while (1) {
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
            /* Phase tracking: capture source-frame delta since last output vsync. */
            int delta = src_count - phase_last_src;
            phase_last_src = src_count;
            phase_ring[phase_ring_idx] = delta;
            phase_ring_idx = (phase_ring_idx + 1) % PHASE_RING_LEN;
            if (out_count >= status_every) {
                u32 park = Xil_In32(vdma_base + 0x28);
                int rdstore = (int)((park >> 16) & 0x1F);
                int wrstore = (int)((park >> 24) & 0x1F);
                u16 h_in, v_in, v_emit, mm2s;
                diag_counters_read(&h_in, &v_in, &v_emit, &mm2s);
                u32 s2mm_sr = Xil_In32(vdma_base + 0x34);
                u32 mm2s_sr = Xil_In32(vdma_base + 0x04);
                /* iter4g: clear error bits (W1C) so next interval's read
                 * tells us if errors are CURRENT (re-asserted) vs SLOW
                 * boot-transient (sticky). Bits 4-12 are W1C error flags;
                 * bits 13-15 are IRQ flags; mask: 0xFFFF (clear all those). */
                Xil_Out32(vdma_base + 0x34, s2mm_sr & 0x0000F000u);  /* W1C errors */
                Xil_Out32(vdma_base + 0x04, mm2s_sr & 0x0000F000u);  /* W1C errors */
                /* IRQFrameCount field (bits 23:16) — track increments. */
                u32 s2mm_frmcnt = (s2mm_sr >> 16) & 0xFFu;
                u32 mm2s_frmcnt = (mm2s_sr >> 16) & 0xFFu;
                /* iter5 step1 EOLEarly debug: counter slots repurposed in
                 * scaler_bypass_1080p — h_in = px-per-line, v_in = lines-per-
                 * frame, v_emit = max px-per-line observed. mm2s unchanged
                 * (output-side TLAST count from axis_to_vid_io). Clean 1080p
                 * source should show px=1920 lines=1080 maxpx=1920. */
                xil_printf("DIAG: px=%u lines=%u maxpx=%u mm2s=%u  "
                           "S2MM_SR=0x%08x[%s%s%s%s%s frmcnt=%u] "
                           "MM2S_SR=0x%08x[%s%s%s%s%s frmcnt=%u]  "
                           "RDSTORE=%d WRSTORE=%d  src=%d out=%d\r\n",
                           (unsigned)h_in, (unsigned)v_in, (unsigned)v_emit, (unsigned)mm2s,
                           /* iter4h relabel: bit 12 is FrmCnt_Irq (benign), bit 15 is real EOLLate */
                           (unsigned)s2mm_sr,
                           (s2mm_sr & 0x80)   ? "SOFEarly " : "",
                           (s2mm_sr & 0x100)  ? "EOLEarly " : "",
                           (s2mm_sr & 0x800)  ? "SOFLate " : "",
                           (s2mm_sr & 0x1000) ? "FrmCnt " : "",     /* benign per PG020 */
                           (s2mm_sr & 0x8000) ? "EOLLate " : "",    /* real EOLLate is bit 15 */
                           (unsigned)s2mm_frmcnt,
                           (unsigned)mm2s_sr,
                           (mm2s_sr & 0x80)   ? "SOFEarly " : "",
                           (mm2s_sr & 0x100)  ? "EOLEarly " : "",
                           (mm2s_sr & 0x800)  ? "SOFLate " : "",
                           (mm2s_sr & 0x1000) ? "FrmCnt " : "",
                           (mm2s_sr & 0x8000) ? "EOLLate " : "",
                           (unsigned)mm2s_frmcnt,
                           rdstore, wrstore, src_count, out_count);
                /* Phase tracking dump — recent per-output-frame source-frame
                 * deltas. Start from oldest entry (right after the last write
                 * position) so the sequence reads left-to-right in time. */
                xil_printf("PHASE: deltas[%d]={", PHASE_RING_LEN);
                for (int i = 0; i < PHASE_RING_LEN; i++) {
                    int idx = (phase_ring_idx + i) % PHASE_RING_LEN;
                    xil_printf("%d%s", phase_ring[idx],
                               (i == PHASE_RING_LEN - 1) ? "" : ",");
                }
                xil_printf("}\r\n");
                src_count = 0;
                out_count = 0;
                phase_last_src = 0;

                /* iter5: one-shot DDR3 dump after the first DIAG print so
                 * pipeline has hit steady state. Frame layout scales with
                 * FRAME_H (1080 here). Same iter4h +27 over-allocate pattern:
                 *  - slot 0 rows 1050..1080 (MM2S read range tail — should be
                 *    correct PLUGE / frame N data)
                 *  - slot 0 rows 1080..1107 (S2MM spillover — should stay zero
                 *    if VSIZE over-allocate has same fix effect at 1080p)
                 *  - slot 1 rows 0..8 (reference for frame N+1's top). */
                if (!did_ddr_dump) {
                    dump_slot_bytes(0, FRAME_H - 30, FRAME_H);
                    dump_slot_bytes(0, FRAME_H,      FRAME_H + 27);
                    dump_slot_bytes(1, 0, 8);
                    did_ddr_dump = 1;
                }
            }
        }
        src_prev = src_cur;
        out_prev = out_cur;
    }
}

/* iter4e: enable v_tc_rx detector + wait for LOCK + read source dimensions.
 * Returns XST_SUCCESS with HACTIVE/VACTIVE filled in on success; XST_FAILURE
 * on timeout. Caller writes detected dims into scaler via scaler_dims_write. */
static int vtc_detector_read(u32 *hactive_out, u32 *vactive_out,
                             u32 *htotal_out, u32 *vtotal_out)
{
    /* Wait for dvi2rgb pLocked first — v_tc_rx's clk is dvi2rgb's PixelClk,
     * which only runs when source is locked. Without this, the detector's
     * AXI-Lite reads would happen before its core clock has any cycles.
     * Reuse the AXI GPIO 0 pLocked sync bit (already wired up in iter-3e). */
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
            xil_printf("ERROR: pLocked never stable for 100ms (boot timeout)\r\n");
            return XST_FAILURE;
        }
    }
    xil_printf("VTC_RX: dvi2rgb pLocked stable, enabling detector\r\n");

    /* Enable detector (CTL.DE = bit 3) along with SW (bit 0) and RU (bit 1).
     * RU is required for any shadow→active register propagation, just like
     * the generator side (see xilinx_vtc_register_update memory). */
    Xil_Out32(VTC_RX_BASEADDR + 0x00, 0x01u | 0x02u | 0x08u);

    /* Poll DTSTAT.LOCKED. Source video is 60p so DTSTAT settles within
     * ~3-5 frames (50-100 ms). Wait up to 5 seconds — VTC detector may
     * need more frames to converge if source has noisy sync. */
    total_ms = 0;
    while ((Xil_In32(VTC_RX_BASEADDR + 0x024) & 0x01u) == 0) {
        usleep(1000);
        if (++total_ms > 5000) {
            xil_printf("ERROR: v_tc_rx never reported LOCKED after 5s\r\n");
            xil_printf("  DTSTAT=0x%08x DASIZE=0x%08x DPOL=0x%08x\r\n",
                       (unsigned)Xil_In32(VTC_RX_BASEADDR + 0x024),
                       (unsigned)Xil_In32(VTC_RX_BASEADDR + 0x020),
                       (unsigned)Xil_In32(VTC_RX_BASEADDR + 0x02C));
            return XST_FAILURE;
        }
    }
    /* Require LOCKED stable for an additional 50 ms (3+ frames at 60p) so
     * DASIZE has settled to the actual source values, not transient noise.
     * NOW WITH TIMEOUT (2026-05-17): if source vsync is flickering, this
     * loop used to spin forever. Cap at 2 seconds and proceed with whatever
     * DASIZE has — caller defaults to 1920×1080 if values look wrong. */
    int lock_stable_ms = 0;
    int stability_total_ms = 0;
    while (lock_stable_ms < 50) {
        if (Xil_In32(VTC_RX_BASEADDR + 0x024) & 0x01u) lock_stable_ms++;
        else lock_stable_ms = 0;
        usleep(1000);
        if (++stability_total_ms > 2000) {
            xil_printf("WARN: v_tc_rx LOCKED unstable (flickering source); proceeding anyway\r\n");
            break;
        }
    }

    u32 dasize = Xil_In32(VTC_RX_BASEADDR + 0x020);
    u32 dvsize = Xil_In32(VTC_RX_BASEADDR + 0x034);
    u32 dhsize = Xil_In32(VTC_RX_BASEADDR + 0x030);
    u32 dpol   = Xil_In32(VTC_RX_BASEADDR + 0x02C);

    u32 hactive = dasize & 0x3FFFu;
    u32 vactive = (dasize >> 16) & 0x3FFFu;
    u32 htotal  = dhsize & 0x3FFFu;
    u32 vtotal  = dvsize & 0x3FFFu;

    xil_printf("\r\nVTC_RX: HACTIVE=%u VACTIVE=%u HTOTAL=%u VTOTAL=%u DPOL=0x%02x\r\n",
               (unsigned)hactive, (unsigned)vactive,
               (unsigned)htotal,  (unsigned)vtotal, (unsigned)(dpol & 0x7Fu));

    if (hactive_out) *hactive_out = hactive;
    if (vactive_out) *vactive_out = vactive;
    if (htotal_out)  *htotal_out  = htotal;
    if (vtotal_out)  *vtotal_out  = vtotal;

    /* Sanity-check ranges so we don't drive garbage into the scaler if the
     * detector spuriously reports zero or oversized values. Reject anything
     * outside reasonable HD source bounds. */
    if (hactive < 320 || hactive > 4096 ||
        vactive < 200 || vactive > 2160) {
        xil_printf("ERROR: detected dimensions out of sane range\r\n");
        return XST_FAILURE;
    }
    return XST_SUCCESS;
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
/* iter5: 1080p24 reduced-blanking at 74.25 MHz pixel clock (CEA-861 mode 32).
 *   2750 H × 1125 V × 24 Hz = 74.25 MHz — matches our existing clk_wiz output,
 *   so NO clk_wiz reconfig needed vs. the 720p60 substrate. Only VTC TX
 *   timings change. HSync/VSync polarity POSITIVE per CEA-861. */
static const vtc_mode_t MODE_1080P24 = {
    "1080p24", 1920, 1080, 2750, 1125,  638, 44,  4, 5
};
/* iter5 step 1 debug: 1080p30 (CEA-861 mode 34). 2200 × 1125 × 30 = 74.25 MHz
 * — same clk_wiz output as 1080p24 and 720p60, no BD reconfig. Source 60p →
 * output 30p is a clean 2:1 drop-every-other-frame ratio. If scroll is FRC-
 * cadence-related (5:2 at 1080p24), 2:1 should be cleaner. If scroll persists
 * here, it's deeper than cadence. */
static const vtc_mode_t MODE_1080P30 = {
    "1080p30", 1920, 1080, 2200, 1125,  88, 44,  4, 5
};
/* 1080p25 (CEA-861 mode 33). 2640 × 1125 × 25 = 74.25 MHz — same clk_wiz
 * output as 1080p24/p30, no clock reconfig. Used to test the 12:5 "ugly"
 * FRC ratio from 60p source. */
static const vtc_mode_t MODE_1080P25 = {
    "1080p25", 1920, 1080, 2640, 1125,  528, 44,  4, 5
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
    /* iter4e: explicitly use V_TC_TX address. Adding the v_tc_rx detector
     * caused XPAR_VTC_0_BASEADDR to alias to v_tc_rx (detector), not v_tc_tx
     * (generator) — programming the detector with generator timing was
     * silently ignored, leaving v_tc_tx unconfigured = no HDMI sync = MS2109
     * fallback bars. */
#if defined(XPAR_V_TC_TX_BASEADDR)
    UINTPTR base = XPAR_V_TC_TX_BASEADDR;
#elif defined(XPAR_V_TC_1_BASEADDR)
    UINTPTR base = XPAR_V_TC_1_BASEADDR;
#else
#  error "v_tc_tx base address not found in xparameters.h"
#endif
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
    /* iter3i MM2S +STRIDE shift RESTORED (2026-05-17 evening): bench at 720p
     * with scaler_top shows the row-0 leak still exists (one line of previous-
     * frame bottom visible at top of displayed frame). Earlier bisect (Option B)
     * tested without scaler_top engaged — bypass module doesn't have the
     * leak. With scaler_top, the shift is still needed. Pre-iter4h pattern. */
    const UINTPTR GUARD_BYTES = STRIDE;
    const UINTPTR SLOT_BYTES  = FRAME_BYTES + GUARD_BYTES;
    for (i = 0; i < NUM_FRAMES; i++) {
        s2mm_frame_addrs[i] = FRAME_BUF_BASE + (UINTPTR)(i * SLOT_BYTES);
        mm2s_frame_addrs[i] = s2mm_frame_addrs[i] + STRIDE;
        volatile u8 *guard = (volatile u8 *)(s2mm_frame_addrs[i] + FRAME_BYTES);
        for (UINTPTR g = 0; g < GUARD_BYTES; g++) guard[g] = 0;
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
    /* iter4e: read source dimensions from v_tc_rx detector FIRST and program
     * scaler runtime IN_W/IN_H via axi_gpio_1 before we engage the vsync
     * alignment path. The detector takes ~50-100 ms to lock + settle, so it
     * MUST run before the source-vsync edge wait (otherwise the alignment
     * window we found would be invalidated by the detector wait).
     *
     * The vtc_detector_read function also requires pLocked; it polls for
     * detector LOCKED which implies pLocked + stable timing. So this
     * subsumes the initial pLocked wait. */
    xil_printf("Waiting for dvi2rgb lock + reading source dimensions...\r\n");
    u32 src_hactive = 1920, src_vactive = 1080;  /* fallback defaults */
    u32 src_htotal = 0, src_vtotal = 0;
    if (vtc_detector_read(&src_hactive, &src_vactive,
                          &src_htotal, &src_vtotal) != XST_SUCCESS) {
        xil_printf("WARN: detector failed, using defaults 1920x1080\r\n");
    }
    /* DIAG: read GPIO initial value to verify C_DOUT_DEFAULT applied at boot. */
    u32 gpio_initial = Xil_In32(SCALER_DIMS_GPIO_BASEADDR + 0x00);
    xil_printf("SCALER GPIO initial value: 0x%08x (expect 0x04380780 = 1920x1080)\r\n",
               (unsigned)gpio_initial);
    scaler_dims_write(src_hactive, src_vactive);
    xil_printf("SCALER: programmed IN_W=%u IN_H=%u\r\n",
               (unsigned)src_hactive, (unsigned)src_vactive);

    /* NOW align VTC generator CTL write to the next source vsync edge.
     * Detector activity above is complete; remaining latency is just the
     * vsync-edge spin in wait_for_aligned_source_vsync. */
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
    /* 720p re-validation (2026-05-17): 1080p60 source → 720p60 output on
     * production substrate (NUM_FRAMES=5, post-bisect). Matched rate, no
     * FRC. Expected PHASE deltas all 1 (every source frame consumed). */
    if (vtc_setup(&MODE_720P60) != XST_SUCCESS) return -1;
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

    xil_printf("VDMA running — S2MM + MM2S enabled, %d-frame ring\r\n", NUM_FRAMES);

    /* iter4g DIAG: correct PG020 register offsets:
     *   MM2S: VSIZE@0x50, HSIZE@0x54, FRMDLY_STRIDE@0x58
     *   S2MM: VSIZE@0x80, HSIZE@0x84, FRMDLY_STRIDE@0x88 (= +0x30 offset)
     * Expected for iter5 1920x1080 in/out, scaler bypassed:
     *   MM2S_VSIZE = 1080  (0x438), MM2S_HSIZE = 5760 bytes (0x1680)
     *   S2MM_VSIZE = 1107  (0x453), S2MM_HSIZE = 5760 bytes (0x1680)
     *                 (iter4h Path 2: S2MM over-allocate FRAME_H + 27) */
    UINTPTR vbase = XPAR_AXI_VDMA_0_BASEADDR;
    /* iter4g DIAG: dump every 4-byte register in 0x00..0xFC to map the
     * actual VDMA register layout for this IP version. Skip zero values
     * to compress output. */
    xil_printf("VDMA regs dump (non-zero) base=0x%08x:\r\n", (unsigned)vbase);
    for (int off = 0; off < 0x100; off += 4) {
        u32 v = Xil_In32(vbase + off);
        if (v != 0) xil_printf("  +0x%02x = 0x%08x  (%u)\r\n", off, (unsigned)v, (unsigned)v);
    }

    /* Color correction demo — strong amber tint so the user can see at a
     * glance that the color_correct block is active and routed correctly.
     * Identity preset would be color_set(0,0,0, 255,255,255). To dial in
     * NEUTRAL white once you've confirmed routing, change to that. */
    /* Demo: 12.5% saturation — colors should be very pastel / near-gray. */
    color_set(32,  0, 0, 0,    255, 255, 255);

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
