// top_phase_a.v — Schindler 2.0 Phase A: HDMI passthrough on Zybo Z7-20.
//
// Goal: validate the HDMI infrastructure end-to-end on this bench.
//   External HDMI source (laptop) → Zybo HDMI RX port → dvi2rgb (TMDS deserialize) →
//   parallel RGB → rgb2dvi (TMDS serialize) → Zybo HDMI TX port → external monitor.
//
// No frame buffer, no scaling, no processing — just pixel-domain pass-through.
// Validates that the bench, Vivado toolchain, and HDMI hardware all work end-to-end
// before we layer on VDMA (Phase B), scaler (C), FRC (D), color (E), geometry (F).
//
// Architecture:
//   sys_clk (125 MHz from Zybo onboard oscillator)
//     ↓
//   MMCM → 200 MHz RefClk (for dvi2rgb's IDELAYCTRL)
//     ↓
//   dvi2rgb: TMDS_IN → vid_pData[23:0] + vid_pVDE + vid_pHSync + vid_pVSync, PixelClk, SerialClk
//     ↓ (direct wire — no clock-domain crossing, both clocks are dvi2rgb-driven)
//   rgb2dvi: vid_pData[23:0] + vid_pVDE + vid_pHSync + vid_pVSync + PixelClk + SerialClk → TMDS_OUT
//
// Resets: dvi2rgb has its own SyncAsync resets; we drive aRst from btn_rst.
// HPD: hdmi_rx_hpd asserted HIGH (source can negotiate); hdmi_tx_hpd is INPUT (sink presence).
// EDID: dvi2rgb's kEmulateDDC=true exposes a basic 720p EDID to the source. Adequate for
// passthrough validation; full Schindler EDID handling lives in Zynq PS later.

`default_nettype none
`timescale 1ns / 1ps

