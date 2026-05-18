// rgb_to_ycbcr.v — RGB → YCbCr colorspace conversion, 4 selectable modes.
//
// Per pixel:
//   Y  = a00·R + a01·G + a02·B + off_Y
//   Cb = a10·R + a11·G + a12·B + 128
//   Cr = a20·R + a21·G + a22·B + 128
//
// All coefficients are signed Q2.14 baked into the HDL — no GPIO needed for
// coefs. The MODE input (2-bit, via axi_gpio) selects one of four lookup
// tables at runtime:
//
//   MODE[1:0] | Standard         | Y range   | Cb/Cr range
//   ----------+------------------+-----------+-----------
//     00      | Rec.601 limited  | 16..235   | 16..240    (NTSC/PAL analog default)
//     01      | Rec.601 full     | 0..255    | 0..255     (PC / digital intermediates)
//     10      | Rec.709 limited  | 16..235   | 16..240    (HD analog 720p/1080i)
//     11      | Rec.709 full     | 0..255    | 0..255     (HD PC)
//
// 3-stage AXIS pipeline (multiply / row sum / shift+offset+clamp), matches
// color_matrix structurally. ~9 DSPs.
//
// INPUT byte order: pipeline convention R-B-G per [[schindler-pipeline-rbg-byte-order]]:
//   s_axis_tdata[23:16] = R   [15:8] = B   [7:0] = G
//
// OUTPUT byte order: standard YCbCr packing:
//   m_axis_tdata[23:16] = Y   [15:8] = Cb   [7:0] = Cr
//
// (Output deliberately breaks from R-B-G convention — this module exits
// the RGB-domain Schindler pipeline. Downstream is ycbcr_444_to_422 + the
// analog encoder path, neither of which uses R-B-G order.)

`default_nettype none
`timescale 1ns / 1ps

