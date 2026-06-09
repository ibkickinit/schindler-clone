// pg_tile_dma_tiled_tb.v — verify TILED mode: 1 contiguous 768B burst/tile at the tiled address, receive +
// 2x2 reorder delivers the correct tile pixels. Source = 32x32 (2x2 tiles), stored TILED in a byte mem
// (tile (tx,ty) at (ty*TILES_X+tx)*768, px(r,c) at +(r*16+c)*3, little-endian 24-bit). Request a few tiles,
// collect the fill blocks (each = 4 px), multiset-check vs the source tile.
`default_nettype none
`timescale 1ns/1ps
module pg_tile_dma_tiled_tb;
    localparam IN_W=32, TILE=16, TILES_X=2, TBYTES=TILE*TILE*3;
    reg clk=0,rstn=0; always #5 clk=~clk;
    // request
    reg t_req=0; reg [11:0] t_tx, t_ty; wire t_ready;
    // fill
    wire fv; wire [95:0] fblk; wire fl;
    // DataMover cmd/data
    wire dm_req; wire [31:0] dm_addr; wire [11:0] dm_len; reg dm_ready=1;
    reg [63:0] beat=0; reg bvalid=0; wire bready; reg blast=0;

    pg_tile_dma #(.IN_W(IN_W),.LTILE(4),.TILED(1),.DREQ(16)) dut(
        .clk(clk),.rstn(rstn),.srst(1'b0),.frame_base(32'd0),
        .t_req(t_req),.t_tx(t_tx),.t_ty(t_ty),.t_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),.fetch_ready(dm_ready),
        .beat_data(beat),.beat_valid(bvalid),.beat_ready(bready),.beat_last(blast));

    // ---- tiled byte memory + source values ----
    reg [7:0] mem[0:4*TBYTES-1];
    function [23:0] srcval; input integer tx,ty,r,c; srcval=(ty*TILES_X+tx)*100000 + r*100 + c; endfunction
    integer tx,ty,r,c,off; reg [23:0] v;
    initial begin
        for(ty=0;ty<2;ty=ty+1) for(tx=0;tx<2;tx=tx+1) for(r=0;r<16;r=r+1) for(c=0;c<16;c=c+1) begin
            off=(ty*TILES_X+tx)*TBYTES + (r*16+c)*3; v=srcval(tx,ty,r,c);
            mem[off]=v[7:0]; mem[off+1]=v[15:8]; mem[off+2]=v[23:16];
        end
    end

    // ---- behavioral DataMover: accept cmd (addr,len), stream len*3 bytes as 64b beats ----
    reg [22:0] caddr; integer btt, bi; reg busy=0;
    wire cmd_go = dm_req && dm_ready && !busy;
    integer k;
    always @(posedge clk) begin
        if(!rstn) begin busy<=0; bvalid<=0; bi<=0; end
        else begin
            if(cmd_go) begin caddr<=dm_addr[22:0]; btt<=dm_len*3; bi<=0; busy<=1; end
            if(busy && (!bvalid || bready)) begin
                for(k=0;k<8;k=k+1) beat[k*8 +: 8] <= (bi*8+k < btt) ? mem[caddr + bi*8 + k] : 8'h0;
                bvalid<=1; blast<=((bi+1)*8 >= btt);
                if((bi+1)*8 >= btt) begin busy<=0; end
                bi<=bi+1;
            end else if(bvalid && bready) bvalid<=0;
        end
    end

    // ---- collect fill blocks, multiset-check per tile ----
    integer want[0:255], got[0:255], nwant, ngot, errs, ti, found, j;
    task check_tile; input integer rtx,rty; begin
        // expected multiset
        nwant=0; for(r=0;r<16;r=r+1) for(c=0;c<16;c=c+1) begin want[nwant]=srcval(rtx,rty,r,c); nwant=nwant+1; end
        ngot=0;
        @(posedge clk); t_req<=1; t_tx<=rtx; t_ty<=rty; @(posedge clk); while(!t_ready) @(posedge clk); t_req<=0;
        // collect until fill_last
        begin : col
            integer guard; guard=0;
            while(ngot<256 && guard<200000) begin
                @(posedge clk);
                if(fv) begin
                    got[ngot]=fblk[23:0];    got[ngot+1]=fblk[47:24];
                    got[ngot+2]=fblk[71:48]; got[ngot+3]=fblk[95:72]; ngot=ngot+4;
                end
                guard=guard+1;
            end
        end
        // multiset compare
        for(j=0;j<nwant;j=j+1) begin found=0;
            for(ti=0;ti<ngot;ti=ti+1) if(!found && got[ti]==want[j]) begin got[ti]=-1; found=1; end
            if(!found) errs=errs+1;
        end
        $display("  tile(%0d,%0d): got=%0d/256 missing=%0d", rtx,rty, ngot, errs);
    end endtask

    initial begin
        errs=0; rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        check_tile(0,0); check_tile(1,0); check_tile(0,1); check_tile(1,1);
        $display("DMA_TILED: %s (errs=%0d)", (errs==0)?"PASS":"FAIL", errs);
        $finish;
    end
    initial begin #500000 $display("WATCHDOG"); $finish; end
endmodule
`default_nettype wire
