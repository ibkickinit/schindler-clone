// uart_tx.v — minimal 8N1 UART transmitter. CLKS_PER_BIT = clk_hz / baud.

`default_nettype none
`timescale 1ns / 1ps

module uart_tx #(
    parameter integer CLKS_PER_BIT = 2604          // 300 MHz / 115200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,                       // pulse with data when !busy
    input  wire [7:0] data,
    output reg        busy,
    output reg        tx
);
    reg [15:0] cnt;
    reg [3:0]  bitn;                               // 0 start, 1..8 data, 9 stop
    reg [9:0]  shreg;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            tx   <= 1'b1;
            cnt  <= 16'd0;
            bitn <= 4'd0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (valid) begin
                shreg <= {1'b1, data, 1'b0};       // stop, data (LSB first), start
                busy  <= 1'b1;
                cnt   <= 16'd0;
                bitn  <= 4'd0;
            end
        end else begin
            tx <= shreg[bitn];
            if (cnt == CLKS_PER_BIT - 1) begin
                cnt <= 16'd0;
                if (bitn == 4'd9) busy <= 1'b0;
                else              bitn <= bitn + 4'd1;
            end else begin
                cnt <= cnt + 16'd1;
            end
        end
    end
endmodule

`default_nettype wire
