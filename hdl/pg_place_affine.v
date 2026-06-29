// pg_place_affine.v — STAGE-2 placement affine (Bite 1, 2026-06-26) + edge AA (#48, 2026-06-26).
//
// Two-stage warp model: pg_projective does the CORNER-PIN (output -> SHEET, 1920x1080 canvas) and emits
// the full-precision sheet coord (sx_q/sy_q, Q.FB). This module applies the PLACEMENT affine (scale +
// rotation + centering) SHEET -> LOD (the compact source), then bounds-tests both spaces:
//   - i_sheet_in (from the projective) = inside the corner-pin sheet quad. If 0 -> OFF-SHEET -> BLACK.
//   - o_alpha = LOD-content COVERAGE (0=fully matte/off-content .. 255=fully content), ramped over the
//     outer 1px of the LOD so the matte/content edge ANTI-ALIASES (was a hard binary lod_in -> jagged on
//     curved/angled edges; #48). o_lod_in = sheet_in && alpha>0 = the FETCH gate.
//   - the bilinear blends content<->matte by o_alpha (matte where alpha=0, content where 255).
//
// WHY no second reciprocal: pg_projective already divided by the corner-pin denominator w (sx=nx/w). A
// plain affine on the already-divided sheet coord is just xl = a*sx + b*sy + c — multiplies + adds.
//
// Fixed-latency 3-stage feed-forward pipe (M multiplies / A sum+coord+edge-distance / B alpha+outputs),
// gated by `pen` (downstream skid ready). pen depends only on registered/downstream state, never on
// i_valid (axis-tready-independence rule). Same advance-only-on-accept contract as the projective tail,
// so the prefetch lead is unchanged (consumer + prefetch get identical latency).

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
    output reg         o_lod_in,                  // sheet_in && alpha>0 -> FETCH gate
    output reg  [7:0]  o_alpha,                   // LOD-content coverage (0=matte .. 255=content), edge AA
    output reg         o_new_row
);
    localparam integer PW = AW + CW;                       // raw product width
    localparam signed [AW-1:0] HALF = (1 <<< (FB-1));      // 0.5 in Q.FB (ramp centre offset)
    localparam signed [AW-1:0] ONE  = (1 <<< FB);          // 1.0 in Q.FB

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

    // ---- Stage A1: sum partials + align c/f + >>FB -> LOD coord (REGISTERED) ----
    // Was one combinational cone (sum -> shift -> +c -> edge-dist -> +HALF) of ~21 logic levels feeding
    // covx_raw; under the TSG build's added congestion that cone slipped to WNS +0.003 (sub-jitter). Split
    // into A1 (this) + A2 (below) so each half is ~half the depth. Functionally identical, +1 pipe stage:
    // both u_place_c and u_place_p (same module) gain the cycle equally, and both legs are valid/ready
    // elastic (skid-buffered, lead is a tile COUNT not a latency) so the cache stays coherent. (#margin)
    wire signed [PW-1:0] sumx = pxa + pxb;        // Q.2FB
    wire signed [PW-1:0] sumy = pya + pyb;
    wire signed [AW-1:0] sumx_sh = sumx >>> FB;   // arithmetic shift, auto-truncated to AW (forbidden to
    wire signed [AW-1:0] sumy_sh = sumy >>> FB;   // part-select a parenthesised expr -> intermediate wire)
    wire signed [AW-1:0] xl_qc = sumx_sh + {{(AW-CW){c2_m[CW-1]}}, c2_m};
    wire signed [AW-1:0] yl_qc = sumy_sh + {{(AW-CW){f2_m[CW-1]}}, f2_m};

    reg signed [AW-1:0] xl_a1, yl_a1;             // LOD coord, registered between the two adder cones
    reg                 a1_valid, a1_sheet_in, a1_new_row;
    always @(posedge clk) begin
        if(!rstn) begin a1_valid<=1'b0; end
        else if(pen) begin
            xl_a1 <= xl_qc;  yl_a1 <= yl_qc;
            a1_valid <= m_valid;  a1_sheet_in <= m_sheet_in;  a1_new_row <= m_new_row;
        end
    end

    // ---- Stage A2: per-axis edge distance for the AA ramp + cov (REGISTERED) ----
    // LOD bounds in Q.FB; the content occupies xl in [0, in_w). dist = signed distance to the nearer edge.
    wire signed [AW-1:0] inw_q = $signed({1'b0, in_w_rt}) <<< FB;
    wire signed [AW-1:0] inh_q = $signed({1'b0, in_h_rt}) <<< FB;
    wire signed [AW-1:0] dxr   = inw_q - xl_a1;            // distance to right edge
    wire signed [AW-1:0] dyr   = inh_q - yl_a1;
    wire signed [AW-1:0] distx = (xl_a1 < dxr) ? xl_a1 : dxr;   // nearer x-edge distance (signed)
    wire signed [AW-1:0] disty = (yl_a1 < dyr) ? yl_a1 : dyr;

    reg signed [AW-1:0] xl_q, yl_q, covx_raw, covy_raw;   // covX_raw = dist + 0.5 (Q.FB; clamp+extract in B)
    reg                 a_valid, a_sheet_in, a_new_row;
    always @(posedge clk) begin
        if(!rstn) begin a_valid<=1'b0; end
        else if(pen) begin
            xl_q <= xl_a1;  yl_q <= yl_a1;
            covx_raw <= distx + HALF;  covy_raw <= disty + HALF;
            a_valid <= a1_valid;  a_sheet_in <= a1_sheet_in;  a_new_row <= a1_new_row;
        end
    end

    // ---- Stage B: clamp coverage -> 8-bit alpha (min of the two axes) ; register outputs ----
    // alpha ramps 0..255 over the outer 1px (covX_raw in (0,1) -> top 8 frac bits; <=0 -> 0; >=1 -> 255).
    // min() (not product) so fully-interior pixels stay 255 (no matte dilution); a corner picks the
    // tighter axis. Interior -> 255 (pure content); exact edge centre -> 128 (50/50); 1px out -> 0 (matte).
    wire        negx = covx_raw[AW-1];                    // < 0
    wire        bigx = |covx_raw[AW-2:FB];                // >= 1.0
    wire        negy = covy_raw[AW-1];
    wire        bigy = |covy_raw[AW-2:FB];
    wire [7:0]  ax   = negx ? 8'd0 : (bigx ? 8'd255 : covx_raw[FB-1 -: 8]);
    wire [7:0]  ay   = negy ? 8'd0 : (bigy ? 8'd255 : covy_raw[FB-1 -: 8]);
    wire [7:0]  alpha = (ax < ay) ? ax : ay;
    always @(posedge clk) begin
        if(!rstn) begin o_valid<=1'b0; end
        else if(pen) begin
            o_lod_col  <= xl_q[FB +: 12];
            o_lod_row  <= yl_q[FB +: 12];
            o_h_frac   <= xl_q[FB-1 -: 12];
            o_v_frac   <= yl_q[FB-1 -: 12];
            o_sheet_in <= a_sheet_in;
            o_alpha    <= alpha;
            o_lod_in   <= a_sheet_in && (alpha != 8'd0);   // fetch gate
            o_new_row  <= a_new_row;
            o_valid    <= a_valid;
        end
    end
endmodule

`default_nettype wire
