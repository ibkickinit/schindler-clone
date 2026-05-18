// rgb_to_ycbcr_tb.v — verifies hdl/rgb_to_ycbcr.v vs Python golden.
//
// Reads vectors/mode_<m>.txt. For each pixel pair (2 RGB inputs), drives
// the HDL and compares the 24-bit YCbCr output against the expected
// (3rd, 4th hex fields in the vector file).
//
// Run via xsim with plusargs:
//   +mode=<0..3>  +vecfile=<path>

`timescale 1ns / 1ps
`default_nettype none

module rgb_to_ycbcr_tb;

    reg [255:0] vecfile_path;
    reg [1:0]   mode_runtime = 2'd0;
    reg         have_mode, have_vecfile;

    reg         aclk = 1'b0;
    reg         aresetn = 1'b0;

    reg  [23:0] s_axis_tdata = 24'b0;
    reg         s_axis_tvalid = 1'b0;
    wire        s_axis_tready;
    reg         s_axis_tlast = 1'b0;
    reg         s_axis_tuser = 1'b0;

    wire [23:0] m_axis_tdata;
    wire        m_axis_tvalid;
    reg         m_axis_tready = 1'b1;
    wire        m_axis_tlast;
    wire        m_axis_tuser;

    reg  [1:0]  mode_async;

    rgb_to_ycbcr uut (
        .aclk          (aclk),
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
        .m_axis_tuser  (m_axis_tuser),
        .mode_async    (mode_async)
    );

    always #5 aclk = ~aclk;

    // Vector storage: each row has rgb0 rgb1 ycc0 ycc1 out0 out1
    // We test rgb_to_ycbcr only — flatten 2 RGB inputs → 2 expected YCbCr outputs.
    reg [23:0] rgb_vec [0:1023];
    reg [23:0] ycc_vec [0:1023];
    integer    n_vecs = 0;

    reg [23:0] rgb0, rgb1, ycc0, ycc1;
    reg [15:0] out0, out1;
    integer fd, n;

    integer drive_idx, check_idx;
    integer pass_count, fail_count;

    initial begin
        have_mode    = $value$plusargs("mode=%d", mode_runtime);
        have_vecfile = $value$plusargs("vecfile=%s", vecfile_path);
        if (!have_mode || !have_vecfile) begin
            $display("[TB] FATAL: need +mode and +vecfile plusargs");
            $finish;
        end
        mode_async = mode_runtime;

        $display("[TB] Loading %0s, mode=%0d", vecfile_path, mode_runtime);
        fd = $fopen(vecfile_path, "r");
        if (fd == 0) begin
            $display("[TB] FATAL: cannot open %0s", vecfile_path);
            $finish;
        end
        n_vecs = 0;
        while (!$feof(fd)) begin
            n = $fscanf(fd, "%h %h %h %h %h %h\n", rgb0, rgb1, ycc0, ycc1, out0, out1);
            if (n == 6) begin
                rgb_vec[2*n_vecs]   = rgb0;
                rgb_vec[2*n_vecs+1] = rgb1;
                ycc_vec[2*n_vecs]   = ycc0;
                ycc_vec[2*n_vecs+1] = ycc1;
                n_vecs = n_vecs + 1;
            end else begin
                begin : skip
                    reg [255:0] dummy;
                    n = $fgets(dummy, fd);
                end
            end
        end
        $fclose(fd);
        $display("[TB] Loaded %0d pixel pairs (%0d total pixels)", n_vecs, 2*n_vecs);

        aresetn = 1'b0;
        repeat (4) @(posedge aclk);
        @(negedge aclk);          // align to negedge — drive on falling, sample on rising
        aresetn = 1'b1;
        @(negedge aclk);          // skip one full cycle after reset release for CDC settle
        @(negedge aclk);

        pass_count = 0;
        fail_count = 0;

        fork
            // DRIVER — sets tvalid/tdata on negedge so they're stable at the next posedge.
            begin : driver
                for (drive_idx = 0; drive_idx < 2*n_vecs; drive_idx = drive_idx + 1) begin
                    s_axis_tdata  = rgb_vec[drive_idx];
                    s_axis_tvalid = 1'b1;
                    @(posedge aclk);          // HDL latches here
                    while (!s_axis_tready) begin
                        @(posedge aclk);
                    end
                    @(negedge aclk);          // back to negedge for next drive
                end
                s_axis_tvalid = 1'b0;
            end

            // CHECKER — samples m_axis on posedge (#1 to settle past NBA region).
            begin : checker
                check_idx = 0;
                while (check_idx < 2*n_vecs) begin
                    @(posedge aclk);
                    #1;
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (m_axis_tdata === ycc_vec[check_idx]) begin
                            pass_count = pass_count + 1;
                        end else begin
                            fail_count = fail_count + 1;
                            if (fail_count <= 6) begin
                                $display("[TB] FAIL #%0d: vec=%0d  rgb=%06h  got=%06h  exp=%06h",
                                         fail_count, check_idx,
                                         rgb_vec[check_idx], m_axis_tdata, ycc_vec[check_idx]);
                            end
                        end
                        check_idx = check_idx + 1;
                    end
                end
            end
        join

        $display("[TB] RESULT mode=%0d: %0d pass, %0d fail (of %0d)",
                 mode_runtime, pass_count, fail_count, 2*n_vecs);
        if (fail_count == 0)
            $display("[TB] PASS");
        else
            $display("[TB] FAIL_TOTAL");
        $finish;
    end

    initial begin
        #2000000;
        $display("[TB] WATCHDOG");
        $finish;
    end

endmodule

`default_nettype wire
