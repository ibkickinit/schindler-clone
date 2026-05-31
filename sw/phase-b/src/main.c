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
/* 2026-05-31: FRAME_W/H parametrized by OUTPUT_1080P compile-time define.
 * Mirrors the tcl/build_phase_b.tcl OUTPUT_MODE env var. The Vitis tcl
 * (tcl/build_phase_b_app.tcl) reads OUTPUT_MODE from the environment and
 * passes -DOUTPUT_1080P=1 to gcc when OUTPUT_MODE is 1080p30 or 1080p60.
 *
 *   No env var set (default)          → 720p60 production substrate
 *   OUTPUT_MODE=720p                  → 720p60 production substrate
 *   OUTPUT_MODE=1080p30               → 1080p30 passthrough (in -1 spec)
 *   OUTPUT_MODE=1080p60               → 1080p60 (dev-board blocked; see
 *                                        zynq7020_rgb2dvi_1080p60_limit) */
#ifdef OUTPUT_1080P
#define FRAME_W           1920
#define FRAME_H           1080
#else
#define FRAME_W           1280
#define FRAME_H           720
#endif
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
 *   sat:    16-bit Q1.15. 0x0000=grayscale, 0x8000=identity, 0xFFFF≈200%.
 *   black_*: per-channel offset (RGB code for "black"). 0 = true black.
 *   white_*: per-channel scale ceiling (RGB code for "white"). 255 = full white.
 * color_saturation runs first, then color_correct (black/white diagonal). */
static inline void color_set(u16 sat,
                             u8 black_r, u8 black_g, u8 black_b,
                             u8 white_r, u8 white_g, u8 white_b)
{
    u8 sat_lo = (u8)(sat & 0xFF);
    u8 sat_hi = (u8)((sat >> 8) & 0xFF);
    u32 ch1 = ((u32)sat_lo   << 24) | ((u32)black_b << 16) |
              ((u32)black_g  <<  8) | (u32)black_r;
    u32 ch2 = ((u32)sat_hi   << 24) | ((u32)white_b << 16) |
              ((u32)white_g  <<  8) | (u32)white_r;
    Xil_Out32(COLOR_GPIO_BASEADDR + 0x00, ch1);
    Xil_Out32(COLOR_GPIO_BASEADDR + 0x08, ch2);
    /* Readback to verify the write reached the register */
    u32 rb1 = Xil_In32(COLOR_GPIO_BASEADDR + 0x00);
    u32 rb2 = Xil_In32(COLOR_GPIO_BASEADDR + 0x08);
    unsigned pct = ((unsigned)sat * 100) >> 15;
    xil_printf("COLOR: sat=0x%04x (%u%%)  black=(%u,%u,%u)  white=(%u,%u,%u)"
               "  base=0x%08x  RB=[%08x,%08x]\r\n",
               (unsigned)sat, pct, black_r, black_g, black_b, white_r, white_g, white_b,
               (unsigned)COLOR_GPIO_BASEADDR, (unsigned)rb1, (unsigned)rb2);
}

/* Convenience: set saturation by percentage (0..200+). Anything above 200
 * is clamped to 0xFFFF (~199.99%). */
static inline u16 color_sat_from_percent(unsigned pct)
{
    if (pct >= 200) return 0xFFFF;
    return (u16)((pct << 15) / 100);
}

/* ============================================================================
 * color_matrix: general 3x3 RGB transform.
 *   out = matrix · in + offset (per channel, clamp to [0,255]).
 * Coefficients are Q2.14 signed (multiply by 16384.0 to convert from float).
 * Offsets are 8-bit signed integers (±127 range; +128 not representable).
 *
 * GPIO 4/5/6 layout (writes to base+0x00 = ch1, base+0x08 = ch2):
 *   GPIO 4 ch1 = (m01<<16) | m00
 *   GPIO 4 ch2 = (m10<<16) | m02
 *   GPIO 5 ch1 = (m12<<16) | m11
 *   GPIO 5 ch2 = (m21<<16) | m20
 *   GPIO 6 ch1 = (spare<<16) | m22
 *   GPIO 6 ch2 = (off_b<<16) | (off_g<<8) | off_r
 * ============================================================================ */
#if defined(XPAR_AXI_GPIO_4_BASEADDR)
#  define MATRIX_GPIO4 XPAR_AXI_GPIO_4_BASEADDR
#  define MATRIX_GPIO5 XPAR_AXI_GPIO_5_BASEADDR
#  define MATRIX_GPIO6 XPAR_AXI_GPIO_6_BASEADDR
#elif defined(XPAR_PHASE_B_BD_AXI_GPIO_4_BASEADDR)
#  define MATRIX_GPIO4 XPAR_PHASE_B_BD_AXI_GPIO_4_BASEADDR
#  define MATRIX_GPIO5 XPAR_PHASE_B_BD_AXI_GPIO_5_BASEADDR
#  define MATRIX_GPIO6 XPAR_PHASE_B_BD_AXI_GPIO_6_BASEADDR
#else
#  error "AXI GPIO 4/5/6 (color_matrix) base addresses not in xparameters.h"
#endif

/* Write a full 3x3 matrix + 3 offsets to GPIO 4/5/6.
 * Coefficients are raw Q2.14 signed s16 (caller converts from float).
 * Offsets are signed s8. */
