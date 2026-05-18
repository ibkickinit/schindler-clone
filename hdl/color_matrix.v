// color_matrix.v — General 3×3 color transform with per-channel offset.
//
// Per pixel:
//   out_r = clamp((m00·r + m01·g + m02·b) >> 14 + off_r, 0, 255)
//   out_g = clamp((m10·r + m11·g + m12·b) >> 14 + off_g, 0, 255)
//   out_b = clamp((m20·r + m21·g + m22·b) >> 14 + off_b, 0, 255)
//
// Coefficient format: signed Q2.14 (16-bit). Range ±2.0, step 1/16384.
//   Identity:     m00=m11=m22 = 0x4000 (1.0), others = 0
//   Saturation:   computed by firmware from a sat factor + Rec.601 luma weights
//   Hue rotation: trig-derived coefficients
//   RGB→YCbCr:    Rec.601 specific values (for Phase G analog out)
//   Sepia, etc.:  any matrix combination
//
// Offset format: signed 8-bit. Added AFTER the shift, BEFORE the clamp.
// Range ±127. Used for raised-black-floor / DC bias.
//
// 3-stage AXIS pipeline:
//   Stage 1: register input pixel + 9 parallel multiplies (1 DSP each).
//   Stage 2: register 3 row sums (each row = 3 partial-product sum).
//   Stage 3: register the shifted+biased+clamped output pixel.
//
// NOTE on byte order: pipeline uses tdata[23:16]=R, [15:8]=B, [7:0]=G per
// [[schindler-pipeline-rbg-byte-order]] memory. The matrix is still defined
// in canonical (R,G,B) terms — internal unpack/repack handles the layout.
//
// Coefficient async inputs come from AXI GPIO (FCLK_CLK0 domain). Internal
// 2-FF synchronizers with ASYNC_REG handle CDC.

`default_nettype none
`timescale 1ns / 1ps

