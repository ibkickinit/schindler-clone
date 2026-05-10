// vbi_gen.v — Combined sync pattern generator for the full NTSC frame.
//
// Decodes line_count into one of 4 line types (pre-equalizing, vertical
// sync, post-equalizing, normal-H) and produces the correct sync pulse
// pattern for each.  Output `sync` is HIGH whenever the composite output
// should sit at sync tip (-286 mV).  Replaces the simpler hsync-only
// approach that didn't generate proper V-sync structure for a CRT to lock.
//
// Sources:
//   - SMPTE 170M Fig 6: pulse widths and intra-line positions
//   - Python reference: ntsc_frame.py (equalizing_line / vertical_sync_line)
//
// VBI line layout (single VBI block at top of frame; field-2 half-line
// offset for interlace not yet modeled — Phase 5 work, needs Schindler
// captures to validate):
//
//   lines  0..2  : pre-equalizing  (two narrow pulses per line, half-line apart)
//   lines  3..5  : vertical sync   (two broad pulses per line, with serrations)
//   lines  6..8  : post-equalizing (same shape as pre-equalizing)
//   lines  9..20 : blank fill      (just H-sync, no active)
//   lines 21..   : active video    (H-sync + active pattern)

`default_nettype none
`timescale 1ns / 1ps

module vbi_gen #(
    parameter integer PIXELS_PER_LINE    = 3435,
    parameter integer H_FRONT_PIXELS     = 81,
    parameter integer H_SYNC_PIXELS      = 254,
    parameter integer EQ_PULSE_PIXELS    = 124,   // 2.3 µs * 54 MHz
    parameter integer V_SERRATION_PIXELS = 254,   // 4.7 µs * 54 MHz (same as H_SYNC)
    parameter integer N_PRE_EQ_LINES     = 3,
    parameter integer N_VSYNC_LINES      = 3,
    parameter integer N_POST_EQ_LINES    = 3
) (
    input  wire [11:0] pixel_count,
    input  wire [9:0]  line_count,
    output wire        sync
);

    localparam integer HALF_LINE_PIXELS  = PIXELS_PER_LINE / 2;

    // Line-type boundaries (0-indexed, half-open: [first, last])
    localparam integer LINE_FIRST_PRE_EQ  = 0;
    localparam integer LINE_LAST_PRE_EQ   = N_PRE_EQ_LINES - 1;
    localparam integer LINE_FIRST_VSYNC   = N_PRE_EQ_LINES;
    localparam integer LINE_LAST_VSYNC    = N_PRE_EQ_LINES + N_VSYNC_LINES - 1;
    localparam integer LINE_FIRST_POST_EQ = N_PRE_EQ_LINES + N_VSYNC_LINES;
    localparam integer LINE_LAST_POST_EQ  = LINE_FIRST_POST_EQ + N_POST_EQ_LINES - 1;

    wire is_pre_eq  = (line_count >= LINE_FIRST_PRE_EQ)  && (line_count <= LINE_LAST_PRE_EQ);
    wire is_vsync   = (line_count >= LINE_FIRST_VSYNC)   && (line_count <= LINE_LAST_VSYNC);
    wire is_post_eq = (line_count >= LINE_FIRST_POST_EQ) && (line_count <= LINE_LAST_POST_EQ);

    // Equalizing pattern: two narrow pulses at pixel 0 and at half-line.
    wire eq_pulse_0 = (pixel_count < EQ_PULSE_PIXELS);
    wire eq_pulse_1 = (pixel_count >= HALF_LINE_PIXELS) &&
                      (pixel_count <  HALF_LINE_PIXELS + EQ_PULSE_PIXELS);
    wire eq_sync = eq_pulse_0 || eq_pulse_1;

    // V-sync pattern: two broad pulses, each spanning a half-line minus a
    // short serration (blanking-level gap) at the half-line boundary.
    wire vsync_half0 = (pixel_count < HALF_LINE_PIXELS - V_SERRATION_PIXELS);
    wire vsync_half1 = (pixel_count >= HALF_LINE_PIXELS) &&
                       (pixel_count <  PIXELS_PER_LINE - V_SERRATION_PIXELS);
    wire vsync_pattern = vsync_half0 || vsync_half1;

    // Normal H-sync: low for H_SYNC_PIXELS after H_FRONT_PIXELS front porch.
    wire h_sync = (pixel_count >= H_FRONT_PIXELS) &&
                  (pixel_count <  H_FRONT_PIXELS + H_SYNC_PIXELS);

    // Select pattern by line type. Blank-fill and active lines both use the
    // plain H-sync pattern (no special VBI shape).
    assign sync = is_pre_eq  ? eq_sync :
                  is_vsync   ? vsync_pattern :
                  is_post_eq ? eq_sync :
                               h_sync;

endmodule

`default_nettype wire
