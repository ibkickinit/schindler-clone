// fp_mon_detector.v — sticky monitor: does s2mm_frame_ptr_out ever DECREASE (mod N)?
//
// The entire pg_cadence (FRC cadence controller) safety argument rests on ONE physical
// assumption: the VDMA S2MM write pointer is forward-monotonic — frame_ptr never moves to
// an older framestore. (A decrease writes onto a slot a reader may be on; no read-side
// logic can prevent it — it breaks pg_genlock v2 too.) That assumption is load-bearing and
// must be VALIDATED, not assumed.
//
// An ILA window (<1 s) cannot confirm it: a decrease, if it ever happens, is a rare
// genlock-corner event, and a sub-second snapshot will miss it → false "monotonic" from
// absence of evidence. So this LATCHES it in fabric (sticky), read over AXI GPIO / UART,
// and runs for minutes/hours across genlock drift (the wrap) + resolution change + hot-plug.
// A clean `decreased==0` after sustained stress is real evidence.
//
// Clocked on FCLK_CLK0; frame_ptr_async (S2MM clock domain) is brought over with a 2-FF +
// 1-sample debounce so a multi-bit CDC transient cannot false-positive. A forward delta
// (mod N) greater than N/2 is the unambiguous signature of a real decrease (e.g. 2->1 at
// N=5 reads as +4); small forward deltas (+1/+2..) are normal advances/skips, tracked in
// max_delta to characterize the pointer's real motion.

`default_nettype none
`timescale 1ns / 1ps

module fp_mon_detector #(
    parameter integer NUM_FRAMES = 5
) (
    input  wire        clk,                // FCLK_CLK0
    input  wire        rstn,
    input  wire [5:0]  frame_ptr_async,    // s2mm_frame_ptr_out (async to clk)
    // 16-bit summary (drops into the diag GPIO's unused mm2s field):
    //   [0]      decreased  — STICKY: 1 if frame_ptr ever moved to an older slot
    //   [7:4]    max_delta  — largest forward step seen (1=normal, 2+=skip)
    //   [15:8]   changes    — low 8 bits of the frame_ptr-change count (liveness)
    output wire [15:0] mon
);
    // ---- 2-FF + debounce CDC ----
    (* ASYNC_REG = "TRUE" *) reg [5:0] q1, q2;
    reg [5:0] q3, fp;
    always @(posedge clk) begin
        if (!rstn) begin q1<=0; q2<=0; q3<=0; fp<=0; end
        else begin q1<=frame_ptr_async; q2<=q1; q3<=q2; if (q2==q3) fp<=q2; end
    end

    // ---- sticky decrease detector + skip characterization ----
    reg [5:0]  fp_seen;
    reg        seen, decreased;
    reg [3:0]  max_delta;
    reg [7:0]  changes;
    wire [5:0] d = (fp + NUM_FRAMES[5:0] - fp_seen) % NUM_FRAMES[5:0];   // forward delta, [0..N-1]
    always @(posedge clk) begin
        if (!rstn) begin fp_seen<=0; seen<=0; decreased<=0; max_delta<=0; changes<=0; end
        else if (!seen) begin seen<=1'b1; fp_seen<=fp; end
        else if (fp != fp_seen) begin
            changes <= changes + 8'd1;
            if (d > (NUM_FRAMES[5:0]>>1)) decreased <= 1'b1;             // > N/2 ⇒ a real decrease
            else if (d[3:0] > max_delta)  max_delta <= d[3:0];           // largest forward skip
            fp_seen <= fp;
        end
    end

    assign mon = {changes, max_delta, 3'd0, decreased};
endmodule

`default_nettype wire
