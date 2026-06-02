// pg_unpack.v — 64-bit DataMover beat → 24-bit pixel gearbox (read-engine-B integration).
//
// The AXI DataMover (MM2S) returns the master frame as 64-bit AXI-stream beats
// (8 bytes/beat, little-endian: tdata[7:0] = lowest byte address). Pixels are
// stored 3 bytes each. Per the Schindler pipeline's empirically-confirmed byte
// order (memory: schindler-pipeline-rbg-byte-order), S2MM writes each AXIS pixel
// {tdata[23:16]=R, [15:8]=B, [7:0]=G} little-endian, so the 3 DDR bytes at
// ascending addresses are [G, B, R]. Re-reading them little-endian into bits
// [7:0]=G, [15:8]=B, [23:16]=R reproduces EXACTLY the {R,B,G} AXIS layout — so a
// reconstructed pixel is simply the low 24 bits of the byte stream. No swizzle.
//
// This is a width gearbox: append 64 bits per accepted beat into a shift
// accumulator, pop 24 bits per emitted pixel. Asserts p_last on the line_px-th
// pixel of each line (matches pg_linefetch's fetch_last expectation).

`default_nettype none
`timescale 1ns / 1ps

module pg_unpack (
    input  wire        clk,
    input  wire        rstn,

    input  wire [11:0] line_px,        // pixels per line (= LINE_W); latched per line

    // 64-bit AXIS in (from AXI DataMover MM2S data stream)
    input  wire [63:0] s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,

    // 24-bit pixel out (to pg_linefetch fetch_* port)
    output reg         p_valid,
    output reg  [23:0] p_data,
    output reg         p_last
);
    // shift accumulator: low bits are the oldest bytes (next pixel)
    reg  [95:0] acc;
    reg  [7:0]  nbits;            // valid bits currently in acc (0..96)
    reg  [11:0] pcount;           // pixels emitted in the current line

    // accept a beat when there is room for 64 more bits
    assign s_tready = (nbits <= 8'd32);
    wire acc_beat   = s_tvalid && s_tready;
    wire emit       = (nbits >= 8'd24);

    // next-state for the accumulator (emit pops 24 from the low end; beat
    // appends 64 at the current top, accounting for a simultaneous emit)
    wire [7:0]  nbits_after_emit = emit ? (nbits - 8'd24) : nbits;
    wire [95:0] acc_after_emit   = emit ? (acc >> 24)     : acc;

    always @(posedge clk) begin
        if (!rstn) begin
            acc <= 96'd0; nbits <= 8'd0; pcount <= 12'd0;
            p_valid <= 1'b0; p_data <= 24'd0; p_last <= 1'b0;
        end else begin
            // emit a pixel
            p_valid <= emit;
            p_data  <= acc[23:0];
            if (emit) begin
                if (pcount == line_px - 12'd1) begin p_last <= 1'b1; pcount <= 12'd0; end
                else                           begin p_last <= 1'b0; pcount <= pcount + 12'd1; end
            end else p_last <= 1'b0;

            // update accumulator: pop 24 (if emit), then append 64 (if beat)
            if (acc_beat) begin
                acc   <= acc_after_emit | ({32'd0, s_tdata} << nbits_after_emit);
                nbits <= nbits_after_emit + 8'd64;
            end else begin
                acc   <= acc_after_emit;
                nbits <= nbits_after_emit;
            end
        end
    end
endmodule

`default_nettype wire
