// pg_linefetch_tb.v — self-checking TB for the line fetch + double buffer.
//
// Behavioral DDR holds a known pattern pix(row,col); a behavioral DataMover
// streams a requested line back. The TB follows the compositor's 1-ahead
// contract (prefetch rows 0,1; then read row n while prefetching n+2) and
// checks every served pixel + the residency flag.
//
// Pass criterion: "Total errors = 0".  Run: make sim-pg.

`default_nettype none
`timescale 1ns / 1ps

module pg_linefetch_tb;
    localparam integer LINE_W = 1280;
    localparam integer STRIDE = 3840;
    localparam [31:0]  FRAME_BASE = 32'h1000_0000;

    reg clk = 1'b0; always #5 clk = ~clk;
    reg rstn;

    reg         pf_req;
    reg  [11:0] pf_row, rd_row, rd_col;
    wire [23:0] rd_data;
    wire        rd_resident, busy;

    wire        fetch_req;
    wire [31:0] fetch_addr;
    wire [11:0] fetch_len;
    reg         fetch_pvalid, fetch_last;
    reg  [23:0] fetch_pdata;

    pg_linefetch #(.LINE_W(LINE_W), .STRIDE(STRIDE)) dut (
        .clk(clk), .rstn(rstn), .frame_base_addr(FRAME_BASE),
        .pf_req(pf_req), .pf_row(pf_row),
        .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data), .rd_resident(rd_resident),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr), .fetch_len(fetch_len),
        .fetch_pvalid(fetch_pvalid), .fetch_pdata(fetch_pdata), .fetch_last(fetch_last),
        .busy(busy)
    );

    // golden pixel pattern
    function [23:0] pix; input integer r, c; pix = (r*7919 + c*31 + 12345) & 24'hFFFFFF; endfunction

    integer errors;

    // ---- behavioral DataMover: on fetch_req, stream fetch_len pixels ----
    integer dm_row, dm_i, dm_len; reg dm_busy, dm_gap;
    always @(posedge clk) begin
        if (!rstn) begin dm_busy <= 0; dm_gap <= 0; fetch_pvalid <= 0; fetch_last <= 0; end
        else begin
            fetch_pvalid <= 0; fetch_last <= 0;
            if (fetch_req && !dm_busy) begin
                dm_row = (fetch_addr - FRAME_BASE) / STRIDE;
                dm_len = fetch_len; dm_i = 0; dm_busy <= 1; dm_gap <= 0;
            end else if (dm_busy) begin
                if (dm_gap) begin
                    dm_gap <= 0;            // one-cycle bubble, then resume
                end else begin
                    fetch_pvalid <= 1; fetch_pdata <= pix(dm_row, dm_i);
                    fetch_last <= (dm_i == dm_len-1);
                    // schedule a 1-cycle gap after every 300th pixel (mimic AXI bursts)
                    if ((dm_i % 300) == 299 && dm_i != dm_len-1) dm_gap <= 1;
                    dm_i = dm_i + 1;
                    if (dm_i == dm_len) dm_busy <= 0;
                end
            end
        end
    end

    task fetch_and_wait; input [11:0] r;
        begin
            @(posedge clk); pf_req <= 1; pf_row <= r;
            @(posedge clk); pf_req <= 0;
            wait (busy);        // fetch started
            wait (!busy);       // fetch done
            @(posedge clk);
        end
    endtask

    task read_check; input [11:0] r;
        integer c; reg [11:0] pcol; reg first;
        begin
            rd_row = r; first = 1; #1;   // blocking + settle so combinational rd_resident is valid
            if (!rd_resident) begin
                $display("  ERR row %0d not resident at read start", r); errors = errors + 1;
            end
            for (c = 0; c < LINE_W; c = c + 1) begin
                rd_col <= c[11:0];
                @(posedge clk);
                if (!first) begin
                    if (rd_data !== pix(r, pcol)) begin
                        if (errors < 20) $display("  ERR row %0d col %0d: dut=%h gold=%h",
                                                  r, pcol, rd_data, pix(r, pcol));
                        errors = errors + 1;
                    end
                end
                pcol = c[11:0]; first = 0;
            end
            @(posedge clk);   // drain last
            if (rd_data !== pix(r, pcol)) begin
                if (errors < 20) $display("  ERR row %0d col %0d (last): dut=%h gold=%h",
                                          r, pcol, rd_data, pix(r, pcol));
                errors = errors + 1;
            end
        end
    endtask

    integer n;
    initial begin
        errors = 0;
        rstn = 0; pf_req = 0; pf_row = 0; rd_row = 12'hFFF; rd_col = 0;
        repeat (5) @(posedge clk); rstn = 1; repeat (3) @(posedge clk);

        // non-resident sanity
        rd_row <= 12'd99; @(posedge clk);
        if (rd_resident) begin $display("  ERR phantom resident"); errors = errors + 1; end

        // prime two rows (vblank), then steady-state 1-ahead
        fetch_and_wait(0);
        fetch_and_wait(1);
        for (n = 0; n < 8; n = n + 1) begin
            read_check(n[11:0]);          // row n resident from the prior prefetch
            fetch_and_wait((n+2));        // prefetch n+2 into the freed (ping-pong) buffer
        end

        $display("=================================");
        $display("Total errors = %0d", errors);
        $display("=================================");
        $finish;
    end

    initial begin
        #20_000_000; $display("TIMEOUT — Total errors = %0d", errors); $finish;
    end
endmodule

`default_nettype wire
