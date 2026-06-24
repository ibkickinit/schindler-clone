// pg_warp_projective_faithful_tb.v — P2 faithful full-engine gate for the PROJECTIVE front-end.
//
// Drives pg_warp_engine#(PROJECTIVE=1) (consumer + prefetch BOTH pg_projective) through the FAITHFUL
// AXI MM2S DataMover model (deep cmd FIFO, cmd->beat latency, mid-burst gaps, never drops a beat) — the
// SAME DataMover model the rotation work used to reproduce / prove "completes, no wedge". Geometry is
// now projective (keystone / corner-pin), so the proof is the load-bearing P2 guarantee: the
// demand-fetch covers the foreshortened coordinate spread with NO wedge/deadlock, AND the output is
// bit-exact to the Python golden (tools/pg_projective_golden.py).
//
// OUTPUT SINK / CHECK: capture-on-accept (o_valid && o_ready), comparing each accepted output pixel to
// the golden pixel stream in raster order. This is the same discipline as the P1 TB — capture keyed on
// accept makes the comparison immune to pipeline latency / stall phase, so a frame's COMPLETION (cn
// reaches N) is an unambiguous "no wedge" verdict and the per-pixel compare is unambiguous bit-exactness.
// A line-FIFO ahead of the accept models the real v_axi4s_vid_out buffer (engine runs ahead during
// blanking); o_ready is FIFO-room AND an optional random back-pressure mask (exercises the handshake).
//
// Cases (coeffs from sim/golden_proj/<case>.coef, golden output pixels from <case>.pix):
//   proj_affineid  g=h=0  -> reciprocal-of-1.0 boundary; must equal a clean affine frame.
//   proj_keyH/V    keystone H / V (real foreshortening on one axis).
//   proj_keyHV     keystone both axes.
//   proj_corner    4-corner pin (real perspective).
// Each runs a CLEAN pass and a BACK-PRESSURE pass. PASS = collected==N (frame completed, no wedge) AND
// bit-err==0 (bit-exact to golden).
//
// Small frame (64x48 out <- 96x72 in) so the golden is reusable AND the run completes deterministically;
// LEAD is deep enough to warm the whole frame, isolating wedge/bit-exactness as the only verdict.
`default_nettype none
`timescale 1ns / 1ps

