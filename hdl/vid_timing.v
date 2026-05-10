// vid_timing.v — Parameterized horizontal/vertical timing generator
//
// Phase 1 of Schindler 2.0. Produces HSYNC, VSYNC, ACTIVE, and pixel/line
// counters. Constants come from the Python reference encoder
// (python/encoder/ntsc_line.py + ntsc_frame.py) — every default value here
// traces back to a value derived in Python from SMPTE 170M and the
// MVPHD-24 flyer.
//
// Sync polarity convention: HIGH during the sync interval (active-high
// logical signal). The downstream sample generator is responsible for
// translating logical HIGH → analog sync-tip voltage (-286 mV).
//
// Default parameters target 24.000 fps Schindler mode at 54 MS/s pixel
// clock; pass overrides for the other presets.

`default_nettype none
`timescale 1ns / 1ps

module vid_timing #(
    // Per-line geometry (samples at PIXEL_CLK_HZ)
    parameter integer PIXELS_PER_LINE  = 3435,  // round(63.6132 µs * 54 MHz) — 24 fps
    parameter integer H_FRONT_PIXELS   = 81,    // round(1.5  µs * 54 MHz) — front porch
    parameter integer H_SYNC_PIXELS    = 254,   // round(4.7  µs * 54 MHz) — sync pulse
    parameter integer H_BACK_PIXELS    = 254,   // round(4.7  µs * 54 MHz) — back porch

    // Per-frame geometry
    parameter integer LINES_PER_FRAME  = 655,   // 24 fps Schindler (flyer)
    parameter integer VBI_LINES        = 21,    // SMPTE 170M: 3 pre-eq + 3 V-sync + 3 post-eq + 12 blank
    parameter integer VSYNC_LINE_FIRST = 3,     // first line of V-sync region (0-indexed)
    parameter integer VSYNC_LINE_LAST  = 5      // last line of V-sync region (inclusive)
) (
    input  wire        clk,            // pixel clock (e.g. 54 MHz)
    input  wire        rst,            // synchronous reset, active-high

    output reg  [11:0] pixel_count,    // 0 .. PIXELS_PER_LINE-1
    output reg  [9:0]  line_count,     // 0 .. LINES_PER_FRAME-1
    output wire        hsync,          // HIGH during sync pulse
    output wire        vsync,          // HIGH during V-sync lines
    output wire        active,         // HIGH during active video region
    output wire        sof,            // start-of-frame: 1 cycle when pixel_count=0 && line_count=0
    output wire        sol             // start-of-line:  1 cycle when pixel_count=0
);

    // Derived constants (synth-time evaluation)
    localparam integer ACTIVE_START_PIXEL = H_FRONT_PIXELS + H_SYNC_PIXELS + H_BACK_PIXELS;

    // Counters
    always @(posedge clk) begin
        if (rst) begin
            pixel_count <= 12'd0;
            line_count  <= 10'd0;
        end else if (pixel_count == PIXELS_PER_LINE - 1) begin
            pixel_count <= 12'd0;
            if (line_count == LINES_PER_FRAME - 1)
                line_count <= 10'd0;
            else
                line_count <= line_count + 1'b1;
        end else begin
            pixel_count <= pixel_count + 1'b1;
        end
    end

    assign hsync  = (pixel_count >= H_FRONT_PIXELS) &&
                    (pixel_count <  H_FRONT_PIXELS + H_SYNC_PIXELS);

    assign vsync  = (line_count >= VSYNC_LINE_FIRST) &&
                    (line_count <= VSYNC_LINE_LAST);

    assign active = (line_count >= VBI_LINES) &&
                    (pixel_count >= ACTIVE_START_PIXEL);

    assign sol    = (pixel_count == 0);
    assign sof    = (pixel_count == 0) && (line_count == 0);

endmodule

`default_nettype wire
