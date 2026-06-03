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
    parameter integer READ_DELAY = 2,
    parameter integer NBUF = 5                        // line-buffer ring depth: 1 read + 2 prefetch + 1 fill + 1 guard
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
    output wire        m_axis_tuser,     // SOF (frame's first pixel) — for SOF-realign
    output wire        m_axis_tlast,     // EOL (row's last pixel)

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
    output wire [2:0]  dbg_write_slot,
    output wire [191:0] dbg_probe       // ILA tap; bit layout in body
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

    // ---- compositor (owns pg_addrgen + pg_linefetch); packed-beat fill ----
    // DataMover M_AXIS (64-bit beats) feeds pg_compose -> pg_linefetch directly;
    // pg_unpack is gone (extraction is now read-side, inside pg_linefetch).
    wire        fetch_req;
    wire [31:0] fetch_addr;
    wire [11:0] fetch_len;

    // debug taps from the compositor (wired in u_compose below)
    wire [11:0] dc_src_col, dc_src_row;
    wire        dc_a_valid, dc_a_inwin, dc_a_newrow, dc_resident;
    wire [23:0] dc_rd_data;
    // prefetch-state taps (build #14)
    wire [11:0] dc_rd_row, dc_pf_src, dc_pf_next_k, dc_served;
    wire        dc_m3_busy, dc_pf_req, dc_push_en, dc_have_row;
    wire [23:0] dc_push_data;
    wire [3:0]  dc_fill_sel, dc_rd_sel;

    pg_compose #(.OUT_W(OUT_W), .OUT_H(OUT_H), .IN_W(IN_W), .IN_H(IN_H),
                 .STRIDE(STRIDE), .FIFO_DEPTH(64), .NBUF(NBUF)) u_compose (
        .clk(clk), .rstn(rstn), .vtg_vsync(out_vsync), .frame_base_addr(frame_base),
        .out_w_win(s_out_w), .out_h_win(s_out_h), .pos_x(s_pos_x), .pos_y(s_pos_y),
        .h_step_int(s_hsi), .h_step_frac(s_hsf),
        .v_step_int(s_vsi), .v_step_frac(s_vsf), .matte_rgb(s_matte),
        .m_tdata(m_axis_tdata), .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready),
        .m_tuser(m_axis_tuser), .m_tlast(m_axis_tlast),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr), .fetch_len(fetch_len),
        .beat_data(s_axis_dm_tdata), .beat_valid(s_axis_dm_tvalid),
        .beat_ready(s_axis_dm_tready), .beat_last(s_axis_dm_tlast),
        .dbg_src_col(dc_src_col), .dbg_src_row(dc_src_row),
        .dbg_a_valid(dc_a_valid), .dbg_a_inwin(dc_a_inwin), .dbg_a_newrow(dc_a_newrow),
        .dbg_resident(dc_resident), .dbg_rd_data(dc_rd_data),
        .dbg_rd_row(dc_rd_row), .dbg_pf_src(dc_pf_src), .dbg_pf_next_k(dc_pf_next_k),
        .dbg_served(dc_served), .dbg_m3_busy(dc_m3_busy), .dbg_pf_req(dc_pf_req),
        .dbg_push_en(dc_push_en), .dbg_push_data(dc_push_data),
        .dbg_fill_sel(dc_fill_sel), .dbg_rd_sel(dc_rd_sel), .dbg_have_row(dc_have_row)
    );

    // ---- debug probe bus (ILA, NATIVE, 192-bit; build #14) ----
    //  [11:0] src_col   [23:12] src_row   [35:24] rd_row(read)  [47:36] pf_src
    //  [59:48] pf_next_k [71:60] served    [75:72] fill_sel(4)  [79:76] rd_sel(4)
    //  [80] a_valid  [81] a_inwin  [82] a_newrow  [83] resident  [84] m3_busy
    //  [85] pf_req   [86] have_row [87] push_en   [88] up_pvalid [89] up_plast
    //  [90] m_tvalid [91] m_tready [95:92] pad
    //  [119:96] rd_data  [143:120] up_pdata  [167:144] push_data  [191:168] pad
    assign dbg_probe = {24'd0, dc_push_data, s_axis_dm_tdata[23:0], dc_rd_data,
                        4'd0, m_axis_tready, m_axis_tvalid, s_axis_dm_tlast, s_axis_dm_tvalid,
                        dc_push_en, dc_have_row, dc_pf_req, dc_m3_busy, dc_resident,
                        dc_a_newrow, dc_a_inwin, dc_a_valid,
                        dc_rd_sel, dc_fill_sel,
                        dc_served, dc_pf_next_k, dc_pf_src, dc_rd_row,
                        dc_src_row, dc_src_col};

    // (pg_unpack removed — packed-beat: DataMover beats go straight to pg_linefetch
    //  via pg_compose's beat port; pixel extraction is read-side in pg_linefetch.)

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
