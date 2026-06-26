// pg_projective.v — projective (homography / keystone / corner-pin) address generator.
// Drop-in, port-compatible replacement for pg_affine (same o_valid/o_ready/o_src_col/row/
// o_h_frac/o_v_frac/o_in_window/o_new_row) PLUS two perspective coeffs m_g, m_h.
//
//   Affine today : sx = a*ox+b*oy+c          sy = d*ox+e*oy+f
//   Projective   : w  = g*ox+h*oy+i (i=1)    sx = (a*ox+b*oy+c)/w    sy = (d*ox+e*oy+f)/w
// Numerators nx,ny and denominator w are ALL linear in (ox,oy) -> all three are incremental
// DDAs (no per-pixel multiply for them). The ONLY new op is the per-pixel reciprocal iw=1/w,
// then two multiplies sx=nx*iw, sy=ny*iw. Affine is the EXACT subset g=h=0,i=1 (w=1,iw=1).
//
// PROJECTIVE parameter:
//   0 -> w forced 1.0, reciprocal+multiplies ELIDED; behaviour is byte-for-byte pg_affine
//        (production affine build: set FB=12, leave m_g/m_h tied 0 -> pays NOTHING).
//   1 -> full projective: 3 DDAs + pipelined LUT+Newton-Raphson reciprocal + 2 multiplies.
//
// RECIPROCAL (pure Verilog, NO Xilinx IP):
//   normalize w into mantissa m in [1,2) with RF frac bits (leading-1 detect + barrel shift),
//   seed x0 = LUT[top LUT_BITS of mantissa] ~ 1/m, NR_ITERS Newton steps x<-x*(2 - m*x),
//   de-normalize iw = (1/w)*2^RF. Round-to-nearest in the NR shifts so 1/(power-of-two) lands
//   on the boundary (no integer-coord off-by-one). Bit-exact to tools/pg_projective_golden.py.
//   This module hardcodes the pipeline for NR_ITERS==2 (the chosen config).
//
// PRECISION (budgeted in the golden; at the most-foreshortened edge of a 1280-wide output over
// 1920x1080): FB=20, GFB=36, RF=28, LUT_BITS=9, NR_ITERS=2 -> worst-case 2.7e-3 px (Q.8.5),
// visually lossless. FB was 24 (Q.13.0 precision) through P1-P4 but overflowed the CW=32 signed
// coeff port on the translation coeffs c/f (source coords ~1920 px); FB=20 gives +/-2048 px range.
// See docs/projective-fb-fix.md. (Affine-compat build uses FB=12, untouched.)
//
// HANDSHAKE: same advance-only-on-accept contract as pg_affine. The reciprocal adds pipeline
// latency, so the WHOLE datapath (DDA front + reciprocal pipe + multiply) freezes as one unit
// whenever the output is valid and the consumer is not ready (pipe_en = !(o_valid && !o_ready)).
// Nothing moves while stalled -> no coord is ever dropped or duplicated; throughput stays 1 px/clk.

`default_nettype none
`timescale 1ns / 1ps

