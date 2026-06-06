// gamma_lut.v — per-channel 256-entry output LUT (gamma / tone curve / levels),
// DOUBLE-BUFFERED with atomic frame-boundary swap.
//
// Final tone stage of the color pipeline, DOWNSTREAM of color_matrix, upstream of
// axis_to_vid_io. Each output channel is remapped through its own 256-entry 8-bit
// LUT:  out_ch = lut_ch[in_ch].  Identity LUT + bypass = transparent.
//
// WHY DOUBLE-BUFFERED (2026-06-05, fixes #114): the single-buffer version loaded the
// LUT *over the live display* and wrote each address's R,B,G as 3 separate (CDC-spaced)
// writes, so a fast/large change showed a half-updated → chromatic LUT mid-load. Here
// the firmware ALWAYS writes the INACTIVE bank; the displayed bank only switches at a
// frame boundary (SOF) when firmware flips `swap`. So the displayed curve is ALWAYS a
// complete, consistent set — no flash, no chroma, any load speed, live-drag safe.
//
// BYTE ORDER: tdata[23:16]=R, [15:8]=B, [7:0]=G (schindler_pipeline_rbg_byte_order).
//
// LATENCY: async-read distributed RAM → combinational lookup, AXIS-transparent
// (tvalid/tready/tuser/tlast pass straight through, zero added latency).
//
// LOAD (quasi-static, from an AXI-GPIO in the PS clock domain):
//   per entry: set {ch,addr,data}, FLIP lut_tog → a 2-FF-synced toggle edge writes
//   lut[ch][addr] in the INACTIVE bank. After loading all entries, FLIP `swap` → the
//   bank swap commits at the next SOF.  ch: 0=R 1=B 2=G.  bypass forces passthrough.

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
    input  wire        lut_tog,       // toggle: each edge commits one (ch,addr,data) to INACTIVE bank
    input  wire [1:0]  lut_ch,        // 0=R, 1=B, 2=G  (R-B-G lane order)
    input  wire [7:0]  lut_addr,
    input  wire [7:0]  lut_data,
    input  wire        bypass,        // 1 = passthrough (ignore LUTs)
    input  wire        swap           // toggle: each edge requests a bank swap at next SOF
);
    // ---- CDC the quasi-static fields into clk ----
    (* ASYNC_REG = "TRUE" *) reg t_q1, t_q2, t_q3;
    (* ASYNC_REG = "TRUE" *) reg sw_q1, sw_q2, sw_q3;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ch_q1, ch_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0] ad_q1, ad_q2, da_q1, da_q2;
    (* ASYNC_REG = "TRUE" *) reg byp_q1, byp_q2;
    always @(posedge clk) begin
        if (!rstn) begin
            t_q1<=1'b0; t_q2<=1'b0; t_q3<=1'b0;
            sw_q1<=1'b0; sw_q2<=1'b0; sw_q3<=1'b0;
            byp_q1<=1'b1; byp_q2<=1'b1;
        end else begin
            t_q1<=lut_tog;  t_q2<=t_q1;  t_q3<=t_q2;
            sw_q1<=swap;    sw_q2<=sw_q1; sw_q3<=sw_q2;
            ch_q1<=lut_ch;  ch_q2<=ch_q1;
            ad_q1<=lut_addr;ad_q2<=ad_q1;
            da_q1<=lut_data;da_q2<=da_q1;
            byp_q1<=bypass; byp_q2<=byp_q1;
        end
    end
    wire lut_we    = (t_q2 ^ t_q3);    // one commit per load toggle edge
    wire swap_edge = (sw_q2 ^ sw_q3);  // one swap request per swap toggle edge

    // ---- bank select: display rd_bank, write the inactive (~rd_bank) bank ----
    reg  rd_bank, swap_pending;
    wire wr_bank = ~rd_bank;
    wire sof = s_axis_tvalid & m_axis_tready & s_axis_tuser;  // start-of-frame beat passes
    always @(posedge clk) begin
        if (!rstn) begin rd_bank <= 1'b0; swap_pending <= 1'b0; end
        else begin
            if (swap_edge)            swap_pending <= 1'b1;
            if (sof && swap_pending) begin rd_bank <= ~rd_bank; swap_pending <= 1'b0; end
        end
    end

    // ---- two banks × three 256-entry LUTs (addr = {bank, idx}), identity-initialised ----
    (* ram_style = "distributed" *) reg [7:0] lut_r [0:511];
    (* ram_style = "distributed" *) reg [7:0] lut_b [0:511];
    (* ram_style = "distributed" *) reg [7:0] lut_g [0:511];
    integer i;
    initial for (i = 0; i < 512; i = i + 1) begin
        lut_r[i] = i[7:0]; lut_b[i] = i[7:0]; lut_g[i] = i[7:0];   // identity in BOTH banks
    end
    always @(posedge clk) if (lut_we) begin
        case (ch_q2)
            2'd0: lut_r[{wr_bank, ad_q2}] <= da_q2;
            2'd1: lut_b[{wr_bank, ad_q2}] <= da_q2;
            default: lut_g[{wr_bank, ad_q2}] <= da_q2;
        endcase
    end

    // ---- combinational lookup (active bank) + AXIS-transparent passthrough ----
    wire [7:0] in_r = s_axis_tdata[23:16];
    wire [7:0] in_b = s_axis_tdata[15:8];
    wire [7:0] in_g = s_axis_tdata[7:0];
    wire [23:0] mapped = { lut_r[{rd_bank,in_r}], lut_b[{rd_bank,in_b}], lut_g[{rd_bank,in_g}] };

    assign m_axis_tdata  = byp_q2 ? s_axis_tdata : mapped;
    assign m_axis_tvalid = s_axis_tvalid;
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tuser  = s_axis_tuser;
    assign m_axis_tlast  = s_axis_tlast;
endmodule

`default_nettype wire