module rgb_to_ycbcr (
    input  wire        aclk,
    input  wire        aresetn,

    // AXIS slave (RGB 4:4:4 in R-B-G byte order)
    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    // AXIS master (YCbCr 4:4:4 in Y-Cb-Cr byte order)
    output reg  [23:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser,

    // Mode selector (async from FCLK_CLK0 via GPIO)
    input  wire [1:0]  mode_async
);

    // ====================================================================
    // CDC: 2-FF synchronizer on mode
    // ====================================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] mode_q1, mode_q2;
    always @(posedge aclk) begin
        if (!aresetn) begin
            mode_q1 <= 2'b00;
            mode_q2 <= 2'b00;
        end else begin
            mode_q1 <= mode_async;
            mode_q2 <= mode_q1;
        end
    end

    // ====================================================================
    // Coefficient ROM — selected by mode_q2
    // ====================================================================
    // Q2.14 signed values for the 9 matrix entries + 3 offsets per mode.
    //
    // Rec.601 limited (CCIR 601):
    //   Y  = 0.257·R + 0.504·G + 0.098·B + 16
    //   Cb = -0.148·R - 0.291·G + 0.439·B + 128
    //   Cr = 0.439·R - 0.368·G - 0.071·B + 128
    //
    // Rec.601 full (JPEG/JFIF):
    //   Y  = 0.299·R + 0.587·G + 0.114·B + 0
    //   Cb = -0.169·R - 0.331·G + 0.500·B + 128
    //   Cr = 0.500·R - 0.419·G - 0.081·B + 128
    //
    // Rec.709 limited:
    //   Y  = 0.183·R + 0.614·G + 0.062·B + 16
    //   Cb = -0.101·R - 0.339·G + 0.439·B + 128
    //   Cr = 0.439·R - 0.399·G - 0.040·B + 128
    //
    // Rec.709 full:
    //   Y  = 0.2126·R + 0.7152·G + 0.0722·B + 0
    //   Cb = -0.1146·R - 0.3854·G + 0.5·B + 128
    //   Cr = 0.5·R - 0.4542·G - 0.0458·B + 128
    //
    // Constants are pre-computed in Q2.14 (×16384, rounded):

    reg signed [15:0] cY_R, cY_G, cY_B;
    reg signed [15:0] cCb_R, cCb_G, cCb_B;
    reg signed [15:0] cCr_R, cCr_G, cCr_B;
    reg signed [8:0]  off_Y;   // 9-bit signed: covers -16..+16 cleanly

    always @(*) begin
        case (mode_q2)
            2'b00: begin // Rec.601 limited
                cY_R  =  16'sd4211;   cY_G  =  16'sd8258;   cY_B  =  16'sd1606;
                cCb_R = -16'sd2425;   cCb_G = -16'sd4768;   cCb_B =  16'sd7193;
                cCr_R =  16'sd7193;   cCr_G = -16'sd6030;   cCr_B = -16'sd1163;
                off_Y =  9'sd16;
            end
            2'b01: begin // Rec.601 full
                cY_R  =  16'sd4899;   cY_G  =  16'sd9617;   cY_B  =  16'sd1868;
                cCb_R = -16'sd2770;   cCb_G = -16'sd5422;   cCb_B =  16'sd8192;
                cCr_R =  16'sd8192;   cCr_G = -16'sd6865;   cCr_B = -16'sd1327;
                off_Y =  9'sd0;
            end
            2'b10: begin // Rec.709 limited
                cY_R  =  16'sd2998;   cY_G  =  16'sd10060;  cY_B  =  16'sd1016;
                cCb_R = -16'sd1655;   cCb_G = -16'sd5555;   cCb_B =  16'sd7193;
                cCr_R =  16'sd7193;   cCr_G = -16'sd6537;   cCr_B = -16'sd656;
                off_Y =  9'sd16;
            end
            2'b11: begin // Rec.709 full
                cY_R  =  16'sd3484;   cY_G  =  16'sd11718;  cY_B  =  16'sd1183;
                cCb_R = -16'sd1878;   cCb_G = -16'sd6315;   cCb_B =  16'sd8192;
                cCr_R =  16'sd8192;   cCr_G = -16'sd7442;   cCr_B = -16'sd750;
                off_Y =  9'sd0;
            end
        endcase
    end

    // ====================================================================
    // Unpack R/B/G from R-B-G pipeline byte order; extend to 9-bit signed
    // ====================================================================
    wire [7:0] in_r = s_axis_tdata[23:16];
    wire [7:0] in_b = s_axis_tdata[15:8];
    wire [7:0] in_g = s_axis_tdata[7:0];

    wire signed [8:0] sin_r = $signed({1'b0, in_r});
    wire signed [8:0] sin_g = $signed({1'b0, in_g});
    wire signed [8:0] sin_b = $signed({1'b0, in_b});

    // ====================================================================
    // STAGE 1 — 9 parallel multiplies + AXIS handshake
    // ====================================================================
    reg signed [24:0] s1_p_y0, s1_p_y1, s1_p_y2;     // Y row partial products
    reg signed [24:0] s1_p_cb0, s1_p_cb1, s1_p_cb2;  // Cb row partial products
    reg signed [24:0] s1_p_cr0, s1_p_cr1, s1_p_cr2;  // Cr row partial products
    reg signed [8:0]  s1_off_y;
    reg               s1_valid, s1_tlast, s1_tuser;

    wire stage1_advance;
    wire stage2_advance;
    wire stage3_advance;

    assign stage1_advance = !s1_valid || stage2_advance;
    assign s_axis_tready  = stage1_advance;   // AXIS-clean: tready independent of tvalid

    always @(posedge aclk) begin
        if (!aresetn) begin
            s1_valid <= 1'b0;
            s1_tlast <= 1'b0;
            s1_tuser <= 1'b0;
        end else begin
            if (s_axis_tvalid && stage1_advance) begin
                s1_p_y0  <= cY_R  * sin_r;
                s1_p_y1  <= cY_G  * sin_g;
                s1_p_y2  <= cY_B  * sin_b;
                s1_p_cb0 <= cCb_R * sin_r;
                s1_p_cb1 <= cCb_G * sin_g;
                s1_p_cb2 <= cCb_B * sin_b;
                s1_p_cr0 <= cCr_R * sin_r;
                s1_p_cr1 <= cCr_G * sin_g;
                s1_p_cr2 <= cCr_B * sin_b;
                s1_off_y <= off_Y;
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
    // STAGE 2 — row sums
    // ====================================================================
    reg signed [26:0] s2_sum_y, s2_sum_cb, s2_sum_cr;
    reg signed [8:0]  s2_off_y;
    reg               s2_valid, s2_tlast, s2_tuser;

    assign stage2_advance = !s2_valid || stage3_advance;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s2_valid <= 1'b0;
            s2_tlast <= 1'b0;
            s2_tuser <= 1'b0;
        end else begin
            if (s1_valid && stage2_advance) begin
                s2_sum_y  <= s1_p_y0  + s1_p_y1  + s1_p_y2;
                s2_sum_cb <= s1_p_cb0 + s1_p_cb1 + s1_p_cb2;
                s2_sum_cr <= s1_p_cr0 + s1_p_cr1 + s1_p_cr2;
                s2_off_y  <= s1_off_y;
                s2_tlast  <= s1_tlast;
                s2_tuser  <= s1_tuser;
                s2_valid  <= 1'b1;
            end else if (stage2_advance) begin
                s2_valid  <= 1'b0;
                s2_tlast  <= 1'b0;
                s2_tuser  <= 1'b0;
            end
        end
    end

    // ====================================================================
    // STAGE 3 — shift right 14, add offset, clamp [0, 255], output
    // ====================================================================
    // Q2.14 × 9-bit_signed → 25-bit. Sum of 3 → 27-bit. >>14 → 13-bit signed.
    // For YCbCr conversions, the result is naturally in [0, 255] when input
    // is valid 8-bit RGB and coefs sum to ≤1.0 per row. Add offsets at the
    // shifted bit position, then clamp.

    wire signed [12:0] shifted_y  = s2_sum_y[26:14];
    wire signed [12:0] shifted_cb = s2_sum_cb[26:14];
    wire signed [12:0] shifted_cr = s2_sum_cr[26:14];

    // Add Y offset (sign-extended 9-bit) and the Cb/Cr +128 bias.
    wire signed [13:0] biased_y  = shifted_y  + $signed({{5{s2_off_y[8]}}, s2_off_y});
    wire signed [13:0] biased_cb = shifted_cb + 14'sd128;
    wire signed [13:0] biased_cr = shifted_cr + 14'sd128;

    wire [7:0] out_y  = (biased_y  < 14'sd0)   ? 8'd0   :
                        (biased_y  > 14'sd255) ? 8'd255 : biased_y[7:0];
    wire [7:0] out_cb = (biased_cb < 14'sd0)   ? 8'd0   :
                        (biased_cb > 14'sd255) ? 8'd255 : biased_cb[7:0];
    wire [7:0] out_cr = (biased_cr < 14'sd0)   ? 8'd0   :
                        (biased_cr > 14'sd255) ? 8'd255 : biased_cr[7:0];

    assign stage3_advance = !m_axis_tvalid || m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= 24'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end else begin
            if (s2_valid && stage3_advance) begin
                // Standard YCbCr packing: [23:16]=Y, [15:8]=Cb, [7:0]=Cr
                m_axis_tdata  <= {out_y, out_cb, out_cr};
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
