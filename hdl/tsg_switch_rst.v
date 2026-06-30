// tsg_switch_rst.v — write-path reset pulse on source/clock switch (2026-06-28).
//
// When tsg_enable toggles, the WRITE side glitch-switches its pixel clock (tsg_clkmux)
// and its source bundle (tsg_srcsel). Pulse an active-low reset across that transition
// so v_vid_in_axi4s + the scaler restart cleanly on the new clock/source instead of
// latching the switch glitch into a half-frame.
//
// Clocked by FCLK_CLK0 (ALWAYS running, independent of either pixel clock — the muxed
// pixel clock can momentarily stop/glitch during the handoff, so it cannot time its own
// switch reset). The downstream IPs already take this reset asynchronously and self-
// synchronize it internally (same as the rst_axi reset it replaces), so generating it in
// the FCLK_CLK0 domain is the established pattern.
//
// rstn_o is also held low for HOLD cycles out of power-on reset (cnt preloaded all-ones)
// and tracks axi_rstn, so it is a strict superset of the reset it replaces.

`default_nettype none
`timescale 1ns / 1ps

module tsg_switch_rst #(
    parameter integer HOLD = 1024     // ~10.2 us at 100 MHz FCLK_CLK0
) (
    input  wire clk,         // FCLK_CLK0 (free-running)
    input  wire axi_rstn,    // upstream peripheral reset (active low)
    input  wire sel_async,   // tsg_enable (async GPIO)
    output wire rstn_o        // active low: low during switch + while axi_rstn low
);
    (* ASYNC_REG = "TRUE" *) reg sel_meta, sel_sync;
    reg sel_prev;
    reg [15:0] cnt;

    always @(posedge clk) begin
        if (!axi_rstn) begin
            sel_meta <= 1'b0;
            sel_sync <= 1'b0;
            sel_prev <= 1'b0;
            cnt      <= 16'hFFFF;        // long hold out of power-on reset
        end else begin
            sel_meta <= sel_async;
            sel_sync <= sel_meta;
            sel_prev <= sel_sync;
            if (sel_sync != sel_prev)
                cnt <= HOLD[15:0];        // switch detected -> assert reset
            else if (cnt != 16'd0)
                cnt <= cnt - 16'd1;
        end
    end

    assign rstn_o = axi_rstn & (cnt == 16'd0);
endmodule

`default_nettype wire
