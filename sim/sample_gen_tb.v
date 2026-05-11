// sample_gen_tb.v — Integration testbench for vid_timing + sample_gen.
//
// Wires the two modules together, drives a 54 MHz clock, and continuously
// checks that the DAC output matches the spec (sync tip during hsync,
// pattern value during active, blanking otherwise — accounting for the
// 1-cycle output register).
//
// Cycles through all 3 patterns (gray, ramp, bars) — one frame each.

`default_nettype none
`timescale 1ns / 1ps

module sample_gen_tb;

    localparam real CLK_PERIOD_NS = 18.5185;  // 54 MHz

    // DAC code constants (must match sample_gen.v)
    localparam [9:0] CODE_SYNC_TIP    = 10'd0;
    localparam [9:0] CODE_BLANKING    = 10'd293;
    localparam [9:0] CODE_BLACK_SETUP = 10'd348;
    localparam [9:0] CODE_GRAY_50     = 10'd658;
    localparam [9:0] CODE_WHITE_100   = 10'd1023;
    localparam [9:0] CODE_BAR_WHITE   = 10'd855;
    localparam [9:0] CODE_BAR_YELLOW  = 10'd797;
    localparam [9:0] CODE_BAR_CYAN    = 10'd702;
    localparam [9:0] CODE_BAR_GREEN   = 10'd643;
    localparam [9:0] CODE_BAR_MAGENTA = 10'd555;
    localparam [9:0] CODE_BAR_RED     = 10'd497;
    localparam [9:0] CODE_BAR_BLUE    = 10'd402;

    // Default geometry (24 fps Schindler)
    localparam integer PIXELS_PER_LINE = 3435;
    localparam integer LINES_PER_FRAME = 655;
    localparam integer ACTIVE_START    = 589;
    localparam integer N_ACTIVE        = PIXELS_PER_LINE - ACTIVE_START;  // 2846
    localparam integer BAR_WIDTH       = N_ACTIVE / 7;                    // 406

    reg         clk = 0;
    reg         rst = 1;
    reg  [2:0]  pattern_sel = 3'd0;
    wire [11:0] pixel_count;
    wire [9:0]  line_count;
    wire        hsync, vsync, active, sof, sol;
    wire        sync_combined;
    wire [9:0]  dac;

    vid_timing dut_timing (
        .clk(clk), .rst(rst),
        .pixel_count(pixel_count), .line_count(line_count),
        .hsync(hsync), .vsync(vsync), .active(active),
        .sof(sof), .sol(sol)
    );

    vbi_gen dut_vbi (
        .pixel_count(pixel_count),
        .line_count(line_count),
        .sync(sync_combined)
    );

    sample_gen dut_samples (
        .clk(clk), .rst(rst),
        .sync(sync_combined), .active(active),
        .pixel_count(pixel_count),
        .pattern_sel(pattern_sel),
        .dac(dac)
    );

    // ------------------------------------------------------------
    // Spec model — independent computation of what DAC SHOULD be.
    // Delayed 1 cycle to match the registered output.
    // ------------------------------------------------------------
    function [9:0] expected_bar;
        input [11:0] active_pixel;
        begin
            if      (active_pixel >= 6*BAR_WIDTH) expected_bar = CODE_BAR_BLUE;
            else if (active_pixel >= 5*BAR_WIDTH) expected_bar = CODE_BAR_RED;
            else if (active_pixel >= 4*BAR_WIDTH) expected_bar = CODE_BAR_MAGENTA;
            else if (active_pixel >= 3*BAR_WIDTH) expected_bar = CODE_BAR_GREEN;
            else if (active_pixel >= 2*BAR_WIDTH) expected_bar = CODE_BAR_CYAN;
            else if (active_pixel >= 1*BAR_WIDTH) expected_bar = CODE_BAR_YELLOW;
            else                                   expected_bar = CODE_BAR_WHITE;
        end
    endfunction

    reg [9:0] expected;
    reg [9:0] expected_d;  // 1-cycle delay to match registered DAC

    always @(*) begin
        if      (rst)            expected = CODE_BLANKING;
        else if (sync_combined)  expected = CODE_SYNC_TIP;
        else if (active) begin
            case (pattern_sel)
                3'd0: expected = CODE_GRAY_50;
                3'd1: expected = (({2'b00, (pixel_count - ACTIVE_START[11:0]) >> 2} + CODE_BLACK_SETUP) > CODE_WHITE_100)
                                  ? CODE_WHITE_100
                                  : ({2'b00, (pixel_count - ACTIVE_START[11:0]) >> 2} + CODE_BLACK_SETUP);
                3'd2: expected = expected_bar(pixel_count - ACTIVE_START[11:0]);
                default: expected = CODE_GRAY_50;
            endcase
        end
        else expected = CODE_BLANKING;
    end

    always @(posedge clk) expected_d <= expected;

    integer errors = 0;
    integer rst_done_cycles = 0;

    always @(posedge clk) begin
        // Skip checking the first cycle out of reset (DAC reg is still BLANKING)
        if (!rst) rst_done_cycles <= rst_done_cycles + 1;
        if (!rst && rst_done_cycles > 1) begin
            if (dac !== expected_d) begin
                $display("MISMATCH @ %0t: line=%0d pixel=%0d hsync=%b active=%b psel=%0d dac=%0d expected=%0d",
                         $time, line_count, pixel_count, hsync, active, pattern_sel, dac, expected_d);
                errors = errors + 1;
                if (errors > 20) begin
                    $display("Too many errors, stopping.");
                    $finish;
                end
            end
        end
    end

    // Clock
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    // Sequence: cycle through patterns, one frame per pattern.
    initial begin
        $display("=== sample_gen_tb (vid_timing + sample_gen, 24 fps) ===");
        repeat (4) @(posedge clk);
        rst = 0;

        // Pattern 0 (gray) — wait for first SOF then run a frame
        pattern_sel = 3'd0;
        @(posedge clk);
        @(posedge sof);                          // first SOF
        $display("[%0t] Frame: pattern=GRAY", $time);
        @(posedge sof);                          // second SOF (one full frame)

        pattern_sel = 3'd1;
        $display("[%0t] Frame: pattern=RAMP", $time);
        @(posedge sof);

        pattern_sel = 3'd2;
        $display("[%0t] Frame: pattern=BARS", $time);
        @(posedge sof);

        $display("=== End of sim ===");
        $display("  Errors: %0d", errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

endmodule

`default_nettype wire