module color_matrix (
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

    // Matrix coefficients (signed Q2.14)
    input  wire [15:0] m00_async, m01_async, m02_async,
    input  wire [15:0] m10_async, m11_async, m12_async,
    input  wire [15:0] m20_async, m21_async, m22_async,

    // Output offsets (signed 8-bit, integer)
    input  wire [7:0]  off_r_async, off_g_async, off_b_async
);
    // ====================================================================
    // CDC: 2-FF synchronizers for all 12 buses
    // ====================================================================
    (* ASYNC_REG = "TRUE" *) reg [15:0] m00_q1, m00_q2, m01_q1, m01_q2, m02_q1, m02_q2;
    (* ASYNC_REG = "TRUE" *) reg [15:0] m10_q1, m10_q2, m11_q1, m11_q2, m12_q1, m12_q2;
    (* ASYNC_REG = "TRUE" *) reg [15:0] m20_q1, m20_q2, m21_q1, m21_q2, m22_q1, m22_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0]  off_r_q1, off_r_q2, off_g_q1, off_g_q2, off_b_q1, off_b_q2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            // Reset to identity matrix (1.0 = 0x4000 in Q2.14)
            m00_q1 <= 16'h4000; m00_q2 <= 16'h4000;
            m01_q1 <= 16'h0000; m01_q2 <= 16'h0000;
            m02_q1 <= 16'h0000; m02_q2 <= 16'h0000;
            m10_q1 <= 16'h0000; m10_q2 <= 16'h0000;
            m11_q1 <= 16'h4000; m11_q2 <= 16'h4000;
            m12_q1 <= 16'h0000; m12_q2 <= 16'h0000;
            m20_q1 <= 16'h0000; m20_q2 <= 16'h0000;
            m21_q1 <= 16'h0000; m21_q2 <= 16'h0000;
            m22_q1 <= 16'h4000; m22_q2 <= 16'h4000;
            off_r_q1 <= 8'd0; off_r_q2 <= 8'd0;
            off_g_q1 <= 8'd0; off_g_q2 <= 8'd0;
            off_b_q1 <= 8'd0; off_b_q2 <= 8'd0;
        end else begin
            m00_q1 <= m00_async; m00_q2 <= m00_q1;
            m01_q1 <= m01_async; m01_q2 <= m01_q1;
            m02_q1 <= m02_async; m02_q2 <= m02_q1;
            m10_q1 <= m10_async; m10_q2 <= m10_q1;
            m11_q1 <= m11_async; m11_q2 <= m11_q1;
            m12_q1 <= m12_async; m12_q2 <= m12_q1;
            m20_q1 <= m20_async; m20_q2 <= m20_q1;
            m21_q1 <= m21_async; m21_q2 <= m21_q1;
            m22_q1 <= m22_async; m22_q2 <= m22_q1;
            off_r_q1 <= off_r_async; off_r_q2 <= off_r_q1;
            off_g_q1 <= off_g_async; off_g_q2 <= off_g_q1;
            off_b_q1 <= off_b_async; off_b_q2 <= off_b_q1;
        end
    end

    // ====================================================================
    // Unpack R/G/B from R-B-G pipeline byte order
    // ====================================================================
    wire [7:0] in_r = s_axis_tdata[23:16];
    wire [7:0] in_b = s_axis_tdata[15:8];
    wire [7:0] in_g = s_axis_tdata[7:0];

    // Promote to 9-bit signed positives for clean signed × signed multiply
    wire signed [8:0] sin_r = $signed({1'b0, in_r});
    wire signed [8:0] sin_g = $signed({1'b0, in_g});
    wire signed [8:0] sin_b = $signed({1'b0, in_b});

    wire signed [15:0] sm00 = $signed(m00_q2);
    wire signed [15:0] sm01 = $signed(m01_q2);
    wire signed [15:0] sm02 = $signed(m02_q2);
    wire signed [15:0] sm10 = $signed(m10_q2);
    wire signed [15:0] sm11 = $signed(m11_q2);
    wire signed [15:0] sm12 = $signed(m12_q2);
    wire signed [15:0] sm20 = $signed(m20_q2);
    wire signed [15:0] sm21 = $signed(m21_q2);
    wire signed [15:0] sm22 = $signed(m22_q2);

    // ====================================================================
    // STAGE 1: parallel 9 multiplies (registered)
    // ====================================================================
    // 16-bit signed × 9-bit signed = 25-bit signed product
    reg signed [24:0] s1_p_r0, s1_p_r1, s1_p_r2;   // R-row partial products
    reg signed [24:0] s1_p_g0, s1_p_g1, s1_p_g2;
    reg signed [24:0] s1_p_b0, s1_p_b1, s1_p_b2;
    reg               s1_valid, s1_tlast, s1_tuser;
    reg [7:0]         s1_off_r, s1_off_g, s1_off_b;  // forward offsets

    wire stage1_advance = !s1_valid || stage2_advance;
    wire stage2_advance;

    assign s_axis_tready = stage1_advance;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s1_valid <= 1'b0;
            s1_tlast <= 1'b0;
            s1_tuser <= 1'b0;
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                s1_p_r0 <= sm00 * sin_r;
                s1_p_r1 <= sm01 * sin_g;
                s1_p_r2 <= sm02 * sin_b;
                s1_p_g0 <= sm10 * sin_r;
                s1_p_g1 <= sm11 * sin_g;
                s1_p_g2 <= sm12 * sin_b;
                s1_p_b0 <= sm20 * sin_r;
                s1_p_b1 <= sm21 * sin_g;
                s1_p_b2 <= sm22 * sin_b;
                s1_off_r <= off_r_q2;
                s1_off_g <= off_g_q2;
                s1_off_b <= off_b_q2;
                s1_tlast <= s_axis_tlast;
                s1_tuser <= s_axis_tuser;
                s1_valid <= 1'b1;
            end else if (stage1_advance) begin
                s1_valid <= 1'b0;
                s1_tlast <= 1'b0;
                s1_tuser <= 1'b0;
            end
        end
    end

    // ====================================================================
    // STAGE 2: row sums (registered)
    // ====================================================================
    // Sum of three 25-bit signed → up to ~27-bit signed
    reg signed [26:0] s2_sum_r, s2_sum_g, s2_sum_b;
    reg               s2_valid, s2_tlast, s2_tuser;
    reg [7:0]         s2_off_r, s2_off_g, s2_off_b;

    assign stage2_advance = !s2_valid || stage3_advance;
    wire stage3_advance;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s2_valid <= 1'b0;
            s2_tlast <= 1'b0;
            s2_tuser <= 1'b0;
        end else begin
            if (s1_valid && stage2_advance) begin
                s2_sum_r <= s1_p_r0 + s1_p_r1 + s1_p_r2;
                s2_sum_g <= s1_p_g0 + s1_p_g1 + s1_p_g2;
                s2_sum_b <= s1_p_b0 + s1_p_b1 + s1_p_b2;
                s2_off_r <= s1_off_r;
                s2_off_g <= s1_off_g;
                s2_off_b <= s1_off_b;
                s2_tlast <= s1_tlast;
                s2_tuser <= s1_tuser;
                s2_valid <= 1'b1;
            end else if (stage2_advance) begin
                s2_valid <= 1'b0;
                s2_tlast <= 1'b0;
                s2_tuser <= 1'b0;
            end
        end
    end

    // ====================================================================
    // STAGE 3: shift right 14, add offset, clamp, output
    // ====================================================================
    // After >>14 the result is up to ~13-bit signed (max ±1530 from Q2.14
    // matrix × 8-bit pixel × 3 sum). Adding signed 8-bit offset stays within
    // 13-bit signed. Clamp to 8-bit unsigned [0, 255].
    wire signed [12:0] shifted_r = s2_sum_r[26:14];
    wire signed [12:0] shifted_g = s2_sum_g[26:14];
    wire signed [12:0] shifted_b = s2_sum_b[26:14];

    wire signed [13:0] biased_r = shifted_r + $signed({{6{s2_off_r[7]}}, s2_off_r});
    wire signed [13:0] biased_g = shifted_g + $signed({{6{s2_off_g[7]}}, s2_off_g});
    wire signed [13:0] biased_b = shifted_b + $signed({{6{s2_off_b[7]}}, s2_off_b});

    wire [7:0] out_r = biased_r < 14'sd0   ? 8'd0   :
                       biased_r > 14'sd255 ? 8'd255 : biased_r[7:0];
    wire [7:0] out_g = biased_g < 14'sd0   ? 8'd0   :
                       biased_g > 14'sd255 ? 8'd255 : biased_g[7:0];
    wire [7:0] out_b = biased_b < 14'sd0   ? 8'd0   :
                       biased_b > 14'sd255 ? 8'd255 : biased_b[7:0];

    assign stage3_advance = !m_axis_tvalid || m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= 24'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end else begin
            if (s2_valid && stage3_advance) begin
                // Reassemble R-B-G byte order
                m_axis_tdata  <= {out_r, out_b, out_g};
                m_axis_tlast  <= s2_tlast;
                m_axis_tuser  <= s2_tuser;
                m_axis_tvalid <= 1'b1;
            end else if (stage3_advance) begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                m_axis_tuser  <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
