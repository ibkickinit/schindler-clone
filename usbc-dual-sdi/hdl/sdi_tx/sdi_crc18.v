// sdi_crc18.v — SMPTE 292 line CRC (CRC-18, C(x) = x^18 + x^5 + x^4 + 1), one 10-bit word per call.
//
// Combinational next-state: crc_out = CRC of (crc_in state) followed by the 10-bit word d, bits taken
// LSB first (= SDI serial transmission order). Initial state per line is 0.
//
// Register convention ("reflected"): bit 0 holds the coefficient of x^17 — the first CRC bit on the wire
// (C0). So the line's CRC words are CR0 = {~c[8], c[8:0]} and CR1 = {~c[17], c[17:9]}.
// Derivation: each message bit multiplies the remainder by x (bit i -> bit i-1, i.e. shift right); the
// x^18 term leaving bit 0 folds back as x^5 + x^4 + 1 -> bits 12, 13, 17.
//
// Cross-checked in sim against an independently written MSB-first polynomial division
// (sim/sdi_tx/tb_sdi_hd_tx.v). Still to confirm on a real analyzer (docs/12).

`default_nettype none
`timescale 1ns / 1ps

module sdi_crc18 (
    input  wire [17:0] crc_in,
    input  wire [9:0]  d,
    output reg  [17:0] crc_out
);
    integer i;
    reg [17:0] c;
    reg        fb;
    always @* begin
        c = crc_in;
        for (i = 0; i < 10; i = i + 1) begin
            fb = d[i] ^ c[0];
            c  = {fb, c[17:1]};
            c[12] = c[12] ^ fb;
            c[13] = c[13] ^ fb;
        end
        crc_out = c;
    end
endmodule

`default_nettype wire
