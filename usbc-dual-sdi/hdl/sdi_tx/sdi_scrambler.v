// sdi_scrambler.v — SMPTE SDI channel coding: scrambler G1(x) = x^9 + x^4 + 1, then NRZI G2(x) = x + 1.
//
// W bits per clock, bit 0 first on the wire (LSB-first, matching GTH TXDATA order). Self-synchronizing,
// so no alignment or reset handshake with the receiver. W = 20 for HD-SDI (1.485 Gb/s at 74.25 MHz);
// the same module is reused at W = 40/80 for 3G/6G/12G (docs/12).
//   scrambled:  s[n] = d[n] ^ s[n-4] ^ s[n-9]
//   NRZI:       q[n] = s[n] ^ q[n-1]

`default_nettype none
`timescale 1ns / 1ps

module sdi_scrambler #(
    parameter integer W = 20
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [W-1:0] din,
    output reg  [W-1:0] dout
);
    reg [8:0] sh;            // sh[k] = s[n-1-k]  (last 9 scrambled bits)
    reg       q;             // last NRZI output bit

    reg [8:0]   sh_nx;
    reg         q_nx, s;
    reg [W-1:0] out_nx;
    integer i;

    always @* begin
        sh_nx = sh;
        q_nx  = q;
        for (i = 0; i < W; i = i + 1) begin
            s         = din[i] ^ sh_nx[3] ^ sh_nx[8];
            sh_nx     = {sh_nx[7:0], s};
            q_nx      = q_nx ^ s;
            out_nx[i] = q_nx;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            sh   <= 9'd0;
            q    <= 1'b0;
            dout <= {W{1'b0}};
        end else begin
            sh   <= sh_nx;
            q    <= q_nx;
            dout <= out_nx;
        end
    end
endmodule

`default_nettype wire
