// iter4a_test_mux.v — Phase E2 bench-diagnostic mux for iter-4a measurement.
//
// Sits between dvi2rgb_0/vid_pVSync and axi_sync_inputs_0/vsync_async so
// firmware can swap the iter-4a source-rate measurement input between the
// real HDMI source vsync and the synth_vsync_gen's known 50.000 Hz output.
//
// Used to validate the iter-4a measurement post-P0-1 fix: feed in the known
// 50 Hz reference, then call 'a'; if iter-4a reads ~50 Hz the measurement
// is honest and any anomalous source rate reading reflects the source
// (Windows custom EDID, etc.), not a measurement bug. If iter-4a reads
// off by the same +X% bias seen against the assumed-60 Hz source, there's
// a residual bias still in the measurement path.
//
// ctrl bus is shared with ref_mux_0 (axi_gpio_refsel/gpio_io_o is fanned
// out to both). Only ctrl[3] (the "reserved" bit per ref_mux's spec) is
// used here; ref_mux's behavior is unaffected.
//
//   ctrl[3] = 0 (default): muxed = src_vsync (HDMI source — current behavior)
//   ctrl[3] = 1          : muxed = test_vsync (synth_vsync_gen → 50 Hz)

`default_nettype none
`timescale 1ns / 1ps

module iter4a_test_mux (
    input  wire [3:0] ctrl,        // shared with ref_mux; uses ctrl[3] only
    input  wire       src_vsync,   // dvi2rgb_0/vid_pVSync
    input  wire       test_vsync,  // synth_vsync_gen_0/vsync_out
    output wire       muxed        // → axi_sync_inputs_0/vsync_async
);
    assign muxed = ctrl[3] ? test_vsync : src_vsync;
endmodule

`default_nettype wire
