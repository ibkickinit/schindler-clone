// color_saturation.v — single-knob saturation control via Rec.601 luma mix.
//
// Per-channel:  out_c = luma + s * (in_c - luma)
//   s = 0   : out = luma everywhere → grayscale
//   s = 255 : out ≈ in_c (identity, ~0.4% error from 255/256 vs 1.0)
//   s ∈ (0, 255) : partial desaturation
// (Oversaturation s > 1.0 would need 9-bit s; not exposed for now.)
//
// luma = 0.299·R + 0.587·G + 0.114·B with integer weights 76, 150, 30 (sum=256).
//
// 2-stage pipeline to keep timing comfortable at 74.25 MHz output pclk:
//   Stage 1: compute luma_int + diff_c per channel (3 mul + tree of adds + 3 sub).
//   Stage 2: compute scaled_c = (s * diff_c) >> 8, out_c = luma_int + scaled_c,
//            clamp to [0, 255].
//
// NOTE: Pipeline byte order is R-B-G per memory [[schindler-pipeline-rbg-byte-order]]:
//   tdata[23:16] = R   tdata[15:8] = B   tdata[7:0] = G
// (Discovered empirically during color_correct bring-up. NOT standard RGB.)
//
// Async sat input: 8-bit value from AXI GPIO (FCLK_CLK0 domain). Internal
// 2-FF synchronizer with ASYNC_REG handles CDC.

`default_nettype none
`timescale 1ns / 1ps

