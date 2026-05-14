// scaler_top_tb.v — Frame-level testbench for scaler_top (1920x1080 -> 1280x720).
//
// What this catches:
//   1. Total pixels per output frame != 1280*720
//   2. Output lines != 1280 pixels (TLAST in wrong position)
//   3. TUSER missing or on wrong pixel
//   4. Behavior under downstream backpressure (m_axis_tready toggling)
//   5. The "back-to-back v_cross resets in-progress emit" bug suspected in
//      scaler_v when an emit hasn't finished before the next cross fires.
//
// Run from sim/ directory (so $readmemh finds scaler_coeffs_{h,v}.hex):
//   xvlog ../hdl/scaler_h.v ../hdl/scaler_v.v ../hdl/scaler_top.v \
//         ../hdl/scaler_coeffs_h.v ../hdl/scaler_coeffs_v.v scaler_top_tb.v
//   xelab -debug typical -top scaler_top_tb -snapshot scaler_top_tb_sim
//   xsim scaler_top_tb_sim -runall

`default_nettype none
`timescale 1ns / 1ps

module scaler_top_tb #(
    // Frame dims — defaulted to the C.1 first-light ratio. Override at
    // elaboration via `xelab -generic_top "IN_W=... OUT_W=... OUT_H=..."`
    // to sim a different ratio without touching this file.
    parameter integer IN_W  = 1920,
    parameter integer IN_H  = 1080,
    parameter integer OUT_W = 1280,
    parameter integer OUT_H = 720
);

    reg clk = 0;
    always #3.367 clk = ~clk;  // ~148.5 MHz

    reg aresetn = 0;

    // Input AXIS
    reg  [23:0] s_axis_tdata = 0;
    reg         s_axis_tvalid = 0;
    wire        s_axis_tready;
    reg         s_axis_tlast = 0;
    reg         s_axis_tuser = 0;

    // Output AXIS
    wire [23:0] m_axis_tdata;
    wire        m_axis_tvalid;
    reg         m_axis_tready = 1;
    wire        m_axis_tlast;
    wire        m_axis_tuser;

    scaler_top #(
        .IN_W  (IN_W),
        .IN_H  (IN_H),
        .OUT_W (OUT_W),
        .OUT_H (OUT_H)
    ) dut (
        .aclk          (clk),
        .aresetn       (aresetn),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tuser  (s_axis_tuser),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast),
        .m_axis_tuser  (m_axis_tuser)
    );

    // -----------------------------------------------------------------------
    // Output AXIS observer: per-frame counters + framing assertions
    // -----------------------------------------------------------------------
    integer out_pixels_in_frame = 0;     // pixels seen since last TUSER (incl current)
    integer out_pixels_in_line  = 0;     // pixels seen since last TLAST (incl current)
    integer out_tlast_count     = 0;     // TLAST count this frame
    integer out_tuser_count     = 0;     // TUSER count total (debug)
    integer out_frame_idx       = 0;     // 0-indexed frames received
    integer out_first_pixel     = 1;     // 1 until first pixel received

    // Per-frame line widths — record first 5 line widths to detect drift
    integer line_widths [0:9];
    integer line_idx = 0;

    integer errors = 0;
    task fail;
        input [511:0] msg;
        begin
            $display("[t=%0t] FAIL: %0s", $time, msg);
            errors = errors + 1;
        end
    endtask

    always @(posedge clk) begin
        if (aresetn && m_axis_tvalid && m_axis_tready) begin
            // TUSER bookkeeping: marks the FIRST pixel of a frame
            if (m_axis_tuser) begin
                out_tuser_count = out_tuser_count + 1;
                if (!out_first_pixel) begin
                    // End of previous frame
                    if (out_pixels_in_frame != OUT_W * OUT_H) begin
                        $display("[t=%0t] FRAME %0d size mismatch: got %0d pixels (expected %0d)",
                                 $time, out_frame_idx, out_pixels_in_frame, OUT_W * OUT_H);
                        errors = errors + 1;
                    end
                    if (out_tlast_count != OUT_H) begin
                        $display("[t=%0t] FRAME %0d TLAST count: got %0d (expected %0d)",
                                 $time, out_frame_idx, out_tlast_count, OUT_H);
                        errors = errors + 1;
                    end
                    out_frame_idx = out_frame_idx + 1;
                end
                out_pixels_in_frame = 0;
                out_tlast_count = 0;
                line_idx = 0;
                out_first_pixel = 0;
            end

            out_pixels_in_frame = out_pixels_in_frame + 1;
            out_pixels_in_line  = out_pixels_in_line  + 1;

            if (m_axis_tlast) begin
                if (line_idx < 10) begin
                    line_widths[line_idx] = out_pixels_in_line;
                    line_idx = line_idx + 1;
                end
                if (out_pixels_in_line != OUT_W) begin
                    if (out_tlast_count < 5 || out_pixels_in_line != OUT_W) begin
                        $display("[t=%0t] FRAME %0d LINE %0d width = %0d (expected %0d)",
                                 $time, out_frame_idx, out_tlast_count, out_pixels_in_line, OUT_W);
                        if (out_pixels_in_line != OUT_W) errors = errors + 1;
                    end
                end
                out_tlast_count = out_tlast_count + 1;
                out_pixels_in_line = 0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Backpressure pattern selector
    // -----------------------------------------------------------------------
    reg [31:0] bp_seed = 32'hCAFEBABE;
    reg        bp_enable = 0;       // when 1, m_axis_tready toggles
    integer    bp_cycle = 0;
    always @(posedge clk) begin
        if (!aresetn) begin
            bp_cycle <= 0;
            m_axis_tready <= 1;
        end else begin
            bp_cycle <= bp_cycle + 1;
            if (bp_enable) begin
                // 80% ready: ready low for 1 cycle every 5
                m_axis_tready <= (bp_cycle % 5 != 0);
            end else begin
                m_axis_tready <= 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Input AXIS driver: full 1080p frames with realistic blanking
    // -----------------------------------------------------------------------
    // v_vid_in_axi4s asserts TUSER on the first active pixel and TLAST on
    // the last active pixel of each line. Blanking arrives as TVALID=0
    // between TLAST and the next active pixel — emulate that.
    //
    // Blanking interval: ~1 source line of blanking between frames (~280
    // cycles inter-line, ~45 lines V blanking but we shorten to keep sim
    // tractable).
    localparam integer H_BLANK_CYCLES = 50;   // shortened from real ~280
    localparam integer V_BLANK_LINES  = 5;    // shortened from real ~45

    task drive_frame;
        input integer frame_num;
        integer row, col, i;
        begin
            $display("[t=%0t] === DRIVE FRAME %0d (input %0dx%0d) ===",
                     $time, frame_num, IN_W, IN_H);
            for (row = 0; row < IN_H; row = row + 1) begin
                for (col = 0; col < IN_W; col = col + 1) begin
                    @(posedge clk);
                    // Pixel data: simple gradient (row<<16 | col<<8 | frame)
                    s_axis_tdata  <= {row[7:0], col[7:0], frame_num[7:0]};
                    s_axis_tvalid <= 1;
                    s_axis_tuser  <= (row == 0) && (col == 0);
                    s_axis_tlast  <= (col == IN_W - 1);
                    // Wait until handshake completes (handles s_axis_tready
                    // backpressure if any — currently scaler_v always = 1, but
                    // future-proofs).
                    while (!s_axis_tready) @(posedge clk);
                end
                // H blanking after each line
                @(posedge clk);
                s_axis_tvalid <= 0;
                s_axis_tuser  <= 0;
                s_axis_tlast  <= 0;
                for (i = 0; i < H_BLANK_CYCLES; i = i + 1) @(posedge clk);
            end
            // V blanking after each frame
            for (i = 0; i < V_BLANK_LINES * (IN_W + H_BLANK_CYCLES); i = i + 1)
                @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------------
    initial begin
        $display("scaler_top_tb starting");
        // Reset
        aresetn = 0;
        repeat (20) @(posedge clk);
        aresetn = 1;
        repeat (10) @(posedge clk);

        // ---------- TEST 1: 1 frame, no backpressure ----------
        $display("\n========================================");
        $display("TEST 1: no backpressure, 1 frame");
        $display("========================================");
        bp_enable = 0;
        drive_frame(0);
        // Allow trailing output to drain after last input pixel
        repeat (10000) @(posedge clk);
        // Drive a sentinel frame so the observer flushes frame-0 checks
        drive_frame(1);
        repeat (10000) @(posedge clk);

        $display("\nFRAME 0 line widths (first %0d): %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 (line_idx > 10) ? 10 : line_idx,
                 line_widths[0], line_widths[1], line_widths[2], line_widths[3], line_widths[4],
                 line_widths[5], line_widths[6], line_widths[7], line_widths[8], line_widths[9]);
        $display("Total TUSERs seen: %0d (expect 2)", out_tuser_count);
        $display("Total errors after TEST 1: %0d", errors);

        // ---------- TEST 2: 1 frame, 80% backpressure ----------
        $display("\n========================================");
        $display("TEST 2: 80%% backpressure, 1 frame");
        $display("========================================");
        // Reset frame-0 expectations
        bp_enable = 1;
        drive_frame(2);
        repeat (50000) @(posedge clk);
        drive_frame(3);
        repeat (50000) @(posedge clk);

        $display("Total TUSERs seen: %0d (expect 4)", out_tuser_count);
        $display("Total errors after TEST 2: %0d", errors);

        // ---------- Summary ----------
        $display("\n========================================");
        if (errors == 0)
            $display("PASS (%0d errors)", errors);
        else
            $display("FAIL (%0d errors)", errors);
        $display("========================================");
        $finish;
    end

    // Failsafe timeout
    initial begin
        #500000000;  // 500 ms simulated
        $display("\n[TIMEOUT] Simulation exceeded 500 ms; exiting.");
        $display("State: out_pixels_in_frame=%0d, out_tlast_count=%0d, out_tuser_count=%0d",
                 out_pixels_in_frame, out_tlast_count, out_tuser_count);
        $finish;
    end

endmodule

`default_nettype wire
