// pg_read_engine_top.v — route-B present-geometry read-engine, BD-ready wrapper.
//
// One BD cell that replaces VDMA MM2S in the output path. It reads the master
// frame from DDR via an AXI DataMover (MM2S), applies runtime size/position/
// matte, and emits a full OUT_W×OUT_H AXIS stream into the existing color stack
// → axis_to_vid_io. S2MM (the write side) is untouched.
//
// Wraps:
//   pg_genlock  — picks the completed ring slot from source vsync (frame-follow)
//   pg_compose  — output walk + prefetch + residency-stall compositor (incl.
//                 pg_addrgen + pg_linefetch); emits the windowed AXIS stream
//   pg_unpack   — 64b DataMover beats → 24b pixels feeding pg_compose's fetch port
//   cmd fmt     — pg_compose's line-fetch requests → AXI DataMover command stream
//
// DataMover command word (PG022, 32-bit addr → 72-bit command):
//   [22:0] BTT  [23] TYPE(1=INCR)  [29:24] DSA  [30] EOF  [31] DRR
//   [63:32] SADDR  [67:64] TAG  [71:68] RSVD
// We issue one full master line per command: BTT = LINE_W*3 bytes, INCR, EOF=1.
//
// All ports are in the output pixel-clock domain except src_vsync (CDC'd inside
// pg_genlock). Geometry/step inputs come from AXI GPIO (firmware-computed).

`default_nettype none
`timescale 1ns / 1ps

