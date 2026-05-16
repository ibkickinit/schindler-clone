// vtc_gen_gate.v — one-time VTC generator startup gate, aligned to source vsync.
//
// Phase D iter-3 (after the fsync_in pivot). Holds v_tc_tx's generator clock
// enable LOW until the first rising edge of dvi2rgb's vid_pVSync has been
// synchronized into the output clock domain, then asserts HIGH forever. With
// Phase D iter 1's rate genlock keeping input and output PixelClks at the same
// rate (148.5 MHz / 74.25 MHz, both derived from the recovered HDMI source
// clock), the one-time release aligns VTC's vsync_out at a fixed offset from
// source vsync — and the lock persists indefinitely.
//
// Why this instead of fsync_in: PG016's fsync_in behavior is conditional on
// CTL source-select bits and (likely) C_DETECT_EN=1. We tried wiring a
// per-frame pulse into fsync_in at iter-3a and the VTC generator stopped
// producing sync (monitor + capture stick both went to "no signal"). gen_clken
// is the generator's plain clock-enable input — held low pauses generator,
// released starts it counting from row 0 column 0. Known-working semantics.
//
// CDC: vid_pVSync is in pclk_in (~148.5 MHz, source-recovered) domain. This
// module runs entirely on dst_clk (~74.25 MHz, output). 2-FF synchronizer with
// ASYNC_REG attribute lets Vivado's timing engine ignore the input arrival.
// vsync transitions at ~60 Hz — vastly slower than any clock period — so
// metastability resolution is overkill but free.

`default_nettype none
`timescale 1ns / 1ps

module vtc_gen_gate (
    input  wire dst_clk,        // VTC clock (clk_wiz_pixclk_out/clk_out1, ~74.25 MHz)
    input  wire dst_rstn,       // active-low reset in dst_clk domain
    input  wire vsync_async,    // dvi2rgb_0/vid_pVSync (level, pclk_in domain)
    output wire gen_clken       // 0 until first sync'd rising edge, then 1 forever
);

    (* ASYNC_REG = "TRUE" *) reg sync_q1;
    (* ASYNC_REG = "TRUE" *) reg sync_q2;
    reg sync_q3;
    reg [3:0] startup_cnt;
    reg armed;
    reg seen;

    // startup_cnt holds back the arm check until the sync chain has had time
    // to propagate real signal samples. The earlier iter-3c version armed on
    // cycle 1 when `!sync_q2 && !sync_q3` was tautologically true (both still
    // at reset value), then immediately fired `seen` 2 cycles later if vsync
    // happened to be HIGH at reset release — giving non-deterministic
    // alignment across boots.
    wire startup_done = (startup_cnt == 4'hF);

    always @(posedge dst_clk) begin
        if (!dst_rstn) begin
            sync_q1     <= 1'b0;
            sync_q2     <= 1'b0;
            sync_q3     <= 1'b0;
            startup_cnt <= 4'd0;
            armed       <= 1'b0;
            seen        <= 1'b0;
        end else begin
            sync_q1 <= vsync_async;
            sync_q2 <= sync_q1;
            sync_q3 <= sync_q2;
            if (!startup_done) startup_cnt <= startup_cnt + 4'd1;
            // After startup, arm when the signal has been stably LOW for two
            // consecutive sync-chain samples (i.e. we're definitely in active
            // video or porch, not mid-vsync-pulse).
            if (startup_done && !sync_q2 && !sync_q3) armed <= 1'b1;
            // Once armed, latch `seen` on the next real LOW->HIGH edge.
            if (armed && sync_q2 && !sync_q3) seen <= 1'b1;
        end
    end

    assign gen_clken = seen;

endmodule

`default_nettype wire
