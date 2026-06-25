// pg_tile_s2mm_cmd_bd.v — BD wrapper for pg_tile_s2mm_cmd (Path B dedicated-DMA command gen + genlock).
//
// The core (pg_tile_s2mm_cmd.v, sim pg_tile_s2mm_cmd_tb) uses raw port names. Vivado's BD AXIS interface
// inference needs conventional master/slave AXIS names so the command stream binds to the DataMover's
// S_AXIS_S2MM_CMD (via a clock converter) and the status stream binds from M_AXIS_S2MM_STS.
//
//   m_axis_cmd_*  : 72-bit DataMover S2MM command stream (master).  -> wr_cc_cmd/S_AXIS -> S_AXIS_S2MM_CMD
//   s_axis_sts_*  : 8-bit DataMover S2MM status stream  (slave).    <- wr_cc_sts/M_AXIS <- M_AXIS_S2MM_STS
//   frame_ptr_out : 6-bit GRAY-coded write-slot pointer -> pg_re_0/frame_ptr (mirrors VDMA s2mm_frame_ptr_out)
//   dbg           : 32-bit bring-up telemetry (route to a GPIO readback if desired)
//
// tkeep/tlast on the status stream are accepted but ignored (the core only needs "a status arrived").

`default_nettype none
`timescale 1ns / 1ps

module pg_tile_s2mm_cmd_bd #(
    parameter [31:0]  FRAME_BUF_BASE = 32'h1000_0000,
    parameter integer NUM_FRAMES     = 7,
    parameter integer SLOT_STRIDE    = 6226560,
    parameter integer FRAME_BYTES    = 6174720
) (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        m_sof,                  // raster_to_tile_0/m_sof (pclk_in domain)

    // master AXIS: DataMover S2MM command (72-bit)
    output wire [71:0] m_axis_cmd_tdata,
    output wire        m_axis_cmd_tvalid,
    input  wire        m_axis_cmd_tready,

    // slave AXIS: DataMover S2MM status (8-bit + sidebands, ignored)
    input  wire [7:0]  s_axis_sts_tdata,
    input  wire        s_axis_sts_tvalid,
    output wire        s_axis_sts_tready,
    input  wire        s_axis_sts_tkeep,
    input  wire        s_axis_sts_tlast,

    output wire [5:0]  frame_ptr_out,
    output wire [31:0] dbg
);
    pg_tile_s2mm_cmd #(
        .FRAME_BUF_BASE(FRAME_BUF_BASE), .NUM_FRAMES(NUM_FRAMES),
        .SLOT_STRIDE(SLOT_STRIDE), .FRAME_BYTES(FRAME_BYTES)
    ) u_core (
        .clk(aclk), .rstn(aresetn), .m_sof(m_sof),
        .cmd_tdata(m_axis_cmd_tdata), .cmd_tvalid(m_axis_cmd_tvalid), .cmd_tready(m_axis_cmd_tready),
        .sts_tdata(s_axis_sts_tdata), .sts_tvalid(s_axis_sts_tvalid), .sts_tready(s_axis_sts_tready),
        .frame_ptr_out(frame_ptr_out), .dbg(dbg)
    );
endmodule

`default_nettype wire
