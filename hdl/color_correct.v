// color_correct.v — RGB white-balance / color-temperature affine transform.
//
// Per-channel diagonal-matrix correction:
//   out_c = ((in_c * (white_c - black_c)) >> 8) + black_c
// where in_c is the input pixel's channel (0..255), white_c is the user's
// desired RGB code for "white" (per channel), and black_c is the user's
// desired RGB code for "black" (per channel).
//
// User intent map:
//   white = (255,255,255), black = (0,0,0)      → identity, no correction
//   white = (255,240,200), black = (0,0,0)      → warmer tint (3200K-ish)
//   white = (220,240,255), black = (0,0,0)      → cooler tint (9300K-ish)
//   white = (255,255,255), black = (8,8,8)      → raised black floor
//   white = (240,240,240), black = (16,16,16)   → limited-range output
//
// Constraints: caller (firmware) MUST ensure white_c ≥ black_c per channel
// (the subtract assumes unsigned 8-bit positive result). Output range
// becomes [black_c, white_c] ⊆ [0,255], no saturation needed.
//
// 1-cycle AXIS pipeline (same shape as scaler_bypass / scaler_passthrough).
// Combinational math is one 8×8 multiplier per channel (3 DSP slices) plus
// adders, well within 74.25 MHz pclk_out timing.
//
// Async params come from AXI GPIO (FCLK_CLK0 domain). Internal 2-FF
// synchronizers with ASYNC_REG=TRUE handle the CDC.

`default_nettype none
`timescale 1ns / 1ps

module color_correct (
    input  wire        aclk,
    input  wire        aresetn,

    // AXIS slave
    input  wire [23:0] s_axis_tdata,    // [23:16]=R, [15:8]=G, [7:0]=B
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    // AXIS master
    output reg  [23:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser,

    // Async color parameters (FCLK_CLK0 domain via AXI GPIO 3).
    input  wire [7:0]  black_r_async,
    input  wire [7:0]  black_g_async,
    input  wire [7:0]  black_b_async,
    input  wire [7:0]  white_r_async,
    input  wire [7:0]  white_g_async,
    input  wire [7:0]  white_b_async
);
    // ---- 2-FF synchronizers (axi clock → aclk = pclk_out) ----
    (* ASYNC_REG = "TRUE" *) reg [7:0] br_q1, br_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] bg_q1, bg_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] bb_q1, bb_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] wr_q1, wr_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] wg_q1, wg_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] wb_q1, wb_q2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            br_q1 <= 8'd0;   br_q2 <= 8'd0;
            bg_q1 <= 8'd0;   bg_q2 <= 8'd0;
            bb_q1 <= 8'd0;   bb_q2 <= 8'd0;
            wr_q1 <= 8'd255; wr_q2 <= 8'd255;
            wg_q1 <= 8'd255; wg_q2 <= 8'd255;
            wb_q1 <= 8'd255; wb_q2 <= 8'd255;
        end else begin
            br_q1 <= black_r_async; br_q2 <= br_q1;
            bg_q1 <= black_g_async; bg_q2 <= bg_q1;
            bb_q1 <= black_b_async; bb_q2 <= bb_q1;
            wr_q1 <= white_r_async; wr_q2 <= wr_q1;
            wg_q1 <= white_g_async; wg_q2 <= wg_q1;
            wb_q1 <= white_b_async; wb_q2 <= wb_q1;
        end
    end

    // ---- Combinational color math (1 cycle, registers into output stage) ----
    // Pipeline byte layout determined empirically 2026-05-17 evening:
    //   tdata[23:16] = R   tdata[15:8] = B   tdata[7:0] = G  (R-B-G, not RGB)
    // White=(255,180,100) made the image pink/magenta which only matches if
    // green is in bits[7:0] and blue in bits[15:8]. dvi2rgb's kRGBMap or
    // v_vid_in_axi4s param produces this ordering through the pipeline.
    wire [7:0] in_r = s_axis_tdata[23:16];
    wire [7:0] in_b = s_axis_tdata[15:8];
    wire [7:0] in_g = s_axis_tdata[7:0];

    // Use signed subtract guarded against white < black (clamp diff to 0).
    // In normal operation firmware ensures white ≥ black, but a transient
    // GPIO write order could violate that briefly.
    wire [7:0] diff_r = (wr_q2 >= br_q2) ? (wr_q2 - br_q2) : 8'd0;
    wire [7:0] diff_g = (wg_q2 >= bg_q2) ? (wg_q2 - bg_q2) : 8'd0;
    wire [7:0] diff_b = (wb_q2 >= bb_q2) ? (wb_q2 - bb_q2) : 8'd0;

    wire [15:0] mul_r = in_r * diff_r;
    wire [15:0] mul_g = in_g * diff_g;
    wire [15:0] mul_b = in_b * diff_b;

    // (in * diff) >> 8 — approximates (in * diff) / 255 with <0.4% error.
    // Result is in [0, diff], so adding black gives [black, black+diff] =
    // [black, white]. No saturation needed.
    wire [7:0] out_r_comb = mul_r[15:8] + br_q2;
    wire [7:0] out_g_comb = mul_g[15:8] + bg_q2;
    wire [7:0] out_b_comb = mul_b[15:8] + bb_q2;

    // ---- AXIS register stage (1-deep, no skid — downstream is rgb2dvi-fed) ----
    assign s_axis_tready = !m_axis_tvalid || m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= 24'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                // Reassemble per the empirical R-B-G byte order (see note above).
                m_axis_tdata  <= {out_r_comb, out_b_comb, out_g_comb};
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
