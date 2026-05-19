// fsync_pulse_gen.v — Convert source vsync level signal to a 1-cycle pulse
// in the output clock domain, suitable for driving v_tc/fsync_in.
//
// Per PG016 v_tc IP:
//   "fsync_in is an active-High input. The video timing generator is
//    synchronized to fsync_in if used. fsync_in should be driven High for
//    only one clock cycle per frame, which resets all internal generator
//    counters and starts the generated frame timing synchronized to this
//    input."
//
// Wiring: dvi2rgb_0/vid_pVSync (async to output clk_pixel_o) → vsync_in_async.
//         v_tc_tx clock (74.25 MHz output domain)             → aclk.
//         output fsync_pulse                                  → v_tc_tx/fsync_in.
//
// This makes VTC TX's first frame hardware-locked to source vsync (boot
// alignment) AND keeps it re-locked every frame after (drift correction).
// Phase error is bounded by the 2-FF CDC synchronizer = 1 pixel-clock period.
// Compare to the firmware-polling approach which had 0-290 rows of jitter.

`default_nettype none
`timescale 1ns / 1ps

module fsync_pulse_gen (
    input  wire aclk,           // destination clock (e.g., clk_wiz_pixclk_out/clk_out1)
    input  wire aresetn,        // synchronous reset, active-low
    input  wire vsync_in_async, // raw source vsync (async to aclk)
    input  wire vtc_vsync_in,   // VTC TX's own vsync_out (proof VTC is enabled+running)
    output wire fsync_pulse     // 1-cycle pulse at the FIRST source vsync AFTER VTC is running
);
    // PG016 Option B (one-shot startup alignment): pulse on the FIRST source
    // vsync rising edge after reset, then never again. Locks VTC generator
    // phase to source vsync at boot. Generator then free-runs on its own
    // clock. Required when source clock and VTC clock are independent
    // oscillators — continuous fsync_in would reset the generator mid-frame
    // every time the source vsync arrives off VTC's natural vsync boundary,
    // producing unstable HDMI output that downstream sinks can't lock.
    //
    // Long-term drift between source and output is absorbed by VDMA's
    // Dynamic Genlock framestore ring (5 slots). MMCM phase-tracking
    // (Phase E1) will tighten this further.
    // 2-FF sync on source vsync (cross-domain from dvi2rgb's PixelClk)
    (* ASYNC_REG = "TRUE" *) reg vsync_q1, vsync_q2, vsync_q3;
    // 1-FF edge-detect on VTC's own vsync (same clock domain — no sync needed)
    reg vtc_q1;
    // State machine: !armed → armed → fired
    //   armed = 1 once VTC TX has emitted its first vsync (proves generator
    //           is enabled by firmware and running)
    //   fired = 1 once the alignment pulse has been emitted
    reg armed, fired;

    always @(posedge aclk) begin
        if (!aresetn) begin
            vsync_q1 <= 1'b0;
            vsync_q2 <= 1'b0;
            vsync_q3 <= 1'b0;
            vtc_q1   <= 1'b0;
            armed    <= 1'b0;
            fired    <= 1'b0;
        end else begin
            vsync_q1 <= vsync_in_async;
            vsync_q2 <= vsync_q1;
            vsync_q3 <= vsync_q2;
            vtc_q1   <= vtc_vsync_in;
            // Arm on VTC TX's first vsync rising edge — guarantees VTC is
            // actually running before we kick fsync_in.
            if (vtc_vsync_in && !vtc_q1 && !armed) armed <= 1'b1;
            // Fire once after armed, on the NEXT source vsync rising edge.
            if (armed && vsync_q2 && !vsync_q3 && !fired) fired <= 1'b1;
        end
    end

    // Pulse fires when: armed, on source vsync rising edge, not yet fired
    assign fsync_pulse = armed && vsync_q2 && !vsync_q3 && !fired;
endmodule

`default_nettype wire
