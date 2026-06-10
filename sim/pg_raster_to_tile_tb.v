// pg_raster_to_tile_tb.v — verify raster -> tile-row-major conversion.
// IN_W=32 (2 tiles wide), one 16-row band. Feed px = row*100+col. Expect the output to be:
//   tile0: (r,c) for r=0..15,c=0..15  then  tile1: (r,c) for r=0..15,c=16..31  (tile-row-major, c fastest).
`default_nettype none
`timescale 1ns/1ps
module pg_raster_to_tile_tb;
    localparam IN_W=32, TILE=16, TILES_X=2, NB=TILE*IN_W;
    reg clk=0, rstn=0; always #5 clk=~clk;
    reg [23:0] s_td; reg s_tv=0, s_tuser=0, s_tlast=0; wire s_tr;
    wire [23:0] m_td; wire m_tv, m_tl, m_tu; reg m_tr=1; integer sofs;

    pg_raster_to_tile #(.IN_W(IN_W),.LTILE(4)) dut(
        .clk(clk),.rstn(rstn),.s_tdata(s_td),.s_tvalid(s_tv),.s_tready(s_tr),
        .s_tuser(s_tuser),.s_tlast(s_tlast),
        .m_tdata(m_td),.m_tvalid(m_tv),.m_tready(m_tr),.m_tuser(m_tu),.m_tlast(m_tl));

    // expected stream
    reg [23:0] exp[0:NB-1]; integer ei, k, tx, r, c, errs, tiles;
    initial begin
        k=0;
        for(tx=0;tx<TILES_X;tx=tx+1)
          for(r=0;r<TILE;r=r+1)
            for(c=0;c<TILE;c=c+1) begin exp[k]=(r*100+(tx*16+c)); k=k+1; end
    end

    // feed raster: 16 rows x 32 px, px=row*100+col
    integer fr, fc;
    initial begin
        errs=0; ei=0; tiles=0; sofs=0;
        rstn=0; repeat(4)@(posedge clk); rstn=1; @(posedge clk);
        for(fr=0;fr<TILE;fr=fr+1) for(fc=0;fc<IN_W;fc=fc+1) begin
            @(posedge clk); s_td<=(fr*100+fc); s_tv<=1; s_tuser<=(fr==0&&fc==0); s_tlast<=(fc==IN_W-1);
            while(!s_tr) @(posedge clk);
        end
        @(posedge clk); s_tv<=0; s_tuser<=0; s_tlast<=0;
        repeat(2000) @(posedge clk);
        $display("RASTER2TILE: collected=%0d/%0d tiles_tlast=%0d sof=%0d(exp 1 @beat0) errs=%0d | %s",
                 ei, NB, tiles, sofs, errs, (ei==NB && errs==0 && tiles==TILES_X && sofs==1)?"PASS":"FAIL");
        $finish;
    end
    // collect + check
    always @(posedge clk) if(rstn && m_tv && m_tr) begin
        if(ei<NB && m_td!==exp[ei]) begin
            errs=errs+1; if(errs<8) $display("  ERR beat %0d got %0d exp %0d",ei,m_td,exp[ei]);
        end
        if(m_tu) begin sofs=sofs+1; if(ei!=0) errs=errs+1; end   // SOF must be on the very first beat
        if(m_tl) tiles=tiles+1;
        ei=ei+1;
    end
    initial begin #200000 $display("WATCHDOG ei=%0d",ei); $finish; end
endmodule
`default_nettype wire