module pg_read_engine_top #(
    parameter integer OUT_W = 1280,
    parameter integer OUT_H = 720,
    parameter integer IN_W  = 1280,
    parameter integer IN_H  = 720,
    parameter integer STRIDE = 3840,                 // master line stride (bytes)
    parameter [31:0]  FRAME_BUF_BASE = 32'h1000_0000,
    parameter integer NUM_FRAMES = 5,
    parameter integer SLOT_STRIDE = 2768640,         // FRAME_BYTES + STRIDE guard
    parameter integer READ_DELAY = 2
) (
    input  wire        clk,
    input  wire        rstn,

    // sync
    input  wire [5:0]  frame_ptr,        // axi_vdma s2mm_frame_ptr_out (FCLK_CLK1, async)
    input  wire        out_vsync,        // v_tc_tx vsync_out (this domain)

    // runtime geometry (AXI GPIO, firmware-computed DDA steps)
    input  wire [11:0] out_w_win, out_h_win, pos_x, pos_y,
    input  wire [11:0] h_step_int, h_step_frac, v_step_int, v_step_frac,
    input  wire [23:0] matte_rgb,

    // output AXIS → color stack (axis_to_vid_io path)
    output wire [23:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,

    // AXI DataMover MM2S command stream (→ datamover S_AXIS_MM2S_CMD)
    output wire [71:0] m_axis_cmd_tdata,
    output wire        m_axis_cmd_tvalid,
    input  wire        m_axis_cmd_tready,

    // AXI DataMover MM2S data stream (← datamover M_AXIS_MM2S, 64-bit)
    input  wire [63:0] s_axis_dm_tdata,
    input  wire        s_axis_dm_tvalid,
    output wire        s_axis_dm_tready,
    input  wire        s_axis_dm_tlast,

    // AXI DataMover MM2S status stream (← datamover M_AXIS_MM2S_STS) — drained
    input  wire [7:0]  s_axis_sts_tdata,
    input  wire        s_axis_sts_tkeep,
    input  wire        s_axis_sts_tlast,
    input  wire        s_axis_sts_tvalid,
    output wire        s_axis_sts_tready,

    // debug
    output wire [2:0]  dbg_read_slot,
    output wire [2:0]  dbg_write_slot
);
    // status stream is informational (per-line completion) — always drain it
    // so the DataMover's status FIFO never fills and stalls command intake.
    assign s_axis_sts_tready = 1'b1;
    wire _sts_keep = s_axis_sts_tvalid & s_axis_sts_tlast & s_axis_sts_tkeep & (|s_axis_sts_tdata);

    // ---- geometry CDC: AXI GPIO (FCLK_CLK0) → this pixel-clock domain ----
    // Quasi-static (firmware writes between frames) + frame-atomic latch in
    // pg_compose/pg_addrgen at SOF, so per-bit 2-FF sync is sufficient. XDC
    // false-paths target g_q1_reg[*]/D.
    localparam integer GW = 8*12 + 24;   // 8 step/pos/size fields + matte
    wire [GW-1:0] g_in = {matte_rgb, v_step_frac, v_step_int, h_step_frac, h_step_int,
                          pos_y, pos_x, out_h_win, out_w_win};
    (* ASYNC_REG = "TRUE" *) reg [GW-1:0] g_q1, g_q2;
    always @(posedge clk) begin
        if (!rstn) begin g_q1 <= {GW{1'b0}}; g_q2 <= {GW{1'b0}}; end
        else       begin g_q1 <= g_in; g_q2 <= g_q1; end
    end
    wire [11:0] s_out_w = g_q2[11:0];
    wire [11:0] s_out_h = g_q2[23:12];
    wire [11:0] s_pos_x = g_q2[35:24];
    wire [11:0] s_pos_y = g_q2[47:36];
    wire [11:0] s_hsi   = g_q2[59:48];
    wire [11:0] s_hsf   = g_q2[71:60];
    wire [11:0] s_vsi   = g_q2[83:72];
    wire [11:0] s_vsf   = g_q2[95:84];
    wire [23:0] s_matte = g_q2[119:96];

    // ---- frame-follow: which completed slot to read ----
    wire [31:0] frame_base;
    pg_genlock #(.FRAME_BUF_BASE(FRAME_BUF_BASE), .NUM_FRAMES(NUM_FRAMES),
                 .SLOT_STRIDE(SLOT_STRIDE), .READ_DELAY(READ_DELAY)) u_genlock (
        .clk(clk), .rstn(rstn), .frame_ptr(frame_ptr), .out_vsync(out_vsync),
        .read_slot(dbg_read_slot), .read_base_addr(frame_base), .write_slot(dbg_write_slot)
    );

    // ---- compositor (owns pg_addrgen + pg_linefetch); fetch_* is DataMover-pixel ----
    wire        fetch_req;
    wire [31:0] fetch_addr;
    wire [11:0] fetch_len;
    wire        up_pvalid, up_plast;
    wire [23:0] up_pdata;

    pg_compose #(.OUT_W(OUT_W), .OUT_H(OUT_H), .IN_W(IN_W), .IN_H(IN_H),
                 .STRIDE(STRIDE), .FIFO_DEPTH(64)) u_compose (
        .clk(clk), .rstn(rstn), .vtg_vsync(out_vsync), .frame_base_addr(frame_base),
        .out_w_win(s_out_w), .out_h_win(s_out_h), .pos_x(s_pos_x), .pos_y(s_pos_y),
        .h_step_int(s_hsi), .h_step_frac(s_hsf),
        .v_step_int(s_vsi), .v_step_frac(s_vsf), .matte_rgb(s_matte),
        .m_tdata(m_axis_tdata), .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr), .fetch_len(fetch_len),
        .fetch_pvalid(up_pvalid), .fetch_pdata(up_pdata), .fetch_last(up_plast)
    );

    // ---- DataMover beats → pixels for the compositor's fetch port ----
    pg_unpack u_unpack (
        .clk(clk), .rstn(rstn), .line_px(IN_W[11:0]),
        .s_tdata(s_axis_dm_tdata), .s_tvalid(s_axis_dm_tvalid),
        .s_tready(s_axis_dm_tready),
        .p_valid(up_pvalid), .p_data(up_pdata), .p_last(up_plast)
    );

    // ---- DataMover command formatter (one line per fetch request) ----
    reg        cmd_valid;
    reg [71:0] cmd_data;
    assign m_axis_cmd_tvalid = cmd_valid;
    assign m_axis_cmd_tdata  = cmd_data;
    wire [22:0] btt = fetch_len * 3;   // bytes to transfer = pixels × 3

    always @(posedge clk) begin
        if (!rstn) begin
            cmd_valid <= 1'b0; cmd_data <= 72'd0;
        end else begin
            if (cmd_valid && m_axis_cmd_tready) cmd_valid <= 1'b0;   // command accepted
            if (fetch_req && !cmd_valid) begin
                // {RSVD[71:68], TAG[67:64], SADDR[63:32], DRR[31], EOF[30], DSA[29:24], TYPE[23], BTT[22:0]}
                cmd_data  <= {4'd0, 4'd0, fetch_addr,
                              1'b0, 1'b1, 6'd0, 1'b1, btt};
                cmd_valid <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
