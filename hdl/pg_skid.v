// pg_skid.v — AXIS-style skid buffer (register slice). s_ready depends only on internal state
// (a register), NOT combinationally on m_ready — this BREAKS the affine<->cache handshake loop
// (affine advance was gated by the live tag lookup). Full throughput (1/clk when flowing).
`default_nettype none
`timescale 1ns / 1ps

module pg_skid #(parameter integer W=32) (
    input  wire         clk, rstn,
    input  wire         s_valid,
    input  wire [W-1:0] s_data,
    output wire         s_ready,
    output reg          m_valid,
    output reg  [W-1:0] m_data,
    input  wire         m_ready
);
    reg [W-1:0] sk_data; reg sk_valid;
    assign s_ready = !sk_valid;                 // can accept unless the skid slot is occupied
    always @(posedge clk) begin
        if(!rstn) begin m_valid<=1'b0; sk_valid<=1'b0; end
        else begin
            if(!m_valid || m_ready) begin       // output reg free -> take skid, else input
                if(sk_valid) begin m_data<=sk_data; m_valid<=1'b1; sk_valid<=1'b0; end
                else begin m_data<=s_data; m_valid<=s_valid; end
            end else if(s_valid && s_ready) begin  // output stalled -> absorb one into the skid
                sk_data<=s_data; sk_valid<=1'b1;
            end
        end
    end
endmodule

`default_nettype wire
