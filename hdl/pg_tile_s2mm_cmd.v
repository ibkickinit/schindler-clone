// pg_tile_s2mm_cmd.v — dedicated S2MM-DataMover command generator + ring-slot genlock for Path B.
//
// Replaces the Xilinx VDMA S2MM write leg. The Path B tiled stream is a SINGLE CONTIGUOUS block per frame
// (TILES_X*TILES_Y tiles * 768 B = 6,174,720 B for 120x67), so the write is one plain S2MM DataMover command
// per frame:  {addr = FRAME_BUF_BASE + wr_slot*SLOT_STRIDE, BTT = FRAME_BYTES, INCR, EOF}.  No 2D, no fsync,
// no per-line semantics — exactly what the VDMA's 2D+fsync model could NOT express for the gapless tiled
// stream (it asserted EOLEarly and corrupted the master).
//
// FRAME START: pg_raster_to_tile/m_sof pulses 1 cycle on the first emitted beat of tile(0,0) of each frame.
// On that pulse we issue the command for the CURRENT write slot.  The 64-bit packed tile data
// (pg_tile_pack64 -> S_AXIS_S2MM) for that frame then streams behind the command; the DataMover writes BTT
// bytes contiguously and posts a status word when the frame's last byte lands.
//
// RING SLOT + GENLOCK (frame_ptr): mirrors the VDMA s2mm_frame_ptr_out semantics that pg_warp_top decodes.
//   * wr_slot = the slot we are CURRENTLY writing (issued at m_sof).  Advances (mod NUM_FRAMES) at frame
//     COMPLETION (DataMover status received) — i.e. wr_slot points at the in-progress write, matching the
//     VDMA "frame_ptr = slot being filled" convention.
//   * frame_ptr_out = gray(wr_slot).  pg_warp_top does gray2bin(frame_ptr) -> fp_bin, then rd_slot=fp_bin-1
//     = the just-COMPLETED slot.  So the warp always reads the most-recently fully-written tiled frame,
//     IDENTICAL to today's VDMA path.  Gray coding guarantees a single-bit change per advance so the warp's
//     3-FF CDC + settle-debounce can never sample a torn multi-bit value.
//
// COMMAND/STATUS HANDSHAKE: one outstanding command at a time (a frame takes ~1/60 s to stream; the next
// m_sof is a full frame away, so single-outstanding is always sufficient and keeps wr_slot/status unambiguous).
// A missed/back-pressured command (cmd_tready low at m_sof — should never happen since the prior frame long
// since drained) would skip that frame's write; we assert the command and HOLD it until accepted, and arm the
// next issue only after the in-flight frame's status returns, so slot accounting stays exact.

`default_nettype none
`timescale 1ns / 1ps

module pg_tile_s2mm_cmd #(
    parameter [31:0]  FRAME_BUF_BASE = 32'h1000_0000,
    parameter integer NUM_FRAMES     = 7,
    parameter integer SLOT_STRIDE    = 6226560,
    parameter integer FRAME_BYTES    = 6174720      // TILES_X*TILES_Y*768 (120*67*768)
) (
    input  wire        clk, rstn,
    input  wire        m_sof,                 // 1-cyc pulse: first beat of tile(0,0) of a new frame (tiler clk)

    // S2MM DataMover command stream (72-bit, standard DataMover format)
    output reg  [71:0] cmd_tdata,
    output reg         cmd_tvalid,
    input  wire        cmd_tready,

    // S2MM DataMover status stream (8-bit: [7]=interr [6]=slverr [5]=decerr [4]=okay ... we only need "a
    // status arrived" to mark the frame's write complete and advance the slot)
    input  wire [7:0]  sts_tdata,
    input  wire        sts_tvalid,
    output wire        sts_tready,

    // genlock: gray-coded write-slot pointer for pg_warp_top/frame_ptr (mirrors VDMA s2mm_frame_ptr_out)
    output wire [5:0]  frame_ptr_out,
    // bring-up telemetry: {sts_err, cmd_inflight, frames_done[13:0], cmds_issued[13:0]}  (read via GPIO)
    output wire [31:0] dbg
);
    // ---- ring write-slot (binary) + gray encode ----
    reg  [5:0] wr_slot;                        // slot currently being written (issued at m_sof)
    function [5:0] bin2gray; input [5:0] b; begin bin2gray = b ^ (b >> 1); end endfunction
    assign frame_ptr_out = bin2gray(wr_slot);

    // ---- command word ----
    // {RSVD[71:68]=0, TAG[67:64]=0, SADDR[63:32], DRR[31]=0, EOF[30]=1, DSA[29:24]=0, TYPE[23]=1(INCR), BTT[22:0]}
    wire [31:0] slot_addr = FRAME_BUF_BASE + wr_slot * SLOT_STRIDE;
    wire [22:0] btt       = FRAME_BYTES[22:0];

    reg        cmd_inflight;                   // a frame's command is issued, status not yet returned
    reg [13:0] cmds_issued, frames_done;
    reg        sts_err;
    assign sts_tready = 1'b1;                   // always drain status
    wire       sts_beat = sts_tvalid && sts_tready;

    always @(posedge clk) begin
        if(!rstn) begin
            wr_slot      <= 6'd0;
            cmd_tvalid   <= 1'b0;
            cmd_tdata    <= 72'd0;
            cmd_inflight <= 1'b0;
            cmds_issued  <= 14'd0;
            frames_done  <= 14'd0;
            sts_err      <= 1'b0;
        end else begin
            // retire an accepted command
            if(cmd_tvalid && cmd_tready) cmd_tvalid <= 1'b0;

            // issue one command per frame start, only if the previous frame's write has completed
            // (cmd_inflight clears on status). A pending (not-yet-accepted) command also blocks a new issue.
            if(m_sof && !cmd_inflight && !cmd_tvalid) begin
                cmd_tdata    <= {4'd0, 4'd0, slot_addr, 1'b0, 1'b1, 6'd0, 1'b1, btt};
                cmd_tvalid   <= 1'b1;
                cmd_inflight <= 1'b1;
                cmds_issued  <= cmds_issued + 14'd1;
            end

            // frame write complete -> advance the ring slot (mod NUM_FRAMES) + clear in-flight
            if(sts_beat && cmd_inflight) begin
                cmd_inflight <= 1'b0;
                frames_done  <= frames_done + 14'd1;
                wr_slot      <= (wr_slot == NUM_FRAMES[5:0]-6'd1) ? 6'd0 : (wr_slot + 6'd1);
                // SLVERR(bit6)/DECERR(bit5)/INTERR(bit7) -> sticky error flag for telemetry
                if(sts_tdata[7] || sts_tdata[6] || sts_tdata[5]) sts_err <= 1'b1;
            end
        end
    end

    assign dbg = { sts_err, cmd_inflight, frames_done, cmds_issued };
endmodule

`default_nettype wire
