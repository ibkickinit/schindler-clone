// pg_tilecache_rt_tb.v — M3a proof: 4-bank 1px/clock 2x2 gather bit-exact.
// Clocked feeder + collector (race-free) + watchdog with DUT state dump.
`default_nettype none
`timescale 1ns / 1ps

module pg_tilecache_rt_tb;
    localparam IN_W=64, IN_H=48, LTILE=4, TILE=16, TPX=TILE*TILE, NTILE=16, SB=4;
    reg clk=0, rstn=0;
    reg in_valid=0; reg [11:0] in_x=0,in_y=0,in_fx=0,in_fy=0; reg in_inwin=0; reg [SB-1:0] in_sb=0;
    wire in_ready;
    wire out_valid; wire [23:0] o00,o10,o01,o11; wire [11:0] ofx,ofy; wire o_in; wire [SB-1:0] osb;
    reg out_ready=1;
    wire fetch_req; wire [11:0] ftx,fty;
    reg fill_valid=0; reg [23:0] fill_data=0; reg fill_last=0;

    pg_tilecache_rt #(.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.SB(SB)) dut (
        .clk(clk),.rstn(rstn),.in_valid(in_valid),.in_x(in_x),.in_y(in_y),.in_fx(in_fx),.in_fy(in_fy),
        .in_inwin(in_inwin),.in_sb(in_sb),.in_ready(in_ready),
        .out_valid(out_valid),.out_p00(o00),.out_p10(o10),.out_p01(o01),.out_p11(o11),
        .out_fx(ofx),.out_fy(ofy),.out_inwin(o_in),.out_sb(osb),.out_ready(out_ready),
        .fetch_req(fetch_req),.fetch_tx(ftx),.fetch_ty(fty),
        .fill_valid(fill_valid),.fill_data(fill_data),.fill_last(fill_last));

    always #5 clk=~clk;

    reg [23:0] frame [0:IN_W*IN_H-1];
    integer fxx, fyy;
    function [23:0] px; input integer x,y; px = frame[y*IN_W + x]; endfunction

    // behavioral DMA
    reg [1:0] dst=0; integer fc; reg [11:0] dtx,dty;
    always @(posedge clk) begin
        if (!rstn) begin dst<=0; fill_valid<=0; fill_last<=0; end
        else case (dst)
            0: begin fill_valid<=0; fill_last<=0; if (fetch_req) begin dtx<=ftx; dty<=fty; fc<=0; dst<=2; end end
            2: begin
                fill_valid<=1;
                fill_data <= frame[(dty*TILE + (fc>>LTILE))*IN_W + dtx*TILE + (fc & (TILE-1))];
                fill_last <= (fc==TPX-1);
                fc <= fc + 1;
                if (fc==TPX-1) dst<=3;
            end
            3: begin fill_valid<=0; fill_last<=0; dst<=0; end
            default: dst<=0;
        endcase
    end

    // test coords (precomputed)
    localparam MAXN=6000;
    integer cxs[0:MAXN-1], cys[0:MAXN-1], NFEED;
    reg [23:0] r00[0:MAXN-1],r10[0:MAXN-1],r01[0:MAXN-1],r11[0:MAXN-1]; reg rinr[0:MAXN-1];

    // clocked feeder: present coord[feed_i]; advance on accept
    integer feed_i; reg feeding;
    integer ni;
    always @(posedge clk) begin
        if (!rstn) begin in_valid<=0; feed_i<=0; end
        else if (feeding) begin
            ni = (in_valid && in_ready) ? feed_i + 1 : feed_i;
            if (in_valid && in_ready) feed_i <= feed_i + 1;
            if (ni < NFEED) begin in_valid<=1; in_x<=cxs[ni][11:0]; in_y<=cys[ni][11:0]; in_inwin<=1'b1; end
            else in_valid<=0;
        end
    end

    // clocked collector
    integer cn; reg collecting;
    always @(posedge clk) if (collecting && out_valid && out_ready && cn<MAXN) begin
        r00[cn]<=o00; r10[cn]<=o10; r01[cn]<=o01; r11[cn]<=o11; rinr[cn]<=o_in; cn<=cn+1;
    end

    integer errors=0, total=0, k, gx, gy, lxr, lyb, pass, xx, yy;

    // watchdog
    initial begin
        #200_000_000;
        $display("WATCHDOG: hang. dut.st=%0d midx=%0d dst=%0d fc(dut)=%0d feed_i=%0d cn=%0d fetch_req=%b fill_valid=%b",
                 dut.st, dut.midx, dst, dut.fc, feed_i, cn, fetch_req, fill_valid);
        $finish;
    end

    initial begin
        for (fyy=0; fyy<IN_H; fyy=fyy+1)
          for (fxx=0; fxx<IN_W; fxx=fxx+1)
            frame[fyy*IN_W+fxx] = {fxx[7:0], fyy[7:0], (fxx*3+fyy*5)+8'h07};
        NFEED=0;
        for (pass=0; pass<2; pass=pass+1)
          for (yy=0; yy<IN_H; yy=yy+2)
            for (xx=0; xx<IN_W; xx=xx+1) begin cxs[NFEED]=xx; cys[NFEED]=yy; NFEED=NFEED+1; end
        feeding=0; collecting=0; feed_i=0; cn=0;
        rstn=0; repeat(4) @(posedge clk); rstn=1; repeat(2) @(posedge clk);
        feeding=1; collecting=1;
        while (cn < NFEED) @(posedge clk);     // watchdog backstops a hang
        feeding=0; collecting=0;
        for (k=0;k<cn;k=k+1) begin
            gx=cxs[k]; gy=cys[k];
            lxr=(gx>=IN_W-1)?gx:gx+1; lyb=(gy>=IN_H-1)?gy:gy+1;
            if (rinr[k]!==1'b1) begin errors=errors+1; if(errors<8)$display("  ERR inwin k=%0d",k); end
            else if (r00[k]!==px(gx,gy)||r10[k]!==px(lxr,gy)||r01[k]!==px(gx,lyb)||r11[k]!==px(lxr,lyb)) begin
                errors=errors+1;
                if(errors<10) $display("  ERR @(%0d,%0d) got %h %h %h %h | exp %h %h %h %h",
                    gx,gy,r00[k],r10[k],r01[k],r11[k],px(gx,gy),px(lxr,gy),px(gx,lyb),px(lxr,lyb));
            end
            total=total+1;
        end
        $display("Total errors = %0d (checked %0d 4-bank 2x2 gathers, 2 passes)", errors, total);
        $finish;
    end
endmodule

`default_nettype wire
