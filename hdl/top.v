// top.v — Schindler 2.0 first-light top level
//
// Wires onboard 125 MHz oscillator → MMCM → 54 MHz pixel clock →
// vid_timing + sample_gen → 8 MSBs of DAC out to Pmod JC.
//
// Inputs:  sys_clk (K17, 125 MHz LVCMOS33)
//          btn_rst (K18, BTN0 — held to reset, released to run)
//          pattern_sel[1:0] (G15=SW0, P15=SW1 — selects gray/ramp/bars)
// Outputs: dac_pmod[7:0] → JC1..JC10  (R-2R DAC input, 8 MSBs of 10-bit DAC code)
//          mmcm_locked_led → LD0 (M14, lights when 54 MHz clock is stable)
//
// MMCM math: VCO = 125 × 27 / 5 = 675 MHz (legal range 600-1200 MHz),
//            CLKOUT0 = 675 / 12.5 = 54.000 MHz exact.

`default_nettype none
`timescale 1ns / 1ps

module top (
    input  wire        sys_clk,
    input  wire        btn_rst,
    input  wire [2:0]  pattern_sel,
    output wire [7:0]  dac_pmod,
    output wire        mmcm_locked_led,

    // Zynq PS-side ports (pass-through to system_wrapper).
    // No PL signals connect to the PS — it exists only so FSBL can boot.
    // All pin constraints are auto-applied by the Digilent Zybo Z7-20 board preset.
    inout  wire [14:0] DDR_addr,
    inout  wire [2:0]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [3:0]  DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire [3:0]  DDR_dqs_n,
    inout  wire [3:0]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb
);

    // ------------------------------------------------------------
    // Clocking — 125 MHz → 54 MHz via MMCME2_BASE
    // ------------------------------------------------------------
    wire pixel_clk_pre, pixel_clk;
    wire mmcm_clkfb_pre, mmcm_clkfb;
    wire mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKFBOUT_MULT_F   (27.000),  // M = 27
        .DIVCLK_DIVIDE     (5),       // D = 5
        .CLKOUT0_DIVIDE_F  (12.500),  // O = 12.5  → 54.000 MHz
        .CLKIN1_PERIOD     (8.000),   // 125 MHz period
        .CLKOUT0_PHASE     (0.000),
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKFBOUT_PHASE    (0.000),
        .STARTUP_WAIT      ("FALSE")
    ) mmcm_inst (
        .CLKIN1   (sys_clk),
        .CLKFBIN  (mmcm_clkfb),
        .CLKFBOUT (mmcm_clkfb_pre),
        .CLKOUT0  (pixel_clk_pre),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (btn_rst)
    );

    BUFG bufg_pixclk  (.I(pixel_clk_pre),   .O(pixel_clk));
    BUFG bufg_clkfb   (.I(mmcm_clkfb_pre),  .O(mmcm_clkfb));

    // ------------------------------------------------------------
    // Reset synchronizer (synchronous in pixel_clk domain)
    // Held HIGH until MMCM locks; releases ~4 cycles after lock.
    // ------------------------------------------------------------
    reg [3:0] rst_sync = 4'b1111;
    always @(posedge pixel_clk) begin
        if (btn_rst || !mmcm_locked) rst_sync <= 4'b1111;
        else                          rst_sync <= {rst_sync[2:0], 1'b0};
    end
    wire pixel_rst = rst_sync[3];

    // ------------------------------------------------------------
    // Video pipeline
    // ------------------------------------------------------------
    wire [11:0] pixel_count;
    wire [9:0]  line_count;
    wire        hsync, vsync, active, sof, sol;
    wire        sync_combined;
    wire [9:0]  dac;

    vid_timing timing_inst (
        .clk         (pixel_clk),
        .rst         (pixel_rst),
        .pixel_count (pixel_count),
        .line_count  (line_count),
        .hsync       (hsync),
        .vsync       (vsync),
        .active      (active),
        .sof         (sof),
        .sol         (sol)
    );

    // Generate the full VBI-aware sync waveform: pre/post-equalizing pulses,
    // broad V-sync, normal H-sync on active/blank lines. Drives sample_gen.
    vbi_gen vbi_inst (
        .pixel_count (pixel_count),
        .line_count  (line_count),
        .sync        (sync_combined)
    );

    sample_gen sample_inst (
        .clk         (pixel_clk),
        .rst         (pixel_rst),
        .sync        (sync_combined),
        .active      (active),
        .pixel_count (pixel_count),
        .pattern_sel (pattern_sel),
        .dac         (dac)
    );

    // ------------------------------------------------------------
    // Chroma subcarrier — produces 3.58 MHz burst on back porch
    // and (placeholder) active-video chroma offsets per pattern_sel.
    // ------------------------------------------------------------
    wire signed [10:0] chroma_offset;

    chroma_gen chroma_inst (
        .clk           (pixel_clk),
        .rst           (pixel_rst),
        .pixel_count   (pixel_count),
        .line_count    (line_count),
        .active        (active),
        .pattern_sel   (pattern_sel),
        .chroma_offset (chroma_offset)
    );

    // Sum luma + chroma with saturation, then truncate for 8-bit Pmod.
    // Bit ordering: dac_pmod[7] is MSB → JC1; dac_pmod[0] is LSB → JC10.
    // During sync, sample_gen drives dac=CODE_SYNC_TIP (0) and chroma_gen
    // outputs 0 (not in burst window, active=0), so sum=0=sync tip.
    // Clamping protects against overflow once active-video chroma is added.
    wire signed [11:0] dac_sum   = $signed({2'b00, dac}) + $signed({chroma_offset[10], chroma_offset});
    wire        [9:0]  dac_final = (dac_sum < 0)          ? 10'd0
                                 : (dac_sum > 12'sd1023)  ? 10'd1023
                                 : dac_sum[9:0];
    assign dac_pmod = dac_final[9:2];

    // Visible health indicator: LD0 lit means clock + reset are alive.
    assign mmcm_locked_led = mmcm_locked;

    // ------------------------------------------------------------
    // Zynq PS instance (block-design wrapper). No PL interconnect.
    // Pure inert — exists so the PS BootROM has an FSBL to run.
    // ------------------------------------------------------------
    system_wrapper system_i (
        .DDR_addr          (DDR_addr),
        .DDR_ba            (DDR_ba),
        .DDR_cas_n         (DDR_cas_n),
        .DDR_ck_n          (DDR_ck_n),
        .DDR_ck_p          (DDR_ck_p),
        .DDR_cke           (DDR_cke),
        .DDR_cs_n          (DDR_cs_n),
        .DDR_dm            (DDR_dm),
        .DDR_dq            (DDR_dq),
        .DDR_dqs_n         (DDR_dqs_n),
        .DDR_dqs_p         (DDR_dqs_p),
        .DDR_odt           (DDR_odt),
        .DDR_ras_n         (DDR_ras_n),
        .DDR_reset_n       (DDR_reset_n),
        .DDR_we_n          (DDR_we_n),
        .FIXED_IO_ddr_vrn  (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp  (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio      (FIXED_IO_mio),
        .FIXED_IO_ps_clk   (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb  (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb (FIXED_IO_ps_srstb)
    );

endmodule

`default_nettype wire
