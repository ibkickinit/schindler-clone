// vsync_cdc_pulse.v — CDC + rising-edge pulse generator.
//
// Brings a slow level signal (e.g. dvi2rgb's vid_pVSync) from one clock domain
// into another and emits a single dst_clk pulse on each rising edge in the
// synchronized signal.
//
// Used for Phase D iter-3 VTC alignment: source vsync from dvi2rgb runs on the
// 148.5 MHz recovered HDMI PixelClk. The output VTC (v_tc_tx) runs on the
// genlocked 74.25 MHz output pixel clock. Wiring the level signal directly
// would violate timing constraints; this module is the CDC layer.
//
// The level signal changes ~60 Hz, so a 2-FF synchronizer is overkill but
// cheap. A 3rd FF gives an extra cycle to compare against for edge detection.
// Glitch tolerance is not a concern — vsync is a clean ~5-line pulse.

`default_nettype none
`timescale 1ns / 1ps

module vsync_cdc_pulse (
    input  wire dst_clk,        // destination clock (~74.25 MHz output PixelClk)
    input  wire dst_rstn,       // dst_clk-domain active-low reset
    input  wire vsync_async,    // level signal from source domain (dvi2rgb vid_pVSync)
    output reg  pulse_out       // single dst_clk pulse on each rising edge
);

    (* ASYNC_REG = "TRUE" *) reg sync_q1;
    (* ASYNC_REG = "TRUE" *) reg sync_q2;
    reg sync_q3;

    always @(posedge dst_clk) begin
        if (!dst_rstn) begin
            sync_q1   <= 1'b0;
            sync_q2   <= 1'b0;
            sync_q3   <= 1'b0;
            pulse_out <= 1'b0;
        end else begin
            sync_q1   <= vsync_async;
            sync_q2   <= sync_q1;
            sync_q3   <= sync_q2;
            pulse_out <= sync_q2 && !sync_q3;
        end
    end

endmodule

`default_nettype wire
