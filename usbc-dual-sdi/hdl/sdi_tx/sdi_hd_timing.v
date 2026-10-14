// sdi_hd_timing.v — word-rate raster counter for HD-SDI (one Y word + one C word per clock).
//
// h  = sample index within the line, 0 = first active sample (SMPTE 274M/296M numbering):
//      [0, H_ACT) active · H_ACT..H_ACT+7 EAV/LN/CRC · ... · H_TOT-4..H_TOT-1 SAV.
// ln = line number 1..V_TOT. It advances when h wraps, so the SAV at the END of counter-line ln
//      belongs to line ln+1 (the framer handles that). LN words after EAV carry this ln.
//
// Defaults = 1080p30 (2200 x 1125, clock 74.25 MHz). Other HD rasters by parameter:
//   1080p25: H_TOT 2640 · 1080p24: H_TOT 2750 · 720p60: H_ACT 1280, H_TOT 1650, V_TOT 750.
// Progressive only for now (F = 0); interlaced 1080i is a later step (docs/12).

`default_nettype none
`timescale 1ns / 1ps

module sdi_hd_timing #(
    parameter integer H_ACT = 1920,
    parameter integer H_TOT = 2200,
    parameter integer V_TOT = 1125
) (
    input  wire        clk,
    input  wire        rst,
    output reg  [11:0] h,
    output reg  [10:0] ln
);
    always @(posedge clk) begin
        if (rst) begin
            h  <= 12'd0;
            ln <= 11'd1;
        end else if (h == H_TOT - 1) begin
            h  <= 12'd0;
            ln <= (ln == V_TOT) ? 11'd1 : ln + 11'd1;
        end else begin
            h  <= h + 12'd1;
        end
    end
endmodule

`default_nettype wire
