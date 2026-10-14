// sdi_bars_hd.v — 75% color bars, Rec.709 YCbCr 4:2:2 10-bit (SMPTE RP 219 values), for SDI bring-up.
//
// Eight equal bars across H_ACT: white, yellow, cyan, green, magenta, red, blue, black.
// C stream is Cb on even samples, Cr on odd (co-sited 4:2:2). Combinational from h.
// Stand-in source until Schindler's pg_tsg is ported to 10-bit YCbCr (docs/10, docs/12).

`default_nettype none
`timescale 1ns / 1ps

module sdi_bars_hd #(
    parameter integer H_ACT = 1920
) (
    input  wire [11:0] h,
    output reg  [9:0]  y,
    output reg  [9:0]  c
);
    reg [2:0] bar;
    reg [9:0] cb, cr;

    always @* begin
        bar = (h * 8) / H_ACT;                      // 0..7 across the active line
        case (bar)
            3'd0: begin y = 10'd721; cb = 10'd512; cr = 10'd512; end   // white 75%
            3'd1: begin y = 10'd674; cb = 10'd176; cr = 10'd543; end   // yellow
            3'd2: begin y = 10'd581; cb = 10'd589; cr = 10'd176; end   // cyan
            3'd3: begin y = 10'd534; cb = 10'd253; cr = 10'd207; end   // green
            3'd4: begin y = 10'd251; cb = 10'd771; cr = 10'd817; end   // magenta
            3'd5: begin y = 10'd204; cb = 10'd435; cr = 10'd848; end   // red
            3'd6: begin y = 10'd111; cb = 10'd848; cr = 10'd481; end   // blue
            default: begin y = 10'd64; cb = 10'd512; cr = 10'd512; end // black
        endcase
        c = h[0] ? cr : cb;
    end
endmodule

`default_nettype wire