module color_saturation (
    input  wire        aclk,
    input  wire        aresetn,

    // AXIS slave
    input  wire [23:0] s_axis_tdata,
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

    // Async saturation factor — 16-bit Q1.15 fixed-point.
    //   0x0000 = grayscale (sat=0)
    //   0x4000 = 50% (sat=0.5)
    //   0x8000 = identity (sat=1.0)
    //   0xC000 = 150% (sat=1.5)
    //   0xFFFF ≈ 200% (sat=1.9999...)
    // Widened from 8-bit Q0.8 (2026-05-17 evening) to support oversaturation.
    input  wire [15:0] sat_async
);
    // ---- CDC: 2-FF synchronizer for sat ----
    (* ASYNC_REG = "TRUE" *) reg [15:0] sat_q1, sat_q2;
    always @(posedge aclk) begin
        if (!aresetn) begin
            sat_q1 <= 16'h8000; sat_q2 <= 16'h8000;  // boot at identity (1.0)
        end else begin
            sat_q1 <= sat_async; sat_q2 <= sat_q1;
        end
    end

    // ---- Unpack per byte order (R-B-G) ----
    wire [7:0] in_r = s_axis_tdata[23:16];
    wire [7:0] in_b = s_axis_tdata[15:8];
    wire [7:0] in_g = s_axis_tdata[7:0];

    // ====================================================================
    // STAGE 1 — compute luma, then diff per channel
    // ====================================================================
    // Pipeline gating: stage1 advances when downstream pipeline isn't stalled.
    wire stage1_advance;
    wire stage2_advance;

    // Stage 1 registers
    reg signed [9:0] s1_diff_r, s1_diff_g, s1_diff_b;
    reg [7:0]        s1_luma_int;
    reg [7:0]        s1_in_r, s1_in_g, s1_in_b;  // forward for clamp fallback
    reg              s1_valid;
    reg              s1_tlast, s1_tuser;

    // Combinational math for stage 1: luma weights 76, 150, 30 (Rec.601 / 256)
    wire [15:0] w_r = in_r * 8'd76;
    wire [15:0] w_g = in_g * 8'd150;
    wire [15:0] w_b = in_b * 8'd30;
    wire [16:0] luma_sum = w_r + w_g + w_b;   // 0 .. ~65536 (Q8.8)
    wire [7:0]  luma_int_comb = luma_sum[15:8];  // back to 8-bit integer

    wire signed [9:0] diff_r_comb = {2'b00, in_r} - {2'b00, luma_int_comb};
    wire signed [9:0] diff_b_comb = {2'b00, in_b} - {2'b00, luma_int_comb};
    wire signed [9:0] diff_g_comb = {2'b00, in_g} - {2'b00, luma_int_comb};

    // ====================================================================
    // STAGE 2 — compute scaled diff, sum with luma, clamp to [0, 255]
    // ====================================================================
    // sat (Q1.15, 17-bit unsigned after 1'b0 pad) × diff (10-bit signed) = 27-bit signed
    wire signed [26:0] scaled_r_full = $signed({1'b0, sat_q2}) * s1_diff_r;
    wire signed [26:0] scaled_g_full = $signed({1'b0, sat_q2}) * s1_diff_g;
    wire signed [26:0] scaled_b_full = $signed({1'b0, sat_q2}) * s1_diff_b;
    // (sat * diff) >> 15 — converts Q1.15 product back to integer.
    // At sat=2.0, diff=±255 → scaled in ±510 range, fits in 12-bit signed.
    wire signed [11:0] scaled_r = scaled_r_full[26:15];
    wire signed [11:0] scaled_g = scaled_g_full[26:15];
    wire signed [11:0] scaled_b = scaled_b_full[26:15];

    // out_c = luma_int + scaled_c, clamp to [0, 255]
    // scaled_c is 12-bit signed (-2048..+2047). luma_int is 8-bit unsigned (0..255).
    // Sum range: -2048..+2302. Fits in 13-bit signed.
    wire signed [12:0] sum_r = {5'b00000, s1_luma_int} + {scaled_r[11], scaled_r};
    wire signed [12:0] sum_g = {5'b00000, s1_luma_int} + {scaled_g[11], scaled_g};
    wire signed [12:0] sum_b = {5'b00000, s1_luma_int} + {scaled_b[11], scaled_b};

    wire [7:0] out_r_clamped = sum_r < 13'sd0    ? 8'd0   :
                                sum_r > 13'sd255  ? 8'd255 : sum_r[7:0];
    wire [7:0] out_g_clamped = sum_g < 13'sd0    ? 8'd0   :
                                sum_g > 13'sd255  ? 8'd255 : sum_g[7:0];
    wire [7:0] out_b_clamped = sum_b < 13'sd0    ? 8'd0   :
                                sum_b > 13'sd255  ? 8'd255 : sum_b[7:0];

    // ---- AXIS handshake with 2-stage pipeline ----
    // Stage 1 holds when stage 2 is full and not advancing
    assign s_axis_tready = !s1_valid || stage1_advance;
    assign stage1_advance = !m_axis_tvalid || m_axis_tready;
    assign stage2_advance = !m_axis_tvalid || m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s1_valid       <= 1'b0;
            s1_tlast       <= 1'b0;
            s1_tuser       <= 1'b0;
            s1_diff_r      <= 10'd0;
            s1_diff_g      <= 10'd0;
            s1_diff_b      <= 10'd0;
            s1_luma_int    <= 8'd0;
            s1_in_r        <= 8'd0;
            s1_in_g        <= 8'd0;
            s1_in_b        <= 8'd0;
            m_axis_tdata   <= 24'd0;
            m_axis_tvalid  <= 1'b0;
            m_axis_tlast   <= 1'b0;
            m_axis_tuser   <= 1'b0;
        end else begin
            // Stage 1 load
            if (s_axis_tvalid && s_axis_tready) begin
                s1_diff_r   <= diff_r_comb;
                s1_diff_g   <= diff_g_comb;
                s1_diff_b   <= diff_b_comb;
                s1_luma_int <= luma_int_comb;
                s1_in_r     <= in_r;
                s1_in_g     <= in_g;
                s1_in_b     <= in_b;
                s1_tlast    <= s_axis_tlast;
                s1_tuser    <= s_axis_tuser;
                s1_valid    <= 1'b1;
            end else if (stage1_advance) begin
                s1_valid    <= 1'b0;
                s1_tlast    <= 1'b0;
                s1_tuser    <= 1'b0;
            end

            // Stage 2 load (output stage)
            if (stage2_advance) begin
                if (s1_valid) begin
                    // Reassemble per R-B-G byte order
                    m_axis_tdata  <= {out_r_clamped, out_b_clamped, out_g_clamped};
                    m_axis_tlast  <= s1_tlast;
                    m_axis_tuser  <= s1_tuser;
                    m_axis_tvalid <= 1'b1;
                end else begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tuser  <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
