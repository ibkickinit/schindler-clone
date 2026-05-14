// scaler_top.v — top-level polyphase scaler. Wraps H + V cores into a
// single AXIS-in / AXIS-out block. Replaces scaler_passthrough in the BD.
//
// Build-time configurable: IN_W × IN_H input → OUT_W × OUT_H output, RGB
// 24-bit. C.1 first-light ran at 1920×1080 → 1280×720 (3:2 H, 3:2 V);
// C.2 makes that a generic. Internal AXIS between H and V is OUT_W × IN_H.
//
// Both stages run on the same input clock (PixelClk_in). VDMA's S2MM
// downstream of m_axis is on the same clock too — the dual-clock CDC
// happens later, between S2MM AXIS and MM2S AXIS via VDMA's internal
// frame buffer crossing.
//
// Downscale only for now: OUT_W <= IN_W and OUT_H <= IN_H. Upscale uses a
// different accumulator/emit policy (repeat input pixels, emit multiple
// per input) — not implemented; will be a separate code path when needed.

`default_nettype none
`timescale 1ns / 1ps

module scaler_top #(
    parameter integer IN_W   = 1920,
    parameter integer IN_H   = 1080,
    parameter integer OUT_W  = 1280,
    parameter integer OUT_H  =  720,
    parameter integer PHASES =   64,
    parameter integer TAPS_H =    8,
    parameter integer TAPS_V =    4
) (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    output wire [23:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser
);
    // Intermediate AXIS between H and V (OUT_W × IN_H)
    wire [23:0] mid_tdata;
    wire        mid_tvalid;
    wire        mid_tready;
    wire        mid_tlast;
    wire        mid_tuser;

    scaler_h #(
        .IN_W   (IN_W),
        .OUT_W  (OUT_W),
        .PHASES (PHASES),
        .TAPS   (TAPS_H)
    ) u_h (
        .clk           (aclk),
        .rstn          (aresetn),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tuser  (s_axis_tuser),
        .m_axis_tdata  (mid_tdata),
        .m_axis_tvalid (mid_tvalid),
        .m_axis_tready (mid_tready),
        .m_axis_tlast  (mid_tlast),
        .m_axis_tuser  (mid_tuser)
    );

    scaler_v #(
        .IN_W   (OUT_W),
        .IN_H   (IN_H),
        .OUT_H  (OUT_H),
        .PHASES (PHASES),
        .TAPS   (TAPS_V)
    ) u_v (
        .clk           (aclk),
        .rstn          (aresetn),
        .s_axis_tdata  (mid_tdata),
        .s_axis_tvalid (mid_tvalid),
        .s_axis_tready (mid_tready),
        .s_axis_tlast  (mid_tlast),
        .s_axis_tuser  (mid_tuser),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast),
        .m_axis_tuser  (m_axis_tuser)
    );
endmodule

`default_nettype wire
