// pg_tilecache_rt2_tb.v — M3b: concurrent prefetch+gather. Bit-exact + real-time THROUGHPUT.
// Feed consumer continuously (prefetch leading, out_ready=1); collect outputs; check bit-exact;
// count total cycles to produce all NA outputs. Real-time PASS if cycles <= frame period (a frame
// of outputs produced within a frame period => with the output FIFO it cannot underrun).
`default_nettype none
`timescale 1ns / 1ps

module pg_tilecache_rt2_tb;
    localparam OUT_W=256, OUT_H=144, IN_W=384, IN_H=216;
    localparam H_TOT=330, V_TOT=170, LTILE=4, TILE=16, TPX=256, NTILE=64, SB=4, NA=OUT_W*OUT_H;
    localparam LEAD=2048, FRAME_PERIOD=H_TOT*V_TOT;        // 56100 cyc
    reg clk=0, rstn=0;
    reg pf_valid=0; reg [11:0] pf_x=0,pf_y=0; reg pf_in=0; wire pf_ready;
    reg c_valid=0; reg [11:0] c_x=0,c_y=0,c_fx=0,c_fy=0; reg c_in=0; reg [SB-1:0] c_sb=0; wire c_ready;
    wire out_valid; wire [23:0] o00,o10,o01,o11; wire [11:0] ofx,ofy; wire o_in; wire [SB-1:0] osb;
    reg out_ready=1;
    wire fetch_req; wire [11:0] ftx,fty;
    reg fill_valid=0; reg [95:0] fill_blk=0; reg fill_last=0;

    pg_tilecache_rt2 #(.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.SB(SB)) dut (
        .clk(clk),.rstn(rstn),
        .pf_valid(pf_valid),.pf_x(pf_x),.pf_y(pf_y),.pf_inwin(pf_in),.pf_ready(pf_ready),
        .c_valid(c_valid),.c_x(c_x),.c_y(c_y),.c_fx(c_fx),.c_fy(c_fy),.c_inwin(c_in),.c_sb(c_sb),.c_ready(c_ready),
        .out_valid(out_valid),.out_p00(o00),.out_p10(o10),.out_p01(o01),.out_p11(o11),
        .out_fx(ofx),.out_fy(ofy),.out_inwin(o_in),.out_sb(osb),.out_ready(out_ready),
        .fetch_req(fetch_req),.fetch_tx(ftx),.fetch_ty(fty),
        .fill_valid(fill_valid),.fill_blk(fill_blk),.fill_last(fill_last));
    always #5 clk=~clk;

    reg [23:0] frame[0:IN_W*IN_H-1];
    function [23:0] pxf; input integer x,y; pxf=frame[y*IN_W+x]; endfunction
    reg [1:0] dst=0; integer fc; reg [11:0] dtx,dty;
    always @(posedge clk) begin
        if(!rstn) begin dst<=0; fill_valid<=0; fill_last<=0; end
        else case(dst)
            0:begin fill_valid<=0;fill_last<=0; if(fetch_req)begin dtx<=ftx;dty<=fty;fc<=0;dst<=2;end end
            2:begin fill_valid<=1;                                  // one 2x2 block per beat (64 blocks)
                    fill_blk<={ frame[(dty*TILE+2*(fc>>3)+1)*IN_W + dtx*TILE+2*(fc&7)+1],   // p11
                                frame[(dty*TILE+2*(fc>>3)+1)*IN_W + dtx*TILE+2*(fc&7)],     // p01
                                frame[(dty*TILE+2*(fc>>3))*IN_W   + dtx*TILE+2*(fc&7)+1],   // p10
                                frame[(dty*TILE+2*(fc>>3))*IN_W   + dtx*TILE+2*(fc&7)] };   // p00
                    fill_last<=(fc==63); fc<=fc+1; if(fc==63)dst<=3; end
            3:begin fill_valid<=0;fill_last<=0;dst<=0; end
            default:dst<=0;
        endcase
    end

    integer csx[0:NA-1],csy[0:NA-1],cfxa[0:NA-1],cfya[0:NA-1],cina[0:NA-1];
    real PI; integer ii,axx,ayy;
    task gen; input real deg; input real sc; begin : g
        real th,co,si,inv,cxo,cyo,cxs,cys,sxr,syr; integer fxv,fyv,ixv,iyv;
        th=deg*PI/180.0; co=$cos(th); si=$sin(th); inv=1.0/sc;
        cxo=OUT_W/2.0;cyo=OUT_H/2.0;cxs=IN_W/2.0;cys=IN_H/2.0;
        for(ayy=0;ayy<OUT_H;ayy=ayy+1) for(axx=0;axx<OUT_W;axx=axx+1) begin
            ii=ayy*OUT_W+axx;
            sxr=cxs+inv*(co*(axx-cxo)+si*(ayy-cyo)); syr=cys+inv*(-si*(axx-cxo)+co*(ayy-cyo));
            ixv=$floor(sxr); iyv=$floor(syr); fxv=$rtoi((sxr-ixv)*4096); fyv=$rtoi((syr-iyv)*4096);
            if(sxr<0||syr<0||sxr>=IN_W-1||syr>=IN_H-1) begin cina[ii]=0;csx[ii]=0;csy[ii]=0;cfxa[ii]=0;cfya[ii]=0; end
            else begin cina[ii]=1;csx[ii]=ixv;csy[ii]=iyv;cfxa[ii]=fxv;cfya[ii]=fyv; end
        end
    end endtask

    integer c_idx, p_idx; reg feeding;
    always @(posedge clk) begin
        if(!rstn) begin c_valid<=0;c_idx<=0; pf_valid<=0;p_idx<=0; end
        else if(feeding) begin
            // consumer
            if(c_valid&&c_ready) c_idx<=c_idx+1;
            ii=(c_valid&&c_ready)?c_idx+1:c_idx;
            if(ii<NA) begin c_valid<=1;c_x<=csx[ii][11:0];c_y<=csy[ii][11:0];c_fx<=cfxa[ii][11:0];
                            c_fy<=cfya[ii][11:0];c_in<=cina[ii][0];c_sb<=ii[SB-1:0]; end
            else c_valid<=0;
            // prefetch (leads)
            if(pf_valid&&pf_ready) p_idx<=p_idx+1;
            ii=(pf_valid&&pf_ready)?p_idx+1:p_idx;
            if(ii<NA && ii<=c_idx+LEAD) begin pf_valid<=1;pf_x<=csx[ii][11:0];pf_y<=csy[ii][11:0];pf_in<=cina[ii][0]; end
            else pf_valid<=0;
        end
    end

    integer cn, errors, total, gx,gy,lxr,lyb, cyc, t_start, t_done;
    always @(posedge clk) cyc<=cyc+1;
    always @(posedge clk) if(feeding && out_valid && out_ready) begin
        gx=csx[cn];gy=csy[cn];
        if(cina[cn]) begin
            lxr=(gx>=IN_W-1)?gx:gx+1; lyb=(gy>=IN_H-1)?gy:gy+1;
            if(o00!==pxf(gx,gy)||o10!==pxf(lxr,gy)||o01!==pxf(gx,lyb)||o11!==pxf(lxr,lyb)) begin
                errors<=errors+1; if(errors<8)$display("  ERR pix %0d got %h %h %h %h exp %h %h %h %h",
                    cn,o00,o10,o01,o11,pxf(gx,gy),pxf(lxr,gy),pxf(gx,lyb),pxf(lxr,lyb)); end
        end
        cn<=cn+1; total<=total+1;
        if(cn==NA-1) t_done=cyc;
    end

    task run_x; input real deg; input real sc; input [127:0] nm; begin
        gen(deg,sc); cn=0;errors=0;total=0;feeding=0;
        rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        t_start=cyc; feeding=1;
        while(cn<NA) @(posedge clk);
        feeding=0;
        $display("M3b %0s: %0d out in %0d cyc (period %0d) | bit-err=%0d | %s",
                 nm, total, cyc-t_start, FRAME_PERIOD, errors,
                 ((cyc-t_start)<=FRAME_PERIOD && errors==0) ? "REAL-TIME PASS" : "FAIL");
        repeat(20)@(posedge clk);
    end endtask
    initial begin
        PI=3.14159265358979;
        for(ayy=0;ayy<IN_H;ayy=ayy+1) for(axx=0;axx<IN_W;axx=axx+1)
            frame[ayy*IN_W+axx]={axx[7:0],ayy[7:0],(axx*3+ayy*5)+8'h07};
        cyc=0;
        run_x(0.0, 1.0, "identity ");
        run_x(25.0,1.0, "rotate25 ");
        run_x(45.0,1.0, "rotate45 ");
        run_x(0.0, 0.5, "shrink0.5");
        $finish;
    end
    initial begin #800_000_000; $display("WATCHDOG cn=%0d errors=%0d c_idx=%0d p_idx=%0d",cn,errors,c_idx,p_idx); $finish; end
endmodule

`default_nettype wire
