// clk_mux.v — Glitchless clock mux between two 148.5 MHz sources.
//
// I0 = dvi2rgb's recovered PixelClk (only valid when HDMI source is locked)
// I1 = clk_wiz_tpg's 148.5 MHz (always valid, derived from FCLK_CLK0)
//
// SEL = 0  -> route I0 (use HDMI clock; required for real HDMI capture)
// SEL = 1  -> route I1 (use synthesized clock; works with or without HDMI)
//
// Uses Xilinx BUFGMUX primitive for glitchless switching. Both inputs MUST
// be alive while SEL is at the wrong value (BUFGMUX won't switch to a dead
// clock). In practice: dvi2rgb's clock is dead when no HDMI — so we MUST be
// at SEL=1 before plugging HDMI out, and MUST switch to SEL=0 only after
// HDMI is plugged in and locked.
//
// At system boot, SEL is driven by axi_gpio_8 ch1 bit 4 (same bit that
// selects the AXIS source mux). Boot default = SEL=0 (HDMI clock). If you
// boot without HDMI plugged in, the pipeline starts dead until firmware
// writes SEL=1 over GPIO — see firmware boot-time auto-fallback logic.

`default_nettype none
`timescale 1ns / 1ps

module clk_mux (
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 148500000" *)
    input  wire clk0,   // 148.5 MHz from dvi2rgb (HDMI-recovered)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 148500000" *)
    input  wire clk1,   // 148.5 MHz from clk_wiz_tpg (synthesized)
    input  wire sel,    // 0 -> clk0, 1 -> clk1
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 148500000" *)
    output wire clk_out
);
    BUFGMUX bufgmux_pclk (
        .O  (clk_out),
        .I0 (clk0),
        .I1 (clk1),
        .S  (sel)
    );
endmodule

`default_nettype wire
