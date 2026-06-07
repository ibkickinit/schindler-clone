// pg_affine.v — affine address generator for the warp read engine (Phase 1 of the
// arbitrary-geometry engine; replaces pg_addrgen's separable DDA with a full 2x3 affine).
//
// Per OUTPUT pixel (ox,oy) it emits the SOURCE coord to read (inverse map):
//   sx = a*ox + b*oy + c      sy = d*ox + e*oy + f
// which is ANY affine: scale, shift, flip, rotation, shear (keystone-shear). Pincushion
// (radial) and keystone (projective divide) layer on later as post-stages on (sx,sy).
//
// Coeffs a..f are signed Q(INT).12 fixed-point, computed once per frame by firmware
// (no hardware trig/divide). Evaluated by an INCREMENTAL DDA — no per-pixel multiply:
//   row start:  ax = rax ;  per pixel: ax += a ;  at EOL: rax += b ; ax = rax  (and y-row)
//   (rax = a*0 + b*oy + c accumulates b each row; ax adds a each column.)
//
// Output is registered: for px_valid in cycle T, o_* are valid in T+1 (matches pg_addrgen).
// o_h_frac/o_v_frac are the TRUE sub-pixel fraction (Q0.12) — the bilinear weight is the top
// 8 bits directly (no inv_w needed; the affine DDA yields the real fraction, unlike the
// integer-numerator DDA in pg_addrgen).

`default_nettype none
`timescale 1ns / 1ps

module pg_affine #(
    parameter integer OUT_W = 1280,
    parameter integer OUT_H = 720,
    parameter integer IN_W  = 1920,
    parameter integer IN_H  = 1080,
    parameter integer CW    = 32,     // coeff/accumulator width (signed)
    parameter integer FB    = 12      // fractional bits (Q(CW-FB).FB)
) (
    input  wire                 clk,
    input  wire                 rstn,
    input  wire                 sof,        // 1-cyc before first active pixel
    input  wire                 px_valid,   // 1 per active output pixel, raster order

    // affine coeffs, signed Q(CW-FB).FB, latched at sof (frame-atomic)
    input  wire signed [CW-1:0] m_a, m_b, m_c,   // sx = a*ox + b*oy + c
    input  wire signed [CW-1:0] m_d, m_e, m_f,   // sy = d*ox + e*oy + f

    output reg                  o_valid,
    output reg                  o_in_window,
    output reg  [11:0]          o_src_col,
    output reg  [11:0]          o_src_row,
    output reg  [11:0]          o_h_frac,   // Q0.12 sub-pixel X (bilinear weight = [11:4])
    output reg  [11:0]          o_v_frac,   // Q0.12 sub-pixel Y
    output reg                  o_new_row
);
    // latched coeffs
    reg signed [CW-1:0] a, b, c, d, e, f;
    // raster position
    reg [11:0] ox, oy;
    // DDA accumulators (current pixel source coord + row-start), signed Q.FB
    reg signed [CW-1:0] ax, ay, rax, ray;

    wire eol = (ox == OUT_W[11:0] - 12'd1);

    // integer + fractional split of the current source coord
    wire signed [CW-1-FB:0] ax_int = ax >>> FB;
    wire signed [CW-1-FB:0] ay_int = ay >>> FB;
    wire in_x = (ax_int >= 0) && (ax_int <  IN_W) ;   // last-col handled by linefetch mirror
    wire in_y = (ay_int >= 0) && (ay_int <  IN_H) ;

    always @(posedge clk) begin
        if (!rstn) begin
            ox <= 0; oy <= 0; ax <= 0; ay <= 0; rax <= 0; ray <= 0;
            a <= 0; b <= 0; c <= 0; d <= 0; e <= 0; f <= 0;
            o_valid <= 1'b0; o_in_window <= 1'b0; o_new_row <= 1'b0;
            o_src_col <= 0; o_src_row <= 0; o_h_frac <= 0; o_v_frac <= 0;
        end else begin
            o_valid   <= 1'b0;
            o_new_row <= 1'b0;
            if (sof) begin
                a <= m_a; b <= m_b; c <= m_c; d <= m_d; e <= m_e; f <= m_f;
                ox <= 0; oy <= 0;
                ax <= m_c; ay <= m_f;       // (ox,oy)=(0,0) -> sx=c, sy=f
                rax <= m_c; ray <= m_f;      // row-start accumulators
            end else if (px_valid) begin
                // ---- emit current pixel ----
                o_valid     <= 1'b1;
                o_in_window <= in_x && in_y;
                o_src_col   <= ax_int[11:0];
                o_src_row   <= ay_int[11:0];
                o_h_frac    <= ax[FB-1:0];
                o_v_frac    <= ay[FB-1:0];
                o_new_row   <= (ox == 12'd0);
                // ---- advance ----
                if (eol) begin
                    ox  <= 12'd0;
                    oy  <= oy + 12'd1;
                    rax <= rax + b;  ray <= ray + e;     // next row start
                    ax  <= rax + b;  ay  <= ray + e;
                end else begin
                    ox <= ox + 12'd1;
                    ax <= ax + a;    ay <= ay + d;
                end
            end
        end
    end
endmodule

`default_nettype wire
