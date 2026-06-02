// axis_mux2.v — 2:1 AXI-Stream mux (24-bit pixel), runtime select.
//
// Route-B integration: selects which producer feeds the color stack →
// axis_to_vid_io.  sel=0 → s0 (VDMA MM2S, proven full-size passthrough,
// the default at boot → zero regression). sel=1 → s1 (pg_read_engine_top,
// runtime geometry). The unselected input is back-pressured (tready=0).
//
// Single clock domain (output pixel clock). sel is a slow GPIO bit; it
// should only be toggled between frames (firmware does so during vblank).

`default_nettype none
`timescale 1ns / 1ps

module axis_mux2 (
    input  wire        clk,
    input  wire        sel,            // 0 = s0, 1 = s1

    input  wire [23:0] s0_tdata,
    input  wire        s0_tvalid,
    output wire        s0_tready,

    input  wire [23:0] s1_tdata,
    input  wire        s1_tvalid,
    output wire        s1_tready,

    output wire [23:0] m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready
);
    assign m_tdata   = sel ? s1_tdata  : s0_tdata;
    assign m_tvalid  = sel ? s1_tvalid : s0_tvalid;
    assign s0_tready = (sel == 1'b0) && m_tready;   // idle input is back-pressured
    assign s1_tready = (sel == 1'b1) && m_tready;
endmodule

`default_nettype wire
