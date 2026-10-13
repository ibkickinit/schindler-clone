// sdi_hd_tx_top.v — HD-SDI / 3G-SDI Level A transmit datapath: raster timing -> 75% bars -> framer
// (TRS, LN, CRC, ST 352) -> scrambler/NRZI -> 20-bit parallel word for a GTH TX.
//   HD-SDI  1080p23.98-30: clk 74.25 (/1.001) MHz -> 1.485 (/1.001) Gb/s, PID_B1 0x85
//   3G-A    1080p50-60:    clk 148.5 (/1.001) MHz -> 2.97  (/1.001) Gb/s, PID_B1 0x89
// Same RTL; the format is set by raster parameters, clock rate and payload ID bytes.
//
// txdata[9:0]  = C word, txdata[19:10] = Y word, bit 0 first on the wire — the HD-SDI word order is
// C0 Y0 C1 Y1 ... (Cb0 Y0 Cr0 Y1 ...). Connect txdata to GTH TXDATA[19:0] (20-bit internal datapath,
// 8b10b off, TXUSRCLK2 = clk = 74.25 (HD) or 148.5 (3G-A) MHz, or /1.001). Latency h -> txdata: 2 clocks.
//
// The GTH itself is generated in Vivado with the free Transceiver Wizard (settings in docs/12). This
// module is vendor-neutral RTL so it can also be simulated with Icarus (sim/sdi_tx/run_iverilog.sh).
// Self-contained on purpose: no Crossover or Schindler dependencies, so either product can vendor it.

`default_nettype none
`timescale 1ns / 1ps

module sdi_hd_tx_top #(
    parameter integer H_ACT       = 1920,
    parameter integer H_TOT       = 2200,
    parameter integer V_TOT       = 1125,
    parameter integer V_ACT_FIRST = 42,
    parameter integer V_ACT_LAST  = 1121,
    parameter integer PID_EN      = 1,
    parameter integer PID_LINE    = 10,
    parameter [7:0]   PID_B1      = 8'h85,
    parameter [7:0]   PID_B2      = 8'hC7,
    parameter [7:0]   PID_B3      = 8'h00,
    parameter [7:0]   PID_B4      = 8'h01
) (
    input  wire        clk,                 // word clock: 74.25 (HD) or 148.5 (3G-A) MHz, or /1.001
    input  wire        rst,                 // synchronous, active high
    output wire [19:0] txdata,              // to GTH TXDATA
    // debug / test taps
    output wire [9:0]  dbg_y,
    output wire [9:0]  dbg_c,
    output wire [11:0] dbg_h,
    output wire [10:0] dbg_ln
);
    wire [11:0] h;
    wire [10:0] ln;
    wire [9:0]  bar_y, bar_c;
    wire [9:0]  y, c;

    sdi_hd_timing #(.H_ACT(H_ACT), .H_TOT(H_TOT), .V_TOT(V_TOT)) u_tim (
        .clk(clk), .rst(rst), .h(h), .ln(ln));

    sdi_bars_hd #(.H_ACT(H_ACT)) u_bars (.h(h), .y(bar_y), .c(bar_c));

    sdi_hd_framer #(.H_ACT(H_ACT), .H_TOT(H_TOT), .V_TOT(V_TOT),
                    .V_ACT_FIRST(V_ACT_FIRST), .V_ACT_LAST(V_ACT_LAST),
                    .PID_EN(PID_EN), .PID_LINE(PID_LINE),
                    .PID_B1(PID_B1), .PID_B2(PID_B2), .PID_B3(PID_B3), .PID_B4(PID_B4)) u_frm (
        .clk(clk), .rst(rst), .h(h), .ln(ln), .y_in(bar_y), .c_in(bar_c), .y_out(y), .c_out(c));

    sdi_scrambler #(.W(20)) u_scr (.clk(clk), .rst(rst), .din({y, c}), .dout(txdata));

    assign dbg_y  = y;
    assign dbg_c  = c;
    assign dbg_h  = h;
    assign dbg_ln = ln;
endmodule

`default_nettype wire
