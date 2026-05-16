// axi_sync_inputs.v — 2-FF synchronizers from various async domains into the
// AXI FCLK_CLK0 domain. Drives an AXI GPIO's gpio_io_i pins so firmware can
// poll source-side and output-side status for alignment and FRC.
//
// Phase D iter-3e (original): firmware-side VTC alignment via source vsync.
// Phase D iter-4d-1: added vsync_out and pclk_locked sync stages so firmware
// can count OUTPUT vsyncs (for cadence-driven PARK writes) and observe the
// output PixelClk MMCM lock directly.
//
// CDC: source vsync (~60 Hz), output vsync (~60 Hz), and both lock signals
// are slow-changing levels, so a plain 2-FF synchronizer is sufficient.

`default_nettype none
`timescale 1ns / 1ps

module axi_sync_inputs (
    input  wire axi_clk,                // FCLK_CLK0 (~100 MHz)
    input  wire axi_rstn,               // active-low reset, axi_clk domain

    input  wire vsync_async,            // dvi2rgb_0/vid_pVSync       (pclk_in)
    input  wire plocked_async,          // dvi2rgb_0/pLocked          (pclk_in)
    input  wire vsync_out_async,        // v_tc_tx/vsync_out          (pclk_out)
    input  wire pclk_locked_async,      // clk_wiz_pixclk_out/locked  (async)

    output wire vsync_sync,             // axi_clk-domain levels
    output wire plocked_sync,
    output wire vsync_out_sync,
    output wire pclk_locked_sync
);

    (* ASYNC_REG = "TRUE" *) reg vsync_q1, vsync_q2;
    (* ASYNC_REG = "TRUE" *) reg plocked_q1, plocked_q2;
    (* ASYNC_REG = "TRUE" *) reg vsync_out_q1, vsync_out_q2;
    (* ASYNC_REG = "TRUE" *) reg pclk_locked_q1, pclk_locked_q2;

    always @(posedge axi_clk) begin
        if (!axi_rstn) begin
            vsync_q1        <= 1'b0; vsync_q2        <= 1'b0;
            plocked_q1      <= 1'b0; plocked_q2      <= 1'b0;
            vsync_out_q1    <= 1'b0; vsync_out_q2    <= 1'b0;
            pclk_locked_q1  <= 1'b0; pclk_locked_q2  <= 1'b0;
        end else begin
            vsync_q1        <= vsync_async;        vsync_q2        <= vsync_q1;
            plocked_q1      <= plocked_async;      plocked_q2      <= plocked_q1;
            vsync_out_q1    <= vsync_out_async;    vsync_out_q2    <= vsync_out_q1;
            pclk_locked_q1  <= pclk_locked_async;  pclk_locked_q2  <= pclk_locked_q1;
        end
    end

    assign vsync_sync       = vsync_q2;
    assign plocked_sync     = plocked_q2;
    assign vsync_out_sync   = vsync_out_q2;
    assign pclk_locked_sync = pclk_locked_q2;

endmodule

`default_nettype wire
