// mackin_blender.v — Per-pixel temporal lerp between two AXIS streams.
//
// Math (per channel):
//   out_c = clamp( prev_c + ((alpha * (curr_c - prev_c) + 0x4000) >> 15), 0, 255 )
//
//   alpha: Q1.15 unsigned, 0..0x8000.
//     alpha = 0x0000 -> out = prev   (full repeat of previous frame)
//     alpha = 0x4000 -> 50/50 blend
//     alpha = 0x8000 -> out = curr   (full pass-through of current frame)
//
// Two synchronous AXIS slave inputs (s_curr, s_prev) — pixel pairs must
// arrive on the same cycle. AXIS handshake takes pixels only when BOTH
// inputs are valid, mirrors the downstream tready back to BOTH.
//
// 3-stage pipeline at 74.25 MHz:
//   Stage 1: capture pixels, compute signed diff per channel (curr - prev)
//   Stage 2: alpha * diff per channel + rounding bias
//   Stage 3: arith-shift >>15, add prev, clamp [0,255], pack output
//
// Byte order: pipeline carries R-B-G per [[schindler-pipeline-rbg-byte-order]]:
//   tdata[23:16]=R, [15:8]=B, [7:0]=G. The blender is channel-independent so
//   byte order is preserved end-to-end without unpacking, but we still split
//   into per-byte lanes for clarity.
//
// Alpha CDC: alpha_async arrives from FCLK_CLK0 (firmware writes axi_gpio).
// Internal 2-FF synchronizer with ASYNC_REG handles metastability.
//
// Bench-validated: TBD (overnight implementation 2026-05-18).

`default_nettype none
`timescale 1ns / 1ps

