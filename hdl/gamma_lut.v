// gamma_lut.v — per-channel 256-entry output LUT (gamma / tone curve / levels).
//
// Final tone stage of the color pipeline, inserted DOWNSTREAM of color_matrix,
// upstream of axis_to_vid_io. Each output channel is remapped through its own
// 256-entry 8-bit LUT:  out_ch = lut_ch[in_ch].  Firmware computes the curve
// (gamma, S-curve, levels, …) and loads it; identity LUT + bypass = transparent.
//
// BYTE ORDER: pipeline carries tdata[23:16]=R, [15:8]=B, [7:0]=G (see
// schindler_pipeline_rbg_byte_order). Three independent LUTs, one per lane.
//
// LATENCY: the LUTs are async-read distributed RAM, so the lookup is
// combinational — this stage is AXIS-transparent (no added latency, no skid;
// tvalid/tready/tuser/tlast pass straight through). Zero throughput cost.
//
// LOAD INTERFACE (quasi-static, from an AXI-GPIO in the PS clock domain):
//   one entry per write — set {ch,addr,data} then FLIP lut_tog. A 2-FF-synced
//   toggle edge writes lut[ch][addr]=data. 768 writes load all three channels.
//   ch: 0=R(lane23:16) 1=B(lane15:8) 2=G(lane7:0). bypass forces passthrough.

`default_nettype none
`timescale 1ns / 1ps

module gamma_lut (
    input  wire        clk,
    input  wire        rstn,

    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tuser,
    input  wire        s_axis_tlast,

    output wire [23:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tuser,
    output wire        m_axis_tlast,

    // LUT load + enable (AXI-GPIO, async to clk — quasi-static)
    input  wire        lut_tog,       // toggle: each edge commits one (ch,addr,data)
    input  wire [1:0]  lut_ch,        // 0=R, 1=B, 2=G  (R-B-G lane order)
    input  wire [7:0]  lut_addr,
    input  wire [7:0]  lut_data,
    input  wire        bypass         // 1 = passthrough (ignore LUTs)
);
    // ---- CDC the quasi-static load/enable fields into clk ----
    (* ASYNC_REG = "TRUE" *) reg t_q1, t_q2, t_q3;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ch_q1, ch_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] ad_q1, ad_q2, da_q1, da_q2;
    (* ASYNC_REG = "TRUE" *) reg byp_q1, byp_q2;
    always @(posedge clk) begin
        if (!rstn) begin t_q1<=1'b0; t_q2<=1'b0; t_q3<=1'b0; byp_q1<=1'b1; byp_q2<=1'b1; end
        else begin
            t_q1<=lut_tog;  t_q2<=t_q1;  t_q3<=t_q2;
            ch_q1<=lut_ch;  ch_q2<=ch_q1;
            ad_q1<=lut_addr;ad_q2<=ad_q1;
            da_q1<=lut_data;da_q2<=da_q1;
            byp_q1<=bypass; byp_q2<=byp_q1;
        end
    end
    wire lut_we = (t_q2 ^ t_q3);   // toggle edge = one commit (addr/data already settled)

    // ---- three per-channel 256-entry LUTs, identity-initialised ----
    (* ram_style = "distributed" *) reg [7:0] lut_r [0:255];
    (* ram_style = "distributed" *) reg [7:0] lut_b [0:255];
    (* ram_style = "distributed" *) reg [7:0] lut_g [0:255];
    integer i;
    initial for (i = 0; i < 256; i = i + 1) begin
        lut_r[i] = i[7:0]; lut_b[i] = i[7:0]; lut_g[i] = i[7:0];
    end
    always @(posedge clk) if (lut_we) begin
        case (ch_q2)
            2'd0: lut_r[ad_q2] <= da_q2;
            2'd1: lut_b[ad_q2] <= da_q2;
            default: lut_g[ad_q2] <= da_q2;
        endcase
    end

    // ---- combinational lookup + AXIS-transparent passthrough ----
    wire [7:0] in_r = s_axis_tdata[23:16];
    wire [7:0] in_b = s_axis_tdata[15:8];
    wire [7:0] in_g = s_axis_tdata[7:0];
    wire [23:0] mapped = { lut_r[in_r], lut_b[in_b], lut_g[in_g] };

    assign m_axis_tdata  = byp_q2 ? s_axis_tdata : mapped;
    assign m_axis_tvalid = s_axis_tvalid;
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tuser  = s_axis_tuser;
    assign m_axis_tlast  = s_axis_tlast;
endmodule

`default_nettype wire