static inline void color_matrix_set(s16 m00, s16 m01, s16 m02,
                                    s16 m10, s16 m11, s16 m12,
                                    s16 m20, s16 m21, s16 m22,
                                    s8  off_r, s8 off_g, s8 off_b)
{
    Xil_Out32(MATRIX_GPIO4 + 0x00, ((u32)(u16)m01 << 16) | (u16)m00);
    Xil_Out32(MATRIX_GPIO4 + 0x08, ((u32)(u16)m10 << 16) | (u16)m02);
    Xil_Out32(MATRIX_GPIO5 + 0x00, ((u32)(u16)m12 << 16) | (u16)m11);
    Xil_Out32(MATRIX_GPIO5 + 0x08, ((u32)(u16)m21 << 16) | (u16)m20);
    Xil_Out32(MATRIX_GPIO6 + 0x00, (u32)(u16)m22);
    Xil_Out32(MATRIX_GPIO6 + 0x08, ((u32)(u8)off_b << 16) | ((u32)(u8)off_g << 8) | (u8)off_r);
    /* Readback all 6 GPIO registers to verify writes reached the registers. */
    u32 rb4_1 = Xil_In32(MATRIX_GPIO4 + 0x00);
    u32 rb4_2 = Xil_In32(MATRIX_GPIO4 + 0x08);
    u32 rb5_1 = Xil_In32(MATRIX_GPIO5 + 0x00);
    u32 rb5_2 = Xil_In32(MATRIX_GPIO5 + 0x08);
    u32 rb6_1 = Xil_In32(MATRIX_GPIO6 + 0x00);
    u32 rb6_2 = Xil_In32(MATRIX_GPIO6 + 0x08);
    xil_printf("MATRIX: [%04x %04x %04x / %04x %04x %04x / %04x %04x %04x]"
               " off=(%d,%d,%d)\r\n",
               (u16)m00, (u16)m01, (u16)m02,
               (u16)m10, (u16)m11, (u16)m12,
               (u16)m20, (u16)m21, (u16)m22,
               off_r, off_g, off_b);
    xil_printf("MATRIX bases: g4=0x%08x g5=0x%08x g6=0x%08x\r\n",
               (unsigned)MATRIX_GPIO4, (unsigned)MATRIX_GPIO5, (unsigned)MATRIX_GPIO6);
    xil_printf("MATRIX RB:  g4=[%08x %08x]  g5=[%08x %08x]  g6=[%08x %08x]\r\n",
               (unsigned)rb4_1, (unsigned)rb4_2,
               (unsigned)rb5_1, (unsigned)rb5_2,
               (unsigned)rb6_1, (unsigned)rb6_2);
}

/* Identity matrix: pass-through. */
static inline void color_matrix_identity(void)
{
    color_matrix_set(0x4000, 0x0000, 0x0000,
                     0x0000, 0x4000, 0x0000,
                     0x0000, 0x0000, 0x4000,
                     0, 0, 0);
}

/* Forward declarations for symbols used by the UART command parser
 * before their definitions appear later in the file. */
static inline void color_matrix_saturation(u16 sat_q15);

/* ============================================================================
 * UART command parser — runtime tuning of color pipeline without rebuilds.
 *
 * Commands (one-line, terminated by \r or \n):
 *   ?               help
 *   i               identity all (sat=100%, black=0,0,0, white=255,255,255, matrix=I)
 *   s <0..200>      color_saturation at percentage
 *   m <0..200>      matrix saturation at percentage (via color_matrix)
 *   g               matrix grayscale (= m 0)
 *   b <r> <g> <b>   color_correct black RGB
 *   w <r> <g> <b>   color_correct white RGB
 *   r               re-print all GPIO readbacks
 *
 * Numeric args are decimal. Pipe from this host:
 *   echo "i" > /dev/ttyUSB1
 *   echo "m 50" > /dev/ttyUSB1
 * ============================================================================ */
#ifndef STDIN_BASEADDRESS
#  if defined(XPAR_PS7_UART_1_BASEADDR)
#    define STDIN_BASEADDRESS XPAR_PS7_UART_1_BASEADDR
#  elif defined(XPAR_PS7_UART_0_BASEADDR)
#    define STDIN_BASEADDRESS XPAR_PS7_UART_0_BASEADDR
#  elif defined(XPAR_XUARTPS_0_BASEADDR)
#    define STDIN_BASEADDRESS XPAR_XUARTPS_0_BASEADDR
#  endif
#endif

/* Last-known color state (for partial-update commands). */
static u16 g_sat_q15 = 0x8000;
static u8  g_black_r = 0, g_black_g = 0, g_black_b = 0;
static u8  g_white_r = 255, g_white_g = 255, g_white_b = 255;

/* V0a catalog shadows: round-trip-clean readback values for control.get.
 * Updated by the same code paths that touch the GPIOs. */
static unsigned g_sat_pct        = 100;
static unsigned g_matrix_sat_pct = 100;
static unsigned g_matrix_preset  = 0;   /* 0=identity, 1=grayscale, 2=custom */

static inline void color_apply_state(void)
{
    color_set(g_sat_q15, g_black_r, g_black_g, g_black_b,
              g_white_r, g_white_g, g_white_b);
}

static int parse_uint(const char **pp, unsigned *out)
{
    const char *p = *pp;
    while (*p == ' ' || *p == '\t') p++;
    if (*p < '0' || *p > '9') return 0;
    unsigned v = 0;
    while (*p >= '0' && *p <= '9') { v = v * 10 + (*p - '0'); p++; }
    *out = v;
    *pp = p;
    return 1;
}

