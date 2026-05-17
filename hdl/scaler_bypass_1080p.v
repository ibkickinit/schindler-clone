// scaler_bypass_1080p.v — iter5: true 1080p AXIS identity passthrough.
//
// Drop-in replacement for scaler_top in the iter5 substrate test. Port
// signature matches scaler_top so BD wiring stays identical:
//   create_bd_cell -type module -reference scaler_bypass_1080p scaler_0
//
// Unlike scaler_crop_bypass (which crops the top-left 1280×720), this module
// passes the entire frame through unchanged. With S2MM configured for 1920×1080
// frames, this lets us validate the iter4h S2MM over-allocate fix at the larger
// frame size without introducing scaler logic as a variable.
//
// 1-cycle AXIS register pipeline. Same handshake pattern as scaler_passthrough.
//
// `in_w_async`, `in_h_async`, `diag_counts` ports are stubbed — they exist only
// so the BD doesn't need different wiring for production vs. bypass builds.

`default_nettype none
`timescale 1ns / 1ps

module scaler_bypass_1080p #(
    /* All parameters present for drop-in compatibility with scaler_top. None
     * affect behavior — this module just passes data through. */
    parameter integer IN_W_DEFAULT = 1920,
    parameter integer IN_H_DEFAULT = 1080,
    parameter integer OUT_W  = 1920,
    parameter integer OUT_H  = 1080,
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

    /* Runtime source dimensions from firmware via AXI GPIO. Unused here;
     * pass-through is dimension-agnostic. */
    input  wire [15:0] in_w_async,
    input  wire [15:0] in_h_async,

    /* scaler_top exposes 48-bit diag counters. Tied low here; firmware will
     * see zeros for h_in/v_in/v_emit during the bypass test. */
    output wire [47:0] diag_counts
);
    /* Suppress unused-input warnings without dropping ports. */
    wire _stub_keep = |{in_w_async, in_h_async};
    assign diag_counts = 48'd0;

    /* Standard 1-deep AXIS register stage. Slave-side ready when output is
     * empty or about to drain. Downstream axis_data_fifo gives us back-
     * pressure absorption so a non-skid register here is fine. */
    assign s_axis_tready = !m_axis_tvalid || m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= 24'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                m_axis_tdata  <= s_axis_tdata;
                m_axis_tlast  <= s_axis_tlast;
                m_axis_tuser  <= s_axis_tuser;
                m_axis_tvalid <= 1'b1;
            end else if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                m_axis_tuser  <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
