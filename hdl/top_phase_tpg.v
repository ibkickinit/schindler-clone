// top_phase_tpg.v — Internal test pattern generator -> rgb2dvi -> HDMI TX.
//
// Diagnostic-only build for the Phase D iter-2 chroma-noise investigation
// (memory: schindler_phase_d_chroma_noise). Eliminates source HDMI,
// dvi2rgb, scaler, VDMA, and DDR3 from the picture entirely. The signal
// path is just:
//
//   sys_clk -> MMCM -> 74.25 MHz pixel clock
//   counters -> 720p60 H/V/VDE timing + RGB pattern
//   -> rgb2dvi -> TMDS -> HDMI TX
//
// If a bench capture of this bitstream is clean, the rgb2dvi + cable +
// monitor + capture-stick path is innocent and the noise is in the
// scaler+VDMA chain (as the Phase A vs scaler A/B already strongly
// suggested). If this also shows speckle, the suspect list expands
// downstream of the FPGA.
//
// 720p60 timing per CEA-861-D Format 4 (matches the scaler bitstream's
// output mode so we're testing the same TX configuration):
//   PixelClk = 74.25 MHz
//   HTotal=1650  HActive=1280  HFP=110  HSync=40  HBP=220  pol=+
//   VTotal=750   VActive=720   VFP=5    VSync=5   VBP=20   pol=+
//
// Pattern:
//   Top 60% (y < 432):     8 SMPTE-75% color bars (160 px each)
//   Bottom 40% (y >= 432): horizontal grayscale gradient 0..255
// Same regions of interest as the bench-source SMPTE pattern, so a side-
// by-side capture compares directly.

`default_nettype none
`timescale 1ns / 1ps

