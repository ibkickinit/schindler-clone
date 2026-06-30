// tsg_srcsel.v — write-side source mux (2026-06-28).
//
// Selects the parallel-video bundle feeding v_vid_in_axi4s between the dvi2rgb HDMI
// source (sel=0) and the internal pg_tsg test pattern (sel=1). Signal-for-signal the
// same bundle dvi2rgb presents: vid_data[23:0] + active/hsync/vsync.
//
// The two sources are each synchronous to the WRITE clock that is selected alongside
// them (tsg_clkmux switches the clock in lockstep with this select), so the muxed
// bundle is always in-domain with v_vid_in_axi4s's aclk (= the muxed write clock).
// The only cross-domain signal is the select itself (FCLK_CLK0 GPIO bit); it is
// 2-FF synchronized here into the write-clock domain (ASYNC_REG + XDC false-path on
// sel_q1_reg/D). Switching is masked by the write-path switch reset, so no reset is
// needed on this sync.
//
// HDMI mode (sel=0) is bit-for-bit the dvi2rgb bundle (a 2:1 mux selecting input 0).

`default_nettype none
`timescale 1ns / 1ps

module tsg_srcsel (
    input  wire        clk,          // muxed write clock (tsg_clkmux/clk_o)
    input  wire        sel_async,    // tsg_enable (FCLK_CLK0 GPIO; 0=HDMI, 1=TSG)

    input  wire [23:0] hdmi_data,
    input  wire        hdmi_active,
    input  wire        hdmi_hsync,
    input  wire        hdmi_vsync,

    input  wire [23:0] tsg_data,
    input  wire        tsg_active,
    input  wire        tsg_hsync,
    input  wire        tsg_vsync,

    output wire [23:0] vid_data,
    output wire        vid_active,
    output wire        vid_hsync,
    output wire        vid_vsync
);
    (* ASYNC_REG = "TRUE" *) reg sel_q1_reg, sel_q2_reg;
    always @(posedge clk) begin
        sel_q1_reg <= sel_async;
        sel_q2_reg <= sel_q1_reg;
    end
    wire s = sel_q2_reg;

    assign vid_data   = s ? tsg_data   : hdmi_data;
    assign vid_active = s ? tsg_active : hdmi_active;
    assign vid_hsync  = s ? tsg_hsync  : hdmi_hsync;
    assign vid_vsync  = s ? tsg_vsync  : hdmi_vsync;
endmodule

`default_nettype wire
