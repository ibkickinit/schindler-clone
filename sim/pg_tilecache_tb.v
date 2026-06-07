// pg_tilecache_tb.v — M1 functional proof: behavioral DDR + bit-exact 2x2 golden.
// Frame in a reg array; behavioral DMA streams the requested 32x32 tile. Drives a region raster
// of source coords (covers tile straddles + frame edges + a 2nd pass for cache hits) and checks
// every returned 2x2 against the frame directly.
`default_nettype none
`timescale 1ns / 1ps

module pg_tilecache_tb;
    localparam IN_W=64, IN_H=48, LTILE=5, TILE=32, TPX=TILE*TILE, NTILE=16, SB=4;
    reg clk=0, rstn=0;
    reg in_valid=0; reg [11:0] in_x=0,in_y=0,in_fx=0,in_fy=0; reg in_inwin=0; reg [SB-1:0] in_sb=0;
    wire in_ready;
    wire out_valid; wire [23:0] o00,o10,o01,o11; wire [11:0] ofx,ofy; wire o_in; wire [SB-1:0] osb;
    reg out_ready=1;
    wire fetch_req; wire [11:0] ftx,fty;
    reg fill_valid=0; reg [23:0] fill_data=0; reg fill_last=0;

    pg_tilecache #(.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.SB(SB)) dut (
        .clk(clk),.rstn(rstn),
        .in_valid(in_valid),.in_x(in_x),.in_y(in_y),.in_fx(in_fx),.in_fy(in_fy),
        .in_inwin(in_inwin),.in_sb(in_sb),.in_ready(in_ready),
        .out_valid(out_valid),.out_p00(o00),.out_p10(o10),.out_p01(o01),.out_p11(o11),
        .out_fx(ofx),.out_fy(ofy),.out_inwin(o_in),.out_sb(osb),.out_ready(out_ready),
        .fetch_req(fetch_req),.fetch_tx(ftx),.fetch_ty(fty),
        .fill_valid(fill_valid),.fill_data(fill_data),.fill_last(fill_last));

    always #5 clk=~clk;

    // ---- behavioral DDR frame ----
    reg [23:0] frame [0:IN_W*IN_H-1];
    integer fx_, fy_;
    function [23:0] px; input integer x,y; begin px = frame[y*IN_W + x]; end endfunction

    // ---- behavioral DMA: stream the requested tile ----
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

    // ---- collector (on out_valid) ----
    localparam MAXN = 4000;
    reg [23:0] r00[0:MAXN-1], r10[0:MAXN-1], r01[0:MAXN-1], r11[0:MAXN-1];
    reg        rin[0:MAXN-1];
    integer cn; reg collecting;
    always @(posedge clk) if (collecting && out_valid && out_ready && cn<MAXN) begin
        r00[cn]<=o00; r10[cn]<=o10; r01[cn]<=o01; r11[cn]<=o11; rin[cn]<=o_in; cn<=cn+1;
    end

    integer errors=0, total=0, k, gx, gy, lxr, lyb, fed;
    integer cxs[0:MAXN-1], cys[0:MAXN-1];

    task put; input integer x,y; begin
        in_x<=x[11:0]; in_y<=y[11:0]; in_inwin<=1'b1; in_valid<=1'b1;
        @(posedge clk);
        while (!in_ready) @(posedge clk);   // spin while cache busy
        in_valid<=1'b0;
        @(posedge clk);
    end endtask

    integer pass, xx, yy;
    initial begin
        for (fy_=0; fy_<IN_H; fy_=fy_+1)
          for (fx_=0; fx_<IN_W; fx_=fx_+1)
            frame[fy_*IN_W+fx_] = {fx_[7:0], fy_[7:0], (fx_^fy_)+8'h11};   // distinct pattern

        rstn=0; repeat(4) @(posedge clk); rstn=1; repeat(2) @(posedge clk);
        cn=0; fed=0; collecting=1;
        // two passes over a region that crosses tile boundaries (x=31,y=31) + frame edge (x=63,y=47)
        for (pass=0; pass<2; pass=pass+1)
          for (yy=0; yy<IN_H; yy=yy+3)
            for (xx=0; xx<IN_W; xx=xx+1) begin
                cxs[fed]=xx; cys[fed]=yy; fed=fed+1; put(xx,yy);
            end
        // drain
        repeat (40) @(posedge clk);
        collecting=0;

        if (cn != fed) begin errors=errors+1; $display("ERR collected %0d/%0d", cn, fed); end
        for (k=0; k<cn; k=k+1) begin
            gx=cxs[k]; gy=cys[k];
            lxr = (gx>=IN_W-1)?gx:gx+1;
            lyb = (gy>=IN_H-1)?gy:gy+1;
            if (rin[k]!==1'b1) begin errors=errors+1; if(errors<8)$display("  ERR inwin k=%0d",k); end
            else if (r00[k]!==px(gx,gy) || r10[k]!==px(lxr,gy) || r01[k]!==px(gx,lyb) || r11[k]!==px(lxr,lyb)) begin
                errors=errors+1;
                if(errors<8) $display("  ERR @(%0d,%0d) got %h %h %h %h | exp %h %h %h %h",
                    gx,gy,r00[k],r10[k],r01[k],r11[k], px(gx,gy),px(lxr,gy),px(gx,lyb),px(lxr,lyb));
            end
            total=total+1;
        end
        $display("Total errors = %0d (checked %0d 2x2 fetches, 2 passes)", errors, total);
        $finish;
    end
endmodule

`default_nettype wire
