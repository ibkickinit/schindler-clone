// pg_pincushion.v — STAGE-2 radial (pincushion/barrel) warp (Bite 2, 2026-06-26).
//
// Two-stage warp model (Bite 1): pg_projective does the CORNER-PIN (output -> SHEET) and emits the
// full-precision sheet coord (sx/sy, Q.FB). This module applies a RADIAL distortion to that sheet
// coord BEFORE the placement affine (sheet -> LOD):
//
//   r2    = dx^2 + dy^2          (dx = sx - cx, dy = sy - cy ; cx/cy = output centre, in pixels)
//   r2max = cx^2 + cy^2          (the CORNER radius^2 — displacement vanishes here)
//   gx    = kx * (r2max - r2)    gy = ky * (r2max - r2)  (signed displacement factors, Q.FB)
//   sx'   = sx + dx * gx         sy' = sy + dy * gy
//
// INDEPENDENT X/Y (2026-06-28): the radial vanishing factor (r2max - r2) is shared, but the per-axis
// coefficient is split — kx scales the HORIZONTAL bow, ky the VERTICAL. kx==ky reproduces the prior
// symmetric pincushion byte-for-byte; ky==0 -> pure horizontal bow, kx==0 -> pure vertical bow.
//
// CORNER-PINNED (2026-06-26): g vanishes at r=r2max (the frame corners) so the 4 corners stay PINNED
// and the interior bows in/out (true pincushion/barrel). The earlier g=k*r2 grew with radius, so the
// corners moved the MOST and the content dragged off the corners into matte — the wrong feel. |bow|
// now peaks near r=sqrt(r2max/3) at ~0.385*rmax*amt.
//
// k>0 bows the interior OUT (barrel), k<0 bows it IN (pincushion). The firmware sets each axis
// k = round((amt / r2max) * 2^(FB+KPSH)). kx==ky==0 -> gx==gy==0 -> sx'=sx, sy'=sy (byte-for-byte
// transparent == Bite 1, so the default build is unchanged).
//
// Under an IDENTITY corner-pin the sheet coord equals the output coord, so this is exactly an
// output-space pincushion (the primary use). The sheet_in (off-sheet -> black) bit is carried through
// UNCHANGED from the projective (the corner-pin's black exterior is not itself bowed — a documented v1
// limitation); the LOD/matte bounds are re-tested downstream in pg_place_affine on the displaced coord,
// so the source AND its matte bow together.
//
// Fixed-latency feed-forward pipe gated by `pen` (downstream skid ready). pen depends only on
// registered/downstream state, never on i_valid (axis-tready-independence rule). Same advance-only-on-
// accept contract as pg_place_affine / the projective tail, so the prefetch lead is unchanged
// (consumer + prefetch get identical latency).
//
// Radial displacement is inherently cubic (disp_x = k*dx*(dx^2+dy^2)); the multiplies are pipelined,
// one DSP product registered raw per stage, so no two multiplies chain (74.25 MHz timing, like the
// projective reciprocal + pg_place_affine).

`default_nettype none
`timescale 1ns / 1ps