module pg_warp_projective_faithful_tb;
    localparam OUT_W=64, OUT_H=48, IN_W=96, IN_H=72;
    localparam LTILE=4, TILE=16, CW=32, FB=24, GCW=40, GFB=36, NA=OUT_W*OUT_H;
    localparam RF=28, LUT_BITS=9, NR_ITERS=2, AW=44, WW=48;
    // source 96x72 -> 24x18 = 432 4x4 tiles. Cache holds the whole working set; deep lead warms the frame.
    localparam NTILE=512, WAY=4, PD=64, DREQ=64, LEAD=32768;
    // --- DataMover faithfulness knobs (same model as pg_warp_real_faithful_tb) ---
    localparam integer CMD_LAT=28, GAP_EVERY=3, GAP_LEN=2, CMDFD=16, LFD=4096;
    localparam STRIDE=IN_W*3, NBEAT=(TILE*3)/8;     // 6 beats per 16-px row command

    reg clk=0, rstn=0, sof=0;
    reg signed [CW-1:0]  m_a,m_b,m_c,m_d,m_e,m_f;
    reg signed [GCW-1:0] m_g,m_h;
    reg [23:0] matte=24'h101010;
    wire o_valid; wire [23:0] o_pix; wire o_ready;
    wire wreq; wire [11:0] wtx,wty; wire fv; wire [95:0] fblk; wire fl;
    wire dm_req; wire [31:0] dm_addr; wire [11:0] dm_len; wire dm_ready; wire t_ready;
    reg [63:0] beat_data=0; reg beat_valid=0; wire beat_ready; reg beat_last=0;

    pg_warp_engine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),
                     .NTILE(NTILE),.WAY(WAY),.PD(PD),.CW(CW),.FB(FB),.LEAD(LEAD),
                     .PROJECTIVE(1),.GCW(GCW),.GFB(GFB),.RF(RF),.LUT_BITS(LUT_BITS),
                     .NR_ITERS(NR_ITERS),.AW(AW),.WW(WW)) dut (
        .clk(clk),.rstn(rstn),.sof(sof),.lead_rt(20'd0),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.m_g(m_g),.m_h(m_h),.matte(matte),
        .o_valid(o_valid),.o_pix(o_pix),.o_ready(o_ready),
        .fetch_req(wreq),.fetch_tx(wtx),.fetch_ty(wty),.fetch_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl));
    pg_tile_dma #(.IN_W(IN_W),.LTILE(LTILE),.DREQ(DREQ)) u_dma (
        .clk(clk),.rstn(rstn),.srst(1'b0),.frame_base(32'd0),
        .t_req(wreq),.t_tx(wtx),.t_ty(wty),.t_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),.fetch_ready(dm_ready),
        .beat_data(beat_data),.beat_valid(beat_valid),.beat_ready(beat_ready),.beat_last(beat_last));
    always #5 clk=~clk;

    // synthetic source (MUST match tools/pg_projective_golden.py src_px())
    reg [23:0] frame[0:IN_W*IN_H-1];
    function [23:0] pxf; input integer x,y; pxf=frame[y*IN_W+x]; endfunction

    // ============================ FAITHFUL AXI MM2S DataMover (verbatim model) ============================
    reg [31:0] cfa[0:CMDFD-1];
    reg [$clog2(CMDFD):0] cf_cnt; reg [$clog2(CMDFD)-1:0] cf_wr, cf_rd;
    wire cf_full  = (cf_cnt==CMDFD[$clog2(CMDFD):0]);
    wire cf_empty = (cf_cnt==0);
    assign dm_ready = !cf_full;
    wire cf_push = dm_req && dm_ready;
    reg        loaded; reg [3:0] bi; reg [383:0] rb; integer srow, scol, kk;
    reg [9:0]  cold, gapc, bsg; reg cf_load;
    wire out_free = !beat_valid || beat_ready;
    always @(posedge clk) begin
        if(!rstn) begin
            cf_cnt<=0; cf_wr<=0; cf_rd<=0; loaded<=0; bi<=0; cold<=CMD_LAT[9:0];
            gapc<=0; bsg<=0; beat_valid<=0; beat_data<=0; beat_last<=0;
        end else begin
            cf_load=1'b0;
            if(cf_push) begin cfa[cf_wr]<=dm_addr; cf_wr<=cf_wr+1'b1; end
            if(!loaded) begin
                if(cf_empty) cold<=CMD_LAT[9:0];
                else if(cold!=0) cold<=cold-1'b1;
                else begin
                    srow = cfa[cf_rd]/STRIDE; scol = (cfa[cf_rd]-srow*STRIDE)/3;
                    for(kk=0;kk<TILE;kk=kk+1) rb[kk*24 +: 24] = pxf(scol+kk, srow);
                    cf_rd<=cf_rd+1'b1; cf_load=1'b1; loaded<=1'b1; bi<=0;
                end
            end
            if(gapc!=0) gapc<=gapc-1'b1;
            if(out_free) begin
                if(loaded && bi<NBEAT[3:0] && gapc==0) begin
                    beat_data<=rb[bi*64 +: 64]; beat_last<=(bi==NBEAT[3:0]-1'b1); beat_valid<=1'b1;
                    bi<=bi+1'b1;
                    if(bi==NBEAT[3:0]-1'b1) begin loaded<=1'b0; cold<=1; end
                    if(GAP_EVERY!=0 && (bsg+1>=GAP_EVERY[9:0])) begin gapc<=GAP_LEN[9:0]; bsg<=0; end
                    else bsg<=bsg+1'b1;
                end else beat_valid<=1'b0;
            end
            cf_cnt <= cf_cnt + (cf_push?1:0) - (cf_load?1:0);
        end
    end

    // ============================ BUFFERED SINK + CAPTURE-ON-ACCEPT CHECK ============================
    // A line FIFO the engine fills ahead (models the v_axi4s_vid_out buffer); the FIFO drains at ~1px/clk
    // (optionally back-pressured) and each DRAINED pixel is checked against the golden in raster order.
    // o_ready = FIFO-room AND a random mask (when bp) so the engine's accept handshake is exercised.
    reg [23:0] lf[0:LFD-1];
    reg [$clog2(LFD):0] lf_cnt; reg [$clog2(LFD)-1:0] lf_wr, lf_rd;
    integer cn, errors, total, axx, ayy;
    reg [23:0] gpix[0:NA-1];
    reg started, bp_en;
    reg [31:0] lfsr;
    always @(posedge clk) lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    wire lf_full  = (lf_cnt>=LFD[$clog2(LFD):0]-2);
    wire lf_empty = (lf_cnt==0);
    // engine-side: accept into the FIFO when there's room (and not masked by back-pressure)
    assign o_ready = started && !lf_full && (!bp_en || lfsr[5]);
    wire push_px = o_valid && o_ready;
    // drain-side: pop one pixel/clk (optionally stalled) and check vs golden
    reg drain_stall;
    always @(posedge clk) drain_stall <= bp_en ? lfsr[9] : 1'b0;
    wire pop_px = started && !lf_empty && !drain_stall && (cn<NA);

    always @(posedge clk) begin
        if(!rstn) begin lf_wr<=0; lf_rd<=0; lf_cnt<=0; end
        else begin
            if(push_px) begin lf[lf_wr]<=o_pix; lf_wr<=lf_wr+1'b1; end
            if(pop_px) begin
                if(lf[lf_rd]!==gpix[cn]) begin errors<=errors+1;
                    if(errors<8) $display("  ERR idx %0d got %h exp %h",cn,lf[lf_rd],gpix[cn]); end
                lf_rd<=lf_rd+1'b1; cn<=cn+1; total<=total+1;
            end
            lf_cnt <= lf_cnt + (push_px?1:0) - (pop_px?1:0);
        end
    end

    // ---- coeff + golden load from the emitted files ----
    reg [GCW-1:0] coefmem [0:7];
    task load_case; input [1023:0] base; reg [1023:0] cpath, ppath; begin
        $sformat(cpath, "%0s.coef", base); $readmemh(cpath, coefmem);
        m_a=coefmem[0][CW-1:0]; m_b=coefmem[1][CW-1:0]; m_c=coefmem[2][CW-1:0];
        m_d=coefmem[3][CW-1:0]; m_e=coefmem[4][CW-1:0]; m_f=coefmem[5][CW-1:0];
        m_g=coefmem[6]; m_h=coefmem[7];
        $sformat(ppath, "%0s.pix", base); $readmemh(ppath, gpix);
    end endtask

    task run_case; input [1023:0] base; input [127:0] nm; input use_bp; integer wc; begin
        load_case(base);
        cn=0; errors=0; started=0; bp_en=use_bp;
        rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        @(posedge clk); sof<=1; started<=1; @(posedge clk); sof<=0;
        // run until the whole frame is collected (no wedge) or a generous budget elapses (wedge -> FAIL)
        wc=0;
        while (cn<NA && wc<(NA*200)) begin @(posedge clk); wc=wc+1; end
        started<=0;
        $display("PROJ-FAITHFUL %0s%0s LEAD=%0d CMD_LAT=%0d GAP=%0d/%0d: bit-err=%0d collected=%0d/%0d | %s",
                 nm, use_bp?"[bp]":"   ", LEAD, CMD_LAT, GAP_EVERY, GAP_LEN, errors, cn, NA,
                 (errors==0 && cn==NA) ? "PASS" : "FAIL");
        repeat(80)@(posedge clk);
    end endtask

    initial begin
        // source: R=x, G=y, B=(x*3+y*5+7) all masked to 8 bits (matches golden src_px()). NOTE the
        // existing affine TBs leave the blue term 32-bit inside the concat, which over-fills the 24-bit
        // word and ZEROES R/G — harmless there (golden reads the same frame) but here the golden is the
        // Python model, so the fields MUST be 8-bit-exact.
        for(ayy=0;ayy<IN_H;ayy=ayy+1) for(axx=0;axx<IN_W;axx=axx+1)
            frame[ayy*IN_W+axx]= (axx[7:0]<<16) | (ayy[7:0]<<8) | ((axx*3+ayy*5+7) & 8'hFF);
        total=0; lfsr=32'hACE1_2345; m_g=0; m_h=0; cn=0; errors=0;
        // (a) affine-equivalent through the projective path (g=h=0) — full clean frame.
        run_case("../../sim/golden_proj/proj_affineid","affine-id ",0);
        run_case("../../sim/golden_proj/proj_affineid","affine-id ",1);
        // (b) keystone H / V / HV — real foreshortening.
        run_case("../../sim/golden_proj/proj_keyH",    "keystoneH ",0);
        run_case("../../sim/golden_proj/proj_keyH",    "keystoneH ",1);
        run_case("../../sim/golden_proj/proj_keyV",    "keystoneV ",0);
        run_case("../../sim/golden_proj/proj_keyHV",   "keystoneHV",0);
        run_case("../../sim/golden_proj/proj_keyHV",   "keystoneHV",1);
        // (c) 4-corner pin — real perspective.
        run_case("../../sim/golden_proj/proj_corner",  "cornerpin ",0);
        run_case("../../sim/golden_proj/proj_corner",  "cornerpin ",1);
`ifdef EXTREME
        // EXTREME foreshortening probe (worst-case fetch/underrun characterization; opt-in via -d EXTREME).
        run_case("../../sim/golden_proj/proj_keyH_extreme",  "keyHxtrm  ",0);
        run_case("../../sim/golden_proj/proj_corner_extreme","cornXtrm  ",0);
`endif
        $finish;
    end

    initial begin #400_000_000; $display("WATCHDOG cn=%0d err=%0d",cn,errors); $finish; end

    // WEDGE DETECTOR: consumer makes no progress for a long time -> dump (once per case).
    integer stuck=0, lastcn=0; reg dumped=0;
    always @(posedge clk) begin
        if(!(rstn && started)) begin stuck<=0; dumped<=0; lastcn<=0; end
        else begin
            if(cn==lastcn) stuck<=stuck+1; else stuck<=0;
            lastcn<=cn;
            if(stuck==150000 && !dumped) begin
                dumped<=1;
                $display("STALL @cn=%0d  IO[ dm_req=%b beat_v=%b beat_r=%b cf_cnt=%0d loaded=%b o_valid=%b o_ready=%b lf_cnt=%0d ]  ENG[ lead_cnt=%0d pf_cnt(tc)=%0d fetch_req(tc)=%b pf_full=%b ]",
                    cn, dm_req, beat_valid, beat_ready, cf_cnt, loaded, o_valid, o_ready, lf_cnt,
                    dut.lead_cnt, dut.u_tc.pf_cnt, dut.u_tc.fetch_req, dut.u_tc.pf_full);
            end
        end
    end
endmodule

`default_nettype wire
