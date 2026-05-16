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