module top_phase_a (
    // Onboard clock + reset
    input  wire        sys_clk,        // K17, 125 MHz LVCMOS33
    input  wire        btn_rst,        // K18, BTN0 (held to reset, released to run)

    // HDMI RX (TMDS input — external source plugs in here)
    input  wire        TMDS_IN_clk_p,
    input  wire        TMDS_IN_clk_n,
    input  wire [2:0]  TMDS_IN_data_p,
    input  wire [2:0]  TMDS_IN_data_n,
    inout  wire        hdmi_in_ddc_scl,
    inout  wire        hdmi_in_ddc_sda,
    output wire        hdmi_rx_hpd,    // Drive HIGH so source negotiates with us

    // HDMI TX (TMDS output — external monitor/sink plugs in here)
    output wire        TMDS_OUT_clk_p,
    output wire        TMDS_OUT_clk_n,
    output wire [2:0]  TMDS_OUT_data_p,
    output wire [2:0]  TMDS_OUT_data_n,
    input  wire        hdmi_tx_hpd,    // Sense downstream sink presence (not used in Phase A)

    // Status LEDs (Zybo 4× user LEDs)
    output wire [3:0]  leds            // LD0..LD3
);

    // ------------------------------------------------------------
    // 200 MHz reference clock for dvi2rgb's IDELAYCTRL
    // MMCME2_BASE: VCO = 125 × 8 / 1 = 1000 MHz, CLKOUT0 = 1000 / 5 = 200 MHz
    // ------------------------------------------------------------
    wire ref_clk_pre, ref_clk;
    wire mmcm_clkfb_pre, mmcm_clkfb;
    wire mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKFBOUT_MULT_F   (8.000),     // M = 8
        .DIVCLK_DIVIDE     (1),         // D = 1, VCO = 125*8/1 = 1000 MHz (in 600-1200 range)
        .CLKOUT0_DIVIDE_F  (5.000),     // O = 5, CLKOUT0 = 200 MHz exact
        .CLKIN1_PERIOD     (8.000),     // 125 MHz period
        .CLKOUT0_PHASE     (0.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKFBOUT_PHASE    (0.000),
        .STARTUP_WAIT      ("FALSE")
    ) mmcm_inst (
        .CLKIN1   (sys_clk),
        .CLKFBIN  (mmcm_clkfb),
        .CLKFBOUT (mmcm_clkfb_pre),
        .CLKOUT0  (ref_clk_pre),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (btn_rst)
    );

    BUFG bufg_refclk (.I(ref_clk_pre),   .O(ref_clk));
    BUFG bufg_clkfb  (.I(mmcm_clkfb_pre), .O(mmcm_clkfb));

    // Drive HDMI RX hot-plug-detect HIGH once MMCM has locked (signals source we're ready)
    assign hdmi_rx_hpd = mmcm_locked;

    // ------------------------------------------------------------
    // dvi2rgb instance — TMDS RX → parallel RGB + sync + clk
    // ------------------------------------------------------------
    wire        pixel_clk;
    wire        rx_locked;
    wire [23:0] vid_data;
    wire        vid_vde;
    wire        vid_hsync;
    wire        vid_vsync;

    // DDC EEPROM tristate signals (dvi2rgb emulates a basic EDID EEPROM)
    wire ddc_sda_i, ddc_sda_o, ddc_sda_t;
    wire ddc_scl_i, ddc_scl_o, ddc_scl_t;

    IOBUF iobuf_sda (
        .I  (ddc_sda_o),
        .O  (ddc_sda_i),
        .T  (ddc_sda_t),
        .IO (hdmi_in_ddc_sda)
    );
    IOBUF iobuf_scl (
        .I  (ddc_scl_o),
        .O  (ddc_scl_i),
        .T  (ddc_scl_t),
        .IO (hdmi_in_ddc_scl)
    );

    // IP wrapper instance — parameters are configured via create_ip in build_phase_a.tcl
    // Note: the IP wrapper drops aRst_n / pRst_n / SerialClk vs the underlying VHDL entity.
    // With kDebug=true the IP wrapper exposes additional ILA-related ports.
    // We use port-by-name binding and let unspecified ports stay disconnected
    // (Vivado handles this).
    dvi2rgb_0 dvi_rx_inst (
        .TMDS_Clk_p   (TMDS_IN_clk_p),
        .TMDS_Clk_n   (TMDS_IN_clk_n),
        .TMDS_Data_p  (TMDS_IN_data_p),
        .TMDS_Data_n  (TMDS_IN_data_n),

        .RefClk       (ref_clk),
        .aRst         (btn_rst),

        .vid_pData    (vid_data),
        .vid_pVDE     (vid_vde),
        .vid_pHSync   (vid_hsync),
        .vid_pVSync   (vid_vsync),
        .PixelClk     (pixel_clk),
        .aPixelClkLckd(),
        .pLocked      (rx_locked),

        .SDA_I        (ddc_sda_i),
        .SDA_O        (ddc_sda_o),
        .SDA_T        (ddc_sda_t),
        .SCL_I        (ddc_scl_i),
        .SCL_O        (ddc_scl_o),
        .SCL_T        (ddc_scl_t),

        .pRst         (1'b0)
    );

    // ------------------------------------------------------------
    // rgb2dvi instance — parallel RGB + sync + clk → TMDS TX
    //
    // kGenerateSerialClk=false because we reuse the SerialClk that dvi2rgb
    // already generates (same pixel-clock domain, no second MMCM needed).
    // ------------------------------------------------------------
    // rgb2dvi generates its own SerialClk internally (kGenerateSerialClk=true);
    // the wrapper drops the SerialClk input port when that parameter is set.
    rgb2dvi_0 dvi_tx_inst (
        .TMDS_Clk_p   (TMDS_OUT_clk_p),
        .TMDS_Clk_n   (TMDS_OUT_clk_n),
        .TMDS_Data_p  (TMDS_OUT_data_p),
        .TMDS_Data_n  (TMDS_OUT_data_n),

        .aRst         (btn_rst),

        .vid_pData    (vid_data),
        .vid_pVDE     (vid_vde),
        .vid_pHSync   (vid_hsync),
        .vid_pVSync   (vid_vsync),
        .PixelClk     (pixel_clk)
    );

    // ------------------------------------------------------------
    // Status LEDs — observable from across the bench:
    //   LD0 = MMCM locked (refclk valid)
    //   LD1 = dvi2rgb locked (HDMI source detected + pixel clock stable)
    //   LD2 = vid_pVDE (active video — flickers when source is alive)
    //   LD3 = downstream sink HPD (monitor is plugged in)
    // ------------------------------------------------------------
    // LD2 is in the pixel-clock domain; we synchronize a single-bit observation to sys_clk
    // for the LED, then divide so it's perceptibly slow.
    reg [23:0] vde_counter = 24'd0;
    always @(posedge pixel_clk) begin
        if (vid_vde) vde_counter <= vde_counter + 24'd1;
    end

    assign leds = {hdmi_tx_hpd, vde_counter[23], rx_locked, mmcm_locked};

endmodule

`default_nettype wire
