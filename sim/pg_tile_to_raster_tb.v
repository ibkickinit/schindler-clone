// pg_tile_to_raster_tb.v — verify 16x16 output tiles (tile-row-major) -> raster lines.
// OUT_W=32 (OTX=2), one 16-row band. Feed tile0 (cols 0..15) then tile1 (cols 16..31), each r0c0..r15c15.
// px value = r*100 + col. Expect raster: row r, col 0..31 = r*100+col; SOF on beat 0; tlast every 32 px.
`default_nettype none
`timescale 1ns/1ps
module pg_tile_to_raster_tb;
    localparam OUT_W=32, TILE=16, OTX=2, NB=TILE*OUT_W;
    reg clk=0, rstn=0; always #5 clk=~clk;
    reg [23:0] s_td; reg s_tv=0, s_tu=0, s_tl=0; wire s_tr;
    wire [23:0] m_td; wire m_tv, m_tl, m_tu; reg m_tr=1;

    pg_tile_to_raster #(.OUT_W(OUT_W),.LTILE(4)) dut(
        .clk(clk),.rstn(rstn),.s_axis_tdata(s_td),.s_axis_tvalid(s_tv),.s_axis_tready(s_tr),
        .s_axis_tuser(s_tu),.s_axis_tlast(s_tl),
        .m_axis_tdata(m_td),.m_axis_tvalid(m_tv),.m_axis_tready(m_tr),.m_axis_tuser(m_tu),.m_axis_tlast(m_tl));

    integer ei, errs, eols, sofs, tile, r, c;
    function [23:0] expras; input integer k; integer rr,cc; begin rr=k/OUT_W; cc=k%OUT_W; expras=rr*100+cc; end endfunction

    initial begin
        ei=0; errs=0; eols=0; sofs=0;
        rstn=0; repeat(4)@(posedge clk); rstn=1; @(posedge clk);
        for(tile=0;tile<OTX;tile=tile+1)
          for(r=0;r<TILE;r=r+1)
            for(c=0;c<TILE;c=c+1) begin
              @(posedge clk); s_td<=r*100+(tile*16+c); s_tv<=1;
              s_tu<=(tile==0&&r==0&&c==0); s_tl<=(r==TILE-1&&c==TILE-1);
              while(!s_tr) @(posedge clk);
            end
        @(posedge clk); s_tv<=0; s_tu<=0; s_tl<=0;
        repeat(2000)@(posedge clk);
        $display("TILE2RASTER: collected=%0d/%0d eols=%0d(exp %0d) sof=%0d(exp1@0) errs=%0d | %s",
                 ei, NB, eols, TILE, sofs, errs,
                 (ei==NB && errs==0 && eols==TILE && sofs==1)?"PASS":"FAIL");
        $finish;
    end
    always @(posedge clk) if(rstn && m_tv && m_tr) begin
        if(ei<NB && m_td!==expras(ei)) begin errs=errs+1; if(errs<8)$display("  ERR beat %0d got %0d exp %0d",ei,m_td,expras(ei)); end
        if(m_tu) begin sofs=sofs+1; if(ei!=0) errs=errs+1; end
        if(m_tl) begin eols=eols+1; if((ei%OUT_W)!=OUT_W-1) errs=errs+1; end  // tlast must be at line end
        ei=ei+1;
    end
    initial begin #300000 $display("WATCHDOG ei=%0d",ei); $finish; end
endmodule
`default_nettype wire
