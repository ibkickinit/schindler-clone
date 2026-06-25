// pg_projective_tb.v — self-checking bit-exact test for pg_projective (Phase P1).
//
//  (A) AFFINE EQUIVALENCE: pg_projective#(PROJECTIVE=1, FB=12, g=h=0) must match pg_affine
//      bit-exact for rotation/scale/shift coeff sets (compared in-HDL, no golden file).
//  (B) PROJECTIVE: pg_projective#(FB=20,GFB=36,RF=28,LUT=9,NR=2) must match the Python golden
//      (tools/pg_projective_golden.py) bit-exact for keystone-H/V/HV and a 4-corner pin.
//  Both phases run a clean pass AND a back-pressure pass (random o_ready stalls) to prove the
//  handshake never drops or duplicates a coord. Outputs are captured keyed on (o_valid && ready)
//  so raster alignment is automatic regardless of pipeline latency/stalls.
//
//  Run:  sim/run_pg_projective.sh

`default_nettype none
`timescale 1ns / 1ps

module pg_projective_tb;
    localparam OUT_W=64, OUT_H=48, IN_W=96, IN_H=72;
    localparam N = OUT_W*OUT_H;
    localparam CW=32, GCW=40;

    reg clk=0, rstn=0;
    always #5 clk = ~clk;

    integer errors = 0;
    real PI; initial PI = 3.14159265358979;

    // ============================================================== shared drive/capture ==========
    // We instantiate the DUTs inside tasks-by-config is awkward in Verilog; instead we instantiate
    // all DUTs once and select which we drive/capture via a small mux of sof + ready.

    // ---- (A) affine-equivalence DUTs: pg_affine and pg_projective#(FB=12) ----
    reg                 a_sof;
    reg signed [CW-1:0] a_a,a_b,a_c,a_d,a_e,a_f;
    reg                 a_ready;           // shared ready into both (same backpressure)
    // pg_affine
    wire aff_v, aff_in, aff_nr; wire [11:0] aff_col,aff_row,aff_hf,aff_vf;
    pg_affine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.CW(CW),.FB(12)) u_aff (
        .clk(clk),.rstn(rstn),.sof(a_sof),
        .m_a(a_a),.m_b(a_b),.m_c(a_c),.m_d(a_d),.m_e(a_e),.m_f(a_f),
        .o_valid(aff_v),.o_ready(a_ready),.o_in_window(aff_in),
        .o_src_col(aff_col),.o_src_row(aff_row),.o_h_frac(aff_hf),.o_v_frac(aff_vf),.o_new_row(aff_nr));
    // pg_projective FB=12, g=h=0
    wire pj12_v, pj12_in, pj12_nr; wire [11:0] pj12_col,pj12_row,pj12_hf,pj12_vf;
    pg_projective #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),
                    .CW(CW),.FB(12),.GCW(GCW),.GFB(36),.RF(28),.LUT_BITS(9),.NR_ITERS(2),
                    .AW(44),.WW(48),.PROJECTIVE(1)) u_pj12 (
        .clk(clk),.rstn(rstn),.sof(a_sof),.lod(3'd0),
        .m_a(a_a),.m_b(a_b),.m_c(a_c),.m_d(a_d),.m_e(a_e),.m_f(a_f),
        .m_g({GCW{1'b0}}),.m_h({GCW{1'b0}}),
        .o_valid(pj12_v),.o_ready(a_ready),.o_in_window(pj12_in),
        .o_src_col(pj12_col),.o_src_row(pj12_row),.o_h_frac(pj12_hf),.o_v_frac(pj12_vf),.o_new_row(pj12_nr));

    // ---- (B) projective DUT: pg_projective#(FB=20) ----
    reg                  p_sof, p_ready;
    reg signed [CW-1:0]  p_a,p_b,p_c,p_d,p_e,p_f;
    reg signed [GCW-1:0] p_g,p_h;
    wire pj_v, pj_in, pj_nr; wire [11:0] pj_col,pj_row,pj_hf,pj_vf;
    pg_projective #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),
                    .CW(CW),.FB(20),.GCW(GCW),.GFB(36),.RF(28),.LUT_BITS(9),.NR_ITERS(2),
                    .AW(44),.WW(48),.PROJECTIVE(1)) u_pj (
        .clk(clk),.rstn(rstn),.sof(p_sof),.lod(3'd0),
        .m_a(p_a),.m_b(p_b),.m_c(p_c),.m_d(p_d),.m_e(p_e),.m_f(p_f),.m_g(p_g),.m_h(p_h),
        .o_valid(pj_v),.o_ready(p_ready),.o_in_window(pj_in),
        .o_src_col(pj_col),.o_src_row(pj_row),.o_h_frac(pj_hf),.o_v_frac(pj_vf),.o_new_row(pj_nr));

    // ============================================================== capture arrays ===============
    reg [11:0] Acol[0:N-1],Arow[0:N-1],Ahf[0:N-1],Avf[0:N-1]; reg Ain[0:N-1];
    reg [11:0] Pcol[0:N-1],Prow[0:N-1],Phf[0:N-1],Pvf[0:N-1]; reg Pin[0:N-1];
    integer aidx, pidx; reg cap_aff, cap_pj;
    // affine accept = valid & ready
    always @(posedge clk) if (cap_aff && aff_v && a_ready && aidx<N) begin
        Acol[aidx]=aff_col; Arow[aidx]=aff_row; Ahf[aidx]=aff_hf; Avf[aidx]=aff_vf; Ain[aidx]=aff_in;
        aidx=aidx+1; end
    // pj12 capture (separate index, same drive) — for affine equivalence we compare pj12 vs aff
    integer p12idx; reg [11:0] P12col[0:N-1],P12row[0:N-1],P12hf[0:N-1],P12vf[0:N-1]; reg P12in[0:N-1];
    always @(posedge clk) if (cap_aff && pj12_v && a_ready && p12idx<N) begin
        P12col[p12idx]=pj12_col; P12row[p12idx]=pj12_row; P12hf[p12idx]=pj12_hf; P12vf[p12idx]=pj12_vf;
        P12in[p12idx]=pj12_in; p12idx=p12idx+1; end
    // projective capture
    always @(posedge clk) if (cap_pj && pj_v && p_ready && pidx<N) begin
        Pcol[pidx]=pj_col; Prow[pidx]=pj_row; Phf[pidx]=pj_hf; Pvf[pidx]=pj_vf; Pin[pidx]=pj_in;
        pidx=pidx+1; end

    // pseudo-random ready generator
    reg [31:0] lfsr;
    always @(posedge clk) lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};

    // ============================================================== (A) affine-equivalence ========
    function signed [CW-1:0] q12; input real v; begin q12 = $rtoi(v*(1<<12)); end endfunction

    task set_rot12; input real deg; input real s; begin : sr
        real th,co,si,cxo,cyo,cxs,cys,aa,bb,dd,ee;
        th=deg*PI/180.0; co=$cos(th); si=$sin(th);
        cxo=OUT_W/2.0; cyo=OUT_H/2.0; cxs=IN_W/2.0; cys=IN_H/2.0;
        aa=co/s; bb=si/s; dd=-si/s; ee=co/s;
        a_a=q12(aa); a_b=q12(bb); a_c=q12(cxs-aa*cxo-bb*cyo);
        a_d=q12(dd); a_e=q12(ee); a_f=q12(cys-dd*cxo-ee*cyo);
    end endtask

    task run_affine; input [127:0] name; input use_bp; begin : ra
        integer k, wc, e0;
        e0 = errors;
        aidx=0; p12idx=0; cap_aff=1;
        a_ready=1'b1;
        @(posedge clk); a_sof<=1'b1; @(posedge clk); a_sof<=1'b0;
        wc=0;
        while ((aidx<N || p12idx<N) && wc<(N*8+200)) begin
            a_ready <= use_bp ? lfsr[3] : 1'b1;   // random stalls when use_bp
            @(posedge clk); wc=wc+1;
        end
        a_ready<=1'b1; cap_aff=0;
        if (aidx!=N || p12idx!=N) begin errors=errors+1;
            $display("  ERR %0s capture aff=%0d pj12=%0d /%0d", name, aidx, p12idx, N); end
        for (k=0; k<N && k<aidx && k<p12idx; k=k+1) begin
            if (Ain[k]!==P12in[k] ||
                (Ain[k] && (Acol[k]!==P12col[k]||Arow[k]!==P12row[k]||Ahf[k]!==P12hf[k]||Avf[k]!==P12vf[k]))) begin
                errors=errors+1;
                if(errors-e0<6) $display("  ERR %0s @%0d aff(in%b %0d,%0d,%0d,%0d) != pj12(in%b %0d,%0d,%0d,%0d)",
                    name,k,Ain[k],Acol[k],Arow[k],Ahf[k],Avf[k], P12in[k],P12col[k],P12row[k],P12hf[k],P12vf[k]);
            end
        end
        $display("CASE %0s%0s : errors=%0d", name, use_bp?" [backpressure]":"", errors-e0);
    end endtask

    // ============================================================== (B) projective vs golden ======
    // load coeffs from <case>.coef (8 lines, GCW-bit hex), vectors from <case>.vec
    reg [GCW-1:0] coefmem [0:7];
    integer vf, r, want_in, col, row, hf, vf_, e0p;

    task load_coef; input [1023:0] base; reg [1023:0] path; begin
        $sformat(path, "%0s.coef", base);
        $readmemh(path, coefmem);
        p_a=coefmem[0][CW-1:0]; p_b=coefmem[1][CW-1:0]; p_c=coefmem[2][CW-1:0];
        p_d=coefmem[3][CW-1:0]; p_e=coefmem[4][CW-1:0]; p_f=coefmem[5][CW-1:0];
        p_g=coefmem[6]; p_h=coefmem[7];
    end endtask

    task run_proj; input [1023:0] base; input use_bp; begin : rp
        integer wc; reg [1023:0] vpath;
        e0p = errors;
        load_coef(base);
        // drive frame, capture
        pidx=0; cap_pj=1; p_ready=1'b1;
        @(posedge clk); p_sof<=1'b1; @(posedge clk); p_sof<=1'b0;
        wc=0;
        while (pidx<N && wc<(N*8+400)) begin
            p_ready <= use_bp ? lfsr[5] : 1'b1;
            @(posedge clk); wc=wc+1;
        end
        p_ready<=1'b1; cap_pj=0;
        if (pidx!=N) begin errors=errors+1; $display("  ERR %0s captured %0d/%0d", base, pidx, N); end
        // compare against golden vec
        $sformat(vpath, "%0s.vec", base);
        vf = $fopen(vpath, "r");
        if (vf==0) begin errors=errors+1; $display("  ERR cannot open %0s", vpath); end
        else begin : cmp
            integer k;
            for (k=0; k<N; k=k+1) begin
                r = $fscanf(vf, "%d %h %h %h %h", want_in, col, row, hf, vf_);
                if (Pin[k] !== want_in[0]) begin
                    errors=errors+1;
                    if(errors-e0p<6) $display("  ERR %0s @%0d inwin got=%b exp=%0d", base,k,Pin[k],want_in);
                end else if (want_in[0]) begin
                    if (Pcol[k]!==col[11:0]||Prow[k]!==row[11:0]||Phf[k]!==hf[11:0]||Pvf[k]!==vf_[11:0]) begin
                        errors=errors+1;
                        if(errors-e0p<6) $display("  ERR %0s @%0d got(%0d,%0d,%0d,%0d) exp(%0d,%0d,%0d,%0d)",
                            base,k,Pcol[k],Prow[k],Phf[k],Pvf[k], col,row,hf,vf_);
                    end
                end
            end
            $fclose(vf);
        end
        $display("CASE %0s%0s : errors=%0d", base, use_bp?" [backpressure]":"", errors-e0p);
    end endtask

    // ============================================================== main ==========================
    initial begin
        a_sof=0; p_sof=0; a_ready=1; p_ready=1; lfsr=32'hACE1_2345;
        a_a=0;a_b=0;a_c=0;a_d=0;a_e=0;a_f=0; p_a=0;p_b=0;p_c=0;p_d=0;p_e=0;p_f=0;p_g=0;p_h=0;
        rstn=0; repeat(6) @(posedge clk); rstn=1; repeat(4) @(posedge clk);

        $display("=== (A) affine equivalence: pg_projective#(FB=12,g=h=0) vs pg_affine ===");
        set_rot12(0.0,1.0);   run_affine("identity",0); run_affine("identity",1);
        set_rot12(0.0,2.0);   run_affine("zoom2",0);
        set_rot12(0.0,0.5);   run_affine("shrink0.5",0);
        set_rot12(30.0,1.0);  run_affine("rot30",0);     run_affine("rot30",1);
        set_rot12(90.0,1.0);  run_affine("rot90",0);
        a_a=q12(1.0);a_b=0;a_c=q12(8.0);a_d=0;a_e=q12(1.0);a_f=q12(-5.0); run_affine("shift",0);

        $display("=== (B) projective vs Python golden (keystone / corner-pin) ===");
        run_proj("../../sim/golden_proj/proj_affineid",0);
        run_proj("../../sim/golden_proj/proj_keyH",0);  run_proj("../../sim/golden_proj/proj_keyH",1);
        run_proj("../../sim/golden_proj/proj_keyV",0);
        run_proj("../../sim/golden_proj/proj_keyHV",0); run_proj("../../sim/golden_proj/proj_keyHV",1);
        run_proj("../../sim/golden_proj/proj_corner",0);run_proj("../../sim/golden_proj/proj_corner",1);

        if (errors==0) $display("RESULT: PASS (all cases bit-exact)");
        else           $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule

`default_nettype wire