module pg_pincushion #(
    parameter integer FB    = 20,   // sheet-coord fractional bits (PROJECTIVE build = 20)
    parameter integer AW    = 44,   // sheet-coord width (matches pg_projective sx_q / pg_place_affine)
    parameter integer KPW   = 32,   // k_pin coeff width (signed)
    parameter integer KPSH  = 20,   // shift after (k_pin*r2) to land g in Q.FB (k_pin is Q(FB+KPSH))
    parameter integer PXW   = 13,   // centre-relative pixel coord width (signed; +/-4096 px headroom)
    parameter integer R2W   = 26    // r2 accumulator width (max ~ (2*PXW) +1)
) (
    input  wire        clk, rstn,
    input  wire        pen,                       // pipe enable (downstream skid s_ready)
    input  wire        i_valid,
    input  wire signed [AW-1:0] i_sheet_x, i_sheet_y, // Q.FB sheet coord (corner-pin output)
    input  wire        i_sheet_in,                // inside the corner-pin sheet quad (carried unchanged)
    input  wire        i_new_row,
    input  wire signed [KPW-1:0] kx, ky,          // per-axis radial coeff (Q(FB+KPSH); 0 -> transparent)
    input  wire [11:0] cx, cy,                    // output centre, in pixels (= out_w/2, out_h/2)
    output reg         o_valid,
    output reg  signed [AW-1:0] o_sheet_x, o_sheet_y,
    output reg         o_sheet_in,
    output reg         o_new_row
);
    localparam integer GW  = R2W + KPW - KPSH + 2; // g width after the >>KPSH (signed, generous)
    localparam integer DPW = AW + GW;              // dx*g raw product width

    // centre in Q.FB (sign-extended to AW) for the full-precision dx/dy.
    wire signed [AW-1:0] cx_q = $signed({1'b0, cx}) <<< FB;
    wire signed [AW-1:0] cy_q = $signed({1'b0, cy}) <<< FB;

    // ---- Stage 0: centre-relative coords (pixel for r2, full-Q for the displacement) ----
    reg signed [PXW-1:0] dxp0, dyp0;
    reg signed [AW-1:0]  dxf0, dyf0, sx0, sy0;
    reg                  v0, sin0, nr0;
    wire signed [12:0]   sx_int = i_sheet_x >>> FB;   // sheet integer px
    wire signed [12:0]   sy_int = i_sheet_y >>> FB;
    always @(posedge clk) begin
        if(!rstn) v0 <= 1'b0;
        else if(pen) begin
            dxp0 <= sx_int - $signed({1'b0, cx});      // centre-relative px (for r2)
            dyp0 <= sy_int - $signed({1'b0, cy});
            dxf0 <= i_sheet_x - cx_q;                  // centre-relative Q.FB (for the displacement)
            dyf0 <= i_sheet_y - cy_q;
            sx0  <= i_sheet_x;  sy0 <= i_sheet_y;
            v0   <= i_valid;  sin0 <= i_sheet_in;  nr0 <= i_new_row;
        end
    end

    // ---- Stage 1: squares (registered raw products). Also cx^2/cy^2 for r2max (corner radius^2). ----
    reg [2*PXW-1:0] dxsq1, dysq1, cxsq1, cysq1;
    reg signed [AW-1:0] dxf1, dyf1, sx1, sy1;
    reg                 v1, sin1, nr1;
    always @(posedge clk) begin
        if(!rstn) v1 <= 1'b0;
        else if(pen) begin
            dxsq1 <= dxp0 * dxp0;   dysq1 <= dyp0 * dyp0;   // unsigned magnitudes
            cxsq1 <= cx * cx;       cysq1 <= cy * cy;        // corner radius^2 components
            dxf1  <= dxf0;  dyf1 <= dyf0;  sx1 <= sx0;  sy1 <= sy0;
            v1    <= v0;  sin1 <= sin0;  nr1 <= nr0;
        end
    end

    // ---- Stage 2: r2 = dx^2 + dy^2 ; r2max = cx^2 + cy^2 ----
    reg [R2W-1:0] r2_2, r2max_2;
    reg signed [AW-1:0] dxf2, dyf2, sx2, sy2;
    reg                 v2, sin2, nr2;
    always @(posedge clk) begin
        if(!rstn) v2 <= 1'b0;
        else if(pen) begin
            r2_2    <= dxsq1 + dysq1;
            r2max_2 <= cxsq1 + cysq1;
            dxf2 <= dxf1;  dyf2 <= dyf1;  sx2 <= sx1;  sy2 <= sy1;
            v2   <= v1;  sin2 <= sin1;  nr2 <= nr1;
        end
    end

    // ---- Stage 3: gq_raw = k{x,y} * (r2max - r2)  (signed; vanishes at the corner -> corners pinned) ----
    // The (r2max - r2) factor is shared; the per-axis coeff (kx/ky) is applied independently so the
    // horizontal and vertical bow scale separately. Two registered raw products (one per axis).
    wire signed [R2W:0] rdiff = $signed({1'b0, r2max_2}) - $signed({1'b0, r2_2});
    reg signed [KPW+R2W:0] gqrx3, gqry3;
    reg signed [AW-1:0] dxf3, dyf3, sx3, sy3;
    reg                 v3, sin3, nr3;
    always @(posedge clk) begin
        if(!rstn) v3 <= 1'b0;
        else if(pen) begin
            gqrx3 <= kx * rdiff;   gqry3 <= ky * rdiff;
            dxf3 <= dxf2;  dyf3 <= dyf2;  sx3 <= sx2;  sy3 <= sy2;
            v3   <= v2;  sin3 <= sin2;  nr3 <= nr2;
        end
    end

    // ---- Stage 4: g = gq_raw >>> KPSH  (Q.FB displacement factor; per axis) ----
    reg signed [GW-1:0] gx4, gy4;
    reg signed [AW-1:0] dxf4, dyf4, sx4, sy4;
    reg                 v4, sin4, nr4;
    always @(posedge clk) begin
        if(!rstn) v4 <= 1'b0;
        else if(pen) begin
            gx4  <= gqrx3 >>> KPSH;   gy4 <= gqry3 >>> KPSH;
            dxf4 <= dxf3;  dyf4 <= dyf3;  sx4 <= sx3;  sy4 <= sy3;
            v4   <= v3;  sin4 <= sin3;  nr4 <= nr3;
        end
    end

    // ---- Stage 5: dispx/dispy raw = dxf*gx, dyf*gy (registered raw) ----
    reg signed [DPW-1:0] dpx5, dpy5;
    reg signed [AW-1:0] sx5, sy5;
    reg                 v5, sin5, nr5;
    always @(posedge clk) begin
        if(!rstn) v5 <= 1'b0;
        else if(pen) begin
            dpx5 <= dxf4 * gx4;   dpy5 <= dyf4 * gy4;
            sx5  <= sx4;  sy5 <= sy4;
            v5   <= v4;  sin5 <= sin4;  nr5 <= nr4;
        end
    end

    // ---- Stage 6: disp = raw >>> FB ; sx' = sx + disp ; output ----
    wire signed [AW-1:0] dispx = dpx5 >>> FB;
    wire signed [AW-1:0] dispy = dpy5 >>> FB;
    always @(posedge clk) begin
        if(!rstn) o_valid <= 1'b0;
        else if(pen) begin
            o_sheet_x  <= sx5 + dispx;
            o_sheet_y  <= sy5 + dispy;
            o_sheet_in <= sin5;
            o_new_row  <= nr5;
            o_valid    <= v5;
        end
    end
endmodule

`default_nettype wire
