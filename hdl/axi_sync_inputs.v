// axi_sync_inputs.v — 2-FF synchronizer from dvi2rgb's pclk_in domain into
// the AXI FCLK_CLK0 domain. Drives an AXI GPIO's gpio_io_i pins so firmware
// can poll dvi2rgb's pLocked and source vsync state for alignment purposes.
//
// Phase D iter-3e — firmware-side VTC alignment. The earlier gen_clken-gate
// approach (iter-3b/c/d) did not produce deterministic per-boot alignment
// because the VTC generator's counter start is driven by firmware's CTL
// register write (SW=0->1 transition, which RU propagates), not by gen_clken.
// Firmware-boot timing varies, so writing CTL at random source-frame phase
// gives random output alignment. Solution: have firmware poll for a source
// vsync rising edge, then immediately write CTL — this aligns CTL-write
// timing to source vsync.
//
// CDC: source signals (vid_pVSync at ~60 Hz, pLocked changes only on
// lock-loss events) are slow-changing levels, so a plain 2-FF synchronizer
// is sufficient. ASYNC_REG attribute on q1 tells Vivado's timing engine
// to place this register in a metastability-resolution path and ignore
// the asynchronous-arrival-time edge.

`default_nettype none
`timescale 1ns / 1ps

module axi_sync_inputs (
    input  wire axi_clk,            // FCLK_CLK0 (~100 MHz)
    input  wire axi_rstn,           // active-low reset, axi_clk domain

    input  wire vsync_async,        // dvi2rgb_0/vid_pVSync (level, pclk_in)
    input  wire plocked_async,      // dvi2rgb_0/pLocked    (level, pclk_in)

    output wire vsync_sync,         // axi_clk-domain level
    output wire plocked_sync        // axi_clk-domain level
);

    (* ASYNC_REG = "TRUE" *) reg vsync_q1;
    (* ASYNC_REG = "TRUE" *) reg vsync_q2;
    (* ASYNC_REG = "TRUE" *) reg plocked_q1;
    (* ASYNC_REG = "TRUE" *) reg plocked_q2;

    always @(posedge axi_clk) begin
        if (!axi_rstn) begin
            vsync_q1   <= 1'b0;
            vsync_q2   <= 1'b0;
            plocked_q1 <= 1'b0;
            plocked_q2 <= 1'b0;
        end else begin
            vsync_q1   <= vsync_async;
            vsync_q2   <= vsync_q1;
            plocked_q1 <= plocked_async;
            plocked_q2 <= plocked_q1;
        end
    end

    assign vsync_sync   = vsync_q2;
    assign plocked_sync = plocked_q2;

endmodule

`default_nettype wire