static void cmd_help(void)
{
    xil_printf("\r\nUART commands:\r\n"
               "  ?               help\r\n"
               "  i               identity (sat=100%%, black=0, white=255, matrix=I)\r\n"
               "  s <pct>         color_saturation at <pct>%% (0..200)\r\n"
               "  m <pct>         matrix saturation at <pct>%% (0..200)\r\n"
               "  g               matrix grayscale (m 0)\r\n"
               "  b <r> <g> <b>   color_correct black RGB (0..255)\r\n"
               "  w <r> <g> <b>   color_correct white RGB (0..255)\r\n"
               "  r               re-print GPIO readbacks\r\n"
               "  k h <0-3>       scaler H kernel: 0=NN 1=2tap 2=4tap (iter14)\r\n"
               "  k v <0-3>       scaler V kernel: 0=NN 1=2tap 2=4tap\r\n"
               "  k               query current kernel modes\r\n"
               "  J <json>        JSON-RPC 2.0 (catalog v0.1.0; for schindlerd)\r\n");
}

/* ============================================================================
 * V0a JSON-RPC bridge — catalog v0.1.0 (control-plane/catalog-v0.1.0.json)
 *
 * Single new UART command 'J' brackets a single-line JSON-RPC 2.0 payload.
 * Hand-rolled minimal JSON tokenizer — no malloc, no nested-object recursion
 * beyond one level (jsonrpc / id / method / params{id,value}).
 *
 * Examples:
 *   J {"jsonrpc":"2.0","id":1,"method":"system.identify"}
 *   J {"jsonrpc":"2.0","id":2,"method":"control.get","params":{"id":"color.saturation"}}
 *   J {"jsonrpc":"2.0","id":3,"method":"control.set","params":{"id":"color.saturation","value":110}}
 *
 * Responses are emitted as single lines starting with '{'. The host daemon
 * filters log noise by requiring lines to start with '{'. The enum-vs-int
 * mapping (e.g. "boxcar_2tap" → 1) lives in the daemon; firmware sees only
 * integer values.
 * ============================================================================ */

/* Locate `"key"` in a single-line JSON snippet and return ptr+len of its value.
 * Tolerates whitespace; tracks string/object/array depth to find the value's
 * comma/brace terminator. Returns 1 on hit, 0 on miss. */
static int cp_find_key(const char *json, const char *key,
                       const char **val_start, int *val_len)
{
    size_t klen = strlen(key);
    const char *p = json;
    while (*p) {
        if (p[0] == '"' && strncmp(p + 1, key, klen) == 0 && p[klen + 1] == '"') {
            const char *q = p + klen + 2;
            while (*q == ' ' || *q == '\t') q++;
            if (*q != ':') { p++; continue; }
            q++;
            while (*q == ' ' || *q == '\t') q++;
            *val_start = q;
            int depth = 0, in_str = 0;
            const char *r = q;
            while (*r) {
                if (in_str) {
                    if (*r == '\\' && r[1]) r++;
                    else if (*r == '"') in_str = 0;
                } else {
                    if (*r == '"') in_str = 1;
                    else if (*r == '{' || *r == '[') depth++;
                    else if (*r == '}' || *r == ']') {
                        if (depth == 0) break;
                        depth--;
                    } else if (*r == ',' && depth == 0) break;
                }
                r++;
            }
            *val_len = (int)(r - q);
            /* Trim trailing whitespace. */
            while (*val_len > 0 && (q[*val_len - 1] == ' ' || q[*val_len - 1] == '\t'))
                (*val_len)--;
            return 1;
        }
        p++;
    }
    return 0;
}

/* Parse a quoted JSON string at p (must include the leading '"' and trailing
 * '"' within len). Copies unescaped chars into out, NUL-terminated. */
static int cp_parse_string(const char *p, int len, char *out, int outsize)
{
    if (len < 2 || p[0] != '"' || p[len - 1] != '"') return 0;
    int o = 0;
    for (int i = 1; i < len - 1 && o < outsize - 1; i++) {
        if (p[i] == '\\' && i + 1 < len - 1) {
            i++;
            switch (p[i]) {
                case 'n': out[o++] = '\n'; break;
                case 't': out[o++] = '\t'; break;
                case 'r': out[o++] = '\r'; break;
                case '"': out[o++] = '"';  break;
                case '\\': out[o++] = '\\'; break;
                default: out[o++] = p[i]; break;
            }
        } else {
            out[o++] = p[i];
        }
    }
    out[o] = '\0';
    return 1;
}

/* Parse a JSON integer literal at p over len bytes. */
static int cp_parse_int(const char *p, int len, int *out)
{
    int sign = 1, val = 0, i = 0;
    if (len <= 0) return 0;
    if (p[0] == '-') { sign = -1; i = 1; }
    if (i >= len) return 0;
    for (; i < len; i++) {
        if (p[i] < '0' || p[i] > '9') return 0;
        val = val * 10 + (p[i] - '0');
    }
    *out = val * sign;
    return 1;
}

/* ---- per-control setters/getters --------------------------------------- */

typedef int (*cp_set_fn)(int v);
typedef int (*cp_get_fn)(int *out);

typedef struct {
    const char *id;
    cp_set_fn set;
    cp_get_fn get;
} cp_control_t;

static int cp_set_sat(int v) {
    if (v < 0 || v > 200) return -2;
    g_sat_pct = (unsigned)v;
    g_sat_q15 = color_sat_from_percent((unsigned)v);
    color_apply_state();
    return 0;
}
static int cp_get_sat(int *o) { *o = (int)g_sat_pct; return 0; }

