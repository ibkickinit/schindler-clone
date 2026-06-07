// pg_warp_real_tb.v — REAL-geometry real-time gate (1280x720 <- 1920x1080), 720p60 raster timing.
// Purpose: pin the minimal prefetch LEAD that keeps the warp output starvation-free at the production
// geometry, to size cache associativity (lead<->assoc coupling). shrink 1.5x is the fill/lead driver
// AND is capacity-clean at 4-way (worst-set-live<=3 even at deep lead, per tools/warp_lead_assoc.py),
// so this runs on the shipping 4-way/NTILE=512 cache without capacity thrash for leads up to ~25600.
// Sweep LEAD via -generic_top or by editing the localparam; report underruns/bit-err/collected.
`default_nettype none
`timescale 1ns / 1ps

module pg_warp_real_tb;
    localparam OUT_W=1280, OUT_H=720, IN_W=1920, IN_H=1080;
    localparam LTILE=4, TILE=16, NTILE=512, CW=32, FB=12, NA=OUT_W*OUT_H;
`ifdef LEADV
    localparam LEAD=`LEADV;
`else
    localparam LEAD=8192;
`endif
    // 720p60 CEA: H_TOT=1650, V_TOT=750, 1280x720 active, ~30 leading blank lines for prefetch warmup.
    localparam STRIDE=IN_W*3, H_TOT=1650, V_TOT=750, VB=30, FRAME_PERIOD=H_TOT*V_TOT;
    reg clk=0, rstn=0, sof=0;
    reg signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f; reg [23:0] matte=24'h101010;
    wire o_valid; wire [23:0] o_pix; reg o_ready;
    wire wreq; wire [11:0] wtx,wty; wire fv; wire [95:0] fblk; wire fl;
    wire dm_req; wire [31:0] dm_addr; wire [11:0] dm_len; wire dm_ready; wire t_ready;
    reg [63:0] beat_data=0; reg beat_valid=0; wire beat_ready; reg beat_last=0;

    pg_warp_engine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.CW(CW),.FB(FB),.LEAD(LEAD)) dut (
        .clk(clk),.rstn(rstn),.sof(sof),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.matte(matte),
        .o_valid(o_valid),.o_pix(o_pix),.o_ready(o_ready),
        .fetch_req(wreq),.fetch_tx(wtx),.fetch_ty(wty),.fetch_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl));
    pg_tile_dma #(.IN_W(IN_W),.LTILE(LTILE),.DREQ(16)) u_dma (
        .clk(clk),.rstn(rstn),.frame_base(32'd0),
        .t_req(wreq),.t_tx(wtx),.t_ty(wty),.t_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),.fetch_ready(dm_ready),
        .beat_data(beat_data),.beat_valid(beat_valid),.beat_ready(beat_ready),.beat_last(beat_last));
    always #5 clk=~clk;

    reg [23:0] frame[0:IN_W*IN_H-1];
    function [23:0] pxf; input integer x,y; pxf=frame[y*IN_W+x]; endfunction

    // gap-free pipelined behavioral DataMover (registered output) — identical model to pg_warp_dma_tb
    localparam NBEAT=(TILE*3)/8, DMD=8;
    reg [31:0] cq[0:DMD-1]; reg [3:0] cq_cnt; reg [$clog2(DMD)-1:0] cq_wr, cq_rd;
    assign dm_ready = (cq_cnt!=DMD);
    wire cq_push = dm_req && dm_ready;
    reg [383:0] rb; integer srcrow, srccol, k; reg [2:0] bidx; reg loaded;
    wire beat_go  = !beat_valid || beat_ready;
    wire cont_row = loaded && (bidx!=NBEAT-1);
    wire take_new = beat_go && !cont_row && (cq_cnt!=0);
    always @(posedge clk) begin
        if(!rstn) begin cq_cnt<=0; cq_wr<=0; cq_rd<=0; bidx<=0; loaded<=0;
                        beat_valid<=0; beat_data<=0; beat_last<=0; end
        else begin
            if(cq_push) begin cq[cq_wr]<=dm_addr; cq_wr<=cq_wr+1'b1; end
            if(beat_go) begin
                if(cont_row) begin
                    beat_data<=rb[(bidx+1)*64 +: 64]; beat_last<=((bidx+1)==NBEAT-1);
                    beat_valid<=1; bidx<=bidx+1'b1;
                end else if(cq_cnt!=0) begin
                    srcrow=cq[cq_rd]/STRIDE; srccol=(cq[cq_rd]-srcrow*STRIDE)/3;
                    for(k=0;k<TILE;k=k+1) rb[k*24 +: 24] = pxf(srccol+k, srcrow);
                    cq_rd<=cq_rd+1'b1; bidx<=0; loaded<=1;
                    beat_data<=rb[0 +: 64]; beat_last<=(NBEAT==1); beat_valid<=1;
                end else begin beat_valid<=0; loaded<=0; end
            end
            cq_cnt <= cq_cnt + (cq_push?1:0) - (take_new?1:0);
        end
    end

    // golden (identical lerp to pg_warp_engine)
    function [7:0] g8; input [7:0] a,b; input [7:0] w;
        reg signed [19:0] d,p,r; begin d=$signed({1'b0,b})-$signed({1'b0,a});
            p=d*$signed({1'b0,w}); r=$signed({1'b0,a})+((p+20'sd128)>>>8); g8=r[7:0]; end endfunction
    function [23:0] g24; input [23:0] a,b; input [7:0] w;
        g24={g8(a[23:16],b[23:16],w),g8(a[15:8],b[15:8],w),g8(a[7:0],b[7:0],w)}; endfunction
    function [23:0] golden; input integer idx; integer ox,oy,sxq,syq,col,row,cn1,rn1; reg[7:0] wx,wy;
        reg[23:0] p00,p10,p01,p11,tp,bt; begin
        ox=idx%OUT_W; oy=idx/OUT_W; sxq=m_c+ox*m_a+oy*m_b; syq=m_f+ox*m_d+oy*m_e;
        col=sxq>>>FB; row=syq>>>FB;
        if(col<0||row<0||col>=IN_W||row>=IN_H) golden=matte;
        else begin cn1=(col>=IN_W-1)?col:col+1; rn1=(row>=IN_H-1)?row:row+1;
            wx=(sxq>>4)&8'hFF; wy=(syq>>4)&8'hFF;
            p00=pxf(col,row);p10=pxf(cn1,row);p01=pxf(col,rn1);p11=pxf(cn1,rn1);
            tp=g24(p00,p10,wx); bt=g24(p01,p11,wx); golden=g24(tp,bt,wy); end end
    endfunction

    integer cn, errors, total, cyc, axx, ayy, underruns; real PI;
    reg [11:0] hx; reg [11:0] vy; reg started;
    wire active = started && (vy>=VB) && (vy<VB+OUT_H) && (hx<OUT_W);
    always @(posedge clk) cyc<=cyc+1;
    always @(posedge clk) begin
        if(!rstn) begin hx<=0; vy<=0; end
        else if(started) begin
            if(hx==H_TOT-1) begin hx<=0; vy<=(vy==V_TOT-1)?0:vy+1; end else hx<=hx+1;
        end
    end
    always @* o_ready = active;
    always @(posedge clk) if(active) begin
        if(o_valid) begin
            if(o_pix!==golden(cn)) begin errors<=errors+1; if(errors<8)$display("  ERR idx %0d got %h exp %h",cn,o_pix,golden(cn)); end
            cn<=cn+1; total<=total+1;
        end else underruns<=underruns+1;
    end

    task setaff; input real deg; input real invx; input real invy; begin : s
        real th,co,si,cxo,cyo,cxs,cys;
        th=deg*PI/180.0;co=$cos(th);si=$sin(th);
        cxo=OUT_W/2.0;cyo=OUT_H/2.0;cxs=IN_W/2.0;cys=IN_H/2.0;
        m_a=$rtoi(co*invx*4096);m_b=$rtoi(si*invx*4096);
        m_d=$rtoi(-si*invy*4096);m_e=$rtoi(co*invy*4096);
        m_c=$rtoi((cxs-co*invx*cxo-si*invx*cyo)*4096);
        m_f=$rtoi((cys+si*invy*cxo-co*invy*cyo)*4096);
    end endtask

    task run_x; input real deg; input real invx; input real invy; input [127:0] nm; begin
        setaff(deg,invx,invy);
        cn=0;errors=0;underruns=0;started=0;
        rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        @(posedge clk); sof<=1; started<=1; @(posedge clk); sof<=0;
        repeat(FRAME_PERIOD + 4000) @(posedge clk);
        started<=0;
        $display("REAL %0s LEAD=%0d: underruns=%0d bit-err=%0d collected=%0d/%0d | %s",
                 nm, LEAD, underruns, errors, cn, NA,
                 (underruns==0 && errors==0 && cn==NA) ? "PASS" : "FAIL");
        repeat(80)@(posedge clk);
    end endtask

    initial begin
        PI=3.14159265358979;
        for(ayy=0;ayy<IN_H;ayy=ayy+1) for(axx=0;axx<IN_W;axx=axx+1)
            frame[ayy*IN_W+axx]={axx[7:0],ayy[7:0],(axx*3+ayy*5)+8'h07};
        total=0;cyc=0;
        run_x(0.0, 1.5, 1.5, "shrink1.5");   // fill/lead driver; capacity-clean at 4-way
        $finish;
    end
    initial begin #40_000_000_000; $display("WATCHDOG cn=%0d err=%0d",cn,errors); $finish; end
endmodule

`default_nettype wire
