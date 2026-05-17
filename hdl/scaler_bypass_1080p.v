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

    /* scaler_top exposes 48-bit diag counters. iter5 step 1 EOLEarly debug:
     * repurpose the slots to measure incoming AXIS line/frame boundaries.
     *   [15:0]  = pixels in last completed line  (should be 1920 for clean 1080p)
     *   [31:16] = lines in last completed frame  (should be 1080)
     *   [47:32] = max pixels-per-line observed   (sticky max; >1920 means TLAST late;
     *                                             <1920 means EOLEarly seen by S2MM)
     * Reset on TUSER (start of frame). 16-bit fields are plenty: max pixel/line
     * is bounded by HTOTAL (~2750 worst case for 1080p), max lines/frame by
     * VTOTAL (~1125). */
    output wire [47:0] diag_counts
);
    /* Suppress unused-input warnings without dropping ports. */
    wire _stub_keep = |{in_w_async, in_h_async};

    reg [15:0] px_running;          /* pixels in current line */
    reg [15:0] px_latched;          /* pixels in last completed line */
    reg [15:0] lines_running;       /* lines in current frame */
    reg [15:0] lines_latched;       /* lines in last completed frame */
    reg [15:0] max_px_running;      /* max pixels-per-line within current frame */
    reg [15:0] max_px_latched;      /* same, latched at TUSER */

    wire beat = s_axis_tvalid && s_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            px_running     <= 16'd0;
            px_latched     <= 16'd0;
            lines_running  <= 16'd0;
            lines_latched  <= 16'd0;
            max_px_running <= 16'd0;
            max_px_latched <= 16'd0;
        end else if (beat) begin
            if (s_axis_tuser) begin
                /* First pixel of new frame. Latch previous frame's line count
                 * and max-pixel-per-line. Reset everything. This beat itself
                 * is pixel 1 of line 0 of the new frame. */
                lines_latched  <= lines_running;
                max_px_latched <= max_px_running;
                lines_running  <= 16'd0;
                max_px_running <= 16'd0;
                px_running     <= 16'd1;
            end else if (s_axis_tlast) begin
                /* End of line. This beat counts toward the line. */
                px_latched     <= px_running + 16'd1;
                lines_running  <= lines_running + 16'd1;
                if ((px_running + 16'd1) > max_px_running)
                    max_px_running <= px_running + 16'd1;
                px_running     <= 16'd0;
            end else begin
                px_running <= px_running + 16'd1;
            end
        end
    end

    assign diag_counts = {max_px_latched, lines_latched, px_latched};

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
