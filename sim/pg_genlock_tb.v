// pg_genlock_tb.v — self-checking TB for the frame-pointer follow (v2).
//
// Drives the S2MM framestore pointer (frame_ptr) and checks:
//   read_slot      == (frame_ptr - READ_DELAY) mod NUM_FRAMES  [latched @ out vsync]
//   read_base_addr == FRAME_BUF_BASE + read_slot*SLOT_STRIDE
//   write_slot     == frame_ptr (debounced)
//   read_slot is always a valid framestore (0..NUM_FRAMES-1), incl. across a
//   rapid frame_ptr transition right at out_vsync (debounce guard).
//
// Pass criterion: "Total errors = 0".  Run: make sim-pg.

`default_nettype none
`timescale 1ns / 1ps

module pg_genlock_tb;
    localparam [31:0]  FRAME_BUF_BASE = 32'h1000_0000;
    localparam integer NUM_FRAMES     = 5;
    localparam integer SLOT_STRIDE    = 2768640;
    localparam integer READ_DELAY     = 2;

    reg clk = 1'b0; always #5 clk = ~clk;
    reg rstn, out_vsync;
    reg  [5:0]  frame_ptr;
    wire [2:0]  read_slot, write_slot;
    wire [31:0] read_base_addr;

    pg_genlock #(.FRAME_BUF_BASE(FRAME_BUF_BASE), .NUM_FRAMES(NUM_FRAMES),
                 .SLOT_STRIDE(SLOT_STRIDE), .READ_DELAY(READ_DELAY)) dut (
        .clk(clk), .rstn(rstn), .frame_ptr(frame_ptr), .out_vsync(out_vsync),
        .read_slot(read_slot), .read_base_addr(read_base_addr), .write_slot(write_slot)
    );

    integer errors;

    // frame_ptr is GRAY-coded on real HW; present bin2gray(value) and keep expectations
    // in the decoded (binary) value, so the DUT's gray2bin path is exercised.
    function [5:0] bin2gray; input [5:0] b; begin bin2gray = b ^ (b >> 1); end endfunction

    task pulse_vsync; begin
        out_vsync <= 1'b1; repeat(2) @(posedge clk); out_vsync <= 1'b0; repeat(2) @(posedge clk);
    end endtask

    task set_and_check; input [5:0] fp; integer exp_read;
        begin
            frame_ptr <= bin2gray(fp);     // present Gray-coded pointer
            repeat(8) @(posedge clk);   // settle CDC (3-FF) + debounce
            pulse_vsync;
            exp_read = (fp >= READ_DELAY) ? (fp - READ_DELAY) : (fp + NUM_FRAMES - READ_DELAY);
            if (read_slot !== exp_read[2:0]) begin
                $display("  ERR fp=%0d read_slot=%0d exp=%0d", fp, read_slot, exp_read); errors=errors+1; end
            if (read_base_addr !== FRAME_BUF_BASE + read_slot*SLOT_STRIDE) begin
                $display("  ERR fp=%0d base=%h", fp, read_base_addr); errors=errors+1; end
            if (write_slot !== fp[2:0]) begin
                $display("  ERR fp=%0d write_slot=%0d", fp, write_slot); errors=errors+1; end
        end
    endtask

    integer i;
    initial begin
        errors=0; rstn=0; out_vsync=0; frame_ptr=0;
        repeat(5) @(posedge clk); rstn=1; repeat(3) @(posedge clk);

        // sweep all framestore values incl. wrap (fp<READ_DELAY → +NUM_FRAMES)
        set_and_check(0); set_and_check(1); set_and_check(2);
        set_and_check(3); set_and_check(4);
        set_and_check(2); set_and_check(0); set_and_check(4); set_and_check(1);

        // glitch/debounce guard: toggle frame_ptr every cycle while pulsing
        // vsync — read_slot/read_base must NEVER point at an invalid slot.
        for (i=0; i<200; i=i+1) begin
            frame_ptr <= bin2gray(i[5:0] % NUM_FRAMES);
            @(posedge clk);
            if ((i % 7) == 0) out_vsync <= 1'b1; else out_vsync <= 1'b0;
            if (read_slot >= NUM_FRAMES[2:0]) begin
                $display("  ERR invalid read_slot=%0d during churn", read_slot); errors=errors+1; end
        end
        out_vsync <= 0;

        $display("================================="); $display("Total errors = %0d", errors);
        $display("================================="); $finish;
    end
    initial begin #20_000_000; $display("TIMEOUT errors=%0d", errors); $finish; end
endmodule

`default_nettype wire