module top_phase_tpg (
    input  wire        sys_clk,        // K17, 125 MHz LVCMOS33
    input  wire        btn_rst,        // K18, BTN0 (held high to reset)

    output wire        TMDS_OUT_clk_p,
    output wire        TMDS_OUT_clk_n,
    output wire [2:0]  TMDS_OUT_data_p,
    output wire [2:0]  TMDS_OUT_data_n,
    input  wire        hdmi_tx_hpd,

    output wire [3:0]  leds            // LD0..LD3
);

    // ------------------------------------------------------------
    // 74.25 MHz pixel clock from 125 MHz sys_clk.
    // VCO = 125 * 37.125 / 5 = 928.125 MHz (in 600..1200 spec)
    // CLKOUT0 = 928.125 / 12.5 = 74.25 MHz (CEA-861 720p60 pixel rate, exact)
    // ------------------------------------------------------------
    wire pix_clk_pre, pix_clk;
    wire mmcm_fb_pre, mmcm_fb;
    wire mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKFBOUT_MULT_F   (37.125),
        .DIVCLK_DIVIDE     (5),
        .CLKOUT0_DIVIDE_F  (12.500),
        .CLKIN1_PERIOD     (8.000),
        .CLKOUT0_PHASE     (0.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKFBOUT_PHASE    (0.000),
        .STARTUP_WAIT      ("FALSE")
    ) mmcm_inst (
        .CLKIN1   (sys_clk),
        .CLKFBIN  (mmcm_fb),
        .CLKFBOUT (mmcm_fb_pre),
        .CLKOUT0  (pix_clk_pre),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (btn_rst)
    );

    BUFG bufg_pix (.I(pix_clk_pre), .O(pix_clk));
    BUFG bufg_fb  (.I(mmcm_fb_pre), .O(mmcm_fb));

    // Reset synchronizer: hold reset until MMCM is locked, then deassert
    // through 3 pix_clk stages to give downstream synchronous logic clean
    // edges. btn_rst can re-arm asynchronously.
    reg [2:0] rst_sync = 3'b111;
    always @(posedge pix_clk or posedge btn_rst) begin
        if (btn_rst)            rst_sync <= 3'b111;
        else if (!mmcm_locked)  rst_sync <= 3'b111;
        else                    rst_sync <= {rst_sync[1:0], 1'b0};
    end
    wire rstn_pix = ~rst_sync[2];

    // ------------------------------------------------------------
    // 720p60 timing counters
    // ------------------------------------------------------------
    localparam integer H_ACTIVE = 1280;
    localparam integer H_FP     = 110;
    localparam integer H_SYNC   = 40;
    localparam integer H_BP     = 220;
    localparam integer H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;  // 1650

    localparam integer V_ACTIVE = 720;
    localparam integer V_FP     = 5;
    localparam integer V_SYNC   = 5;
    localparam integer V_BP     = 20;
    localparam integer V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;  // 750

    reg [10:0] hcount = 11'd0;
    reg [9:0]  vcount = 10'd0;

    always @(posedge pix_clk) begin
        if (!rstn_pix) begin
            hcount <= 11'd0;
            vcount <= 10'd0;
        end else begin
            if (hcount == H_TOTAL - 1) begin
                hcount <= 11'd0;
                if (vcount == V_TOTAL - 1) vcount <= 10'd0;
                else                       vcount <= vcount + 10'd1;
            end else begin
                hcount <= hcount + 11'd1;
            end
        end
    end

    wire active  = (hcount < H_ACTIVE) && (vcount < V_ACTIVE);
    // 720p60 sync polarity is positive for both H and V (CEA-861-D)
    wire hsync_p = (hcount >= H_ACTIVE + H_FP) && (hcount < H_ACTIVE + H_FP + H_SYNC);
    wire vsync_p = (vcount >= V_ACTIVE + V_FP) && (vcount < V_ACTIVE + V_FP + V_SYNC);

    // ------------------------------------------------------------
    // Pattern generator
    // ------------------------------------------------------------
    // Bottom-half gradient: hcount/4 -> 0..319, saturated at 255.
    // 1280 cols / 256 levels would be 5 cols/level; using /4 (320 cols/256)
    // gives a slightly wider-than-needed ramp and saturates the right ~75 px
    // to white — exposes any saturation-edge artifacts as a bonus.
    wire [10:0] grad_x   = hcount >> 2;
    wire [7:0]  grad_val = (grad_x > 11'd255) ? 8'hFF : grad_x[7:0];

    reg [7:0] r, g, b;
    always @* begin
        if (vcount < 432) begin
            // Top 60% — SMPTE 75% color bars, 160 px each
            if      (hcount <  160)  begin r = 8'd180; g = 8'd180; b = 8'd180; end // gray
            else if (hcount <  320)  begin r = 8'd180; g = 8'd180; b = 8'd000; end // yellow
            else if (hcount <  480)  begin r = 8'd000; g = 8'd180; b = 8'd180; end // cyan
            else if (hcount <  640)  begin r = 8'd000; g = 8'd180; b = 8'd000; end // green
            else if (hcount <  800)  begin r = 8'd180; g = 8'd000; b = 8'd180; end // magenta
            else if (hcount <  960)  begin r = 8'd180; g = 8'd000; b = 8'd000; end // red
            else if (hcount < 1120)  begin r = 8'd000; g = 8'd000; b = 8'd180; end // blue
            else                     begin r = 8'd180; g = 8'd180; b = 8'd180; end // gray
        end else begin
            // Bottom 40% — horizontal gray gradient
            r = grad_val;
            g = grad_val;
            b = grad_val;
        end
    end

    // Force black during blanking so any TMDS-time leakage is obvious
    wire [23:0] rgb_data = active ? {r, g, b} : 24'h000000;

    // ------------------------------------------------------------
    // rgb2dvi -> HDMI TX. Same IP and config as Phase A (kRstActiveHigh,
    // kGenerateSerialClk=true with MMCM primitive, kClkRange=1).
    // aRst is active-high; tie to ~rstn_pix so the TX waits for MMCM lock.
    // ------------------------------------------------------------
    rgb2dvi_0 dvi_tx_inst (
        .TMDS_Clk_p   (TMDS_OUT_clk_p),
        .TMDS_Clk_n   (TMDS_OUT_clk_n),
        .TMDS_Data_p  (TMDS_OUT_data_p),
        .TMDS_Data_n  (TMDS_OUT_data_n),

        .aRst         (~rstn_pix),

        .vid_pData    (rgb_data),
        .vid_pVDE     (active),
        .vid_pHSync   (hsync_p),
        .vid_pVSync   (vsync_p),
        .PixelClk     (pix_clk)
    );

    // ------------------------------------------------------------
    // LEDs (same family as Phase A so visual cues match expectations):
    //   LD0 = MMCM locked (pixel clock valid)
    //   LD1 = unused (off)
    //   LD2 = pix_clk heartbeat (~4 Hz blink — confirms PL is alive)
    //   LD3 = downstream sink HPD (monitor plugged in)
    // ------------------------------------------------------------
    reg [23:0] heartbeat = 24'd0;
    always @(posedge pix_clk) heartbeat <= heartbeat + 24'd1;

    assign leds = {hdmi_tx_hpd, heartbeat[23], 1'b0, mmcm_locked};

endmodule

`default_nettype wire
