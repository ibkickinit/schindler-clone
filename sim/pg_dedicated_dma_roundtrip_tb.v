// pg_dedicated_dma_roundtrip_tb.v — PATH B DEDICATED-DMA end-to-end proof (replaces VDMA S2MM).
//
// Full write leg under test:
//   raster --> pg_raster_to_tile --> pg_tile_pack64 (24b->64b) --> [behavioral axi_datamover S2MM] --> DDR
// driven by pg_tile_s2mm_cmd (one contiguous command/frame at FRAME_BUF_BASE + wr_slot*SLOT_STRIDE, BTT=FBYTES).
// Then the warp read leg: pg_tile_dma TILED reads each tile from the slot the cmd-gen's frame_ptr points the
// warp at (gray2bin(frame_ptr)-1), and we bit-exact-check the recovered tile vs the source raster — across
// MULTIPLE FRAMES, with the ring slot advancing, exactly like silicon.
//
// What this proves (the deliverable's SIM list):
//   (a) one DataMover write command per frame, addr = slot base, BTT = whole tiled frame (contiguous),
//   (b) the write slot advances and wraps at NUM_FRAMES,
//   (c) the frame_ptr the warp reads points at the just-COMPLETED slot,
//   (d) raster -> tile -> contiguous S2MM store -> TILED read is BIT-EXACT, per frame, frame-after-frame.
//
// Scaled geometry (topologically identical to 1920x1080->120x67, NUM_FRAMES=7):
//   IN_W=32 -> TILES_X=2;  H=40 -> 2 full 16-row bands (+8 dropped) -> TILES_Y=2;  tiles/frame=4;
//   FBYTES = 4*768 = 3072;  SLOT_STRIDE = 4096 (> FBYTES, like silicon);  NUM_FRAMES=3 (small ring to wrap).
`default_nettype none
`timescale 1ns/1ps
module pg_dedicated_dma_roundtrip_tb;
    localparam integer IN_W=32, TILE=16, TILES_X=IN_W/TILE; // =2
    localparam integer H=40, TILES_Y=H/TILE;                // =2
    localparam integer TPF=TILES_X*TILES_Y;                 // tiles/frame = 4
    localparam integer TBYTES=TILE*TILE*3;                  // 768
    localparam integer FBYTES=TPF*TBYTES;                   // 3072
    localparam [31:0]  BASE=32'h0001_0000;
    localparam integer STRIDE=4096;
    localparam integer NFR=3;                               // NUM_FRAMES (ring depth)
    localparam integer NFRAMES_DRIVE=8;                     // drive > 2 ring wraps
    localparam integer MEMBYTES=NFR*STRIDE;

    reg clk=0, rstn=0; always #5 clk=~clk;

    // ---- producer: pg_raster_to_tile ----
    reg [23:0] s_td; reg s_tv=0, s_tuser=0, s_tlast=0; wire s_tr;
    wire [23:0] t_td; wire t_tv, t_tl, t_sof; wire t_tr;
    // RUNTIME-WIDTH PROOF (dest-res-master): synth the tiler BRAM for a MAX width 64 (.IN_W(64)) but drive the
    // ACTIVE width in_w=IN_W=32 at runtime. Proves a runtime width *below* the synth max tiles+reads bit-exact
    // end-to-end — exactly the silicon case (BRAM sized 1920, active LOD e.g. 1280).
    pg_raster_to_tile #(.IN_W(64),.LTILE(4)) u_prod(
        .clk(clk),.rstn(rstn),.in_w(IN_W[11:0]),.s_tdata(s_td),.s_tvalid(s_tv),.s_tready(s_tr),
        .s_tuser(s_tuser),.s_tlast(s_tlast),
        .m_tdata(t_td),.m_tvalid(t_tv),.m_tready(t_tr),.m_tlast(t_tl),.m_sof(t_sof));

    // ---- 24b -> 64b packer ----
    wire [63:0] p_td; wire p_tv; wire p_tr;
    pg_tile_pack64 u_pack(
        .clk(clk),.rstn(rstn),
        .s_tdata(t_td),.s_tvalid(t_tv),.s_tready(t_tr),
        .m_tdata(p_td),.m_tvalid(p_tv),.m_tready(p_tr));

    // ---- command generator + ring slot + gray frame_ptr ----
    wire [71:0] cmd_td; wire cmd_tv; reg cmd_tr_int;
    reg  [7:0]  sts_td; reg sts_tv; wire sts_tr;
    wire [5:0]  fp; wire [31:0] cmd_dbg;
    pg_tile_s2mm_cmd #(.FRAME_BUF_BASE(BASE),.NUM_FRAMES(NFR)) u_cmd(
        .clk(clk),.rstn(rstn),.m_sof(t_sof),
        .frame_bytes(FBYTES[22:0]),.slot_stride(STRIDE[31:0]),
        .cmd_tdata(cmd_td),.cmd_tvalid(cmd_tv),.cmd_tready(cmd_tr_int),
        .sts_tdata(sts_td),.sts_tvalid(sts_tv),.sts_tready(sts_tr),
        .frame_ptr_out(fp),.dbg(cmd_dbg));

    // ===================================================================================================
    // Behavioral axi_datamover S2MM: latches a command (addr,BTT), then drains the packed 64-bit AXIS
    // stream writing 8 bytes/beat contiguously from addr; posts a status (0x80) after BTT bytes. Little-
    // endian within the beat (beat[8*k +: 8] -> mem[addr + off + k]) == the real DDR byte image.
    // ===================================================================================================
    reg [7:0] mem[0:MEMBYTES-1];
    reg [31:0] w_addr; integer w_left;     // bytes remaining for the active write command
    reg w_busy;
    integer wcmd_count;                    // total commands accepted (== frames written)
    assign p_tr = w_busy;                  // accept packed beats only while a write command is active
    integer kk;
    always @(posedge clk) begin
        if(!rstn) begin
            w_busy<=0; cmd_tr_int<=1; sts_tv<=0; sts_td<=8'h00; w_left<=0; wcmd_count<=0;
        end else begin
            if(sts_tv && sts_tr) sts_tv<=0;
            // accept a command when idle
            if(!w_busy) begin
                cmd_tr_int<=1;
                if(cmd_tv && cmd_tr_int) begin
                    w_addr <= cmd_td[63:32];
                    w_left <= cmd_td[22:0];
                    w_busy <= 1'b1;
                    cmd_tr_int <= 1'b0;       // single outstanding
                    wcmd_count <= wcmd_count + 1;
                end
            end else begin
                cmd_tr_int<=0;
                // drain packed beats into mem
                if(p_tv && p_tr) begin
                    for(kk=0; kk<8; kk=kk+1)
                        if(w_left - kk > 0) mem[(w_addr[31:0] - BASE) + kk] = p_td[8*kk +: 8];
                    w_addr <= w_addr + 8;
                    w_left <= w_left - 8;
                    if(w_left - 8 <= 0) begin
                        w_busy <= 1'b0;
                        sts_td <= 8'h80; sts_tv <= 1'b1;   // post completion status (non-error)
                    end
                end
            end
        end
    end

    // ---- consumer: pg_tile_dma TILED (behavioral read DataMover from mem) ----
    reg t_req=0; reg [11:0] t_tx,t_ty; wire t_ready;
    wire fv; wire [95:0] fblk; wire fl;
    wire dm_req; wire [31:0] dm_addr; wire [11:0] dm_len; reg dm_ready=1;
    reg [63:0] beat=0; reg bvalid=0; wire bready; reg blast=0;
    reg [31:0] rd_frame_base;
    pg_tile_dma #(.IN_W(IN_W),.LTILE(4),.TILED(1),.DREQ(16)) u_cons(
        .clk(clk),.rstn(rstn),.srst(1'b0),.frame_base(rd_frame_base),
        .t_req(t_req),.t_tx(t_tx),.t_ty(t_ty),.t_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),.fetch_ready(dm_ready),
        .beat_data(beat),.beat_valid(bvalid),.beat_ready(bready),.beat_last(blast));
    reg [31:0] rcaddr; integer rbtt, rbi; reg rbusy=0; integer rk;
    wire rcmd_go = dm_req && dm_ready && !rbusy;
    always @(posedge clk) begin
        if(!rstn) begin rbusy<=0; bvalid<=0; rbi<=0; end
        else begin
            if(rcmd_go) begin rcaddr<=dm_addr - BASE; rbtt<=dm_len*3; rbi<=0; rbusy<=1; end
            if(rbusy && (!bvalid || bready)) begin
                for(rk=0;rk<8;rk=rk+1) beat[rk*8 +: 8] <= (rbi*8+rk < rbtt) ? mem[rcaddr + rbi*8 + rk] : 8'h0;
                bvalid<=1; blast<=((rbi+1)*8 >= rbtt);
                if((rbi+1)*8 >= rbtt) rbusy<=0;
                rbi<=rbi+1;
            end else if(bvalid && bready) bvalid<=0;
        end
    end

    function [23:0] gray2bin; input [5:0] g; reg [5:0] b; begin
        b[5]=g[5]; b[4]=b[5]^g[4]; b[3]=b[4]^g[3]; b[2]=b[3]^g[2]; b[1]=b[2]^g[1]; b[0]=b[1]^g[0];
        gray2bin=b; end
    endfunction
    function [23:0] srcval; input integer f,r,c; srcval = f*100000 + r*1000 + c; endfunction

    // ===================================================================================================
    // SEQUENCE: drive NFRAMES_DRIVE frames into the producer. The write leg (pack+cmd+model) stores them in
    // the ring. After each frame completes, read it back from the COMPLETED slot the frame_ptr points at and
    // bit-exact-check vs that frame's source raster.
    // ===================================================================================================
    integer fnum, r, c, ti, j, k, found, errs, frame_errs, total_read;
    integer want[0:255], got[0:255], nwant, ngot;
    integer prev_done, rd_slot, expect_slot;
    integer drv_done;

    // background: keep wcmd_count visible; drive thread:
    initial begin
        errs=0; total_read=0; rstn=0; s_tv<=0;
        repeat(4)@(posedge clk); rstn=1; @(posedge clk);

        for(fnum=0; fnum<NFRAMES_DRIVE; fnum=fnum+1) begin
            prev_done = cmd_dbg[27:14];     // frames_done (status-completion count), NOT the issue count
            // ---- drive one frame's raster ----
            for(r=0;r<H;r=r+1) for(c=0;c<IN_W;c=c+1) begin
                @(posedge clk);
                s_td<=srcval(fnum,r,c); s_tv<=1; s_tuser<=(r==0&&c==0); s_tlast<=(c==IN_W-1);
                while(!s_tr) @(posedge clk);
            end
            @(posedge clk); s_tv<=0; s_tuser<=0; s_tlast<=0;
            // ---- wait for this frame's write to COMPLETE (cmd-gen frames_done increments at STATUS) ----
            begin : waitw integer g2; g2=0;
                while(cmd_dbg[27:14]==prev_done && g2<200000) begin @(posedge clk); g2=g2+1; end
            end
            repeat(4) @(posedge clk);   // let the cmd-gen advance wr_slot + settle frame_ptr

            // ---- the warp's read slot from the live frame_ptr ----
            rd_slot = (gray2bin(fp)==0) ? (NFR-1) : (gray2bin(fp)-1);
            expect_slot = fnum % NFR;   // frame fnum was written into slot fnum%NFR
            if(rd_slot !== expect_slot) begin
                errs=errs+1;
                $display("  ERR frame %0d: warp rd_slot=%0d expected_completed_slot=%0d (fp=%b)",
                         fnum, rd_slot, expect_slot, fp);
            end
            rd_frame_base = BASE + rd_slot*STRIDE;

            // ---- read every tile of this frame back and bit-exact check vs source ----
            frame_errs=0;
            for(ti=0; ti<TPF; ti=ti+1) begin
                // tile (ty,tx) where ti = ty*TILES_X + tx
                nwant=0;
                for(r=0;r<16;r=r+1) for(c=0;c<16;c=c+1) begin
                    want[nwant]=srcval(fnum, (ti/TILES_X)*16+r, (ti%TILES_X)*16+c); nwant=nwant+1; end
                ngot=0;
                @(posedge clk); t_req<=1; t_tx<=ti%TILES_X; t_ty<=ti/TILES_X; @(posedge clk);
                while(!t_ready) @(posedge clk); t_req<=0;
                begin : col integer guard; guard=0;
                    while(ngot<256 && guard<200000) begin
                        @(posedge clk);
                        if(fv) begin
                            got[ngot]=fblk[23:0];    got[ngot+1]=fblk[47:24];
                            got[ngot+2]=fblk[71:48]; got[ngot+3]=fblk[95:72]; ngot=ngot+4;
                        end
                        guard=guard+1;
                    end
                end
                total_read=total_read+ngot;
                for(j=0;j<nwant;j=j+1) begin found=0;
                    for(k=0;k<ngot;k=k+1) if(!found && got[k]==want[j]) begin got[k]=-1; found=1; end
                    if(!found) begin errs=errs+1; frame_errs=frame_errs+1; end
                end
            end
            $display("  frame %0d -> slot %0d : %0d tiles read, frame_errs=%0d", fnum, rd_slot, TPF, frame_errs);
        end

        $display("DEDICATED_DMA_RT: frames=%0d  writes=%0d  total_px_read=%0d  errs=%0d",
                 NFRAMES_DRIVE, wcmd_count, total_read, errs);
        if(errs==0 && wcmd_count==NFRAMES_DRIVE) $display("DEDICATED_DMA_RT: PASS");
        else $display("DEDICATED_DMA_RT: FAIL");
        $finish;
    end
    initial begin #20000000 $display("WATCHDOG writes=%0d errs=%0d",wcmd_count,errs); $finish; end
endmodule
`default_nettype wire
