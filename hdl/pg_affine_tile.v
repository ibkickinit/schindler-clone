// pg_affine_tile.v — affine coord walker in OUTPUT-TILE order (vs pg_affine's raster order).
// Walks (oty, otx, or, oc) — output tiles tile-row-major, 16x16 px within each — so the cache holds an
// output tile's few source tiles for ALL its 256 px (small working set, no full-frame band). Same affine
// (sx = m_a*ox + m_b*oy + m_c) and same output format as pg_affine; 4-level nested DDA (no per-px multiply).
// Adds o_tlast (last px of an output tile) + o_tuser (first px of frame) for the tile->raster reorder.
`default_nettype none
`timescale 1ns / 1ps
module pg_affine_tile #(
    parameter integer OUT_W=1280, OUT_H=720, IN_W=1920, IN_H=1080, CW=32, FB=12, LTILE=4
) (
    input  wire        clk, rstn,
    input  wire        sof,
    input  wire signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f,
    output wire        o_valid,
    input  wire        o_ready,
    output wire        o_in_window,
    output wire [11:0] o_src_col, o_src_row,
    output wire [11:0] o_h_frac, o_v_frac,
    output wire        o_tlast,    // last px (oc=15,or=15) of an output tile
    output wire        o_tuser     // first px of the frame
);
    localparam integer TILE=(1<<LTILE), OTX=OUT_W/TILE, OTY=OUT_H/TILE;
    // ax/ay = src coord at (otx*16+oc, oty*16+or); r_=row base (oc=0), t_=tile base (oc=0,or=0),
    // s_=tile-row-start base (otx=0,oc=0,or=0). Each level's wrap advances the higher accumulator.
    reg signed [CW-1:0] ax, ay, r_ax, r_ay, t_ax, t_ay, s_ax, s_ay;
    reg [11:0] oc, orr, otx, oty;
    reg running;
    wire accept = o_valid & o_ready;
    wire signed [CW-1-FB:0] ax_int = ax>>>FB, ay_int = ay>>>FB;
    assign o_valid     = running;
    assign o_in_window = (ax_int>=0)&&(ax_int<IN_W)&&(ay_int>=0)&&(ay_int<IN_H);
    assign o_src_col   = ax_int[11:0];
    assign o_src_row   = ay_int[11:0];
    assign o_h_frac    = ax[FB-1:0];
    assign o_v_frac    = ay[FB-1:0];
    assign o_tlast     = (oc==TILE-1) && (orr==TILE-1);
    assign o_tuser     = (oc==0)&&(orr==0)&&(otx==0)&&(oty==0);

    wire oc_last=(oc==TILE-1), or_last=(orr==TILE-1), otx_last=(otx==OTX-1), oty_last=(oty==OTY-1);
    wire last = oc_last && or_last && otx_last && oty_last;
    wire signed [CW-1:0] a16=m_a<<<LTILE, b16=m_b<<<LTILE, d16=m_d<<<LTILE, e16=m_e<<<LTILE;

    always @(posedge clk) begin
        if(!rstn) begin running<=0; oc<=0; orr<=0; otx<=0; oty<=0;
            ax<=0; ay<=0; r_ax<=0; r_ay<=0; t_ax<=0; t_ay<=0; s_ax<=0; s_ay<=0; end
        else if(sof) begin
            ax<=m_c; ay<=m_f; r_ax<=m_c; r_ay<=m_f; t_ax<=m_c; t_ay<=m_f; s_ax<=m_c; s_ay<=m_f;
            oc<=0; orr<=0; otx<=0; oty<=0; running<=1;
        end else if(accept) begin
            if(last) running<=0;
            else if(!oc_last) begin                                   // next col within tile
                oc<=oc+1'b1; ax<=ax+m_a; ay<=ay+m_d;
            end else if(!or_last) begin                               // next row within tile
                oc<=0; orr<=orr+1'b1;
                r_ax<=r_ax+m_b; r_ay<=r_ay+m_e; ax<=r_ax+m_b; ay<=r_ay+m_e;
            end else if(!otx_last) begin                              // next output tile (same tile-row)
                oc<=0; orr<=0; otx<=otx+1'b1;
                t_ax<=t_ax+a16; t_ay<=t_ay+d16; r_ax<=t_ax+a16; r_ay<=t_ay+d16; ax<=t_ax+a16; ay<=t_ay+d16;
            end else begin                                            // next output tile-row
                oc<=0; orr<=0; otx<=0; oty<=oty+1'b1;
                s_ax<=s_ax+b16; s_ay<=s_ay+e16; t_ax<=s_ax+b16; t_ay<=s_ay+e16;
                r_ax<=s_ax+b16; r_ay<=s_ay+e16; ax<=s_ax+b16; ay<=s_ay+e16;
            end
        end
    end
endmodule
`default_nettype wire
