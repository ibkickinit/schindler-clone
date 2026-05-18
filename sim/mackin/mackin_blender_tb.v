// mackin_blender_tb.v — Verilog testbench for mackin_blender.v
//
// Reads a vector file (one pixel pair per line):
//     prev_hex  curr_hex  expected_hex
// Drives the HDL with prev/curr/alpha (alpha hardcoded via parameter ALPHA_HEX),
// captures output, compares to expected. Reports pass/fail count.
//
// Run via xsim:
//     xvlog ../../hdl/mackin_blender.v mackin_blender_tb.v
//     xelab -d ALPHA_HEX=0x4000 -d VECFILE=\"vectors/alpha_4000.txt\" \
//           -top mackin_blender_tb -snapshot mb_tb -timescale 1ns/1ps
//     xsim mb_tb -R
//
// Drives 100 MHz aclk (10 ns period). Uses simple AXIS handshake — both inputs
// always valid, downstream always ready. Skips pipeline-stall scenarios for
// simplicity (tested separately in stall test).

`timescale 1ns / 1ps
`default_nettype none

// Runtime args (xsim plusargs):
//   +alpha=XXXX     hex alpha value (e.g., +alpha=4000 for 0x4000)
//   +vecfile=path   path to vector file

module mackin_blender_tb;

    reg [255:0] vecfile_path;
    reg [15:0]  alpha_runtime = 16'h8000;

    reg         aclk = 1'b0;
    reg         aresetn = 1'b0;
    reg         have_alpha = 1'b0;
    reg         have_vecfile = 1'b0;
    reg  [23:0] s_curr_tdata = 24'b0;
    reg         s_curr_tvalid = 1'b0;
    wire        s_curr_tready;
    reg         s_curr_tlast = 1'b0;
    reg         s_curr_tuser = 1'b0;

    reg  [23:0] s_prev_tdata = 24'b0;
    reg         s_prev_tvalid = 1'b0;
    wire        s_prev_tready;
    reg         s_prev_tlast = 1'b0;
    reg         s_prev_tuser = 1'b0;

    wire [23:0] m_axis_tdata;
    wire        m_axis_tvalid;
    reg         m_axis_tready = 1'b1;   // always ready
    wire        m_axis_tlast;
    wire        m_axis_tuser;

    reg  [15:0] alpha_async = 16'h8000;

    mackin_blender uut (
        .aclk           (aclk),
        .aresetn        (aresetn),
        .s_curr_tdata   (s_curr_tdata),
        .s_curr_tvalid  (s_curr_tvalid),
        .s_curr_tready  (s_curr_tready),
        .s_curr_tlast   (s_curr_tlast),
        .s_curr_tuser   (s_curr_tuser),
        .s_prev_tdata   (s_prev_tdata),
        .s_prev_tvalid  (s_prev_tvalid),
        .s_prev_tready  (s_prev_tready),
        .s_prev_tlast   (s_prev_tlast),
        .s_prev_tuser   (s_prev_tuser),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tuser   (m_axis_tuser),
        .alpha_async    (alpha_async)
    );

    // 100 MHz clock
    always #5 aclk = ~aclk;

    // ========================================================================
    // Vector file reader
    // ========================================================================
    integer fd, n;
    integer line_count = 0;

    // Stored vectors (max 1024 pixel pairs)
    reg [23:0] prev_vec [0:1023];
    reg [23:0] curr_vec [0:1023];
    reg [23:0] expt_vec [0:1023];
    integer    n_vecs = 0;

    reg [23:0] prev_tmp, curr_tmp, expt_tmp;

    integer drive_idx, check_idx;
    integer pass_count, fail_count;

    initial begin
        // Resolve runtime args
        have_alpha   = $value$plusargs("alpha=%h", alpha_runtime);
        have_vecfile = $value$plusargs("vecfile=%s", vecfile_path);
        if (!have_alpha) begin
            $display("[TB] FATAL: missing +alpha=<hex> plusarg");
            $finish;
        end
        if (!have_vecfile) begin
            $display("[TB] FATAL: missing +vecfile=<path> plusarg");
            $finish;
        end
        alpha_async = alpha_runtime;

        // Load vectors
        $display("[TB] Loading %0s ...", vecfile_path);
        fd = $fopen(vecfile_path, "r");
        if (fd == 0) begin
            $display("[TB] FATAL: could not open %0s", vecfile_path);
            $finish;
        end

        n_vecs = 0;
        while (!$feof(fd)) begin
            // Skip comment lines ("//...")
            n = $fscanf(fd, "%h %h %h\n", prev_tmp, curr_tmp, expt_tmp);
            if (n == 3) begin
                prev_vec[n_vecs] = prev_tmp;
                curr_vec[n_vecs] = curr_tmp;
                expt_vec[n_vecs] = expt_tmp;
                n_vecs = n_vecs + 1;
            end else begin
                // Skip non-data lines
                begin : skip_line
                    reg [255:0] dummy;
                    n = $fgets(dummy, fd);
                end
            end
        end
        $fclose(fd);
        $display("[TB] Loaded %0d vectors (alpha=0x%04x)", n_vecs, alpha_runtime);

        // Reset
        aresetn = 1'b0;
        repeat (4) @(posedge aclk);
        aresetn = 1'b1;
        @(posedge aclk);

        // Drive all vectors back-to-back, then drain and check
        drive_idx = 0;
        pass_count = 0;
        fail_count = 0;

        s_curr_tvalid = 1'b1;
        s_prev_tvalid = 1'b1;

        // Driver loop
        fork
            // Driver
            begin : driver
                for (drive_idx = 0; drive_idx < n_vecs; drive_idx = drive_idx + 1) begin
                    s_curr_tdata = curr_vec[drive_idx];
                    s_prev_tdata = prev_vec[drive_idx];
                    @(posedge aclk);
                    while (!s_curr_tready) @(posedge aclk);
                end
                s_curr_tvalid = 1'b0;
                s_prev_tvalid = 1'b0;
            end

            // Checker
            begin : checker
                check_idx = 0;
                while (check_idx < n_vecs) begin
                    @(posedge aclk);
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (m_axis_tdata === expt_vec[check_idx]) begin
                            pass_count = pass_count + 1;
                        end else begin
                            fail_count = fail_count + 1;
                            if (fail_count <= 8) begin
                                $display("[TB] FAIL #%0d: vec=%0d  prev=%06h curr=%06h  got=%06h  exp=%06h",
                                         fail_count, check_idx,
                                         prev_vec[check_idx], curr_vec[check_idx],
                                         m_axis_tdata, expt_vec[check_idx]);
                            end
                        end
                        check_idx = check_idx + 1;
                    end
                end
            end
        join

        // Report
        $display("[TB] RESULT alpha=0x%04x: %0d pass, %0d fail (of %0d)",
                 alpha_runtime, pass_count, fail_count, n_vecs);
        if (fail_count == 0)
            $display("[TB] PASS");
        else
            $display("[TB] FAIL_TOTAL");
        $finish;
    end

    // Watchdog
    initial begin
        #1000000;  // 1 ms simulated
        $display("[TB] WATCHDOG TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