static int cp_set_msat(int v) {
    if (v < 0 || v > 200) return -2;
    g_matrix_sat_pct = (unsigned)v; g_matrix_preset = 2;
    color_matrix_saturation(color_sat_from_percent((unsigned)v));
    return 0;
}
static int cp_get_msat(int *o) { *o = (int)g_matrix_sat_pct; return 0; }

static int cp_set_preset(int v) {
    if (v < 0 || v > 2) return -2;
    g_matrix_preset = (unsigned)v;
    if (v == 0)      { color_matrix_identity(); g_matrix_sat_pct = 100; }
    else if (v == 1) { color_matrix_saturation(0); g_matrix_sat_pct = 0; }
    /* v == 2: custom — leave matrix where the user last set it */
    return 0;
}
static int cp_get_preset(int *o) { *o = (int)g_matrix_preset; return 0; }

#define DEF_RGB_LEVEL(name, var, default_val) \
    static int cp_set_##name(int v) { \
        if (v < 0 || v > 255) return -2; \
        var = (u8)v; color_apply_state(); return 0; \
    } \
    static int cp_get_##name(int *o) { *o = (int)var; return 0; }

DEF_RGB_LEVEL(blk_r, g_black_r, 0)
DEF_RGB_LEVEL(blk_g, g_black_g, 0)
DEF_RGB_LEVEL(blk_b, g_black_b, 0)
DEF_RGB_LEVEL(wht_r, g_white_r, 255)
DEF_RGB_LEVEL(wht_g, g_white_g, 255)
DEF_RGB_LEVEL(wht_b, g_white_b, 255)

#ifdef XPAR_AXI_GPIO_7_BASEADDR
static int cp_set_kh(int v) {
    if (v < 0 || v > 3) return -2;
    u32 cur = Xil_In32(XPAR_AXI_GPIO_7_BASEADDR);
    cur = (cur & ~0x3u) | ((u32)v & 0x3u);
    Xil_Out32(XPAR_AXI_GPIO_7_BASEADDR, cur);
    return 0;
}
static int cp_get_kh(int *o) { *o = (int)(Xil_In32(XPAR_AXI_GPIO_7_BASEADDR) & 0x3); return 0; }
static int cp_set_kv(int v) {
    if (v < 0 || v > 3) return -2;
    u32 cur = Xil_In32(XPAR_AXI_GPIO_7_BASEADDR);
    cur = (cur & ~0xCu) | (((u32)v & 0x3u) << 2);
    Xil_Out32(XPAR_AXI_GPIO_7_BASEADDR, cur);
    return 0;
}
static int cp_get_kv(int *o) { *o = (int)((Xil_In32(XPAR_AXI_GPIO_7_BASEADDR) >> 2) & 0x3); return 0; }
#else
static int cp_set_kh(int v) { (void)v; return -2; }
static int cp_get_kh(int *o) { *o = -1; return -2; }
static int cp_set_kv(int v) { (void)v; return -2; }
static int cp_get_kv(int *o) { *o = -1; return -2; }
#endif

static const cp_control_t CP_CONTROLS[] = {
    {"color.saturation",         cp_set_sat,    cp_get_sat   },
    {"color.matrix_saturation",  cp_set_msat,   cp_get_msat  },
    {"color.matrix.preset",      cp_set_preset, cp_get_preset},
    {"color.correct.black_r",    cp_set_blk_r,  cp_get_blk_r },
    {"color.correct.black_g",    cp_set_blk_g,  cp_get_blk_g },
    {"color.correct.black_b",    cp_set_blk_b,  cp_get_blk_b },
    {"color.correct.white_r",    cp_set_wht_r,  cp_get_wht_r },
    {"color.correct.white_g",    cp_set_wht_g,  cp_get_wht_g },
    {"color.correct.white_b",    cp_set_wht_b,  cp_get_wht_b },
    {"scaler.kernel_h",          cp_set_kh,     cp_get_kh    },
    {"scaler.kernel_v",          cp_set_kv,     cp_get_kv    },
    {NULL, NULL, NULL}
};

/* Emit a JSON-RPC error response for the given id (raw literal: number or
 * "null"), error code, and message. Single line, '{'-prefixed. */
static void cp_emit_error(const char *id_lit, int code, const char *msg)
{
    xil_printf("{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":%d,\"message\":\"%s\"}}\r\n",
               id_lit, code, msg);
}

