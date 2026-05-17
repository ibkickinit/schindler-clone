// scaler_crop_bypass.v — iter4h diagnostic: drop-in replacement for scaler_top
// that crops the source's top-left 1280x720 region instead of scaling. Output
// framing matches what S2MM expects (1280 pixels per row, 720 rows per frame,
// TUSER on pixel 0 of frame, TLAST on pixel 1279 of each output row).
//
// Purpose: bisect the bottom-bars-artifact debug. If the artifact appears with
// this crop in place, the scaler is innocent and the bug is downstream (FIFO,
// S2MM, DDR3, or some integration issue). If the artifact disappears, the bug
// IS in scaler_h/scaler_v despite sim showing them clean.
//
// Same port shape as scaler_top so swapping is one line in tcl/build_phase_b.tcl:
//   create_bd_cell -type module -reference scaler_top scaler_0
// becomes
//   create_bd_cell -type module -reference scaler_crop_bypass scaler_0
//
// in_w_async/in_h_async/diag_counts ports are stubbed (unused) — keeps the BD
// wiring identical so we don't need to touch the rest of the build TCL.

`default_nettype none
`timescale 1ns / 1ps

module scaler_crop_bypass #(
    /* All parameters present for drop-in-compatibility with scaler_top, but
     * only OUT_W/OUT_H actually matter — those define the crop window. */
    parameter integer IN_W_DEFAULT = 1920,
    parameter integer IN_H_DEFAULT = 1080,
    parameter integer OUT_W  = 1280,
    parameter integer OUT_H  =  720,
    parameter integer PHASES =   64,
    parameter integer TAPS_H =    8,
    parameter integer TAPS_V =    4
) (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    output reg  [23:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser,

    // Stub: scaler_top takes runtime IN_W/IN_H via GPIO. We ignore them.
    input  wire [15:0] in_w_async,
    input  wire [15:0] in_h_async,

    // Stub: scaler_top exposes 48-bit diag counters. Tie low; firmware will
    // read zeros for h_in/v_in/v_emit during the bypass test.
    output wire [47:0] diag_counts
);
    /* Suppress unused-input warnings without dropping ports. */
    wire _stub_keep = |{in_w_async, in_h_async};
    assign diag_counts = 48'd0;

    /* Always ready — input is consumed every cycle, but we only EMIT during
     * the top-left 1280x720 crop window. This matches scaler_v's
     * tready=1 model; back-pressure on output is handled by m_axis_tvalid
     * gating. */
    assign s_axis_tready = 1'b1;

    /* Track input position. in_col counts 0..IN_W-1 within each source row;
     * in_row counts 0..IN_H-1 within each source frame. Reset on TUSER. */
    reg [11:0] in_col;
    reg [11:0] in_row;

    /* Crop window: emit iff in_col < OUT_W && in_row < OUT_H. Generated
     * combinationally so we can also drive tlast/tuser on the same cycle. */
    wire in_crop_window  = (in_col < OUT_W) && (in_row < OUT_H);
    wire is_first_pixel  = (in_col == 0) && (in_row == 0);
    wire is_last_in_row  = (in_col == OUT_W - 1);

    always @(posedge aclk) begin
        if (!aresetn) begin
            in_col        <= 12'd0;
            in_row        <= 12'd0;
            m_axis_tdata  <= 24'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end else begin
            /* Clear master-side valid when downstream takes a beat. */
            if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                m_axis_tuser  <= 1'b0;
            end

            /* Input handshake: update position + maybe emit. */
            if (s_axis_tvalid && s_axis_tready) begin
                if (s_axis_tuser) begin
                    in_col <= 12'd0;
                    in_row <= 12'd0;
                end else if (s_axis_tlast) begin
                    in_col <= 12'd0;
                    in_row <= in_row + 12'd1;
                end else begin
                    in_col <= in_col + 12'd1;
                end

                /* Emit if this pixel is inside the crop window. TUSER on the
                 * first emitted pixel of frame; TLAST on the last col of each
                 * emitted row. */
                if (in_crop_window) begin
                    m_axis_tdata  <= s_axis_tdata;
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= is_last_in_row;
                    m_axis_tuser  <= is_first_pixel;
                end
            end
        end
    end
endmodule

`default_nettype wire
