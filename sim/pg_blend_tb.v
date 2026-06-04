// pg_blend_tb.v — GATE for the Mackin dual-fetch blend (task #103).
//
// Drives pg_compose directly with blend_en=1 (forced worst case: EVERY in-window
// pixel blends, so EVERY window row does the 2x line fill). Proves two things
// before any Vivado build:
//   (1) BANDWIDTH: the output FIFO never starves (starv=0) at 2x line-fill, on a
//       geometry whose dual-fill/row-budget ratio mirrors the real hardware
//       (1440 beats / 1650 cyc ≈ 0.87). If the ring can't stay fed at 2x, this
//       reproduces the underrun here instead of at the bench.
//   (2) CORRECTNESS: every blended output pixel == the mackin lerp
//       clamp(A + ((a*(B-A)+0x4000)>>15)) per channel, vs an independent golden.
//
// Behavioral DataMover: 1 beat/clk, serves a line from frame A (base BASE_A) or
// frame B (base BASE_B) by decoding the command SADDR. A and B carry DISTINCT
// pixel data so the blend is observable.
//
// Geometry: OUT_W=128, IN_W=256 -> dual-fill = 2*ceil(256*3/8)=192 beats/row;
// budget = OUT_W+HBLANK = 128+92 = 220 cyc -> ratio 0.873 == real. starv=0 here
// ⇒ the real 1440/1650 fits with the same margin.

`default_nettype none
`timescale 1ns / 1ps