static void cp_dispatch_jsonrpc(const char *json)
{
    const char *vs; int vl;
    char method[40] = {0};
    char id_lit[20] = "null";

    if (cp_find_key(json, "id", &vs, &vl)) {
        int n = (vl < (int)sizeof(id_lit) - 1) ? vl : (int)sizeof(id_lit) - 1;
        memcpy(id_lit, vs, n); id_lit[n] = '\0';
    }
    if (!cp_find_key(json, "method", &vs, &vl) ||
        !cp_parse_string(vs, vl, method, sizeof(method))) {
        cp_emit_error(id_lit, -32600, "missing method");
        return;
    }

    if (strcmp(method, "system.identify") == 0) {
        xil_printf("{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{"
                   "\"model\":\"Schindler 2.0 Phase B\","
                   "\"fw\":\"iter5-1080p-clean\","
                   "\"catalog\":\"0.1.0\""
                   "}}\r\n", id_lit);
        return;
    }

    if (strcmp(method, "system.list_controls") == 0) {
        xil_printf("{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"ids\":[", id_lit);
        for (int i = 0; CP_CONTROLS[i].id; i++) {
            xil_printf("%s\"%s\"", i == 0 ? "" : ",", CP_CONTROLS[i].id);
        }
        xil_printf("]}}\r\n");
        return;
    }

    const char *ps; int pl;
    if (!cp_find_key(json, "params", &ps, &pl)) {
        cp_emit_error(id_lit, -32602, "missing params");
        return;
    }
    const char *pid_s; int pid_l;
    char ctl_id[48];
    if (!cp_find_key(ps, "id", &pid_s, &pid_l) ||
        !cp_parse_string(pid_s, pid_l, ctl_id, sizeof(ctl_id))) {
        cp_emit_error(id_lit, -32602, "missing params.id");
        return;
    }

    const cp_control_t *ctl = NULL;
    for (int i = 0; CP_CONTROLS[i].id; i++) {
        if (strcmp(CP_CONTROLS[i].id, ctl_id) == 0) { ctl = &CP_CONTROLS[i]; break; }
    }
    if (!ctl) { cp_emit_error(id_lit, -32601, "unknown control id"); return; }

    if (strcmp(method, "control.get") == 0) {
        int val = 0;
        if (ctl->get && ctl->get(&val) == 0) {
            xil_printf("{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"value\":%d}}\r\n", id_lit, val);
        } else {
            cp_emit_error(id_lit, -32603, "read failed");
        }
        return;
    }
    if (strcmp(method, "control.set") == 0) {
        const char *pv_s; int pv_l; int val = 0;
        if (!cp_find_key(ps, "value", &pv_s, &pv_l) || !cp_parse_int(pv_s, pv_l, &val)) {
            cp_emit_error(id_lit, -32602, "missing/invalid value");
            return;
        }
        int rc = ctl->set ? ctl->set(val) : -1;
        if (rc == 0) {
            int rb = val;
            if (ctl->get) ctl->get(&rb);
            xil_printf("{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"value\":%d}}\r\n", id_lit, rb);
        } else if (rc == -2) {
            cp_emit_error(id_lit, -32602, "value out of range");
        } else {
            cp_emit_error(id_lit, -32603, "set failed");
        }
        return;
    }

    cp_emit_error(id_lit, -32601, "unknown method");
}

static void uart_dispatch(const char *line)
{
    if (line[0] == '\0') return;
    char op = line[0];
    const char *p = line + 1;
    unsigned a, b, c;
    if (op == 'J') {
        while (*p == ' ' || *p == '\t') p++;
        cp_dispatch_jsonrpc(p);
        return;
    }
    if (op == '?' || op == 'h') {
        cmd_help();
    } else if (op == 'i') {
        g_sat_q15 = 0x8000; g_sat_pct = 100;
        g_black_r = g_black_g = g_black_b = 0;
        g_white_r = g_white_g = g_white_b = 255;
        g_matrix_sat_pct = 100; g_matrix_preset = 0;
        color_apply_state();
        color_matrix_identity();
    } else if (op == 's' && parse_uint(&p, &a)) {
        g_sat_pct = (a > 200) ? 200 : a;
        g_sat_q15 = color_sat_from_percent(a);
        color_apply_state();
    } else if (op == 'm' && parse_uint(&p, &a)) {
        g_matrix_sat_pct = (a > 200) ? 200 : a; g_matrix_preset = 2;
        color_matrix_saturation(color_sat_from_percent(a));
    } else if (op == 'g') {
        g_matrix_sat_pct = 0; g_matrix_preset = 1;
        color_matrix_saturation(0);
    } else if (op == 'b' && parse_uint(&p, &a) && parse_uint(&p, &b) && parse_uint(&p, &c)) {
        g_black_r = (u8)a; g_black_g = (u8)b; g_black_b = (u8)c;
        color_apply_state();
    } else if (op == 'w' && parse_uint(&p, &a) && parse_uint(&p, &b) && parse_uint(&p, &c)) {
        g_white_r = (u8)a; g_white_g = (u8)b; g_white_b = (u8)c;
        color_apply_state();
    } else if (op == 'r') {
        color_apply_state();   /* re-write triggers readback prints */
        color_matrix_identity(); /* same — re-emits MATRIX line */
    } else if (op == 'k') {
        /* iter14 (2026-05-31): runtime scaler kernel-mode toggle.
         *   k h <0|1|2|3>  — set H scaler kernel mode
         *   k v <0|1|2|3>  — set V scaler kernel mode
         *   k             — print current mode
         * Modes: 0=NN, 1=2-tap boxcar (production), 2=4-tap boxcar, 3=rsv.
         * GPIO 7 holds 4-bit value: [1:0]=H, [3:2]=V. */
#ifdef XPAR_AXI_GPIO_7_BASEADDR
        u32 cur = Xil_In32(XPAR_AXI_GPIO_7_BASEADDR);
        if (*p == ' ') p++;
        char axis = *p++;
        if (axis == '\0') {
            /* query */
            xil_printf("KERNEL: H=%u V=%u  (raw=0x%01x)\r\n",
                       (unsigned)(cur & 0x3), (unsigned)((cur >> 2) & 0x3),
                       (unsigned)(cur & 0xf));
        } else if ((axis == 'h' || axis == 'v') && parse_uint(&p, &a) && a <= 3) {
            if (axis == 'h') cur = (cur & ~0x3) | (a & 0x3);
            else             cur = (cur & ~0xC) | ((a & 0x3) << 2);
            Xil_Out32(XPAR_AXI_GPIO_7_BASEADDR, cur);
            xil_printf("KERNEL: H=%u V=%u  (k%c=%u)\r\n",
                       (unsigned)(cur & 0x3), (unsigned)((cur >> 2) & 0x3),
                       axis, a);
        } else {
            xil_printf("UART: usage 'k h|v <0-3>' or just 'k' to query\r\n");
        }
#else
        xil_printf("UART: kernel-mode GPIO not present in this build\r\n");
#endif
    } else {
        xil_printf("UART: unknown cmd '%s' — type ? for help\r\n", line);
    }
}

