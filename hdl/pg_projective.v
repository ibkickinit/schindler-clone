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
// PRECISION (budgeted in the golden; for >=Q.12 sub-pixel at the most-foreshortened edge of a
// 1280-wide output over 1920x1080): FB=24, GFB=36, RF=28, LUT_BITS=9, NR_ITERS=2 -> worst-case
// 1.2e-4 px (Q.13.0). (Affine-compat build uses FB=12.)
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
    input  wire signed [CW-1:0]  m_a,m_b,m_c,m_d,m_e,m_f,
    input  wire signed [GCW-1:0] m_g,m_h,
    output wire        o_valid,
    input  wire        o_ready,
    output wire        o_in_window,
    output wire [11:0] o_src_col, o_src_row,
    output wire [11:0] o_h_frac, o_v_frac,
    output wire        o_new_row
);
generate
// =========================== AFFINE SUBSET (byte-for-byte pg_affine) ===========================
if (PROJECTIVE==0) begin : g_affine
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
// Pipeline (each row a register stage; the whole pipe is gated by pipe_en):
//   S0  latch DDA: w0, nx0, ny0, nr0(new_row), valid; plus w_bad guard
//   S1  leading-1 detect -> msb
//   S2  normalize w -> mantissa m (Q.RF, leading 1 at bit RF); seed x0 = LUT[top bits]
//   S3  NR1a: mx1 = round(m*x0 >> RF)
//   S4  NR1b: x1  = round(x0*(2 - mx1) >> RF)
//   S5  NR2a: mx2 = round(m*x1 >> RF)
//   S6  NR2b: x2  = round(x1*(2 - mx2) >> RF)
//   S7  denorm: iw = x2 << (GFB - msb)            [shift sign per exponent]
//   S8  multiply: sx=round? no, trunc(nx*iw >> RF), sy=...; in_window from sx,sy
// LAT = 8 stages. nx/ny/new_row/valid/w_bad ride a parallel LAT-1 deep delay line to S7,
// where nx/ny meet iw at the S8 multiply. (NR_ITERS is fixed at 2 for this datapath.)

    localparam integer LAT = 8;
    wire pipe_en;

    // ---------------- 3 incremental DDAs ----------------
    reg signed [CW-1:0]  a,b,c,d,e,f;
    reg signed [GCW-1:0] g,h;
    reg signed [AW-1:0]  nx, ny, rnx, rny;
    reg signed [WW-1:0]  w,  rw;
    reg [11:0] ox, oy; reg running;
    wire eol  = (ox == OUT_W[11:0]-12'd1);
    wire last = eol && (oy == OUT_H[11:0]-12'd1);
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
    reg                 s0_v, s1_v, s2_v, s3_v, s4_v, s5_v, s6_v, s7_v;
    reg [WW-1:0]        s0_w, s1_w;
    reg [7:0]           s1_msb, s2_msb, s3_msb, s4_msb, s5_msb, s6_msb, s7_msb;
    reg [RF:0]          s2_m, s3_m, s4_m, s5_m;             // mantissa m carried (leading 1 @ bit RF)
    reg [RF+1:0]        s2_x, s3_x, s4_x, s5_x, s6_x;       // x estimate (Q.RF)
    reg [RF+1:0]        s3_mx, s5_mx;                       // m*x rounded (Q.RF, ~1.0)
    reg [RF+2:0]        s7_iw;

    // parallel delay line for nx/ny/new_row/valid/w_bad, aligned so nx/ny meet iw at the multiply.
    reg signed [AW-1:0] nxq [0:LAT-1];
    reg signed [AW-1:0] nyq [0:LAT-1];
    reg [11:0]          nrq [0:LAT-1];
    reg                 bdq [0:LAT-1];
    reg                 vvq [0:LAT-1];
    integer di;

    wire w_bad = ($signed(w) <= WEPS);
    wire [RF:0] m_s1 = norm_m(s1_w, s1_msb);                // normalized mantissa from S1

    // 2.0 - m*x  in Q.RF  (m*x ~ 1.0, so this is ~1.0; fits RF+2 bits)
    wire [RF+1:0] two_minus_3 = TWO_RF - s3_mx;
    wire [RF+1:0] two_minus_5 = TWO_RF - s5_mx;

    // FULL-WIDTH products (must be explicit wide wires; an in-line A*B inside a narrow assignment
    // context is truncated to the LHS width BEFORE the >>RF and yields 0). m and x are ~RF+1 bits
    // each -> products up to ~2*RF+3 bits.
    localparam integer MW = 2*RF + 4;                       // product width guard
    wire [MW-1:0] mx1_full = {1'b0,s2_m} * s2_x;            // m * x0
    wire [MW-1:0] x1_full  = s3_x       * two_minus_3;      // x0 * (2 - mx1)
    wire [MW-1:0] mx2_full = {1'b0,s4_m} * s4_x;            // m * x1
    wire [MW-1:0] x2_full  = s5_x       * two_minus_5;      // x1 * (2 - mx2)
    wire [MW-1:0] HALF_W   = {{(MW-RF){1'b0}}, HALF_RF};    // round constant, MW-wide

    always @(posedge clk) begin
        if(!rstn) begin
            s0_v<=0; s1_v<=0; s2_v<=0; s3_v<=0; s4_v<=0; s5_v<=0; s6_v<=0; s7_v<=0;
            for(di=0; di<LAT; di=di+1) vvq[di]<=0;
        end else if(pipe_en) begin
            // S0: latch DDA
            s0_v<=running; s0_w<=w;
            // S1: leading-1 detect
            s1_v<=s0_v; s1_w<=s0_w; s1_msb<=msb_of(s0_w);
            // S2: normalize + LUT seed
            s2_v<=s1_v; s2_msb<=s1_msb; s2_m<=m_s1;
            s2_x<=seed_lut[(m_s1-(1<<RF))>>(RF-LUT_BITS)];
            // S3: NR1a  mx1 = round(m*x0)
            s3_v<=s2_v; s3_msb<=s2_msb; s3_m<=s2_m; s3_x<=s2_x;
            s3_mx<=( (mx1_full + HALF_W) >> RF );
            // S4: NR1b  x1 = round(x0*(2-mx1))
            s4_v<=s3_v; s4_msb<=s3_msb; s4_m<=s3_m;
            s4_x<=( (x1_full + HALF_W) >> RF );
            // S5: NR2a  mx2 = round(m*x1)
            s5_v<=s4_v; s5_msb<=s4_msb; s5_m<=s4_m; s5_x<=s4_x;
            s5_mx<=( (mx2_full + HALF_W) >> RF );
            // S6: NR2b  x2 = round(x1*(2-mx2))
            s6_v<=s5_v; s6_msb<=s5_msb;
            s6_x<=( (x2_full + HALF_W) >> RF );
            // S7: de-normalize -> iw
            s7_v<=s6_v; s7_msb<=s6_msb;
            s7_iw<=denorm(s6_x, s6_msb);

            // parallel delay line (LAT deep so nxq[LAT-1] aligns with s7_iw at the multiply)
            nxq[0]<=nx; nyq[0]<=ny; nrq[0]<=(ox==12'd0)?12'd1:12'd0; bdq[0]<=w_bad; vvq[0]<=running;
            for(di=1; di<LAT; di=di+1) begin
                nxq[di]<=nxq[di-1]; nyq[di]<=nyq[di-1]; nrq[di]<=nrq[di-1];
                bdq[di]<=bdq[di-1]; vvq[di]<=vvq[di-1];
            end
        end
    end

    // ---------------- final multiply: sx=nx*iw, sy=ny*iw (>>RF -> Q.FB) ----------------
    reg                 o_v_r, o_in_r, o_nr_r;
    reg signed [AW-1:0] sx_q, sy_q;
    wire signed [AW+RF+3:0] px = nxq[LAT-1] * $signed({1'b0,s7_iw});
    wire signed [AW+RF+3:0] py = nyq[LAT-1] * $signed({1'b0,s7_iw});
    wire signed [AW-1:0] sx_n = px >>> RF;
    wire signed [AW-1:0] sy_n = py >>> RF;
    wire signed [AW-1-FB:0] sx_int = sx_n >>> FB, sy_int = sy_n >>> FB;
    wire inwin_n = (!bdq[LAT-1]) && (sx_int>=0)&&(sx_int<IN_W)&&(sy_int>=0)&&(sy_int<IN_H);

    always @(posedge clk) begin
        if(!rstn) o_v_r<=0;
        else if(pipe_en) begin
            o_v_r<=s7_v; o_in_r<=inwin_n; o_nr_r<=nrq[LAT-1][0]; sx_q<=sx_n; sy_q<=sy_n;
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
