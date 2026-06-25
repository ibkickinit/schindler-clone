// pg_tile_pack64.v — 24-bit tile-pixel AXIS -> 64-bit AXIS gearbox for the Path B dedicated S2MM DataMover.
//
// pg_raster_to_tile emits a CONTIGUOUS tile-row-major byte stream as 24-bit/beat (1 pixel/clk, little-endian
// per pixel: tdata[7:0]=byte0, [15:8]=byte1, [23:16]=byte2). The dedicated axi_datamover S2MM writes the DDR
// in 64-bit words (= the HP mem-side width), so the stream feeding S_AXIS_S2MM must be 64-bit. This module
// packs the 24-bit pixel stream into 64-bit beats, LITTLE-ENDIAN at the byte level, IDENTICAL to the DDR
// image the roundtrip TB models ("every producer beat -> 3 contiguous LE bytes"):
//   byte k of the contiguous stream lands at DDR offset k; 8 bytes per 64-bit beat; beat[8*j +: 8] = byte j.
//
// One tile = 768 bytes = 96 whole 64-bit beats, and the whole tiled frame is a whole number of 64-bit beats
// (768 % 8 == 0), so the packer NEVER emits a partial final beat across a frame boundary.
//
// DESIGN (robust under back-pressure on BOTH sides — no pixel can be lost when m_tready drops):
//   * A bit-accumulator `acc` (little-endian) holds 0..87 valid bits (`nbits`).
//   * INPUT is accepted whenever there is room: nbits < 64  (after accept, nbits < 88, always fits acc).
//     s_tready depends ONLY on the local fill level, never on the output handshake -> a downstream stall
//     can't deassert s_tready mid-pixel and lose the offered pixel.
//   * OUTPUT: a held output register (m_tvalid/m_tdata). A beat is loaded from acc[63:0] whenever the output
//     reg is free (or being consumed) AND nbits >= 64; on load, acc >>= 64 and nbits -= 64.
//   Accept and drain are independent events that may both fire in one cycle.

`default_nettype none
`timescale 1ns / 1ps

module pg_tile_pack64 (
    input  wire        clk, rstn,
    // slave AXIS — 24-bit tile-pixel stream from pg_raster_to_tile (m_tdata/m_tvalid/m_tready)
    input  wire [23:0] s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    // master AXIS — 64-bit packed stream to the dedicated DataMover S_AXIS_S2MM
    output reg  [63:0] m_tdata,
    output reg         m_tvalid,
    input  wire        m_tready
);
    reg  [87:0] acc;            // little-endian byte buffer (acc[8*j +: 8] = next byte j out)
    reg  [7:0]  nbits;          // valid bits currently buffered (0..87)

    // accept input whenever there is room for a full pixel below the 64-bit drain threshold.
    assign s_tready = (nbits < 8'd64);
    wire   in_go    = s_tvalid && s_tready;

    // output register is free to load when it is empty OR being consumed this cycle
    wire   out_free   = !m_tvalid || m_tready;

    // combinational "post-accept" view of the accumulator (so accept+drain can happen the same cycle)
    wire [7:0]  nb_in  = in_go ? (nbits + 8'd24) : nbits;
    wire [87:0] acc_in = in_go ? (acc | ({64'd0, s_tdata} << nbits)) : acc;
    wire        drain  = out_free && (nb_in >= 8'd64);

    always @(posedge clk) begin
        if(!rstn) begin
            acc <= 88'd0; nbits <= 8'd0; m_tvalid <= 1'b0; m_tdata <= 64'd0;
        end else begin
            // retire a consumed beat (may be re-loaded below in the same cycle)
            if(m_tvalid && m_tready) m_tvalid <= 1'b0;

            if(drain) begin
                m_tdata  <= acc_in[63:0];
                m_tvalid <= 1'b1;
                acc      <= acc_in >> 64;
                nbits    <= nb_in - 8'd64;
            end else begin
                acc   <= acc_in;
                nbits <= nb_in;
            end
        end
    end
endmodule

`default_nettype wire
