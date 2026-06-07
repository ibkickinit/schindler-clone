// pg_affine.v — affine address generator (ready/valid producer) for the warp read engine.
//
// Per OUTPUT pixel emits the SOURCE coord (inverse map): sx=a*ox+b*oy+c, sy=d*ox+e*oy+f — ANY affine
// (scale/shift/flip/rotation/shear). Coeffs signed Q(CW-FB).FB, firmware-computed; evaluated by an
// incremental DDA (no per-pixel multiply). o_h_frac/o_v_frac are the TRUE sub-pixel fraction (Q0.FB);
// bilinear weight = top 8 bits.
//
// PROPER HANDSHAKE: after `sof` the walker presents pixel 0 and holds o_valid high; it ADVANCES only
// on an accept (o_valid && o_ready). This is required when the downstream (tile cache) can stall —
// a pulse-valid producer drops coords when the consumer isn't ready.

`default_nettype none
`timescale 1ns / 1ps

module pg_affine #(
    parameter integer OUT_W=1280, OUT_H=720, IN_W=1920, IN_H=1080, CW=32, FB=12
) (
    input  wire        clk, rstn,
    input  wire        sof,                         // 1-cyc: (re)start the raster walk
    input  wire signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f,
    output wire        o_valid,
    input  wire        o_ready,
    output wire        o_in_window,
    output wire [11:0] o_src_col, o_src_row,
    output wire [11:0] o_h_frac, o_v_frac,
    output wire        o_new_row
);
    reg signed [CW-1:0] a,b,c,d,e,f, ax,ay,rax,ray;
    reg [11:0] ox, oy; reg running;
    wire accept = o_valid & o_ready;
    wire eol = (ox == OUT_W[11:0]-12'd1);
    wire last = eol && (oy == OUT_H[11:0]-12'd1);

    wire signed [CW-1-FB:0] ax_int = ax >>> FB, ay_int = ay >>> FB;
    assign o_valid     = running;
    assign o_in_window = (ax_int>=0)&&(ax_int<IN_W)&&(ay_int>=0)&&(ay_int<IN_H);
    assign o_src_col   = ax_int[11:0];
    assign o_src_row   = ay_int[11:0];
    assign o_h_frac    = ax[FB-1:0];
    assign o_v_frac    = ay[FB-1:0];
    assign o_new_row   = (ox==12'd0);

    always @(posedge clk) begin
        if(!rstn) begin running<=0; ox<=0; oy<=0; ax<=0; ay<=0; rax<=0; ray<=0; end
        else if(sof) begin
            a<=m_a;b<=m_b;c<=m_c;d<=m_d;e<=m_e;f<=m_f;
            ax<=m_c; ay<=m_f; rax<=m_c; ray<=m_f; ox<=0; oy<=0; running<=1;
        end else if(accept) begin
            if(last) running<=0;
            else if(eol) begin
                ox<=0; oy<=oy+12'd1;
                rax<=rax+b; ray<=ray+e; ax<=rax+b; ay<=ray+e;
            end else begin
                ox<=ox+12'd1; ax<=ax+a; ay<=ay+d;
            end
        end
    end
endmodule

`default_nettype wire
