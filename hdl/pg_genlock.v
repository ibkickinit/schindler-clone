// pg_genlock.v — present-geometry frame-follow (read-engine-B, Module 2). v2.
//
// v1 MIRRORED S2MM by counting source vsyncs and assuming framestores cycle
// 0,1,2,3,4 linearly. BENCH-DISPROVEN (2026-06-01): S2MM as a Dynamic-Master
// genlock + iter6 hw fsync does NOT pick framestores by a linear count, so the
// mirror drifted off and the reader landed on frozen slots.
//
// v2 follows S2MM's ACTUAL framestore pointer: the AXI VDMA exposes
// `s2mm_frame_ptr_out[5:0]` (the framestore S2MM is currently writing) even
// with internal genlock kept ON — so we tap it WITHOUT touching the proven
// VDMA genlock config. read_slot = (frame_ptr - READ_DELAY) mod NUM_FRAMES,
// giving a completed frame with margin. Latched at output vsync (frame-stable).
//
// frame_ptr is in the S2MM clock domain (FCLK_CLK1), async to this pixel clock.
// CDC: 2-FF sync + a 1-sample debounce (accept the value only when two
// consecutive synced samples agree) so a multi-bit mid-transition can't latch
// an invalid (e.g. >NUM_FRAMES) slot. XDC false-paths fp_q1_reg[*]/D.

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

    input  wire [5:0]  frame_ptr,   // S2MM current framestore (FCLK_CLK1, async)
    input  wire        out_vsync,   // output VTC vsync (this clock domain)

    output reg  [2:0]  read_slot,       // latched at output vsync, frame-stable
    output reg  [31:0] read_base_addr,  // FRAME_BUF_BASE + read_slot*SLOT_STRIDE
    output reg  [2:0]  write_slot       // debug: synced+debounced S2MM frame_ptr
);
    // ---- CDC + debounce for the multi-bit frame pointer ----
    (* ASYNC_REG = "TRUE" *) reg [5:0] fp_q1, fp_q2;
    reg [5:0] fp_q3, fp_stable;
    always @(posedge clk) begin
        if (!rstn) begin fp_q1 <= 6'd0; fp_q2 <= 6'd0; fp_q3 <= 6'd0; fp_stable <= 6'd0; end
        else begin
            fp_q1 <= frame_ptr; fp_q2 <= fp_q1; fp_q3 <= fp_q2;
            if (fp_q2 == fp_q3) fp_stable <= fp_q2;   // accept only a settled value
        end
    end

    // ---- output-vsync rising edge ----
    reg ov_q;
    always @(posedge clk) ov_q <= (!rstn) ? 1'b0 : out_vsync;
    wire ov_pulse = out_vsync & ~ov_q;

    // ---- read_slot = (frame_ptr - READ_DELAY) mod NUM_FRAMES ----
    // s2mm_frame_ptr_out is GRAY-CODED (bench-confirmed 2026-06-03). It MUST be decoded
    // before use; treating it as binary mis-tracks frames (only looked clean on a static
    // grid, where every framestore is identical). gray2bin then mod NUM_FRAMES → clean slot.
    function [5:0] gray2bin; input [5:0] g; begin
        gray2bin[5]=g[5]; gray2bin[4]=gray2bin[5]^g[4]; gray2bin[3]=gray2bin[4]^g[3];
        gray2bin[2]=gray2bin[3]^g[2]; gray2bin[1]=gray2bin[2]^g[1]; gray2bin[0]=gray2bin[1]^g[0];
    end endfunction
    wire [5:0] fp_use = gray2bin(fp_stable) % NUM_FRAMES[5:0];
    wire [3:0] rs = (fp_use >= READ_DELAY[5:0]) ? (fp_use[3:0] - READ_DELAY[3:0])
                                                : (fp_use[3:0] + NUM_FRAMES[3:0] - READ_DELAY[3:0]);

    always @(posedge clk) begin
        if (!rstn) begin
            read_slot <= 3'd0; read_base_addr <= FRAME_BUF_BASE; write_slot <= 3'd0;
        end else if (ov_pulse) begin
            read_slot      <= rs[2:0];
            read_base_addr <= FRAME_BUF_BASE + rs[2:0] * SLOT_STRIDE;
            write_slot     <= fp_use[2:0];
        end
    end
endmodule

`default_nettype wire
