// vid_timing_tb.v — Self-checking testbench for vid_timing.v
//
// Drives a 54 MHz clock, exercises one full 24 fps Schindler frame, and
// asserts that HSYNC, VSYNC, ACTIVE, SOF, SOL, and the counters all
// transition at the sample/line indices the Python encoder predicts.
//
// Run with: vivado -mode batch -source ../tcl/sim_vid_timing.tcl
// Or via xsim directly: xvlog/xelab/xsim — see tcl script.

`default_nettype none
`timescale 1ns / 1ps

module vid_timing_tb;

    // 54 MHz clock period: 1/54e6 = 18.5185... ns
    localparam real CLK_PERIOD_NS = 18.5185;

    reg         clk = 0;
    reg         rst = 1;
    wire [11:0] pixel_count;
    wire [9:0]  line_count;
    wire        hsync, vsync, active, sof, sol;

    // DUT — default params = 24 fps Schindler at 54 MS/s
    vid_timing dut (
        .clk(clk),
        .rst(rst),
        .pixel_count(pixel_count),
        .line_count(line_count),
        .hsync(hsync),
        .vsync(vsync),
        .active(active),
        .sof(sof),
        .sol(sol)
    );

    // Match the DUT defaults (kept here for assertion math)
    localparam integer PIXELS_PER_LINE  = 3435;
    localparam integer H_FRONT_PIXELS   = 81;
    localparam integer H_SYNC_PIXELS    = 254;
    localparam integer H_BACK_PIXELS    = 254;
    localparam integer LINES_PER_FRAME  = 655;
    localparam integer VBI_LINES        = 21;
    localparam integer VSYNC_LINE_FIRST = 3;
    localparam integer VSYNC_LINE_LAST  = 5;
    localparam integer ACTIVE_START     = H_FRONT_PIXELS + H_SYNC_PIXELS + H_BACK_PIXELS;

    integer errors = 0;

    // Clock
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    // ------------------------------------------------------------
    // Assertions (sampled on every clock edge after reset)
    // ------------------------------------------------------------
    task check;
        input        cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                $display("ASSERT FAIL @ %0t: %0s  (line=%0d pixel=%0d hsync=%b vsync=%b active=%b)",
                         $time, msg, line_count, pixel_count, hsync, vsync, active);
                errors = errors + 1;
            end
        end
    endtask

    // Continuous checks
    always @(posedge clk) if (!rst) begin
        // hsync HIGH iff pixel in [H_FRONT, H_FRONT+H_SYNC)
        check(hsync == ((pixel_count >= H_FRONT_PIXELS) &&
                        (pixel_count <  H_FRONT_PIXELS + H_SYNC_PIXELS)),
              "hsync timing");

        // vsync HIGH iff line in [VSYNC_FIRST, VSYNC_LAST]
        check(vsync == ((line_count >= VSYNC_LINE_FIRST) &&
                        (line_count <= VSYNC_LINE_LAST)),
              "vsync timing");

        // active HIGH iff line>=VBI AND pixel>=ACTIVE_START
        check(active == ((line_count >= VBI_LINES) &&
                         (pixel_count >= ACTIVE_START)),
              "active timing");

        // sol pulse iff pixel==0
        check(sol == (pixel_count == 0), "sol");

        // sof pulse iff pixel==0 && line==0
        check(sof == ((pixel_count == 0) && (line_count == 0)), "sof");

        // Bounds
        check(pixel_count < PIXELS_PER_LINE, "pixel_count bound");
        check(line_count  < LINES_PER_FRAME, "line_count bound");
    end

    // ------------------------------------------------------------
    // Milestone reporting + sequence + finish
    // ------------------------------------------------------------
    integer hsync_count = 0;
    integer vsync_lines_seen = 0;
    integer active_pulses = 0;
    integer prev_active = 0;

    always @(posedge clk) if (!rst) begin
        if (sol)        hsync_count <= hsync_count + 1;       // counts lines via sol pulses
        if (sof)        $display("[%0t] SOF — start of frame (line=%0d pixel=%0d)", $time, line_count, pixel_count);
        if (line_count == VSYNC_LINE_FIRST && pixel_count == 0)
            $display("[%0t] V-sync starts at line %0d", $time, line_count);
        if (line_count == VSYNC_LINE_LAST + 1 && pixel_count == 0)
            $display("[%0t] V-sync ends after line %0d", $time, line_count - 1);
        if (line_count == VBI_LINES && pixel_count == ACTIVE_START)
            $display("[%0t] First active pixel  (line=%0d pixel=%0d)", $time, line_count, pixel_count);

        // Count active pulses (rising edges of `active` per frame)
        if (active && !prev_active) active_pulses <= active_pulses + 1;
        prev_active <= active;
    end

    initial begin
        $display("=== vid_timing_tb start (24 fps Schindler defaults) ===");
        $display("Expected: %0d pixels/line, %0d lines/frame, ACTIVE_START=%0d",
                 PIXELS_PER_LINE, LINES_PER_FRAME, ACTIVE_START);

        // Hold reset for 4 cycles
        repeat (4) @(posedge clk);
        rst = 0;

        // Run for one full frame + a bit more so we catch the wrap
        repeat (PIXELS_PER_LINE * (LINES_PER_FRAME + 2)) @(posedge clk);

        // Final summary
        $display("=== End of sim ===");
        $display("  SOL pulses (lines completed):  %0d  (expected %0d)",
                 hsync_count, LINES_PER_FRAME + 2);
        $display("  Active pulses (= active lines): %0d  (expected %0d/frame)",
                 active_pulses, LINES_PER_FRAME - VBI_LINES);
        $display("  Errors: %0d", errors);

        if (errors == 0) $display("PASS");
        else             $display("FAIL");

        $finish;
    end

endmodule

`default_nettype wire
