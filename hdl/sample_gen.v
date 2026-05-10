// sample_gen.v — Maps timing strobes + pixel index to a 10-bit DAC code.
//
// Phase 1 v0: luma-only output. Sync, blanking, and active-region patterns.
// No colorburst, no proper VBI broad pulses (deferred to v1).
//
// DAC convention: 10-bit unipolar, intended to drive a 10-resistor R-2R
// ladder from FPGA GPIO (0-3.3V swing). A downstream op-amp scales
// 0-3.3V → -286 mV to +714 mV (NTSC composite range), so:
//   DAC code 0    → 0.000 V → -286 mV (sync tip,  -40 IRE)
//   DAC code 293  → 0.945 V →    0 mV (blanking,    0 IRE)
//   DAC code 348  → 1.123 V →  +54 mV (black setup, 7.5 IRE)
//   DAC code 658  → 2.122 V → +357 mV (50 IRE gray)
//   DAC code 1023 → 3.300 V → +714 mV (peak white, 100 IRE)
//
// Bar codes derived from ntsc_line.py:smpte_color_bars_luma()
// (75% SMPTE bars, luma only — chroma adds in chroma_mod.v later)

`default_nettype none
`timescale 1ns / 1ps

module sample_gen #(
    // Geometry — must match the vid_timing instance feeding us
    parameter integer PIXELS_PER_LINE = 3435,
    parameter integer ACTIVE_START    = 589   // = H_FRONT + H_SYNC + H_BACK
) (
    input  wire        clk,
    input  wire        rst,

    // From vid_timing
    input  wire        sync,         // HIGH during ANY sync interval (H-sync, equalizing, or V-sync — driven by vbi_gen)
    input  wire        active,       // HIGH during active video region
    input  wire [11:0] pixel_count,  // 0 .. PIXELS_PER_LINE-1

    // Pattern select: 0=gray, 1=ramp, 2=bars
    input  wire [1:0]  pattern_sel,

    // 10-bit DAC code
    output reg  [9:0]  dac
);

    // ------------------------------------------------------------
    // DAC codes — math in the header comment.
    // ------------------------------------------------------------
    localparam [9:0] CODE_SYNC_TIP    = 10'd0;
    localparam [9:0] CODE_BLANKING    = 10'd293;
    localparam [9:0] CODE_BLACK_SETUP = 10'd348;
    localparam [9:0] CODE_GRAY_50     = 10'd658;
    localparam [9:0] CODE_WHITE_100   = 10'd1023;

    // 75% SMPTE bars luma (white→blue), per ntsc_line.py
    localparam [9:0] CODE_BAR_WHITE   = 10'd855;  // 77 IRE
    localparam [9:0] CODE_BAR_YELLOW  = 10'd797;  // 69 IRE
    localparam [9:0] CODE_BAR_CYAN    = 10'd702;  // 56 IRE
    localparam [9:0] CODE_BAR_GREEN   = 10'd643;  // 48 IRE
    localparam [9:0] CODE_BAR_MAGENTA = 10'd555;  // 36 IRE
    localparam [9:0] CODE_BAR_RED     = 10'd497;  // 28 IRE
    localparam [9:0] CODE_BAR_BLUE    = 10'd402;  // 15 IRE

    // ------------------------------------------------------------
    // Pattern computation
    // ------------------------------------------------------------
    localparam integer N_ACTIVE_PIXELS = PIXELS_PER_LINE - ACTIVE_START;  // 2846 default
    localparam integer BAR_WIDTH       = N_ACTIVE_PIXELS / 7;             // 406 default

    wire [11:0] active_pixel = pixel_count - ACTIVE_START[11:0];

    // Bar selector (priority encoder, 7-way)
    reg [9:0] bars_value;
    always @(*) begin
        if      (active_pixel >= 6*BAR_WIDTH) bars_value = CODE_BAR_BLUE;
        else if (active_pixel >= 5*BAR_WIDTH) bars_value = CODE_BAR_RED;
        else if (active_pixel >= 4*BAR_WIDTH) bars_value = CODE_BAR_MAGENTA;
        else if (active_pixel >= 3*BAR_WIDTH) bars_value = CODE_BAR_GREEN;
        else if (active_pixel >= 2*BAR_WIDTH) bars_value = CODE_BAR_CYAN;
        else if (active_pixel >= 1*BAR_WIDTH) bars_value = CODE_BAR_YELLOW;
        else                                   bars_value = CODE_BAR_WHITE;
    end

    // Ramp: span CODE_BLACK_SETUP .. CODE_WHITE_100 across the active region.
    // active_pixel/N_ACTIVE_PIXELS * (WHITE - BLACK_SETUP) + BLACK_SETUP
    // For 2846 active pixels and (1023-348)=675 range, slope ≈ 0.237 per pixel.
    // Approximate with right-shift (>>2 ≈ /4): ramp ≈ active_pixel[11:2] + BLACK_SETUP.
    // At active_pixel=2846, this gives 711 + 348 = 1059 → saturates to 1023.
    wire [11:0] ramp_raw = {2'b00, active_pixel[11:2]} + CODE_BLACK_SETUP;
    wire [9:0]  ramp_value = (ramp_raw[11:10] != 2'b00) ? CODE_WHITE_100 : ramp_raw[9:0];

    // Pattern mux
    reg [9:0] pattern_value;
    always @(*) begin
        case (pattern_sel)
            2'd0: pattern_value = CODE_GRAY_50;
            2'd1: pattern_value = ramp_value;
            2'd2: pattern_value = bars_value;
            default: pattern_value = CODE_GRAY_50;
        endcase
    end

    // ------------------------------------------------------------
    // Output: hsync wins over active wins over blanking
    // Registered to avoid glitches on the GPIO pins.
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (rst)         dac <= CODE_BLANKING;
        else if (sync)   dac <= CODE_SYNC_TIP;
        else if (active) dac <= pattern_value;
        else             dac <= CODE_BLANKING;
    end

endmodule

`default_nettype wire
