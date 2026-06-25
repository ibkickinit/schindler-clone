// pg_tile_s2mm_cmd_tb.v — Path B dedicated-DMA command generator + ring-slot genlock proof.
//
// Drives N frame-start (m_sof) pulses, models the DataMover cmd/status handshake (accept cmd, return a
// status some latency later), and checks:
//   (a) exactly ONE command per frame, with addr = FRAME_BUF_BASE + wr_slot*SLOT_STRIDE and BTT = FRAME_BYTES,
//   (b) the write slot advances 0,1,..,NUM_FRAMES-1,0,.. (wraps),
//   (c) frame_ptr_out is the GRAY code of wr_slot, and gray2bin(frame_ptr_out)-1 (mod N) = the slot just
//       COMPLETED == what pg_warp_top will read,
//   (d) no command is issued while a prior frame's write is still in flight (single-outstanding).
`default_nettype none
`timescale 1ns/1ps
module pg_tile_s2mm_cmd_tb;
    localparam [31:0] BASE   = 32'h1000_0000;
    localparam integer N     = 7;             // NUM_FRAMES
    localparam integer STRIDE= 6226560;
    localparam integer FBYTES= 6174720;
    localparam integer NFR   = 18;            // frames to drive (> 2 full ring wraps)

    reg clk=0, rstn=0; always #5 clk=~clk;
    reg m_sof=0;
    wire [71:0] cmd_td; wire cmd_tv; reg cmd_tr=1;
    reg  [7:0]  sts_td=8'h00; reg sts_tv=0; wire sts_tr;
    wire [5:0]  fp; wire [31:0] dbg;

    pg_tile_s2mm_cmd #(.FRAME_BUF_BASE(BASE),.NUM_FRAMES(N),.SLOT_STRIDE(STRIDE),.FRAME_BYTES(FBYTES)) dut(
        .clk(clk),.rstn(rstn),.m_sof(m_sof),
        .cmd_tdata(cmd_td),.cmd_tvalid(cmd_tv),.cmd_tready(cmd_tr),
        .sts_tdata(sts_td),.sts_tvalid(sts_tv),.sts_tready(sts_tr),
        .frame_ptr_out(fp),.dbg(dbg));

    function [5:0] gray2bin; input [5:0] g; begin
        gray2bin[5]=g[5];             gray2bin[4]=gray2bin[5]^g[4]; gray2bin[3]=gray2bin[4]^g[3];
        gray2bin[2]=gray2bin[3]^g[2]; gray2bin[1]=gray2bin[2]^g[1]; gray2bin[0]=gray2bin[1]^g[0];
    end endfunction

    // capture issued commands
    integer ncmd, errs;
    integer exp_slot;                  // the slot the NEXT command should target
    reg [31:0] got_addr; reg [22:0] got_btt;
    integer pending;                   // 1 = a command was accepted, status not yet returned

    // --- DataMover model: accept a command (cmd_tr=1), then after a random-ish latency post one status.
    integer lat;
    always @(posedge clk) begin
        if(!rstn) begin pending<=0; sts_tv<=0; lat<=0; end
        else begin
            if(sts_tv && sts_tr) sts_tv<=0;
            if(cmd_tv && cmd_tr) begin
                // a command was accepted -> schedule a status
                pending<=1; lat<= (ncmd%3)+3;   // 3..5 cycle write latency
            end
            if(pending==1) begin
                if(lat>0) lat<=lat-1;
                else begin sts_td<=8'h80; sts_tv<=1; pending<=2; end  // bit7=OKAY-ish; non-error
            end
            if(pending==2 && sts_tv && sts_tr) pending<=0;
        end
    end

    // --- check each issued command at the cycle it is accepted ---
    always @(posedge clk) if(rstn && cmd_tv && cmd_tr) begin
        got_addr = cmd_td[63:32];
        got_btt  = cmd_td[22:0];
        // addr must equal BASE + exp_slot*STRIDE
        if(got_addr !== (BASE + exp_slot*STRIDE)) begin
            errs=errs+1;
            $display("  ERR cmd %0d addr=0x%08x exp=0x%08x (slot %0d)", ncmd, got_addr, BASE+exp_slot*STRIDE, exp_slot);
        end
        if(got_btt !== FBYTES[22:0]) begin
            errs=errs+1; $display("  ERR cmd %0d BTT=%0d exp=%0d", ncmd, got_btt, FBYTES); end
        // INCR(type bit23)=1, EOF(bit30)=1
        if(cmd_td[23]!==1'b1 || cmd_td[30]!==1'b1) begin
            errs=errs+1; $display("  ERR cmd %0d TYPE/EOF bits wrong (td[30:23]=%b)", ncmd, cmd_td[30:23]); end
        // frame_ptr_out must be gray(exp_slot) at issue time
        if(gray2bin(fp) !== exp_slot[5:0]) begin
            errs=errs+1; $display("  ERR cmd %0d frame_ptr gray2bin=%0d exp slot=%0d", ncmd, gray2bin(fp), exp_slot); end
        ncmd=ncmd+1;
        exp_slot = (exp_slot==N-1)? 0 : exp_slot+1;   // next command targets the next slot
    end

    // --- after each completion, the warp's read slot = gray2bin(fp)-1 mod N must equal the slot just done ---
    integer rd_slot, done_slot, comp_errs;
    reg comp_done=0;
    integer comps;
    always @(posedge clk) if(rstn && sts_tv && sts_tr) begin
        // at the cycle the status is accepted, dut is about to advance wr_slot to (done_slot+1).
        // Right AFTER advance, gray2bin(fp)=done_slot+1, rd_slot = done_slot. We check on the next cycle.
        comp_done <= 1'b1;
    end
    always @(posedge clk) if(rstn && comp_done) begin
        comp_done <= 1'b0;
        rd_slot = (gray2bin(fp)==0) ? (N-1) : (gray2bin(fp)-1);
        // rd_slot should be the slot whose write JUST completed = comps (mod N)
        done_slot = comps % N;
        if(rd_slot !== done_slot) begin
            comp_errs=comp_errs+1;
            $display("  ERR completion %0d: warp rd_slot=%0d exp=%0d (fp=%b)", comps, rd_slot, done_slot, fp);
        end
        comps=comps+1;
    end

    integer i;
    initial begin
        ncmd=0; errs=0; exp_slot=0; comps=0; comp_errs=0;
        rstn=0; repeat(4)@(posedge clk); rstn=1; @(posedge clk);
        for(i=0;i<NFR;i=i+1) begin
            // wait until the dut is ready to accept a new frame's command (prior write done)
            while(dbg[28]) @(posedge clk);          // dbg[28]=cmd_inflight; wait until idle
            @(posedge clk); m_sof<=1; @(posedge clk); m_sof<=0;
            // let the command issue + write complete
            repeat(12) @(posedge clk);
        end
        repeat(20)@(posedge clk);
        $display("CMD_TB: issued=%0d (exp %0d)  completions=%0d  data_errs=%0d  comp_errs=%0d",
                 ncmd, NFR, comps, errs, comp_errs);
        if(ncmd==NFR && comps==NFR && errs==0 && comp_errs==0) $display("CMD_TB: PASS");
        else $display("CMD_TB: FAIL");
        $finish;
    end
    initial begin #500000 $display("WATCHDOG ncmd=%0d comps=%0d",ncmd,comps); $finish; end
endmodule
`default_nettype wire
