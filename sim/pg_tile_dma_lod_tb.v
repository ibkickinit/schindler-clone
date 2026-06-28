// pg_tile_dma_lod_tb.v — Phase 1 LOD read-path proof: pg_tile_dma per-LOD DDR ADDRESSING.
//
// Drives pg_tile_dma at lod=0,1,2 with known (tx,ty,rd_slot) tile requests and CHECKS the byte
// fetch_addr the module emits against the hand-computed per-LOD formula:
//
//   fetch_addr = FRAME_BUF_BASE + BASE_OFF[L] + rd_slot*SLOT[L] + (ty*16 + row)*STRIDE[L] + (tx*16)*3
//
// with the production params (IN_W=1920, IN_H=1080, NUM_FRAMES=7):
//   L0: BASE=0          STRIDE=5760  SLOT=6226560
//   L1: BASE=43585920   STRIDE=2880  SLOT=1558080
//   L2: BASE=54492480   STRIDE=1440  SLOT=390240
//
// REGRESSION (the byte-identical-at-L0 guarantee): the L0 column is compared against the ORIGINAL
// pre-LOD formula  FRAME_BUF_BASE + rd_slot*6226560 + (ty*16+row)*5760 + (tx*16)*3  — independently
// re-derived in this TB so a drift in the DUT's L0 path is caught.
//
// The DUT issues one DataMover command PER tile-row (RASTER mode, TILED=0), holding fetch_req and
// advancing iss_row on each fetch_ready. We snapshot fetch_addr at each fetch_req&fetch_ready and
// compare row-by-row. A trivial behavioral DataMover supplies just enough beats to retire the tile.
//
// Run: sim/run_tile_dma_lod.sh   (pure HDL, no golden, no hardware)