#ifdef STDIN_BASEADDRESS
static void uart_poll(void)
{
    /* 512 bytes accommodates the longest JSON-RPC requests for v0.1.0
     * (control.set with the longest control id ~95 bytes; headroom for
     * future namespaced ids). */
    static char buf[512];
    static int  len = 0;
    while (!(Xil_In32(STDIN_BASEADDRESS + 0x2C) & 0x2)) {
        u8 ch = (u8)Xil_In32(STDIN_BASEADDRESS + 0x30);
        if (ch == '\r' || ch == '\n') {
            if (len > 0) {
                buf[len] = '\0';
                /* Suppress the human-readable echo for JSON-RPC lines —
                 * the daemon scans for lines starting with '{'. */
                if (buf[0] != 'J') xil_printf("\r\nUART> %s\r\n", buf);
                uart_dispatch(buf);
                len = 0;
            }
        } else if (ch >= ' ' && len < (int)sizeof(buf) - 1) {
            buf[len++] = (char)ch;
        }
    }
}
#else
static void uart_poll(void) {}
#endif

/* Saturation matrix via Rec.601 luma weights (Yr=0.299, Yg=0.587, Yb=0.114).
 * sat_q15 is Q1.15 (0x0000=gray, 0x8000=identity, 0xFFFF≈200%).
 * Note: this duplicates color_saturation_0's function — useful for verifying
 * the matrix module produces equivalent results. */
