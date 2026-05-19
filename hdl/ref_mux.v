// ref_mux.v — Phase E1 Phase 7 reference selector.
//
// 4:1 mux + maskable output. ctrl[1:0] selects which reference source feeds
// the loop's phase detector (vsync_timestamp_0/ref_vsync_async). ctrl[2] is
// a "mask" override: when high, the output is forced to 0 regardless of
// selector — used to simulate ref loss for the holdover test.
//
//   ctrl[1:0]   meaning           wire-up
//   00          free-run (1'b0)   tied low — no edges, integrator freezes at 0
//   01          synthetic ref     Phase 2 FCLK_CLK1 / DIVISOR divider output
//   10          (reserved)        tied low for now; placeholder for Si5351 / analog
//   11          (reserved)        tied low for now; placeholder for HDMI source vsync
//
//   ctrl[2]     mask              0 = pass-through, 1 = force ref_out=0
//   ctrl[3]     (reserved)        unused
//
// Purely combinational. The downstream 2-FF synchronizer in vsync_timestamp
// handles the CDC and metastability protection.

`default_nettype none
`timescale 1ns / 1ps

module ref_mux (
    input  wire [3:0] ctrl,        // {reserved, mask, sel[1:0]}
    input  wire       ref_synth,   // synth_vsync_gen output (Phase 2)
    input  wire       ref_ext0,    // future: Si5351 / analog recovery
    input  wire       ref_ext1,    // future: HDMI source vsync
    output wire       ref_out
);
    wire [1:0] sel  = ctrl[1:0];
    wire       mask = ctrl[2];

    reg muxed;
    always @* begin
        case (sel)
            2'b00:   muxed = 1'b0;          // free-run
            2'b01:   muxed = ref_synth;     // synthetic reference (Phase 2)
            2'b10:   muxed = ref_ext0;      // future
            2'b11:   muxed = ref_ext1;      // future
            default: muxed = 1'b0;
        endcase
    end

    assign ref_out = mask ? 1'b0 : muxed;

endmodule

`default_nettype wire