`default_nettype none
`timescale 1ns/1ps
module pg_tile_dma_lod_tb;
    localparam integer IN_W=1920, IN_H=1080, NUM_FRAMES=7, TILE=16, BYTES_PP=3;
    localparam [31:0]  FRAME_BUF_BASE = 32'h1000_0000;

    // expected per-LOD constants (independently computed here, NOT pulled from the DUT)
    localparam [31:0] STR_L0=IN_W*BYTES_PP,        STR_L1=(IN_W/2)*BYTES_PP,        STR_L2=(IN_W/4)*BYTES_PP;
    localparam [31:0] SLT_L0=IN_W*IN_H*BYTES_PP + IN_W*BYTES_PP;
    localparam [31:0] SLT_L1=(IN_W/2)*(IN_H/2)*BYTES_PP + (IN_W/2)*BYTES_PP;
    localparam [31:0] SLT_L2=(IN_W/4)*(IN_H/4)*BYTES_PP + (IN_W/4)*BYTES_PP;
    localparam [31:0] BAS_L0=0, BAS_L1=NUM_FRAMES*SLT_L0, BAS_L2=BAS_L1+NUM_FRAMES*SLT_L1;

    reg clk=0, rstn=0; always #5 clk=~clk;

    // DUT IO
    reg  [5:0] rd_slot=0; reg [2:0] lod=0;
    reg        t_req=0; reg [11:0] t_tx=0, t_ty=0; wire t_ready;
    wire       fv; wire [95:0] fblk; wire fl;
    wire       dm_req; wire [31:0] dm_addr; wire [11:0] dm_len; reg dm_ready=1;
    reg [63:0] beat=0; reg bvalid=0; wire bready; reg blast=0;

    pg_tile_dma #(.IN_W(IN_W),.IN_H(IN_H),.NUM_FRAMES(NUM_FRAMES),.LTILE(4),.TILED(0),.DREQ(16)) dut(
        .clk(clk),.rstn(rstn),.srst(1'b0),
        .frame_buf_base(FRAME_BUF_BASE),.rd_slot(rd_slot),.lod(lod),
        .t_req(t_req),.t_tx(t_tx),.t_ty(t_ty),.t_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),.fetch_ready(dm_ready),
        .beat_data(beat),.beat_valid(bvalid),.beat_ready(bready),.beat_last(blast));

    // trivial behavioral DataMover: on each accepted row command, emit ceil(len*3/8) beats of dummy
    // data so the receiver/emitter retire the tile (we only care about the addresses, not the pixels).
    reg [22:0] btt; integer bi; reg busy=0;
    wire cmd_go = dm_req && dm_ready && !busy;
    always @(posedge clk) begin
        if(!rstn) begin busy<=0; bvalid<=0; bi<=0; blast<=0; end
        else begin
            if(cmd_go) begin btt<=dm_len*3; bi<=0; busy<=1; end
            if(busy && (!bvalid || bready)) begin
                beat <= {8{8'hA5}};
                bvalid<=1; blast<=((bi+1)*8 >= btt);
                if((bi+1)*8 >= btt) busy<=0;
                bi<=bi+1;
            end else if(bvalid && bready) bvalid<=0;
        end
    end

    // expected-address helper (per-L constants chosen by `el`)
    integer errs, checks;
    function [31:0] exp_addr; input integer el; input integer ttx,tty,trow,tslot;
        reg [31:0] bas,str,slt; begin
            case(el) 1: begin bas=BAS_L1; str=STR_L1; slt=SLT_L1; end
                     2: begin bas=BAS_L2; str=STR_L2; slt=SLT_L2; end
                     default: begin bas=BAS_L0; str=STR_L0; slt=SLT_L0; end endcase
            exp_addr = FRAME_BUF_BASE + bas + tslot*slt + (tty*TILE + trow)*str + (ttx*TILE)*BYTES_PP;
        end
    endfunction
    // INDEPENDENT L0 oracle = the ORIGINAL pre-LOD formula (byte-identical regression).
    function [31:0] orig_addr; input integer ttx,tty,trow,tslot; begin
        orig_addr = FRAME_BUF_BASE + tslot*32'd6226560 + (tty*TILE+trow)*32'd5760 + (ttx*TILE)*3;
    end endfunction

    // issue ONE tile and snapshot the 16 row addresses the DUT emits, compare to expected.
    task run_tile; input integer el; input integer ttx,tty,tslot;
        integer rrow, exp, got, guard; begin
            lod <= el[2:0]; rd_slot <= tslot[5:0];
            @(posedge clk);
            t_req<=1; t_tx<=ttx[11:0]; t_ty<=tty[11:0];
            @(posedge clk); while(!t_ready) @(posedge clk); t_req<=0;
            rrow=0; guard=0;
            while(rrow<TILE && guard<5000) begin
                @(posedge clk);
                if(dm_req && dm_ready) begin
                    got = dm_addr;
                    exp = exp_addr(el,ttx,tty,rrow,tslot);
                    if(got!==exp) begin
                        $display("  FAIL L%0d tile(%0d,%0d) slot=%0d row=%0d: got=0x%08x exp=0x%08x",
                                 el,ttx,tty,tslot,rrow,got,exp); errs=errs+1;
                    end
                    // L0 also checked against the independent original formula
                    if(el==0 && got!==orig_addr(ttx,tty,rrow,tslot)) begin
                        $display("  FAIL L0-REGRESSION tile(%0d,%0d) row=%0d: got=0x%08x orig=0x%08x",
                                 ttx,tty,rrow,got,orig_addr(ttx,tty,rrow,tslot)); errs=errs+1;
                    end
                    checks=checks+1; rrow=rrow+1;
                end
                guard=guard+1;
            end
            if(rrow<TILE) begin $display("  TIMEOUT L%0d tile(%0d,%0d): only %0d rows",el,ttx,tty,rrow); errs=errs+1; end
            // print the row-0 address + bound check for the report
            $display("  L%0d tile(tx=%0d,ty=%0d,slot=%0d): row0=0x%08x (exp=0x%08x) STRIDE=%0d",
                     el,ttx,tty,tslot, exp_addr(el,ttx,tty,0,tslot), exp_addr(el,ttx,tty,0,tslot),
                     (el==1)?STR_L1:(el==2)?STR_L2:STR_L0);
            // region bound check (per task): L1 addresses in [base+BAS_L1, base+BAS_L1+NUM_FRAMES*SLT_L1)
            if(el==1) begin
                if(!(exp_addr(1,ttx,tty,0,tslot) >= FRAME_BUF_BASE+BAS_L1 &&
                     exp_addr(1,ttx,tty,15,tslot) <  FRAME_BUF_BASE+BAS_L1+NUM_FRAMES*SLT_L1)) begin
                    $display("  FAIL L1 region bound"); errs=errs+1; end
            end else if(el==2) begin
                if(!(exp_addr(2,ttx,tty,0,tslot) >= FRAME_BUF_BASE+BAS_L2 &&
                     exp_addr(2,ttx,tty,15,tslot) <  FRAME_BUF_BASE+BAS_L2+NUM_FRAMES*SLT_L2)) begin
                    $display("  FAIL L2 region bound"); errs=errs+1; end
            end
        end
    endtask

    initial begin
        errs=0; checks=0;
        rstn=0; repeat(6)@(posedge clk); rstn=1; repeat(3)@(posedge clk);

        $display("=== Phase1 LOD pg_tile_dma addressing ===");
        $display("constants: L0 STR=%0d SLOT=%0d BASE=%0d", STR_L0,SLT_L0,BAS_L0);
        $display("           L1 STR=%0d SLOT=%0d BASE=%0d", STR_L1,SLT_L1,BAS_L1);
        $display("           L2 STR=%0d SLOT=%0d BASE=%0d", STR_L2,SLT_L2,BAS_L2);

        // L0 (regression): a couple of tiles + slots
        run_tile(0, 0,0, 0);
        run_tile(0, 5,3, 2);
        run_tile(0, 17,9, 6);
        // L1
        run_tile(1, 0,0, 0);
        run_tile(1, 4,2, 3);
        run_tile(1, 10,7, 6);
        // L2
        run_tile(2, 0,0, 0);
        run_tile(2, 3,1, 5);

        $display("RESULT: %s  (checks=%0d errs=%0d)", (errs==0)?"PASS":"FAIL", checks, errs);
        $finish;
    end
    initial begin #2000000 $display("WATCHDOG"); $finish; end
endmodule
`default_nettype wire
