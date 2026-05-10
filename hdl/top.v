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
    input  wire [1:0]  pattern_sel,
    output wire [7:0]  dac_pmod,
    output wire        mmcm_locked_led
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

    sample_gen sample_inst (
        .clk         (pixel_clk),
        .rst         (pixel_rst),
        .hsync       (hsync),
        .active      (active),
        .pixel_count (pixel_count),
        .pattern_sel (pattern_sel),
        .dac         (dac)
    );

    // 10-bit DAC code → 8-bit Pmod (drop 2 LSBs; coarser steps but full range).
    // Bit ordering: dac_pmod[7] is MSB → JC1; dac_pmod[0] is LSB → JC10.
    assign dac_pmod = dac[9:2];

    // Visible health indicator: LD0 lit means clock + reset are alive.
    assign mmcm_locked_led = mmcm_locked;

endmodule

`default_nettype wire
