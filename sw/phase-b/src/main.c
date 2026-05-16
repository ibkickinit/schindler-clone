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
    cfg.FrameDelay        = 0;
    cfg.EnableCircularBuf = 1;
    cfg.EnableSync        = 0;
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
#define VSYNC_GPIO_PLOCKED_MASK  0x1
#define VSYNC_GPIO_VSYNC_MASK    0x2

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

static int vtc_setup_720p(void)
{
    /* Direct register writes to the VTC. We bypass the Xilinx XVtc driver here
     * because its XVtc_SetGenerator implementation does an internal GFENC
     * read-modify-write and writes that have caused Data Aborts on this config.
     *
     * 1280x720p60 CEA-861 timing (720p, pivot target from 480p):
     *   HActive=1280, HFront=110, HSync=40, HBack=220 → HTotal=1650
     *   VActive=720,  VFront=5,   VSync=5,  VBack=20  → VTotal=750
     *   Pixel clock = 74.25 MHz (clk_wiz_pixclk_out outputs ~74.25 MHz).
     *   HSync + VSync polarity: POSITIVE per CEA-861 720p spec.
     */
    UINTPTR base = XPAR_VTC_0_BASEADDR;
    const u32 H_ACTIVE = 1280, V_ACTIVE = 720;
    const u32 H_TOTAL  = 1650, V_TOTAL  = 750;
    const u32 H_SYNC_START   = 1390;          /* 1280 + 110 */
    const u32 H_BACK_START   = 1430;          /* 1390 + 40  */
    const u32 V_SYNC_START   = 725;           /* 720 + 5    */
    const u32 V_BACK_START   = 730;           /* 725 + 5    */

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
     * state machine waits for fsync activity with c_use_mm2s_fsync=1). */
    if (vtc_setup_720p() != XST_SUCCESS) return -1;
    xil_printf("VTC aligned to source vsync, generating 1280x720@60p timing\r\n");
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
    volatile u32 *fb0 = (volatile u32 *)FRAME_BUF_BASE;
    int tick = 0;

    /* Phase D source-event tracking (informational only).
     *
     * Phase D's input-clock-sourced output MMCM means a source
     * disconnect stops both input and output PixelClk. The output-side
     * proc_sys_reset hard-resets VTC, clearing its CTL; VDMA S2MM also
     * appears to get stuck and doesn't auto-resume on replug. Auto-
     * recovery via VTC re-init + S2MM Stop/Start was tried 2026-05-14
     * and DOES NOT WORK — S2MM needs a deeper reset than the standard
     * driver helpers provide, and PARK-based "source dead" detection
     * gave false positives after btn_rst (PARK stuck for unrelated
     * reasons). Picking the hammer back up requires either a BD-side
     * change (route dvi2rgb_0/pLocked to an AXI GPIO so PS can detect
     * source events) or a deeper VDMA reset dance.
     *
     * Until then, recovery from a source disconnect is manual:
     *   xsct tcl/program_phase_b_full.tcl
     * which reloads the ELF and re-inits VTC + VDMA cleanly.
     *
     * The PARK-delta logging here is purely informational — useful in
     * UART for confirming whether S2MM is actively writing frames. */
    u32 prev_park       = Xil_In32(vdma_base + 0x28);
    int src_quiet_ticks = 0;
    int first_tick      = 1;

    while (1) {
        u32 park_now      = Xil_In32(vdma_base + 0x28);
        int s2mm_advanced = (((park_now >> 16) & 0xFF) !=
                             ((prev_park >> 16) & 0xFF));
        prev_park = park_now;
        if (first_tick) { s2mm_advanced = 1; first_tick = 0; }

        if (s2mm_advanced) {
            if (src_quiet_ticks > 0) {
                xil_printf("[t=%ds] ** Source restored — PARK advancing after %d quiet ticks **\r\n",
                           tick, src_quiet_ticks);
            }
            src_quiet_ticks = 0;
        } else {
            src_quiet_ticks++;
            if (src_quiet_ticks == 1) {
                xil_printf("[t=%ds] ** Source quiet (S2MM PARK static) — reload ELF to recover **\r\n", tick);
            }
        }

        u32 mm2s_sr  = Xil_In32(vdma_base + 0x04);   /* MM2S_DMASR */
        u32 s2mm_sr  = Xil_In32(vdma_base + 0x34);   /* S2MM_DMASR */
        u32 mm2s_cr  = Xil_In32(vdma_base + 0x00);   /* MM2S_DMACR */
        u32 s2mm_cr  = Xil_In32(vdma_base + 0x30);   /* S2MM_DMACR */
        /* Park pointers — show which frame buffer each channel is touching */
        u32 park     = Xil_In32(vdma_base + 0x28);   /* PARK_PTR_REG */
        u32 vdmavers = Xil_In32(vdma_base + 0x2C);   /* VDMA_VERSION */

        xil_printf("[t=%ds]\r\n", tick);
        xil_printf("  MM2S CR=%08x SR=%08x   err{slv=%d dec=%d sof_e=%d eol_e=%d sof_l=%d eol_l=%d}\r\n",
                   (unsigned)mm2s_cr, (unsigned)mm2s_sr,
                   (int)((mm2s_sr >> 5) & 1), (int)((mm2s_sr >> 6) & 1),
                   (int)((mm2s_sr >> 7) & 1), (int)((mm2s_sr >> 8) & 1),
                   (int)((mm2s_sr >> 11) & 1), (int)((mm2s_sr >> 12) & 1));
        xil_printf("  S2MM CR=%08x SR=%08x   err{slv=%d dec=%d sof_e=%d eol_e=%d sof_l=%d eol_l=%d}\r\n",
                   (unsigned)s2mm_cr, (unsigned)s2mm_sr,
                   (int)((s2mm_sr >> 5) & 1), (int)((s2mm_sr >> 6) & 1),
                   (int)((s2mm_sr >> 7) & 1), (int)((s2mm_sr >> 8) & 1),
                   (int)((s2mm_sr >> 11) & 1), (int)((s2mm_sr >> 12) & 1));
        xil_printf("  PARK=%08x VERS=%08x\r\n",
                   (unsigned)park, (unsigned)vdmavers);
        /* Frame buffer contents (S2MM should be writing here) */
        xil_printf("  FB0 first 4 pixels: %08x %08x %08x %08x\r\n",
                   (unsigned)fb0[0], (unsigned)fb0[1],
                   (unsigned)fb0[2], (unsigned)fb0[3]);

        /* Phase D iter-4a — passive source rate detection.
         * measure_source_rate_mhz blocks for ~1 second (60 vsync edges) so
         * it both takes the place of the old sleep(1) AND yields useful data
         * each tick. Reports rate in milli-Hz (60000 = 60.000 Hz). */
        u32 rate_mHz = measure_source_rate_mhz(60);
        if (rate_mHz == 0) {
            xil_printf("  SRC RATE: -- (source not locked)\r\n");
        } else {
            xil_printf("  SRC RATE: %u.%03u Hz\r\n",
                       (unsigned)(rate_mHz / 1000), (unsigned)(rate_mHz % 1000));
        }
        xil_printf("\r\n");
        tick++;
    }

    return 0;
}
