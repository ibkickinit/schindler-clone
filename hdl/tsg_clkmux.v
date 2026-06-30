// tsg_clkmux.v — glitch-tolerant write-side pixel-clock mux (2026-06-28).
//
// Selects the WRITE-side pixel clock between the recovered HDMI clock (dvi2rgb PixelClk,
// sel=0) and the internal TSG PLL clock (sel=1). Uses a 7-series BUFGCTRL with the
// IGNORE0/IGNORE1 inputs tied HIGH so the handoff completes IMMEDIATELY without waiting
// for the outgoing clock to toggle low.
//
// WHY IGNORE=1 (not a plain glitchless BUFGMUX_CTRL): the whole point of the TSG is to
// run with NOTHING plugged into HDMI. In that case dvi2rgb's recovered PixelClk (clk0)
// is STOPPED. A glitchless BUFGMUX_CTRL waits for the *currently selected* clock to go
// low before switching — if clk0 is stopped it can HANG and never switch to the TSG
// clock, defeating the feature. IGNORE0/IGNORE1=1 makes the switch unconditional. The
// brief glitch this can produce on clk_o is masked by the write-path switch reset
// (tsg_switch_rst) that holds v_vid_in_axi4s + scaler in reset across the transition.
//
// Both I0 and I1 are driven by clock buffers (dvi2rgb's internal BUFG on PixelClk, and
// clk_wiz_tsg's BUFG on clk_out1) — the required BUFGCTRL source topology.
//
// sel (= tsg_enable) is a quasi-static GPIO bit; with IGNORE=1 the BUFGCTRL select pins
// tolerate the asynchronous input. PRESELECT_I0 makes clk0 the power-up selection.

`default_nettype none
`timescale 1ns / 1ps

module tsg_clkmux (
    input  wire clk0,    // sel=0 : dvi2rgb_0/PixelClk (recovered HDMI)
    input  wire clk1,    // sel=1 : internal TSG PLL clk (clk_wiz_tsg)
    input  wire sel,     // tsg_enable (quasi-static; 0=HDMI, 1=TSG)
    output wire clk_o    // muxed write-side pixel clock
);
    BUFGCTRL #(
        .INIT_OUT     (0),
        .PRESELECT_I0 ("TRUE"),
        .PRESELECT_I1 ("FALSE")
    ) u_bufgctrl (
        .O       (clk_o),
        .I0      (clk0),
        .I1      (clk1),
        .CE0     (1'b1),
        .CE1     (1'b1),
        .S0      (~sel),
        .S1      ( sel),
        .IGNORE0 (1'b1),
        .IGNORE1 (1'b1)
    );
endmodule

`default_nettype wire
