// pg_genlock.v — present-geometry frame-follow (read-engine-B, Module 2).
//
// The read-engine is "a second MM2S": S2MM keeps writing the 5-slot ring at
// source rate (anchored by iter6 hw fsync) and does not care who reads. This
// module tells the read-engine WHICH slot to read so it always pulls a frame
// S2MM has finished writing — no tearing, decoupled output cadence.
//
// Mechanism (mirror, not coupling):
//   - S2MM advances one ring slot per source vsync. We watch the SAME source
//     vsync and mirror that advance:  write_slot = (#src_vsync) mod NUM_FRAMES.
//   - At each OUTPUT vsync we latch  read_slot = (write_slot - READ_DELAY) mod N
//     and hold it stable for the whole output frame (frame-atomic).
//   - read_base_addr = FRAME_BUF_BASE + read_slot * SLOT_STRIDE.
//
// READ_DELAY=2 reads two frames behind the in-progress write. With NUM_FRAMES=5
// that tolerates up to <3 source frames per output frame (60→~20 Hz) AND ±1 of
// absolute-slot mismatch between our mirror and S2MM's true pointer — the only
// part that is bench-gated (confirm: no tearing across 3 cold boots). All the
// counter/address/latch logic here is sim-verifiable against a model.
//
// src_vsync is a level from a different clock domain (dvi2rgb pclk_in); we
// synchronize + rising-edge detect it locally. out_vsync is in this domain.

`default_nettype none
`timescale 1ns / 1ps

module pg_genlock #(
    parameter [31:0]  FRAME_BUF_BASE = 32'h1000_0000,
    parameter integer NUM_FRAMES     = 5,
    parameter integer SLOT_STRIDE    = 2768640,  // FRAME_BYTES + STRIDE guard row
    parameter integer READ_DELAY     = 2
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire        src_vsync,   // async level from dvi2rgb vid_pVSync
    input  wire        out_vsync,   // output VTC vsync (this clock domain)

    output reg  [2:0]  read_slot,       // latched at output vsync, frame-stable
    output reg  [31:0] read_base_addr,  // FRAME_BUF_BASE + read_slot*SLOT_STRIDE
    output reg  [2:0]  write_slot       // debug: mirrored S2MM write pointer
);
    // ---- CDC + rising-edge detect on src_vsync (foreign domain) ----
    (* ASYNC_REG = "TRUE" *) reg sv_q1, sv_q2;
    reg sv_q3;
    always @(posedge clk) begin
        if (!rstn) begin sv_q1 <= 1'b0; sv_q2 <= 1'b0; sv_q3 <= 1'b0; end
        else       begin sv_q1 <= src_vsync; sv_q2 <= sv_q1; sv_q3 <= sv_q2; end
    end
    wire src_vsync_pulse = sv_q2 & ~sv_q3;   // 1-cycle pulse per source frame

    // ---- rising-edge detect on out_vsync (same domain) ----
    reg ov_q;
    always @(posedge clk) ov_q <= (!rstn) ? 1'b0 : out_vsync;
    wire out_vsync_pulse = out_vsync & ~ov_q;

    // ---- mirrored write pointer + latched read pointer ----
    wire [3:0] ws_next = (write_slot == NUM_FRAMES[3:0]-4'd1) ? 4'd0
                                                              : (write_slot + 4'd1);
    // read_slot = (write_slot - READ_DELAY) mod NUM_FRAMES, no negative wrap
    wire [3:0] rs_calc = (write_slot >= READ_DELAY[3:0])
                         ? (write_slot - READ_DELAY[3:0])
                         : (write_slot + NUM_FRAMES[3:0] - READ_DELAY[3:0]);

    always @(posedge clk) begin
        if (!rstn) begin
            write_slot     <= 3'd0;
            read_slot      <= 3'd0;
            read_base_addr <= FRAME_BUF_BASE;
        end else begin
            if (src_vsync_pulse)
                write_slot <= ws_next[2:0];

            if (out_vsync_pulse) begin
                read_slot      <= rs_calc[2:0];
                read_base_addr <= FRAME_BUF_BASE + rs_calc[2:0] * SLOT_STRIDE;
            end
        end
    end
endmodule

`default_nettype wire
