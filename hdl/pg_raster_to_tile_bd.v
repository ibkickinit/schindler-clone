// pg_raster_to_tile_bd.v — BD wrapper for pg_raster_to_tile (Path B, tiled S2MM write leg).
//
// pg_raster_to_tile.v (the bit-exact-validated core; sim pg_raster_to_tile_tb) uses raw port names
// (s_tdata/s_tvalid/... , m_tdata/m_tvalid/...). Vivado's BD interface inference + connect_bd_intf_net need
// AXI4-Stream-conventional names (s_axis_tdata, m_axis_tdata, ...). This wrapper renames the ports (no logic
// change) so it drops straight into the BD between scaler_0/m_axis and axi_vdma_0/S_AXIS_S2MM via
// connect_bd_intf_net, leaving the proven core + its testbench untouched.
//
// The wrapper passes the source SOF (s_axis_tuser) into the core's s_tuser (the core resets to row0/col0 on
// SOF and counts row width internally). The core emits a contiguous TILE-ROW-MAJOR stream with m_tlast on
// the LAST beat of each 16x16 tile (every 768 bytes). The S2MM is programmed (firmware) with HSIZE=Stride=768
// and VSIZE=TILES_X*TILES_Y so each per-tile tlast == one S2MM "line", storing the frame contiguously at
// frame_base + (ty*TILES_X+tx)*768 — exactly where pg_tile_dma's TILED branch reads it.
//
// The output carries NO tuser to S2MM. SOF framing comes from the hardware s2mm_fsync. CRITICAL (Path B fsync
// fix, 2026-06-25): s2mm_fsync MUST be driven by m_sof (this wrapper's frame-sync output), NOT the raw source
// vsync. The tiler buffers a 16-row band before emitting, so its output frame boundary LAGS source vsync by
// up to one band; driving s2mm_fsync from source vsync fired mid-stream (tiler still emitting the previous
// frame's last band) -> EOLEarly + a misaligned/garbage tiled master. m_sof pulses for exactly one aclk
// cycle on the FIRST emitted beat of tile(0,0) of each frame, so the VDMA frame boundary coincides with the
// tiler starting a new tiled frame. Wire raster_to_tile_0/m_sof -> axi_vdma_0/s2mm_fsync (see build_phase_b.tcl
// RASTER_TO_TILE block). m_axis_tlast is the per-tile (per-S2MM-line) EOL the VDMA needs to advance lines.

`default_nettype none
`timescale 1ns / 1ps

module pg_raster_to_tile_bd #(
    parameter integer IN_W  = 1920,                   // MAX width (BRAM band sizing); active width = in_w port
    parameter integer LTILE = 4                       // TILE = 16
) (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [11:0] in_w,                          // RUNTIME active width (firmware GPIO; multiple of TILE, <= IN_W)

    // slave AXIS (from scaler_0/m_axis — the source raster, now the output-res LOD)
    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tuser,                  // SOF
    input  wire        s_axis_tlast,                  // EOL (core counts width; tlast unused)

    // master AXIS (to axi_vdma_0/S_AXIS_S2MM — contiguous tile-row-major tile stream)
    output wire [23:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,                  // last beat of each 16x16 tile (= one S2MM line)

    // output frame-sync — drive axi_vdma_0/s2mm_fsync from THIS, not raw source vsync (see header)
    output wire        m_sof                          // 1-cyc pulse on first beat of tile(0,0) of each frame
);
    pg_raster_to_tile #(.IN_W(IN_W), .LTILE(LTILE)) u_core (
        .clk     (aclk),
        .rstn    (aresetn),
        .in_w    (in_w),
        .s_tdata (s_axis_tdata),
        .s_tvalid(s_axis_tvalid),
        .s_tready(s_axis_tready),
        .s_tuser (s_axis_tuser),
        .s_tlast (s_axis_tlast),
        .m_tdata (m_axis_tdata),
        .m_tvalid(m_axis_tvalid),
        .m_tready(m_axis_tready),
        .m_tlast (m_axis_tlast),
        .m_sof   (m_sof)
    );
endmodule

`default_nettype wire
