// fp_mon_detector.v — RAW capture of s2mm_frame_ptr_out behaviour.
//
// v4 (2026-06-03): earlier versions derived "decreased" from a mod-NUM_FRAMES model, but the
// bench showed the pointer takes values up to 7 (visited=0x15, max_slot=7) — NOT a clean 0..4
// framestore index. So the model was wrong; stop deriving flags from it and just LOG the raw
// values. This records a rolling 4-deep history of the robustly-debounced accepted pointer plus
// an OR-mask of every bit ever seen, so firmware can print the actual recent sequence and we can
// see what s2mm_frame_ptr_out really does (range, which bits move, monotonic or not).
//
// Clocked on FCLK_CLK0; frame_ptr_async (S2MM clock domain) brought over with a 2-FF sync + a
// STABLE_CYC-cycle stability filter (the pointer holds ~ms between frames, so real values pass;
// 1-2-cycle CDC transition glitches on this multi-bit binary signal are rejected).

`default_nettype none
`timescale 1ns / 1ps

module fp_mon_detector #(
    parameter integer NUM_FRAMES = 5,      // unused for the raw capture; kept for port compat
    parameter integer STABLE_CYC = 8
) (
    input  wire        clk,                // FCLK_CLK0
    input  wire        rstn,
    input  wire [5:0]  frame_ptr_async,    // s2mm_frame_ptr_out (async to clk)
    // 32-bit RAW capture:
    //   [5:0]   h0  — most-recent accepted value     [11:6]  h1
    //   [17:12] h2                                    [23:18] h3 (oldest of the 4)
    //   [29:24] or_mask — OR of every accepted value (which bits ever toggle)
    //   [30]    chg_seen (any change observed)        [31] spare
    output wire [31:0] mon
);
    // ---- 2-FF sync ----
    (* ASYNC_REG = "TRUE" *) reg [5:0] q1, q2;
    always @(posedge clk) begin
        if (!rstn) begin q1<=0; q2<=0; end
        else begin q1<=frame_ptr_async; q2<=q1; end
    end

    // ---- robust stability filter ----
    reg [5:0] cand, fp;
    reg [3:0] stbl;
    reg       seen;
    always @(posedge clk) begin
        if (!rstn) begin cand<=0; fp<=0; stbl<=0; seen<=0; end
        else if (q2 != cand) begin cand<=q2; stbl<=0; end
        else if (stbl < STABLE_CYC[3:0]) stbl<=stbl+4'd1;
        else if (!seen) begin seen<=1'b1; fp<=cand; end
        else fp<=cand;
    end

    // ---- rolling history of accepted values (shift on change) ----
    reg [5:0] h0, h1, h2, h3, fp_seen, or_mask;
    reg       seen2, chg_seen;
    always @(posedge clk) begin
        if (!rstn) begin h0<=0;h1<=0;h2<=0;h3<=0; fp_seen<=0; or_mask<=0; seen2<=0; chg_seen<=0; end
        else if (seen) begin
            if (!seen2) begin seen2<=1'b1; fp_seen<=fp; h0<=fp; or_mask<=fp; end
            else if (fp != fp_seen) begin
                h3<=h2; h2<=h1; h1<=h0; h0<=fp;     // newest at h0
                or_mask <= or_mask | fp;
                chg_seen <= 1'b1;
                fp_seen <= fp;
            end
        end
    end

    assign mon = {1'b0, chg_seen, or_mask, h3, h2, h1, h0};
endmodule

`default_nettype wire
