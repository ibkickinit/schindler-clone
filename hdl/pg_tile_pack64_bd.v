// pg_tile_pack64_bd.v — BD wrapper for pg_tile_pack64 (Path B dedicated-DMA 24b->64b packer).
//
// The core (pg_tile_pack64.v, sim pg_tile_pack64_tb) uses raw port names (s_tdata/s_tvalid/..., m_tdata/...).
// Vivado's BD AXIS interface inference + connect_bd_intf_net need conventional names (s_axis_*, m_axis_*).
// This wrapper renames the ports (no logic change) so it drops into the BD between raster_to_tile_0/m_axis
// and the dedicated write DataMover's data clock-converter.

`default_nettype none
`timescale 1ns / 1ps

module pg_tile_pack64_bd (
    input  wire        aclk,
    input  wire        aresetn,
    // slave AXIS — 24-bit tile-pixel stream from raster_to_tile_0/m_axis
    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    // master AXIS — 64-bit packed stream to the dedicated DataMover (via clock converter)
    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready
);
    pg_tile_pack64 u_core (
        .clk(aclk), .rstn(aresetn),
        .s_tdata(s_axis_tdata), .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
        .m_tdata(m_axis_tdata), .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready)
    );
endmodule

`default_nettype wire