module mackin_blender (
    input  wire        aclk,
    input  wire        aresetn,

    // AXIS slave: current-frame pixels
    input  wire [23:0] s_curr_tdata,
    input  wire        s_curr_tvalid,
    output wire        s_curr_tready,
    input  wire        s_curr_tlast,
    input  wire        s_curr_tuser,

    // AXIS slave: previous-frame pixels
    input  wire [23:0] s_prev_tdata,
    input  wire        s_prev_tvalid,
    output wire        s_prev_tready,
    input  wire        s_prev_tlast,
    input  wire        s_prev_tuser,

    // AXIS master: blended output
    output reg  [23:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser,

    // Blend coefficient (Q1.15, 0..0x8000), async from FCLK_CLK0
    input  wire [15:0] alpha_async
);

    // ========================================================================
    // CDC: 2-FF synchronizer for alpha
    // ========================================================================
    (* ASYNC_REG = "TRUE" *) reg [15:0] alpha_q1, alpha_q2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            alpha_q1 <= 16'h8000;   // boot: out = curr (no-op blender)
            alpha_q2 <= 16'h8000;
        end else begin
            alpha_q1 <= alpha_async;
            alpha_q2 <= alpha_q1;
        end
    end

    // ========================================================================
    // AXIS handshake — tready depends ONLY on internal pipeline state, NEVER
    // on tvalid inputs. (Earlier version had tready=pair_valid && stage1_adv
    // which combinationally couples tready to tvalid. With axis_clone fanout
    // upstream that creates a closed comb loop: MM2S_tready = f(MM2S_tvalid).
    // Vivado synthesizes it but the resolved logic deadlocks intermittently.
    // Per AXIS spec: TREADY may be high while TVALID is low.)
    //
    // Capture (always-block below) only fires when BOTH tvalids high. With
    // axis_clone upstream (both inputs from same source), tvalids are always
    // equal — no risk of "accepted but not captured" pixel loss. For future
    // dual-VDMA wiring where the two streams may de-synchronize transiently,
    // skid buffers per input will be required (deferred until that iter).
    // ========================================================================
    wire pair_valid = s_curr_tvalid && s_prev_tvalid;
    wire stage1_advance;
    wire stage2_advance;
    wire stage3_advance;

    assign s_curr_tready = stage1_advance;
    assign s_prev_tready = stage1_advance;

    // ========================================================================
    // Channel unpacking (R-B-G byte order, but math is per-byte and order-blind)
    // ========================================================================
    wire [7:0] curr_r = s_curr_tdata[23:16];
    wire [7:0] curr_b = s_curr_tdata[15:8];
    wire [7:0] curr_g = s_curr_tdata[7:0];

    wire [7:0] prev_r = s_prev_tdata[23:16];
    wire [7:0] prev_b = s_prev_tdata[15:8];
    wire [7:0] prev_g = s_prev_tdata[7:0];

    // Signed extension for diff
    wire signed [9:0] curr_r_se = {2'b00, curr_r};
    wire signed [9:0] curr_b_se = {2'b00, curr_b};
    wire signed [9:0] curr_g_se = {2'b00, curr_g};
    wire signed [9:0] prev_r_se = {2'b00, prev_r};
    wire signed [9:0] prev_b_se = {2'b00, prev_b};
    wire signed [9:0] prev_g_se = {2'b00, prev_g};

    // ========================================================================
    // STAGE 1 — capture, compute diff
    // ========================================================================
    reg signed [9:0]  s1_diff_r, s1_diff_b, s1_diff_g;  // -255..+255
    reg [7:0]         s1_prev_r, s1_prev_b, s1_prev_g;  // forward prev for stage 3
    reg [15:0]        s1_alpha;
    reg               s1_valid;
    reg               s1_tlast, s1_tuser;

    assign stage1_advance = !s1_valid || stage2_advance;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s1_valid <= 1'b0;
            s1_tlast <= 1'b0;
            s1_tuser <= 1'b0;
        end else begin
            if (pair_valid && stage1_advance) begin
                s1_diff_r <= curr_r_se - prev_r_se;
                s1_diff_b <= curr_b_se - prev_b_se;
                s1_diff_g <= curr_g_se - prev_g_se;
                s1_prev_r <= prev_r;
                s1_prev_b <= prev_b;
                s1_prev_g <= prev_g;
                s1_alpha  <= alpha_q2;
                // tlast/tuser propagation: use s_curr's framing (both streams
                // should be aligned, but pick one as authoritative).
                s1_tlast  <= s_curr_tlast;
                s1_tuser  <= s_curr_tuser;
                s1_valid  <= 1'b1;
            end else if (stage1_advance) begin
                s1_valid  <= 1'b0;
                s1_tlast  <= 1'b0;
                s1_tuser  <= 1'b0;
            end
        end
    end

    // ========================================================================
    // STAGE 2 — alpha * diff per channel + rounding bias
    // ========================================================================
    // alpha (16-bit unsigned, treated as Q1.15) × diff (10-bit signed) =
    // 26-bit signed product. Range: |0x8000 * 255| = 0x7F8000 (about 8.36M)
    // fits in 24 bits + sign. Use 27-bit reg for headroom on the +0x4000 bias.
    //
    // Promote alpha to signed Q2.16 by zero-extending — value is in [0, 0x8000]
    // so MSB is always 0; signed multiply remains positive.

    reg signed [26:0] s2_p_r, s2_p_b, s2_p_g;   // alpha*diff + 0x4000
    reg [7:0]         s2_prev_r, s2_prev_b, s2_prev_g;
    reg               s2_valid;
    reg               s2_tlast, s2_tuser;

    wire signed [16:0] alpha_signed = {1'b0, s1_alpha};  // unsigned 0..0x8000

    assign stage2_advance = !s2_valid || stage3_advance;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s2_valid <= 1'b0;
            s2_tlast <= 1'b0;
            s2_tuser <= 1'b0;
        end else begin
            if (s1_valid && stage2_advance) begin
                s2_p_r <= alpha_signed * s1_diff_r + 27'sd16384;  // + 0x4000
                s2_p_b <= alpha_signed * s1_diff_b + 27'sd16384;
                s2_p_g <= alpha_signed * s1_diff_g + 27'sd16384;
                s2_prev_r <= s1_prev_r;
                s2_prev_b <= s1_prev_b;
                s2_prev_g <= s1_prev_g;
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

    // ========================================================================
    // STAGE 3 — arith-shift >>15, add prev, clamp [0,255], pack output
    // ========================================================================
    // Arithmetic shift right 15: bits [26:15] of the signed product+bias.
    // That gives a 12-bit signed value (sign-extended). Then add 9-bit unsigned
    // prev → 13-bit signed sum. Clamp to [0, 255].

    wire signed [11:0] shift_r = s2_p_r[26:15];
    wire signed [11:0] shift_b = s2_p_b[26:15];
    wire signed [11:0] shift_g = s2_p_g[26:15];

    wire signed [12:0] sum_r = shift_r + $signed({5'b00000, s2_prev_r});
    wire signed [12:0] sum_b = shift_b + $signed({5'b00000, s2_prev_b});
    wire signed [12:0] sum_g = shift_g + $signed({5'b00000, s2_prev_g});

    wire [7:0] out_r = (sum_r < 13'sd0)   ? 8'd0   :
                       (sum_r > 13'sd255) ? 8'd255 : sum_r[7:0];
    wire [7:0] out_b = (sum_b < 13'sd0)   ? 8'd0   :
                       (sum_b > 13'sd255) ? 8'd255 : sum_b[7:0];
    wire [7:0] out_g = (sum_g < 13'sd0)   ? 8'd0   :
                       (sum_g > 13'sd255) ? 8'd255 : sum_g[7:0];

    assign stage3_advance = !m_axis_tvalid || m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= 24'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end else begin
            if (s2_valid && stage3_advance) begin
                // Reassemble per R-B-G byte order
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