static inline void color_matrix_saturation(u16 sat_q15)
{
    /* Convert sat from Q1.15 to Q2.14 (right-shift by 1 since one fewer
     * fraction bit). At 100% sat (Q1.15=0x8000), q14=0x4000 (1.0). */
    s32 s = (s32)sat_q15 >> 1;  /* Q2.14 signed */
    s32 one_q14 = 0x4000;
    s32 inv_s   = one_q14 - s;  /* (1-s) in Q2.14 */

    /* Yr=0.299*16384=4899 ; Yg=0.587*16384=9617 ; Yb=0.114*16384=1868 */
    s32 yr = (inv_s * 4899) >> 14;
    s32 yg = (inv_s * 9617) >> 14;
    s32 yb = (inv_s * 1868) >> 14;

    /* Diagonal entries = s + (1-s)·Y_channel ; off-diagonals = (1-s)·Y_col_channel */
    color_matrix_set((s16)(s + yr), (s16)yg,        (s16)yb,
                     (s16)yr,       (s16)(s + yg),  (s16)yb,
                     (s16)yr,       (s16)yg,        (s16)(s + yb),
                     0, 0, 0);
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

/* iter5 (2026-05-22): repurposed [63:48] slot. Was mm2s_tlast (always 0).
 * Now scaler_v's m_axis_tlast handshake count per source frame — the A2
 * disambiguator. Caller param renamed for clarity. */
static inline void diag_counters_read(u16 *h_in, u16 *v_in, u16 *v_emit, u16 *v_out_tlast)
{
    u32 ch1 = Xil_In32(DIAG_GPIO_BASEADDR + 0x00);
    u32 ch2 = Xil_In32(DIAG_GPIO_BASEADDR + 0x08);
    if (h_in)        *h_in        = (u16)(ch1 & 0xFFFFu);
    if (v_in)        *v_in        = (u16)((ch1 >> 16) & 0xFFFFu);
    if (v_emit)      *v_emit      = (u16)(ch2 & 0xFFFFu);
    if (v_out_tlast) *v_out_tlast = (u16)((ch2 >> 16) & 0xFFFFu);
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
/* iter6 H-shift probe (2026-05-23): dump first 10 + last 10 pixels of
 * each row. Decisive test for byte-level wrap: if row N's cols 1270-1279
 * == row N+1's cols 0-9, the wrap is real. If they differ, the row N
 * tail follows the source content and row N+1 head is the next row's
 * own content (no wrap; what looked like wrap is scaler_h's 8-tap window
 * carryover smear). */
static void dump_slot_head_pixels(u32 slot_idx, u32 row_start, u32 row_end)
{
    const u32 SLOT_STRIDE_BYTES = FRAME_BYTES + STRIDE;
    volatile u8 *slot = (volatile u8 *)(FRAME_BUF_BASE + slot_idx * SLOT_STRIDE_BYTES);
    xil_printf("\r\nDDR3 HEAD+TAIL: slot=%u rows=%u..%u (cols 0-9 + 1270-1279)  base=0x%08x\r\n",
               (unsigned)slot_idx, (unsigned)row_start, (unsigned)row_end,
               (unsigned)(FRAME_BUF_BASE + slot_idx * SLOT_STRIDE_BYTES));
    for (u32 row = row_start; row <= row_end; row++) {
        u32 row_base = row * STRIDE;
        xil_printf("  r%3u HEAD ", (unsigned)row);
        for (u32 col = 0; col < 10; col++) {
            u32 a = row_base + col * 3;
            xil_printf("%02x%02x%02x ",
                       (unsigned)slot[a + 0], (unsigned)slot[a + 1], (unsigned)slot[a + 2]);
        }
        xil_printf("| TAIL ");
        for (u32 col = 1270; col < 1280; col++) {
            u32 a = row_base + col * 3;
            xil_printf("%02x%02x%02x ",
                       (unsigned)slot[a + 0], (unsigned)slot[a + 1], (unsigned)slot[a + 2]);
        }
        xil_printf("\r\n");
    }
}

static void dump_slot_bytes(u32 slot_idx, u32 row_start, u32 row_end)
{
    /* iter5 slot layout: FRAME_BYTES of S2MM-written rows + STRIDE of guard.
     * Matches the firmware addr math at main() line ~1104-1108. The old
     * iter4h +27 over-allocate stride here was a stale leftover; it placed
     * slot N base ~100 KB past where S2MM actually writes for N≥1. */
    const u32 SLOT_STRIDE_BYTES = FRAME_BYTES + STRIDE;
    volatile u8 *slot = (volatile u8 *)(FRAME_BUF_BASE + slot_idx * SLOT_STRIDE_BYTES);
    xil_printf("\r\nDDR3 DUMP: slot=%u rows=%u..%u  base=0x%08x\r\n",
               (unsigned)slot_idx, (unsigned)row_start, (unsigned)row_end,
               (unsigned)(FRAME_BUF_BASE + slot_idx * SLOT_STRIDE_BYTES));
    /* 6 cols spaced across the 1280-pixel-wide scaler OUTPUT (= what S2MM
     * writes to each slot row). Each col lands in a distinct SMPTE color
     * bar (each bar ≈ 183 px at 1280 wide): white / yellow / cyan / green /
     * magenta / red. A row showing 6 distinct bar colors is from the TOP
     * (main-bars region); a row showing mostly uniform black/dim values is
     * from the BOTTOM (PLUGE region). This is the fingerprint test for
     * the bottom-bars artifact: slot row 694..719 (expected PLUGE) showing
     * 6 distinct bar colors = frame K+1 top leaking into frame K bottom. */
    /* iter6 H-shift probe (2026-05-23): mix of boundary cols (0..3,
     * 1276..1279) for the per-row alignment check + interior cols
     * (90, 270, 460, 640, 820, 1010) covering the 7 SMPTE bars to
     * verify slot has content. If interior cols match the prior iter6
     * verification fingerprint but boundary cols are zero → slot is
     * byte-clean, shift is post-MM2S. If boundary AND interior cols
     * both look weird → may indicate slot empty (S2MM not writing). */
    static const u32 SAMPLE_COLS[14] = {
        0, 1, 2, 3,                        /* row LEFT boundary */
        90, 270, 460, 640, 820, 1010,      /* SMPTE bar interior cols */
        1276, 1277, 1278, 1279             /* row RIGHT boundary */
    };
    /* Also compute a XOR checksum of every byte in the row so we know
     * whether the row has ANY data at all, beyond just the sample cols. */
    for (u32 row = row_start; row <= row_end; row++) {
        u32 row_base = row * STRIDE;
        u8 chk = 0;
        u32 nonzero = 0;
        for (u32 b = 0; b < STRIDE; b++) {
            u8 v = slot[row_base + b];
            chk ^= v;
            if (v) nonzero++;
        }
        xil_printf("  row %3u  chk=%02x nz=%5u  ", (unsigned)row,
                   (unsigned)chk, (unsigned)nonzero);
        for (u32 i = 0; i < 14; i++) {
            u32 col = SAMPLE_COLS[i];
            u32 a = row_base + col * 3;
            xil_printf("c%u=%02x%02x%02x ", (unsigned)col,
                       (unsigned)slot[a + 0], (unsigned)slot[a + 1], (unsigned)slot[a + 2]);
        }
        xil_printf("\r\n");
    }
}

static void telemetry_loop(UINTPTR vdma_base)
{
    (void)vdma_base;
    /* iter4 (2026-05-22): two-shot DDR dump for A1/A2 disambiguation. With
     * Osee on the motion source, dump 1 (at first DIAG ≈ 1s after boot) and
     * dump 2 (at 4th DIAG ≈ 4s after boot) sample the slot ~3s apart. If
     * slot 0 rows 694-719 are byte-identical between dumps → A1 (stale prior
     * write, frozen). If they shift to track the motion source → A2 (live
     * frame K+1 leak). */
    int ddr_dump_count = 0;       /* 0=none yet, 1=did first, 2=done */
    int diag_iter      = 0;       /* incremented at each DIAG print */

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
        uart_poll();  /* runtime command parser — non-blocking */
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
                u16 h_in, v_in, v_emit, v_out_tlast;
                diag_counters_read(&h_in, &v_in, &v_emit, &v_out_tlast);
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
                /* DIAG fields (scaler_top counters, snapshotted at TUSER):
                 *   h_in        = scaler_h s_axis_tlast count  (= src rows)
                 *   v_in        = scaler_v s_axis_tlast count  (= src rows)
                 *   v_emit      = scaler_v v_cross count       (= 720 expect)
                 *   v_out_tlast = scaler_v m_axis_tlast count  (iter5 NEW)
                 *
                 * iter5 (2026-05-22) A2 disambiguator:
                 *   v_out_tlast == 720 → scaler emits cleanly; bug is in
                 *     S2MM slot-advance timing (A2-S2MM).
                 *   v_out_tlast <  720 → scaler aborts last ~26 emits at
                 *     frame boundary (A2-scaler). */
                /* iter6-post (2026-05-31): S2MM SOFLate (bit 0x800) is set
                 * every frame because iter6's hardware fsync from source
                 * vsync arrives slightly ahead of TUSER on AXIS. PG020
                 * flags this as "late" but it's cosmetic — picture is
                 * clean. Suppress the noise in the DIAG print; the bit
                 * is still visible in the raw s2mm_sr hex if anything
                 * else changes about timing. MM2S SOFLate is NOT
                 * suppressed — that side has no fsync re-timing so any
                 * SOFLate there would be a real issue. */
                xil_printf("DIAG: h_in=%u v_in=%u v_emit=%u v_out_tlast=%u  "
                           "S2MM_SR=0x%08x[%s%s%s%s frmcnt=%u] "
                           "MM2S_SR=0x%08x[%s%s%s%s%s frmcnt=%u]  "
                           "RDSTORE=%d WRSTORE=%d  src=%d out=%d\r\n",
                           (unsigned)h_in, (unsigned)v_in, (unsigned)v_emit, (unsigned)v_out_tlast,
                           /* iter4h relabel: bit 12 is FrmCnt_Irq (benign), bit 15 is real EOLLate */
                           (unsigned)s2mm_sr,
                           (s2mm_sr & 0x80)   ? "SOFEarly " : "",
                           (s2mm_sr & 0x100)  ? "EOLEarly " : "",
                           /* SOFLate (0x800) suppressed — cosmetic post-iter6 */
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

                /* iter4 (2026-05-22): two-shot DDR3 dump for A1/A2
                 * disambiguation. Run Osee on input 2 (motion) so the source
                 * varies over time. Dump #1 fires at first DIAG (~1s),
                 * dump #2 fires at fourth DIAG (~4s) — ~3s apart, plenty for
                 * the motion loop to shift the source content.
                 *
                 *  - A1 (stale prior-write): slot 0 rows 694-719 will be
                 *    byte-identical between dumps. The slot tail is frozen
                 *    from whichever frame last wrote that region before the
                 *    early-TUSER abort started clobbering.
                 *  - A2 (live frame K+1 leak): slot 0 rows 694-719 will
                 *    shift between dumps — tracking what frame K+1's row 0+
                 *    area looks like at each dump moment in the motion loop. */
                diag_iter++;
                int trigger = (ddr_dump_count == 0 && diag_iter >= 1) ? 1 :
                              (ddr_dump_count == 1 && diag_iter >= 4) ? 2 : 0;
                if (trigger) {
                    xil_printf("\r\n=== DDR3 DUMP #%d (diag_iter=%d) ===\r\n",
                               trigger, diag_iter);
                    /* iter6 H-shift probe (2026-05-23): re-read VTC_RX
                     * detector now — boot might have failed to lock, but
                     * mid-stream the source could be stable. If detector
                     * reports HACTIVE != 1920, we've found the wrap cause:
                     * scaler operating with wrong row width. */
                    u32 dtstat = Xil_In32(VTC_RX_BASEADDR + 0x024);
                    u32 dasize = Xil_In32(VTC_RX_BASEADDR + 0x020);
                    u32 dhsize = Xil_In32(VTC_RX_BASEADDR + 0x030);
                    u32 dvsize = Xil_In32(VTC_RX_BASEADDR + 0x034);
                    u32 dpol   = Xil_In32(VTC_RX_BASEADDR + 0x02C);
                    xil_printf("[VTC_RX LIVE] DTSTAT=0x%08x (LOCK=%d) HACTIVE=%u VACTIVE=%u HTOTAL=%u VTOTAL=%u DPOL=0x%02x\r\n",
                               (unsigned)dtstat, (int)(dtstat & 1),
                               (unsigned)(dasize & 0x3FFF),
                               (unsigned)((dasize >> 16) & 0x3FFF),
                               (unsigned)(dhsize & 0x3FFF),
                               (unsigned)(dvsize & 0x3FFF),
                               (unsigned)(dpol & 0x1F));
                    dump_slot_head_pixels(0, 0, 99);
                    ddr_dump_count = trigger;
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

    /* iter2 2026-05-21: printf MOVED to after CTL register write below.
     * Caller spec at main() lines 1156-1168 demands no printfs between
     * wait_for_aligned_source_vsync() and the CTL write. The internal printf
     * here was violating that rule (115200 baud × ~40 chars ≈ 3.5 ms delay
     * = ~227 source lines of misalignment at 1080p60 source). Suspected
     * cause of the deterministic ~50-line vertical wraparound visible at
     * the bottom of the output frame. */

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

    /* Now safe to printf — CTL write committed, alignment locked. */
    xil_printf("VTC: configuring %s (HTOTAL=%u VTOTAL=%u)\r\n",
               m->name, (unsigned)H_TOTAL, (unsigned)V_TOTAL);

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
     * FRC. Expected PHASE deltas all 1 (every source frame consumed).
     *
     * 2026-05-31: OUTPUT_1080P compile-time switch picks MODE_1080P30 for
     * the 1080p30 passthrough test build. Was a missed hardcode that left
     * VTC generating 720p timing on 1080p builds — VDMA HSIZE was correct
     * (per FRAME_W param) but VTC told axis_to_vid_io to gate 1280 cols of
     * active video per row → output rendered ~half-width, repeated. */
#ifdef OUTPUT_1080P
    if (vtc_setup(&MODE_1080P30) != XST_SUCCESS) return -1;
#else
    if (vtc_setup(&MODE_720P60) != XST_SUCCESS) return -1;
#endif
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
    /* color_correct / color_saturation: identity baseline. */
    color_set(color_sat_from_percent(100),  0, 0, 0,    255, 255, 255);

    /* color_matrix boot default: identity (full color pass-through).
     * Send 'g' over UART for Rec.601 grayscale, 'm 0' for matrix-based
     * grayscale, 'm 150' for vivid, etc. */
    color_matrix_identity();

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
