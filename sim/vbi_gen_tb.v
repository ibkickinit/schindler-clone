// vbi_gen_tb.v — Unit test for vbi_gen.v.
//
// Sweeps pixel_count across one full line for each line type (pre-eq,
// vsync, post-eq, normal-H, active) and asserts the expected fraction of
// samples at sync tip, the expected pulse count, and that pulse widths
// match SMPTE 170M to within sample-period accuracy.

`default_nettype none
`timescale 1ns / 1ps

module vbi_gen_tb;

    // Match vbi_gen defaults (24 fps Schindler at 54 MS/s)
    localparam integer PIXELS_PER_LINE    = 3435;
    localparam integer H_FRONT_PIXELS     = 81;
    localparam integer H_SYNC_PIXELS      = 254;
    localparam integer EQ_PULSE_PIXELS    = 124;
    localparam integer V_SERRATION_PIXELS = 254;
    localparam integer HALF_LINE_PIXELS   = PIXELS_PER_LINE / 2;

    reg  [11:0] pixel_count;
    reg  [9:0]  line_count;
    wire        sync;

    vbi_gen dut (
        .pixel_count(pixel_count),
        .line_count(line_count),
        .sync(sync)
    );

    integer errors = 0;
    task check;
        input        cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                $display("FAIL: %0s  (line=%0d pixel=%0d sync=%b)",
                         msg, line_count, pixel_count, sync);
                errors = errors + 1;
            end
        end
    endtask

    // Sweep one line and count sync-high samples + pulse edges
    task analyze_line;
        input [9:0]  ln;
        input [31:0] expected_sync_count;
        input [3:0]  expected_pulse_count;
        input [255:0] label;

        integer sync_count;
        integer pulse_count;
        reg     prev_sync;
        integer i;
        begin
            line_count = ln;
            sync_count = 0;
            pulse_count = 0;
            prev_sync = 0;

            for (i = 0; i < PIXELS_PER_LINE; i = i + 1) begin
                pixel_count = i[11:0];
                #1;  // settle combinational
                if (sync) sync_count = sync_count + 1;
                if (sync && !prev_sync) pulse_count = pulse_count + 1;
                prev_sync = sync;
            end

            $display("%0s line=%0d:  sync_high=%0d (expected %0d), pulses=%0d (expected %0d)",
                     label, ln, sync_count, expected_sync_count, pulse_count, expected_pulse_count);

            if (sync_count != expected_sync_count) begin
                $display("  FAIL: sync_high count mismatch");
                errors = errors + 1;
            end
            if (pulse_count != expected_pulse_count) begin
                $display("  FAIL: pulse count mismatch");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("=== vbi_gen_tb start ===");
        pixel_count = 0;
        line_count = 0;

        // Expected sync-tip sample counts per line type:
        //   Pre-eq / Post-eq:  2 * EQ_PULSE_PIXELS         = 248
        //   V-sync:            PIXELS_PER_LINE - 2*V_SERR  = 2927  (odd line; halves asymmetric by 1)
        //   Normal H-sync:     H_SYNC_PIXELS               = 254
        analyze_line(10'd0,  2 * EQ_PULSE_PIXELS,                            4'd2, "pre-eq    ");
        analyze_line(10'd2,  2 * EQ_PULSE_PIXELS,                            4'd2, "pre-eq    ");
        analyze_line(10'd3,  PIXELS_PER_LINE - 2*V_SERRATION_PIXELS,         4'd2, "vsync     ");
        analyze_line(10'd5,  PIXELS_PER_LINE - 2*V_SERRATION_PIXELS,         4'd2, "vsync     ");
        analyze_line(10'd6,  2 * EQ_PULSE_PIXELS,                            4'd2, "post-eq   ");
        analyze_line(10'd8,  2 * EQ_PULSE_PIXELS,                            4'd2, "post-eq   ");
        analyze_line(10'd15, H_SYNC_PIXELS,                                  4'd1, "blank-fill");
        analyze_line(10'd50, H_SYNC_PIXELS,                                  4'd1, "active    ");
        analyze_line(10'd654, H_SYNC_PIXELS,                                 4'd1, "last line ");

        // Spot-check positions:
        // - First eq pulse must start at pixel 0 (eq line)
        line_count = 0; pixel_count = 0; #1;
        check(sync, "eq line: pulse at pixel 0");

        // - Second eq pulse starts at HALF_LINE
        line_count = 0; pixel_count = HALF_LINE_PIXELS; #1;
        check(sync, "eq line: pulse at half-line");

        // - eq pulse ends at EQ_PULSE_PIXELS
        line_count = 0; pixel_count = EQ_PULSE_PIXELS; #1;
        check(!sync, "eq line: gap right after first pulse");

        // - V-sync: serration at HALF_LINE - V_SERRATION
        line_count = 3; pixel_count = HALF_LINE_PIXELS - V_SERRATION_PIXELS; #1;
        check(!sync, "vsync line: serration gap before half-line");

        // - V-sync: broad pulse resumes at HALF_LINE
        line_count = 3; pixel_count = HALF_LINE_PIXELS; #1;
        check(sync, "vsync line: second broad pulse at half-line");

        // - Normal line: H-sync at H_FRONT
        line_count = 50; pixel_count = H_FRONT_PIXELS; #1;
        check(sync, "normal line: H-sync starts at front-porch end");

        // - Normal line: blanking before H_FRONT
        line_count = 50; pixel_count = H_FRONT_PIXELS - 1'b1; #1;
        check(!sync, "normal line: blanking during front porch");

        $display("=== End of sim ===");
        $display("Errors: %0d", errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

endmodule

`default_nettype wire
