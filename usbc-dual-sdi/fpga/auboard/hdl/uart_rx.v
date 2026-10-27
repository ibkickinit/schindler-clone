// uart_rx.v — minimal 8N1 UART receiver (mid-bit sampling, 2-FF input sync).

`default_nettype none
`timescale 1ns / 1ps

module uart_rx #(
    parameter integer CLKS_PER_BIT = 2604
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg        valid,                       // 1-clock pulse per received byte
    output reg  [7:0] data
);
    reg        rx_q1, rx_q2;
    reg        active;
    reg [15:0] cnt;
    reg [3:0]  bitn;

    always @(posedge clk) begin
        rx_q1 <= rx;
        rx_q2 <= rx_q1;
        valid <= 1'b0;
        if (rst) begin
            active <= 1'b0;
            rx_q1  <= 1'b1;
            rx_q2  <= 1'b1;
        end else if (!active) begin
            if (!rx_q2) begin                      // start-bit edge
                active <= 1'b1;
                cnt    <= CLKS_PER_BIT / 2;        // aim for mid-bit
                bitn   <= 4'd0;
            end
        end else if (cnt == CLKS_PER_BIT - 1) begin
            cnt <= 16'd0;
            if (bitn == 4'd0) begin
                if (rx_q2) active <= 1'b0;         // false start
                else       bitn   <= 4'd1;
            end else if (bitn <= 4'd8) begin
                data <= {rx_q2, data[7:1]};
                bitn <= bitn + 4'd1;
            end else begin                         // stop bit
                active <= 1'b0;
                valid  <= rx_q2;                   // drop framing errors
            end
        end else begin
            cnt <= cnt + 16'd1;
        end
    end
endmodule

`default_nettype wire