module pg_projective #(
    parameter integer OUT_W=1280, OUT_H=720, IN_W=1920, IN_H=1080,
    parameter integer CW=32, FB=24,            // numerator coeff/word width + frac bits
    parameter integer GCW=40, GFB=36,          // perspective coeff word width + frac bits
    parameter integer RF=28, LUT_BITS=9, NR_ITERS=2,
    parameter integer AW=44,                   // numerator accumulator width
    parameter integer WW=48,                   // denominator (w) accumulator width
    parameter integer PROJECTIVE=1
) (
    input  wire        clk, rstn,
    input  wire        sof,
    // DYNAMIC RING (2026-06-26): runtime active source dims (the LOD). The
    // in-window test below uses these so a coord beyond the (smaller) LOD reads
    // the warp's out-of-window matte. 0 -> build-time IN_W/IN_H (legacy).
    input  wire [11:0] in_w_rt, in_h_rt,
    // RUNTIME OUTPUT (2026-06-26): the output raster the warp walks (eol/last).
    // = the VTC active res; switched live 720<->1080. 0 -> build OUT_W/OUT_H.
    input  wire [11:0] out_w_rt, out_h_rt,
    input  wire signed [CW-1:0]  m_a,m_b,m_c,m_d,m_e,m_f,
    input  wire signed [GCW-1:0] m_g,m_h,
    output wire        o_valid,
    input  wire        o_ready,
    output wire        o_in_window,
    output wire [11:0] o_src_col, o_src_row,
    output wire [11:0] o_h_frac, o_v_frac,
    output wire        o_new_row
);
// DYNAMIC RING: effective active source bounds (signed, for the >=0 && <bound tests).
wire signed [12:0] inw_eff = $signed({1'b0, (in_w_rt == 12'd0) ? IN_W[11:0] : in_w_rt});
wire signed [12:0] inh_eff = $signed({1'b0, (in_h_rt == 12'd0) ? IN_H[11:0] : in_h_rt});
// RUNTIME OUTPUT: effective output raster bounds (eol/last). 0 -> build OUT_W/OUT_H.
wire [11:0] outw_eff = (out_w_rt == 12'd0) ? OUT_W[11:0] : out_w_rt;
wire [11:0] outh_eff = (out_h_rt == 12'd0) ? OUT_H[11:0] : out_h_rt;
generate
// =========================== AFFINE SUBSET (byte-for-byte pg_affine) ===========================
if (PROJECTIVE==0) begin : g_affine
    reg signed [CW-1:0] a,b,c,d,e,f, ax,ay,rax,ray;
    reg [11:0] ox, oy; reg running;
    wire accept = o_valid & o_ready;
    wire eol = (ox == outw_eff-12'd1);
    wire last = eol && (oy == outh_eff-12'd1);
    wire signed [CW-1-FB:0] ax_int = ax >>> FB, ay_int = ay >>> FB;
    assign o_valid     = running;
    assign o_in_window = (ax_int>=0)&&(ax_int<inw_eff)&&(ay_int>=0)&&(ay_int<inh_eff);
    assign o_src_col   = ax_int[11:0];
    assign o_src_row   = ay_int[11:0];
    assign o_h_frac    = ax[FB-1 -: 12];      // top 12 frac bits (= ax[11:0] when FB==12)
    assign o_v_frac    = ay[FB-1 -: 12];
    assign o_new_row   = (ox==12'd0);
    always @(posedge clk) begin
        if(!rstn) begin running<=0; ox<=0; oy<=0; ax<=0; ay<=0; rax<=0; ray<=0; end
        else if(sof) begin
            a<=m_a;b<=m_b;c<=m_c;d<=m_d;e<=m_e;f<=m_f;
            ax<=m_c; ay<=m_f; rax<=m_c; ray<=m_f; ox<=0; oy<=0; running<=1;
        end else if(accept) begin
            if(last) running<=0;
            else if(eol) begin ox<=0; oy<=oy+12'd1; rax<=rax+b; ray<=ray+e; ax<=rax+b; ay<=ray+e; end
            else        begin ox<=ox+12'd1; ax<=ax+a; ay<=ay+d; end
        end
    end
end else begin : g_proj
// =============================== FULL PROJECTIVE PATH ===============================
//
// DEEPENED reciprocal pipeline (timing fix — see the detailed stage table at RECIP_LAT below and
// docs/projective-fb-fix.md "reciprocal timing fix"). Every Newton-Raphson multiply now lives in
// its OWN clock with its RAW product registered, and every round-shift / (2 - m*x) subtract is its
// own stage, so no two DSP multiplies (and no multiply->reduction->multiply chain) are ever
// combinationally chained. The whole pipe is gated by pipe_en; throughput stays 1 px/clk and the
// extra latency is hidden by the prefetch lead. (NR_ITERS is fixed at 2 for this datapath.)

    // ---- DEEPENED reciprocal pipeline (timing fix) ----
    // Every DSP multiply now occupies its OWN clock with its RAW product registered (so the DSP
    // output reg absorbs it and the partial-product reduction never chains into the next multiply),
    // and every round-shift / (2 - m*x) subtract is isolated into its own stage. No two multiplies
    // (and no multiply->reduction->multiply chain) are combinational anymore.
    //
    //  S0  latch DDA: w0, valid
    //  S1  leading-1 detect -> msb
    //  S2  normalize w -> mantissa m (Q.RF); seed x0 = LUT[top bits]
    //  S3  MUL : raw product p_mx1 = m*x0           (DSP, raw reg)
    //  S4  RND : mx1 = round(p_mx1>>RF); t1 = 2-mx1  (subtract isolated)
    //  S5  MUL : raw product p_x1 = x0*t1            (DSP, raw reg)
    //  S6  RND : x1 = round(p_x1>>RF)
    //  S7  MUL : raw product p_mx2 = m*x1            (DSP, raw reg)
    //  S8  RND : mx2 = round(p_mx2>>RF); t2 = 2-mx2  (subtract isolated)
    //  S9  MUL : raw product p_x2 = x1*t2            (DSP, raw reg)
    //  S10 RND : x2 = round(p_x2>>RF)
    //  S11 DEN : iw = denorm(x2, msb)
    //  S12 MUL : raw products px=nx*iw, py=ny*iw     (DSP, raw reg)  <- nx/ny meet iw here
    //  S13 OUT : sx=round(px>>RF), sy=...; in_window; register outputs
    // RECIP_LAT = stage index at which iw is valid (= 11). The nx/ny/new_row/valid/w_bad delay line
    // is RECIP_LAT deep so nxq[RECIP_LAT-1] aligns with s11_iw at the S12 multiply.
    localparam integer RECIP_LAT = 11;   // stage index at which iw is valid (s11_v / s11_iw)
    localparam integer DLINE     = RECIP_LAT + 1;   // delay-line depth: nxq[DLINE-1]=nxq[11] aligns s11_iw
    wire pipe_en;

    // ---------------- 3 incremental DDAs ----------------
    reg signed [CW-1:0]  a,b,c,d,e,f;
    reg signed [GCW-1:0] g,h;
    reg signed [AW-1:0]  nx, ny, rnx, rny;
    reg signed [WW-1:0]  w,  rw;
    reg [11:0] ox, oy; reg running;
    wire eol  = (ox == outw_eff-12'd1);
    wire last = eol && (oy == outh_eff-12'd1);
    localparam signed [WW-1:0] WONE = (48'sd1 <<< GFB);          // 1.0 in Q.GFB
    localparam signed [WW-1:0] WEPS = (48'sd1 <<< (GFB-6));      // ~1/64 in Q.GFB (horizon guard)

    wire signed [AW-1:0] a_x={{(AW-CW){a[CW-1]}},a}, b_x={{(AW-CW){b[CW-1]}},b},
                         c_x={{(AW-CW){c[CW-1]}},c}, d_x={{(AW-CW){d[CW-1]}},d},
                         e_x={{(AW-CW){e[CW-1]}},e}, f_x={{(AW-CW){f[CW-1]}},f};
    wire signed [WW-1:0] g_x={{(WW-GCW){g[GCW-1]}},g}, h_x={{(WW-GCW){h[GCW-1]}},h};
    wire signed [AW-1:0] mc_x={{(AW-CW){m_c[CW-1]}},m_c}, mf_x={{(AW-CW){m_f[CW-1]}},m_f};

    always @(posedge clk) begin
        if(!rstn) begin running<=0; ox<=0; oy<=0; nx<=0; ny<=0; w<=0; rnx<=0; rny<=0; rw<=0; end
        else if(sof) begin
            a<=m_a;b<=m_b;c<=m_c;d<=m_d;e<=m_e;f<=m_f; g<=m_g; h<=m_h;
            nx<=mc_x; ny<=mf_x; w<=WONE; rnx<=mc_x; rny<=mf_x; rw<=WONE;
            ox<=0; oy<=0; running<=1;
        end else if(running && pipe_en) begin
            if(last) running<=0;
            else if(eol) begin
                ox<=0; oy<=oy+12'd1;
                rnx<=rnx+b_x; rny<=rny+e_x; rw<=rw+h_x;
                nx <=rnx+b_x; ny <=rny+e_x; w <=rw+h_x;
            end else begin
                ox<=ox+12'd1; nx<=nx+a_x; ny<=ny+d_x; w<=w+g_x;
            end
        end
    end

    // ---------------- LUT seed ROM (1/m at bin centers, RF frac), constant-folded ----------------
    function [RF+1:0] rnd_recip; input integer idx; real fr, m, r; begin
        fr = (idx + 0.5) / (1.0*(1<<LUT_BITS)); m = 1.0 + fr; r = 1.0/m;
        rnd_recip = $rtoi(r * (1<<RF) + 0.5);
    end endfunction
    reg [RF+1:0] seed_lut [0:(1<<LUT_BITS)-1];
    integer li; initial for(li=0; li<(1<<LUT_BITS); li=li+1) seed_lut[li]=rnd_recip(li);

    // leading-1 detect
    function [7:0] msb_of; input [WW-1:0] v; integer i; reg [7:0] r;
        begin r=0; for(i=0;i<WW;i=i+1) if(v[i]) r=i[7:0]; msb_of=r; end
    endfunction
    // normalize: m = w << (RF-msb) (or >>); leading 1 lands at bit RF
    function [RF:0] norm_m; input [WW-1:0] v; input [7:0] msb; integer sh; reg [WW+RF:0] t;
        begin sh = RF - msb;
              t = sh>=0 ? ({{(RF+1){1'b0}},v} << sh) : ({{(RF+1){1'b0}},v} >> (-sh));
              norm_m = t[RF:0]; end
    endfunction
    // denorm: iw = x << (GFB-msb) (or >>)
    function [RF+2:0] denorm; input [RF+1:0] x; input [7:0] msb; integer e; reg [RF+2+WW:0] t;
        begin e = GFB - msb;
              t = e>=0 ? ({{WW{1'b0}},x} << e) : ({{WW{1'b0}},x} >> (-e));
              denorm = t[RF+2:0]; end
    endfunction

    localparam [RF+1:0] HALF_RF = (1 <<< (RF-1));   // round constant for >>RF
    localparam [RF+1:0] TWO_RF  = (2 <<< RF);       // 2.0 in Q.RF

    // ---------------- reciprocal pipeline registers ----------------
    // valid bits, one per stage S0..S11 (S11 = iw valid).
    reg s0_v, s1_v, s2_v, s3_v, s4_v, s5_v, s6_v, s7_v, s8_v, s9_v, s10_v, s11_v;
    reg [WW-1:0] s0_w, s1_w;
    // msb (exponent) carried all the way to the de-normalize at S11.
    reg [7:0] s1_msb,s2_msb,s3_msb,s4_msb,s5_msb,s6_msb,s7_msb,s8_msb,s9_msb,s10_msb;
    // mantissa m carried to whichever multiply needs it (m*x0 @ S3, m*x1 @ S7).
    reg [RF:0] s2_m, s3_m, s4_m, s5_m, s6_m;               // leading 1 @ bit RF
    // x estimates and the x-operands carried across the split multiply/round stages.
    reg [RF+1:0] s2_x;                                     // x0 seed
    reg [RF+1:0] s3_x0, s4_x0;                             // x0 carried to the x1=x0*(2-mx1) multiply
    reg [RF+1:0] s6_x1, s7_x1, s8_x1;                      // x1 carried to the x2=x1*(2-mx2) multiply
    reg [RF+1:0] s4_mx1;                                   // mx1 rounded (Q.RF)
    reg [RF+1:0] s8_mx2;                                   // mx2 rounded (Q.RF)
    reg [RF+1:0] s10_x2;                                   // x2 = round(p_x2) (Q.RF)
    reg [RF+2:0] s11_iw;
    localparam integer MW = 2*RF + 4;                      // product width guard
    reg [MW-1:0] s3_pmx1;                                  // raw m*x0
    reg [MW-1:0] s5_px1;                                   // raw x0*(2-mx1)
    reg [MW-1:0] s7_pmx2;                                  // raw m*x1
    reg [MW-1:0] s9_px2;                                   // raw x1*(2-mx2)

    // parallel delay line for nx/ny/new_row/valid/w_bad, aligned so nx/ny meet iw at the S12 multiply.
    reg signed [AW-1:0] nxq [0:DLINE-1];
    reg signed [AW-1:0] nyq [0:DLINE-1];
    reg [11:0]          nrq [0:DLINE-1];
    reg                 bdq [0:DLINE-1];
    reg                 vvq [0:DLINE-1];
    integer di;

    wire w_bad = ($signed(w) <= WEPS);
    wire [RF:0] m_s1 = norm_m(s1_w, s1_msb);              // normalized mantissa from S1

    // round constant, MW-wide
    wire [MW-1:0] HALF_W = {{(MW-RF){1'b0}}, HALF_RF};

    // (2.0 - m*x) operands, formed in the round stage right before the consuming multiply.
    wire [RF+1:0] two_minus_mx1 = TWO_RF - s4_mx1;        // formed @ S4, consumed by S5 multiply
    wire [RF+1:0] two_minus_mx2 = TWO_RF - s8_mx2;        // formed @ S8, consumed by S9 multiply

    // FULL-WIDTH products (explicit wide wires; m,x are ~RF+1 bits -> products up to ~2*RF+3 bits).
    // Each is a SINGLE multiply whose result is registered raw in the same stage (no chaining).
    wire [MW-1:0] mx1_mul = {1'b0,s2_m} * s2_x;           // S3: m * x0
    wire [MW-1:0] x1_mul  = s4_x0       * two_minus_mx1;  // S5: x0 * (2 - mx1)
    wire [MW-1:0] mx2_mul = {1'b0,s6_m} * s6_x1;          // S7: m * x1
    wire [MW-1:0] x2_mul  = s8_x1       * two_minus_mx2;  // S9: x1 * (2 - mx2)

    always @(posedge clk) begin
        if(!rstn) begin
            s0_v<=0; s1_v<=0; s2_v<=0; s3_v<=0; s4_v<=0; s5_v<=0;
            s6_v<=0; s7_v<=0; s8_v<=0; s9_v<=0; s10_v<=0; s11_v<=0;
            for(di=0; di<DLINE; di=di+1) vvq[di]<=0;
        end else if(pipe_en) begin
            // S0: latch DDA
            s0_v<=running; s0_w<=w;
            // S1: leading-1 detect
            s1_v<=s0_v; s1_w<=s0_w; s1_msb<=msb_of(s0_w);
            // S2: normalize + LUT seed
            s2_v<=s1_v; s2_msb<=s1_msb; s2_m<=m_s1;
            s2_x<=seed_lut[(m_s1-(1<<RF))>>(RF-LUT_BITS)];
            // S3: MUL  raw p_mx1 = m*x0   (DSP, raw product registered)
            s3_v<=s2_v; s3_msb<=s2_msb; s3_m<=s2_m; s3_x0<=s2_x;
            s3_pmx1<=mx1_mul;
            // S4: RND  mx1 = round(p_mx1>>RF); carry x0 for the next multiply
            s4_v<=s3_v; s4_msb<=s3_msb; s4_m<=s3_m; s4_x0<=s3_x0;
            s4_mx1<=( (s3_pmx1 + HALF_W) >> RF );
            // S5: MUL  raw p_x1 = x0*(2-mx1)   (DSP, raw product registered)
            s5_v<=s4_v; s5_msb<=s4_msb; s5_m<=s4_m;
            s5_px1<=x1_mul;
            // S6: RND  x1 = round(p_x1>>RF)
            s6_v<=s5_v; s6_msb<=s5_msb; s6_m<=s5_m;
            s6_x1<=( (s5_px1 + HALF_W) >> RF );
            // S7: MUL  raw p_mx2 = m*x1   (DSP, raw product registered); carry x1
            s7_v<=s6_v; s7_msb<=s6_msb; s7_x1<=s6_x1;
            s7_pmx2<=mx2_mul;
            // S8: RND  mx2 = round(p_mx2>>RF); carry x1
            s8_v<=s7_v; s8_msb<=s7_msb; s8_x1<=s7_x1;
            s8_mx2<=( (s7_pmx2 + HALF_W) >> RF );
            // S9: MUL  raw p_x2 = x1*(2-mx2)   (DSP, raw product registered)
            s9_v<=s8_v; s9_msb<=s8_msb;
            s9_px2<=x2_mul;
            // S10: RND  x2 = round(p_x2>>RF)
            s10_v<=s9_v; s10_msb<=s9_msb;
            s10_x2<=( (s9_px2 + HALF_W) >> RF );
            // S11: DEN  iw = denorm(x2, msb)
            s11_v<=s10_v;
            s11_iw<=denorm(s10_x2, s10_msb);

            // parallel delay line (DLINE deep so nxq[DLINE-1] aligns with s11_iw at the S12 multiply)
            nxq[0]<=nx; nyq[0]<=ny; nrq[0]<=(ox==12'd0)?12'd1:12'd0; bdq[0]<=w_bad; vvq[0]<=running;
            for(di=1; di<DLINE; di=di+1) begin
                nxq[di]<=nxq[di-1]; nyq[di]<=nyq[di-1]; nrq[di]<=nrq[di-1];
                bdq[di]<=bdq[di-1]; vvq[di]<=vvq[di-1];
            end
        end
    end

    // ---------------- S12: final multiply (raw products registered), S13: shift/window/output -------
    // px=nx*iw, py=ny*iw registered RAW so the big AW*(RF+3) multiply is isolated to its own clock;
    // the >>RF reduction + int/frac split + window compare then happen in S13 before the outputs.
    localparam integer PXW = AW + RF + 4;
    reg signed [PXW-1:0] s12_px, s12_py;
    reg                  s12_v, s12_bad; reg [11:0] s12_nr;
    wire signed [PXW-1:0] px_mul = nxq[DLINE-1] * $signed({1'b0,s11_iw});
    wire signed [PXW-1:0] py_mul = nyq[DLINE-1] * $signed({1'b0,s11_iw});

    reg                 o_v_r, o_in_r, o_nr_r;
    reg signed [AW-1:0] sx_q, sy_q;
    wire signed [AW-1:0] sx_n = s12_px >>> RF;
    wire signed [AW-1:0] sy_n = s12_py >>> RF;
    wire signed [AW-1-FB:0] sx_int = sx_n >>> FB, sy_int = sy_n >>> FB;
    wire inwin_n = (!s12_bad) && (sx_int>=0)&&(sx_int<inw_eff)&&(sy_int>=0)&&(sy_int<inh_eff);

    always @(posedge clk) begin
        if(!rstn) begin s12_v<=0; o_v_r<=0; end
        else if(pipe_en) begin
            // S12: register raw products + the aligned side-band (bad/new_row/valid)
            s12_px<=px_mul; s12_py<=py_mul;
            s12_v<=s11_v; s12_bad<=bdq[DLINE-1]; s12_nr<=nrq[DLINE-1];
            // S13: reduce + window + register outputs
            o_v_r<=s12_v; o_in_r<=inwin_n; o_nr_r<=s12_nr[0]; sx_q<=sx_n; sy_q<=sy_n;
        end
    end

    assign pipe_en     = !(o_v_r && !o_ready);
    assign o_valid     = o_v_r;
    assign o_in_window = o_in_r;
    assign o_src_col   = sx_q[FB +: 12];
    assign o_src_row   = sy_q[FB +: 12];
    assign o_h_frac    = sx_q[FB-1 -: 12];
    assign o_v_frac    = sy_q[FB-1 -: 12];
    assign o_new_row   = o_nr_r;

end
endgenerate
endmodule

`default_nettype wire
