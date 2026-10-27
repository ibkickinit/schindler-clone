// tb_blinky_uart.v — Icarus check of the blinky top: decodes the UART banner and an echoed byte.
// Uses a fast simulated clock (CLKS_PER_BIT is derived from 300 MHz; the TB samples at the same rate).
`timescale 1ns / 1ps

module tb_blinky_uart;
    reg clk = 1'b0;
    always #1.6667 clk = ~clk;                       // 300 MHz

    reg        rst_n = 1'b1;
    reg  [3:0] dip = 4'b1010, pb = 4'b0000;
    reg        host_tx = 1'b1;                       // host -> FPGA
    wire [3:0] led;
    wire [2:0] rgb1, rgb2;
    wire       fpga_tx;

    auboard_blinky_top dut (.sys_clk_p(clk), .sys_clk_n(~clk), .rst_n(rst_n), .dip(dip), .pb(pb),
                            .led(led), .rgb1(rgb1), .rgb2(rgb2), .uart_tx(fpga_tx), .uart_rx(host_tx));


    localparam integer CPB = 300_000_000 / 115200;
    reg [8*64-1:0] line;
    integer nchars = 0, errors = 0;
    reg [7:0] ch;

    task uart_get(output [7:0] b);
        integer i;
        begin
            @(negedge fpga_tx);
            repeat (CPB + CPB/2) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = fpga_tx;
                repeat (CPB) @(posedge clk);
            end
        end
    endtask

    task uart_put(input [7:0] b);
        integer i;
        begin
            host_tx = 1'b0; repeat (CPB) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin host_tx = b[i]; repeat (CPB) @(posedge clk); end
            host_tx = 1'b1; repeat (CPB) @(posedge clk);
        end
    endtask

    initial begin
        // force the 1 s tick early so the sim doesn't need 300 M cycles
        repeat (300) @(posedge clk);
        force dut.sec_cnt = 300_000_000 - 2;
        @(posedge clk); release dut.sec_cnt;
        // read the banner
        line = 0;
        repeat (23) begin
            uart_get(ch);
            line = {line[8*63-1:0], ch};
            nchars = nchars + 1;
        end
        $display("banner bytes: \"%0s\"", line);
        if (line[8*23-1:8*4] !== "AUBoard 15P alive #") begin errors = errors + 1; $display("ERROR banner"); end
        // echo test
        fork
            uart_put("Z");
            begin uart_get(ch); end
        join
        if (ch !== "Z") begin errors = errors + 1; $display("ERROR echo got %h", ch); end
        // DIP mirror on button press
        pb = 4'b0001; repeat (10) @(posedge clk);
        if (led !== dip) begin errors = errors + 1; $display("ERROR led/dip"); end
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
