// pg_place_affine.v — STAGE-2 placement affine (Bite 1, 2026-06-26).
//
// Two-stage warp model: pg_projective does the CORNER-PIN (output raster ->
// SHEET, 1920x1080 canvas) and emits the full-precision sheet coord (sx_q/sy_q,
// Q.FB). This module applies the PLACEMENT affine (scale + rotation + centering)
// SHEET -> LOD (the compact source), then bounds-tests both spaces:
//   - i_sheet_in (from the projective) = inside the corner-pin sheet quad. If 0
//     -> OFF-SHEET -> the bilinear paints BLACK.
//   - o_lod_in = inside the LOD content. If 0 (but on-sheet) -> GRAY MATTE.
//   - else -> sample the LOD at (o_lod_col,o_lod_row)+frac.
//
// WHY no second reciprocal: pg_projective already divided by the corner-pin
// denominator w (sx=nx/w). A plain affine on the already-divided sheet coord is
// just xl = a*sx + b*sy + c — multiplies + adds, no divide. (Operator's
// same-denominator insight is what guarantees placement-then-pin composes to one
// homography; we exploit it by reusing the divide, not by fusing into it.)
//
// Fixed-latency 2-stage feed-forward pipe, gated by `pen` (downstream skid
// ready). pen depends only on registered/downstream state, never on i_valid
// (axis-tready-independence rule). Same advance-only-on-accept contract as the
// projective tail, so the prefetch lead is unchanged (consumer + prefetch get
// identical latency).

`default_nettype none
`timescale 1ns / 1ps

module pg_place_affine #(
    parameter integer CW = 32,     // coeff word width (signed Q(CW-FB).FB)
    parameter integer FB = 20,     // fractional bits (PROJECTIVE build = 20)
    parameter integer AW = 44      // sheet-coord width (matches pg_projective sx_q)
) (
    input  wire        clk, rstn,
    input  wire        pen,                       // pipe enable (downstream skid s_ready)
    input  wire        i_valid,
    input  wire signed [AW-1:0] i_sheet_x, i_sheet_y, // Q.FB sheet coord (corner-pin output)
    input  wire        i_sheet_in,                // inside the corner-pin sheet quad
    input  wire        i_new_row,
    input  wire signed [CW-1:0] a2,b2,c2,d2,e2,f2, // placement affine (sheet->LOD), Q.FB
    input  wire [11:0] in_w_rt, in_h_rt,          // runtime LOD bounds (0 -> treat as max via caller)
    output reg         o_valid,
    output reg  [11:0] o_lod_col, o_lod_row,
    output reg  [11:0] o_h_frac,  o_v_frac,
    output reg         o_sheet_in,                // carried: off-sheet -> black
    output reg         o_lod_in,                  // inside LOD content -> sample, else matte
    output reg         o_new_row
);
    localparam integer PW = AW + CW;              // raw product width

    // ---- Stage M: isolated multiplies, raw products registered (DSP output reg) ----
    reg signed [PW-1:0] pxa, pxb, pya, pyb;
    reg signed [CW-1:0] c2_m, f2_m;
    reg                 m_valid, m_sheet_in, m_new_row;
    always @(posedge clk) begin
        if(!rstn) begin m_valid<=1'b0; end
        else if(pen) begin
            pxa <= a2 * i_sheet_x;  pxb <= b2 * i_sheet_y;   // numerator X partials
            pya <= d2 * i_sheet_x;  pyb <= e2 * i_sheet_y;   // numerator Y partials
            c2_m <= c2;  f2_m <= f2;
            m_valid <= i_valid;  m_sheet_in <= i_sheet_in;  m_new_row <= i_new_row;
        end
    end

    // ---- Stage A: sum + align c/f + >>FB + split into int/frac + LOD bounds ----
    wire signed [PW-1:0] sumx = pxa + pxb;        // Q.2FB
    wire signed [PW-1:0] sumy = pya + pyb;
    // (sum >>> FB) is Q.FB; add c2/f2 (already Q.FB, sign-extended to AW).
    wire signed [AW-1:0] xl_q = ($signed(sumx >>> FB))[AW-1:0] + {{(AW-CW){c2_m[CW-1]}}, c2_m};
    wire signed [AW-1:0] yl_q = ($signed(sumy >>> FB))[AW-1:0] + {{(AW-CW){f2_m[CW-1]}}, f2_m};
    wire signed [AW-1-FB:0] xl_int = xl_q >>> FB;
    wire signed [AW-1-FB:0] yl_int = yl_q >>> FB;
    wire lod_in = m_sheet_in
                && (xl_int >= 0) && (xl_int < $signed({1'b0, in_w_rt}))
                && (yl_int >= 0) && (yl_int < $signed({1'b0, in_h_rt}));
    always @(posedge clk) begin
        if(!rstn) begin o_valid<=1'b0; end
        else if(pen) begin
            o_lod_col  <= xl_q[FB +: 12];
            o_lod_row  <= yl_q[FB +: 12];
            o_h_frac   <= xl_q[FB-1 -: 12];
            o_v_frac   <= yl_q[FB-1 -: 12];
            o_sheet_in <= m_sheet_in;
            o_lod_in   <= lod_in;
            o_new_row  <= m_new_row;
            o_valid    <= m_valid;
        end
    end
endmodule

`default_nettype wire
