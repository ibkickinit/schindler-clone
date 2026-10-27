// auboard_blinky_top.v — Avnet/Tria AUBoard 15P first-light design (Crossover bench, docs/11 step 3).
//
// Proves: toolchain, JTAG programming, the 300 MHz system clock, user LEDs/DIP/buttons, and the
// USB-UART (J9). Behaviour:
//   * LED1..4 count in binary (~1.1 Hz on LED1). Hold any push button -> LEDs show the DIP switches.
//   * RGB LED 1 cycles R/G/B (~1 s each); RGB LED 2 lights green while the PL reset button is released.
//   * UART 115200 8N1: prints "AUBoard 15P alive #<n>" once a second and echoes any typed character.
// Pins and bank voltages come from the Tria AUB-15P-DK-UG v1.0 (constraints/auboard_blinky.xdc).

`default_nettype none
`timescale 1ns / 1ps

module auboard_blinky_top (
    input  wire       sys_clk_p,        // 300 MHz LVDS oscillator X1 (AD21/AE21)
    input  wire       sys_clk_n,
    input  wire       rst_n,            // PL reset push button, active low (V19)
    input  wire [3:0] dip,              // SW2
    input  wire [3:0] pb,               // PB4..PB7
    output wire [3:0] led,              // D31..D34, active high
    output wire [2:0] rgb1,             // D35 {b, g, r}
    output wire [2:0] rgb2,             // second RGB LED {b, g, r}
    output wire       uart_tx,          // FPGA -> host (AF15)
    input  wire       uart_rx           // host -> FPGA (AF14)
);
    localparam integer CLK_HZ = 300_000_000;
    localparam integer CPB    = CLK_HZ / 115200;

    // ---- clock ----
    wire clk_ibuf, clk;
`ifdef SIM
    assign clk = sys_clk_p;
`else
    IBUFDS u_ibufds (.I(sys_clk_p), .IB(sys_clk_n), .O(clk_ibuf));
    BUFG   u_bufg   (.I(clk_ibuf), .O(clk));
`endif

    // ---- reset: sync the button, plus a short power-on reset ----
    reg [1:0]  rst_sync = 2'b00;
    reg [7:0]  por      = 8'd0;
    always @(posedge clk) begin
        rst_sync <= {rst_sync[0], rst_n};
        if (!por[7]) por <= por + 8'd1;
    end
    wire rst = !por[7] || !rst_sync[1];

    // ---- input sync ----
    reg [3:0] dip_q1, dip_q2, pb_q1, pb_q2;
    always @(posedge clk) begin
        dip_q1 <= dip; dip_q2 <= dip_q1;
        pb_q1  <= pb;  pb_q2  <= pb_q1;
    end

    // ---- counters ----
    reg [31:0] cnt;
    reg [28:0] sec_cnt;
    reg        tick_1s;
    reg [1:0]  rgb_phase;
    always @(posedge clk) begin
        tick_1s <= 1'b0;
        if (rst) begin
            cnt <= 32'd0; sec_cnt <= 29'd0; rgb_phase <= 2'd0;
        end else begin
            cnt <= cnt + 32'd1;
            if (sec_cnt == CLK_HZ - 1) begin
                sec_cnt   <= 29'd0;
                tick_1s   <= 1'b1;
                rgb_phase <= (rgb_phase == 2'd2) ? 2'd0 : rgb_phase + 2'd1;
            end else begin
                sec_cnt <= sec_cnt + 29'd1;
            end
        end
    end

    assign led  = (|pb_q2) ? dip_q2 : cnt[31:28];
    assign rgb1 = (rgb_phase == 2'd0) ? 3'b001 : (rgb_phase == 2'd1) ? 3'b010 : 3'b100;
    assign rgb2 = rst_sync[1] ? 3'b010 : 3'b000;

    // ---- UART: banner once a second, echo received bytes ----
    wire       rx_valid;
    wire [7:0] rx_data;
    uart_rx #(.CLKS_PER_BIT(CPB)) u_rx (.clk(clk), .rst(rst), .rx(uart_rx), .valid(rx_valid), .data(rx_data));

    localparam integer MSG_LEN = 24;                // "AUBoard 15P alive #N\r\n" with 2-digit hex N
    reg [7:0]  msg [0:MSG_LEN-1];
    reg [7:0]  n_banner;
    reg [4:0]  msg_idx;
    reg        sending;
    reg        echo_pend;
    reg [7:0]  echo_byte;
    reg        tx_valid;
    reg [7:0]  tx_data;
    wire       tx_busy;

    function [7:0] hexc;
        input [3:0] v;
        hexc = (v < 4'd10) ? (8'h30 + v) : (8'h37 + v);
    endfunction

    always @* begin
        msg[0]="A"; msg[1]="U"; msg[2]="B"; msg[3]="o"; msg[4]="a"; msg[5]="r"; msg[6]="d"; msg[7]=" ";
        msg[8]="1"; msg[9]="5"; msg[10]="P"; msg[11]=" "; msg[12]="a"; msg[13]="l"; msg[14]="i";
        msg[15]="v"; msg[16]="e"; msg[17]=" "; msg[18]="#";
        msg[19]=hexc(n_banner[7:4]); msg[20]=hexc(n_banner[3:0]);
        msg[21]=8'h0D; msg[22]=8'h0A; msg[23]=8'h00;
    end

    always @(posedge clk) begin
        tx_valid <= 1'b0;
        if (rst) begin
            n_banner <= 8'd0; msg_idx <= 5'd0; sending <= 1'b0; echo_pend <= 1'b0;
        end else begin
            if (rx_valid) begin echo_pend <= 1'b1; echo_byte <= rx_data; end
            if (tick_1s && !sending) begin sending <= 1'b1; msg_idx <= 5'd0; end

            if (!tx_busy && !tx_valid) begin
                if (echo_pend && !sending) begin
                    tx_data <= echo_byte; tx_valid <= 1'b1; echo_pend <= 1'b0;
                end else if (sending) begin
                    if (msg_idx == MSG_LEN - 1) begin
                        sending  <= 1'b0;
                        n_banner <= n_banner + 8'd1;
                    end else begin
                        tx_data  <= msg[msg_idx];
                        tx_valid <= 1'b1;
                        msg_idx  <= msg_idx + 5'd1;
                    end
                end
            end
        end
    end

    uart_tx #(.CLKS_PER_BIT(CPB)) u_tx (.clk(clk), .rst(rst), .valid(tx_valid), .data(tx_data),
                                       .busy(tx_busy), .tx(uart_tx));
endmodule

`default_nettype wire