module pg_blend_tb;
    localparam integer OUT_W=128, OUT_H=24, IN_W=256, IN_H=24;
    localparam integer STRIDE = IN_W*3;          // 768 bytes/line
    localparam [31:0]  BASE_A = 32'h1000_0000;
    localparam [31:0]  BASE_B = 32'h2000_0000;   // far from A so SADDR decodes cleanly
    localparam integer FIFO_DEPTH=64, NBUF=5;
    localparam integer HBLANK=92, VBLANK=400;
    localparam [7:0]   ALPHA = 8'd64;             // mid-ish blend weight
    localparam [15:0]  ALPHA_Q15 = {1'b0, ALPHA, ALPHA[6:0]};  // matches pg_compose

    reg clk=1'b0; always #5 clk=~clk;
    reg rstn;

    reg         vtg_vsync, m_tready, blend_en;
    reg  [11:0] out_w_win,out_h_win,pos_x,pos_y,hsi,hsf,vsi,vsf;
    reg  [23:0] matte;
    reg  [31:0] base_a, base_b;
    reg  [7:0]  alpha;

    wire [23:0] m_tdata; wire m_tvalid, m_tuser, m_tlast;
    wire        fetch_req; wire [31:0] fetch_addr; wire [11:0] fetch_len;
    reg  [63:0] dm_tdata; reg dm_tvalid, dm_tlast; wire dm_tready;

    pg_compose #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),
        .STRIDE(STRIDE),.FIFO_DEPTH(FIFO_DEPTH),.NBUF(NBUF)) dut (
        .clk(clk),.rstn(rstn),.vtg_vsync(vtg_vsync),
        .frame_base_addr(base_a),.frame_base_addr2(base_b),
        .blend_alpha(alpha),.blend_en(blend_en),
        .out_w_win(out_w_win),.out_h_win(out_h_win),.pos_x(pos_x),.pos_y(pos_y),
        .src_col0(12'd0),.src_row0(12'd0),
        .h_step_int(hsi),.h_step_frac(hsf),.v_step_int(vsi),.v_step_frac(vsf),.matte_rgb(matte),
        .m_tdata(m_tdata),.m_tvalid(m_tvalid),.m_tready(m_tready),.m_tuser(m_tuser),.m_tlast(m_tlast),
        .fetch_req(fetch_req),.fetch_addr(fetch_addr),.fetch_len(fetch_len),
        .beat_data(dm_tdata),.beat_valid(dm_tvalid),.beat_ready(dm_tready),.beat_last(dm_tlast),
        .dbg_src_col(),.dbg_src_row(),.dbg_a_valid(),.dbg_a_inwin(),.dbg_a_newrow(),
        .dbg_resident(),.dbg_rd_data(),.dbg_rd_row(),.dbg_pf_src(),.dbg_pf_next_k(),
        .dbg_served(),.dbg_m3_busy(),.dbg_pf_req(),.dbg_push_en(),.dbg_push_data(),
        .dbg_fill_sel(),.dbg_rd_sel(),.dbg_have_row());

    // distinct pixel data per frame
    function [23:0] gA; input integer r,c; gA=(r*7919 + c*31 + 12345)&24'hFFFFFF; endfunction
    function [23:0] gB; input integer r,c; gB=(r*5003 + c*97 + 54321)&24'hFFFFFF; endfunction
    function [7:0] lbyte; input integer fr,r,off; integer p,ch; reg [23:0] pv; begin
        p=off/3; ch=off%3; pv = fr ? gB(r,p) : gA(r,p);
        lbyte = (ch==0)?pv[7:0] : (ch==1)?pv[15:8] : pv[23:16];   // [G,B,R] mem order
    end endfunction

    // golden mackin lerp (mirror of pg_compose lerp8, per channel).
    // aa/diff/prod/res are signed integers so a*diff stays SIGNED (a is positive).
    function [7:0] lerp8; input [7:0] pv,cv; input [15:0] a;
        integer pvv, cvv, aa, diff, prod, res; begin
            pvv=pv; cvv=cv; aa=a;           // all positive integers (signed context)
            diff = cvv - pvv;               // signed -255..255
            prod = aa*diff;                 // signed
            res  = pvv + ((prod + 16384) >>> 15);
            lerp8 = (res<0)?0:(res>255)?255:res;
        end
    endfunction
    function [23:0] blend24; input [23:0] av,bv; input [15:0] a;
        blend24 = { lerp8(av[23:16],bv[23:16],a), lerp8(av[15:8],bv[15:8],a), lerp8(av[7:0],bv[7:0],a) };
    endfunction

    integer errors, c_ow,c_oh,c_px,c_py;
    function integer ginwin; input integer ox,oy;
        ginwin=((ox>=c_px)&&(ox<c_px+c_ow)&&(oy>=c_py)&&(oy<c_py+c_oh))?1:0; endfunction
    function [23:0] golden; input integer ox,oy; integer sc,sr; begin
        if (ginwin(ox,oy)) begin sc=((ox-c_px)*IN_W)/c_ow; sr=((oy-c_py)*IN_H)/c_oh;
            golden = blend24(gA(sr,sc), gB(sr,sc), ALPHA_Q15); end
        else golden = matte; end
    endfunction

    // ---- command latch (mirrors pg_read_engine_top's formatter): capture every
    //      fetch_req pulse so the back-to-back A+B fetches aren't lost ----
    reg        pend_v; reg [31:0] pend_a; reg [11:0] pend_l;
    wire       dm_idle;
    always @(posedge clk) begin
        if (!rstn) pend_v<=1'b0;
        else if (fetch_req) begin pend_a<=fetch_addr; pend_l<=fetch_len; pend_v<=1'b1; end
        else if (dm_idle && pend_v) pend_v<=1'b0;   // consumed by the DM
    end

    // ---- behavioral DataMover: serve A or B line by SADDR decode, 1 beat/clk ----
    // Clean load-on-entry / single-advance (no double-fire on the last beat — the
    // bug that, with dual-fetch, leaked a spurious tlast beat into S_FILL_B).
    localparam DM_IDLE=0, DM_STREAM=1;
    integer dm_state, dm_fr, dm_row, dm_byte, dm_btt, bb;
    assign dm_idle = (dm_state==DM_IDLE);
    task load_beat; input integer byt; begin
        for (bb=0; bb<8; bb=bb+1)
            dm_tdata[bb*8 +: 8] <= (byt+bb<dm_btt) ? lbyte(dm_fr,dm_row,byt+bb) : 8'd0;
    end endtask
    always @(posedge clk) begin
        if (!rstn) begin dm_state<=DM_IDLE; dm_tvalid<=0; dm_tlast<=0; end
        else case (dm_state)
            DM_IDLE: begin
                dm_tvalid<=1'b0; dm_tlast<=1'b0;
                if (pend_v) begin
                    if (pend_a >= BASE_B) begin dm_fr=1; dm_row=(pend_a-BASE_B)/STRIDE; end
                    else                  begin dm_fr=0; dm_row=(pend_a-BASE_A)/STRIDE; end
                    dm_btt = pend_l*3; dm_byte=0;
                    load_beat(0); dm_tvalid<=1'b1; dm_tlast<=(8>=pend_l*3);
                    dm_state<=DM_STREAM;
                end
            end
            DM_STREAM: if (dm_tvalid && dm_tready) begin
                if (dm_tlast) begin dm_tvalid<=1'b0; dm_tlast<=1'b0; dm_state<=DM_IDLE; end
                else begin
                    dm_byte = dm_byte + 8;
                    load_beat(dm_byte); dm_tlast<=(dm_byte+8>=dm_btt);
                end
            end
        endcase
    end

    // ---- output checker ----
    integer vox,voy,seen,starv; reg checking,in_active;
    always @(posedge clk) begin
        if (checking) begin
            if (in_active && !m_tvalid) starv=starv+1;
            if (m_tvalid && m_tready) begin
                if (m_tdata!==golden(vox,voy)) begin
                    if (errors<10) $display("  ERR @ (%0d,%0d): dut=%h gold=%h",vox,voy,m_tdata,golden(vox,voy));
                    errors=errors+1;
                end
                seen=seen+1;
                if (vox==OUT_W-1) begin vox=0; voy=voy+1; end else vox=vox+1;
            end
        end
    end

    // diagnostics: count fetch_req pulses (A+B) and cycles spent in S_FILL_B (state 2)
    integer fr_cnt, fb_cyc;
    always @(posedge clk) begin
        if (rstn && fetch_req)                  fr_cnt = fr_cnt + 1;
        if (rstn && dut.u_fetch.state==2'd2)    fb_cyc = fb_cyc + 1;
    end

    integer f,line;
    task run_frame; begin
        vtg_vsync<=1; repeat(3)@(posedge clk); vtg_vsync<=0;
        vox=0; voy=0; seen=0; starv=0; checking=1; in_active=0;
        repeat(VBLANK)@(posedge clk);
        for (line=0; line<OUT_H; line=line+1) begin
            in_active<=1; m_tready<=1; repeat(OUT_W)@(posedge clk);
            in_active<=0; m_tready<=0; repeat(HBLANK)@(posedge clk);
        end
        repeat(80)@(posedge clk); checking=0;
        $display("  frame: seen=%0d/%0d  starv(underrun cyc)=%0d  errors=%0d",
                 seen, OUT_W*OUT_H, starv, errors);
    end endtask

    initial begin
        errors=0; fr_cnt=0; fb_cyc=0; rstn=0; vtg_vsync=0; m_tready=0; checking=0; in_active=0; blend_en=1;
        base_a=BASE_A; base_b=BASE_B; alpha=ALPHA; matte=24'h101010;
        c_ow=OUT_W;c_oh=OUT_H;c_px=0;c_py=0;
        out_w_win=OUT_W;out_h_win=OUT_H;pos_x=0;pos_y=0;
        hsi=IN_W/OUT_W;hsf=IN_W%OUT_W;vsi=IN_H/OUT_H;vsf=IN_H%OUT_H;
        repeat(6)@(posedge clk); rstn=1; repeat(20)@(posedge clk);
        for (f=0; f<3; f=f+1) run_frame;
        $display("=================================");
        if (starv==0 && seen==OUT_W*OUT_H && errors==0)
            $display("PG_BLEND_TB: PASS (dual-fetch fed, blend bit-exact) — starv=0 seen=%0d errors=0", seen);
        else
            $display("PG_BLEND_TB: FAIL — starv=%0d seen=%0d/%0d errors=%0d",
                     starv, seen, OUT_W*OUT_H, errors);
        $display("DIAG: fetch_req pulses(total)=%0d  S_FILL_B cycles=%0d (0 = B fetch never ran)", fr_cnt, fb_cyc); $display("================================="); $finish;
    end
    initial begin #200_000_000; $display("PG_BLEND_TB: TIMEOUT"); $finish; end
endmodule

`default_nettype wire
