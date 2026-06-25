// pg_raster_to_tile_misalign_tb.v — PROVE the TLAST-delimited tiler is immune to the dest-res 640-seam DRIFT.
//
// Root cause (silicon, 2026-06-25): scaler_top intermittently emits rows with != in_w valid beats. The old
// tiler counted in_w beats and IGNORED tlast, so an over-length row spilled its extra beats into the next
// band-row -> progressive horizontal drift -> the 640-seam shear. The fix rolls each band-row on the
// scaler's m_axis_tlast (EOL), dropping extra beats / padding short rows, so band-rows stay aligned.
//
// This TB feeds a band where SOME rows carry EXTRA beats past in_w-1 before tlast. With the fix, every
// emitted tile must still contain the source row's FIRST in_w pixels (extras dropped, no drift).
`default_nettype none
`timescale 1ns/1ps
module pg_raster_to_tile_misalign_tb;
    localparam IN_W=32, TILE=16, TILES_X=2, NB=TILE*IN_W;
    reg clk=0, rstn=0; always #5 clk=~clk;
    reg [23:0] s_td; reg s_tv=0, s_tuser=0, s_tlast=0; wire s_tr;
    wire [23:0] m_td; wire m_tv, m_tl; reg m_tr=1;

    pg_raster_to_tile #(.IN_W(IN_W),.LTILE(4)) dut(
        .clk(clk),.rstn(rstn),.in_w(IN_W[11:0]),
        .s_tdata(s_td),.s_tvalid(s_tv),.s_tready(s_tr),
        .s_tuser(s_tuser),.s_tlast(s_tlast),
        .m_tdata(m_td),.m_tvalid(m_tv),.m_tready(m_tr),.m_tlast(m_tl));

    // src pixel value for (row,col) of the ONLY band (rows 0..15). Distinct per (r,c).
    function [23:0] src; input integer r, c; src = r*256 + c; endfunction
    // extra beats appended to each row before its tlast (the scaler-misalignment we must survive)
    function integer extra; input integer r; extra = (r==1)?5 : (r==4)?11 : (r==9)?1 : (r==15)?7 : 0; endfunction

    // expected emit: tile-row-major (tx){r,c} -> src(r, tx*16+c); extras NEVER appear
    reg [23:0] exp[0:NB-1]; integer ei,k,tx,r,c,errs,tiles;
    initial begin k=0;
        for(tx=0;tx<TILES_X;tx=tx+1) for(r=0;r<TILE;r=r+1) for(c=0;c<TILE;c=c+1) begin exp[k]=src(r,tx*16+c); k=k+1; end
    end

    integer fr, fc, ncols;
    initial begin
        errs=0; ei=0; tiles=0;
        rstn=0; repeat(4)@(posedge clk); rstn=1; @(posedge clk);
        for(fr=0;fr<TILE;fr=fr+1) begin
            ncols = IN_W + extra(fr);                       // some rows carry EXTRA beats past in_w
            for(fc=0;fc<ncols;fc=fc+1) begin
                @(posedge clk);
                s_td  <= src(fr, fc);                       // extras (fc>=IN_W) carry junk-ish high values
                s_tv  <= 1;
                s_tuser<=(fr==0&&fc==0);
                s_tlast<=(fc==ncols-1);                     // EOL on the LAST beat of the (possibly long) row
                while(!s_tr) @(posedge clk);
            end
        end
        @(posedge clk); s_tv<=0; s_tuser<=0; s_tlast<=0;
        repeat(3000) @(posedge clk);
        $display("MISALIGN_TB: collected=%0d/%0d tiles=%0d errs=%0d | %s",
                 ei, NB, tiles, errs, (ei==NB && errs==0 && tiles==TILES_X)?"PASS":"FAIL");
        $finish;
    end
    always @(posedge clk) if(rstn && m_tv && m_tr) begin
        if(ei<NB && m_td!==exp[ei]) begin
            errs=errs+1; if(errs<10) $display("  ERR beat %0d got %0d exp %0d", ei, m_td, exp[ei]);
        end
        if(m_tl) tiles=tiles+1;
        ei=ei+1;
    end
    initial begin #400000 $display("WATCHDOG ei=%0d",ei); $finish; end
endmodule
`default_nettype wire
