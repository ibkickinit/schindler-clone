// ycbcr_422_tb.v — verifies hdl/ycbcr_444_to_422.v vs Python golden.
//
// Reads vectors/mode_<m>.txt. For each PAIR of input YCbCr 4:4:4 pixels,
// expects 2 output 16-bit 4:2:2 beats matching the Python ref.
//
// +mode=<0..3>  +vecfile=<path>

`timescale 1ns / 1ps
`default_nettype none

module ycbcr_422_tb;
    reg [255:0] vecfile_path;
    reg [1:0]   mode_runtime = 2'd0;
    reg         have_mode, have_vecfile;

    reg aclk = 1'b0;
    reg aresetn = 1'b0;

    reg  [23:0] s_axis_tdata = 24'b0;
    reg         s_axis_tvalid = 1'b0;
    wire        s_axis_tready;
    reg         s_axis_tlast = 1'b0;
    reg         s_axis_tuser = 1'b0;

    wire [15:0] m_axis_tdata;
    wire        m_axis_tvalid;
    reg         m_axis_tready = 1'b1;
    wire        m_axis_tlast;
    wire        m_axis_tuser;

    ycbcr_444_to_422 uut (
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
        .m_axis_tuser  (m_axis_tuser)
    );

    always #5 aclk = ~aclk;

    reg [23:0] ycc_in [0:1023];     // input 4:4:4 pixels
    reg [15:0] out_expected [0:1023]; // expected 4:2:2 beats
    integer    n_pairs = 0;

    reg [23:0] rgb0, rgb1, ycc0, ycc1;
    reg [15:0] out0, out1;
    integer fd, n;

    integer drive_idx, check_idx;
    integer pass_count, fail_count;

    initial begin
        have_mode    = $value$plusargs("mode=%d", mode_runtime);
        have_vecfile = $value$plusargs("vecfile=%s", vecfile_path);
        if (!have_mode || !have_vecfile) begin
            $display("[TB422] FATAL: need plusargs");
            $finish;
        end

        fd = $fopen(vecfile_path, "r");
        if (fd == 0) begin $display("[TB422] cannot open"); $finish; end
        n_pairs = 0;
        while (!$feof(fd)) begin
            n = $fscanf(fd, "%h %h %h %h %h %h\n", rgb0, rgb1, ycc0, ycc1, out0, out1);
            if (n == 6) begin
                ycc_in[2*n_pairs]     = ycc0;
                ycc_in[2*n_pairs+1]   = ycc1;
                out_expected[2*n_pairs]   = out0;
                out_expected[2*n_pairs+1] = out1;
                n_pairs = n_pairs + 1;
            end else begin
                begin : skip
                    reg [255:0] dummy;
                    n = $fgets(dummy, fd);
                end
            end
        end
        $fclose(fd);
        $display("[TB422] Loaded %0d pixel pairs (mode=%0d)", n_pairs, mode_runtime);

        aresetn = 1'b0;
        repeat (4) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;
        @(negedge aclk);
        @(negedge aclk);

        pass_count = 0;
        fail_count = 0;

        fork
            // Driver: SOF on first pixel, drive 4:4:4 pixels back-to-back
            begin : driver
                for (drive_idx = 0; drive_idx < 2*n_pairs; drive_idx = drive_idx + 1) begin
                    s_axis_tdata  = ycc_in[drive_idx];
                    s_axis_tvalid = 1'b1;
                    s_axis_tuser  = (drive_idx == 0) ? 1'b1 : 1'b0;  // SOF only on first
                    s_axis_tlast  = 1'b0;
                    @(posedge aclk);
                    while (!s_axis_tready) @(posedge aclk);
                    @(negedge aclk);
                end
                s_axis_tvalid = 1'b0;
                s_axis_tuser  = 1'b0;
            end

            // Checker
            begin : checker
                check_idx = 0;
                while (check_idx < 2*n_pairs) begin
                    @(posedge aclk);
                    #1;
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (m_axis_tdata === out_expected[check_idx]) begin
                            pass_count = pass_count + 1;
                        end else begin
                            fail_count = fail_count + 1;
                            if (fail_count <= 6) begin
                                $display("[TB422] FAIL #%0d: vec=%0d  ycc_in=%06h%06h  got=%04h  exp=%04h",
                                         fail_count, check_idx,
                                         ycc_in[check_idx & ~1], ycc_in[check_idx | 1],
                                         m_axis_tdata, out_expected[check_idx]);
                            end
                        end
                        check_idx = check_idx + 1;
                    end
                end
            end
        join

        $display("[TB422] RESULT mode=%0d: %0d pass, %0d fail (of %0d)",
                 mode_runtime, pass_count, fail_count, 2*n_pairs);
        if (fail_count == 0) $display("[TB422] PASS");
        else                 $display("[TB422] FAIL_TOTAL");
        $finish;
    end

    initial begin #5000000; $display("[TB422] WATCHDOG"); $finish; end
endmodule

`default_nettype wire
