// pg_tiled_roundtrip_tb.v — PATH B end-to-end proof: pg_raster_to_tile -> (S2MM contiguous store model)
// -> pg_tile_dma TILED -> recovered pixels, bit-exact vs the source raster.
//
// This is the #1-risk gate: it proves the PRODUCER (pg_raster_to_tile emit order) and the CONSUMER
// (pg_tile_dma TILED read addressing) agree THROUGH the S2MM contiguous-store contract, as one closed loop
// — not just that each half passes its own TB against a hand-written expectation.
//
// Model of the S2MM write leg (firmware: HSIZE=Stride=768, VSIZE=TILES_X*TILES_Y): the S2MM writes the
// pg_raster_to_tile AXIS byte-stream CONTIGUOUSLY at the slot base, little-endian 24-bit/px. We capture the
// producer's output beats straight into a byte memory at a running offset -> that IS the DDR image. Then
// pg_tile_dma TILED reads tiles from that same memory at frame_base + (ty*TILES_X+tx)*768 and we multiset-
// check each recovered tile against the source raster pixels.
//
// Non-multiple-of-16 height (IN_H_SRC=24 over a 16-row band) mirrors 1080-over-16 (=67.5): the producer
// emits only the COMPLETE band (rows 0..15 -> tile-row 0) and drops the trailing 8 rows; the consumer is
// asked only for tile-row 0 (= the IN_H=16-clamped read window), and recovers it bit-exact.
`default_nettype none
`timescale 1ns/1ps
module pg_tiled_roundtrip_tb;
    localparam IN_W=32, TILE=16, TILES_X=IN_W/TILE, TBYTES=TILE*TILE*3;
    localparam IN_H_SRC=24;                 // 1.5 bands: tile-row 0 complete, last 8 rows dropped (like 1080)
    localparam TILES_Y=1;                   // floor(24/16)=1 emitted tile-row
    reg clk=0, rstn=0; always #5 clk=~clk;

    // ---- producer: pg_raster_to_tile ----
    reg [23:0] s_td; reg s_tv=0, s_tuser=0, s_tlast=0; wire s_tr;
    wire [23:0] p_td; wire p_tv, p_tl; reg p_tr=1;
    pg_raster_to_tile #(.IN_W(IN_W),.LTILE(4)) u_prod(
        .clk(clk),.rstn(rstn),.in_w(IN_W[11:0]),.s_tdata(s_td),.s_tvalid(s_tv),.s_tready(s_tr),
        .s_tuser(s_tuser),.s_tlast(s_tlast),
        .m_tdata(p_td),.m_tvalid(p_tv),.m_tready(p_tr),.m_tlast(p_tl));

    // ---- DDR byte memory written by the (modeled) S2MM, read by the consumer ----
    reg [7:0] mem[0:TILES_X*TILES_Y*TBYTES-1];
    integer wbyte;                          // running contiguous S2MM write offset

    // source pixel value (unique per (row,col)); kept small so $display is readable
    function [23:0] srcval; input integer r,c; srcval=r*1000 + c; endfunction

    // ---- consumer: pg_tile_dma TILED, reading mem via a behavioral DataMover ----
    reg t_req=0; reg [11:0] t_tx,t_ty; wire t_ready;
    wire fv; wire [95:0] fblk; wire fl;
    wire dm_req; wire [31:0] dm_addr; wire [11:0] dm_len; reg dm_ready=1;
    reg [63:0] beat=0; reg bvalid=0; wire bready; reg blast=0;
    pg_tile_dma #(.IN_W(IN_W),.LTILE(4),.TILED(1),.DREQ(16)) u_cons(
        .clk(clk),.rstn(rstn),.srst(1'b0),.frame_base(32'd0),
        .t_req(t_req),.t_tx(t_tx),.t_ty(t_ty),.t_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),.fetch_ready(dm_ready),
        .beat_data(beat),.beat_valid(bvalid),.beat_ready(bready),.beat_last(blast));

    // behavioral DataMover: accept (addr,len), stream len*3 bytes from mem as 64b beats
    reg [22:0] caddr; integer btt, bi; reg busy=0; integer k;
    wire cmd_go = dm_req && dm_ready && !busy;
    always @(posedge clk) begin
        if(!rstn) begin busy<=0; bvalid<=0; bi<=0; end
        else begin
            if(cmd_go) begin caddr<=dm_addr[22:0]; btt<=dm_len*3; bi<=0; busy<=1; end
            if(busy && (!bvalid || bready)) begin
                for(k=0;k<8;k=k+1) beat[k*8 +: 8] <= (bi*8+k < btt) ? mem[caddr + bi*8 + k] : 8'h0;
                bvalid<=1; blast<=((bi+1)*8 >= btt);
                if((bi+1)*8 >= btt) busy<=0;
                bi<=bi+1;
            end else if(bvalid && bready) bvalid<=0;
        end
    end

    // ---- PHASE 1: drive the source raster into the producer, capture its tiled output into mem ----
    integer fr,fc, errs, j, ti, found;
    integer want[0:255], got[0:255], nwant, ngot;
    initial begin
        errs=0; wbyte=0; rstn=0; repeat(4)@(posedge clk); rstn=1; @(posedge clk);
        // feed IN_H_SRC rows x IN_W cols, px=srcval(r,c)
        for(fr=0;fr<IN_H_SRC;fr=fr+1) for(fc=0;fc<IN_W;fc=fc+1) begin
            @(posedge clk); s_td<=srcval(fr,fc); s_tv<=1; s_tuser<=(fr==0&&fc==0); s_tlast<=(fc==IN_W-1);
            while(!s_tr) @(posedge clk);
        end
        @(posedge clk); s_tv<=0; s_tuser<=0; s_tlast<=0;
        // let the producer drain its band into mem (capture happens in the always block below)
        repeat(4000) @(posedge clk);
        $display("CAPTURE: wrote %0d bytes (expect %0d = %0d tiles x 768)",
                 wbyte, TILES_X*TILES_Y*TBYTES, TILES_X*TILES_Y);

        // ---- PHASE 2: read every emitted tile back via pg_tile_dma TILED, bit-exact check ----
        for(ti=0; ti<TILES_X; ti=ti+1) begin   // tile-row 0 only (the in-window tiles)
            // expected pixels of source tile (ty=0, tx=ti): src rows 0..15, cols ti*16..ti*16+15
            nwant=0;
            for(fr=0;fr<16;fr=fr+1) for(fc=0;fc<16;fc=fc+1) begin
                want[nwant]=srcval(fr, ti*16+fc); nwant=nwant+1; end
            ngot=0;
            @(posedge clk); t_req<=1; t_tx<=ti; t_ty<=0; @(posedge clk);
            while(!t_ready) @(posedge clk); t_req<=0;
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
            for(j=0;j<nwant;j=j+1) begin found=0;
                for(k=0;k<ngot;k=k+1) if(!found && got[k]==want[j]) begin got[k]=-1; found=1; end
                if(!found) errs=errs+1;
            end
            $display("  roundtrip tile(tx=%0d,ty=0): got=%0d/256 missing=%0d", ti, ngot, errs);
        end
        $display("TILED_ROUNDTRIP: %s (errs=%0d)", (errs==0 && wbyte==TILES_X*TILES_Y*TBYTES)?"PASS":"FAIL", errs);
        $finish;
    end

    // model the S2MM contiguous store: every producer output beat -> 3 mem bytes at the running offset
    always @(posedge clk) if(rstn && p_tv && p_tr) begin
        mem[wbyte]   = p_td[7:0];
        mem[wbyte+1] = p_td[15:8];
        mem[wbyte+2] = p_td[23:16];
        wbyte = wbyte + 3;
    end

    initial begin #2000000 $display("WATCHDOG wbyte=%0d",wbyte); $finish; end
endmodule
`default_nettype wire
