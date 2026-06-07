// pg_warp_top.v — BD-level wrapper for the arbitrary-geometry (affine) read engine.
//
// Drop-in alternative to pg_read_engine_top for the warp path: same DataMover + frame_ptr + VTC +
// output-AXIS interface, but internally  pg_tile_dma (tile fetch + 2x2 reorder) -> pg_warp_engine
// (dual pg_affine + tile cache + bilinear). FIRST-bitstream scope: free-running — reads the latest
// completed VDMA frame and warps it (genlock/FRC/Mackin layer on after the warp proves on silicon).
//
// Geometry = 6 affine coeffs (signed Q(CW-FB).FB), firmware-computed: sx=a*ox+b*oy+c, sy=d*ox+e*oy+f.

`default_nettype none
`timescale 1ns / 1ps

module pg_warp_top #(
    parameter integer OUT_W = 1280,
    parameter integer OUT_H = 720,
    parameter integer IN_W  = 1920,
    parameter integer IN_H  = 1080,
    parameter [31:0]  FRAME_BUF_BASE = 32'h1000_0000,
    parameter integer NUM_FRAMES  = 7,
    parameter integer SLOT_STRIDE  = 2768640,
    parameter integer NTILE = 256,
    parameter integer WAY   = 4,
    parameter integer PD    = 16,
    parameter integer DREQ  = 16,
    parameter integer LTILE = 4,
    parameter integer LEAD  = 2048,
    parameter integer CW = 32,
    parameter integer FB = 12
) (
    input  wire        clk, rstn,
    input  wire [5:0]  frame_ptr,            // VDMA s2mm_frame_ptr_out (async)
    input  wire        out_vsync,            // v_tc_tx vsync_out (this domain)
    // affine coeffs (AXI GPIO, async — frame-atomic latched at sof inside pg_affine)
    input  wire signed [CW-1:0] m_a, m_b, m_c, m_d, m_e, m_f,
    input  wire [23:0] matte_rgb,
    // output AXIS -> color stack
    output wire [23:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tuser,         // SOF
    output wire        m_axis_tlast,         // EOL
    // AXI DataMover MM2S command / data / status
    output wire [71:0] m_axis_cmd_tdata,
    output wire        m_axis_cmd_tvalid,
    input  wire        m_axis_cmd_tready,
    input  wire [63:0] s_axis_dm_tdata,
    input  wire        s_axis_dm_tvalid,
    output wire        s_axis_dm_tready,
    input  wire        s_axis_dm_tlast,
    input  wire [7:0]  s_axis_sts_tdata,
    input  wire        s_axis_sts_tkeep,
    input  wire        s_axis_sts_tlast,
    input  wire        s_axis_sts_tvalid,
    output wire        s_axis_sts_tready
);
    assign s_axis_sts_tready = 1'b1;          // drain status FIFO

    // ---- frame_ptr CDC + sof (vsync rising) + frame_base latch ----
    (* ASYNC_REG="TRUE" *) reg [5:0] fp_q1, fp_q2;
    reg vs_d; wire sof = out_vsync & ~vs_d;
    reg [31:0] frame_base;
    always @(posedge clk) begin
        if(!rstn) begin fp_q1<=0; fp_q2<=0; vs_d<=0; frame_base<=FRAME_BUF_BASE; end
        else begin
            fp_q1<=frame_ptr; fp_q2<=fp_q1; vs_d<=out_vsync;
            if(sof) begin                     // latch the latest COMPLETED slot (frame_ptr - 1)
                frame_base <= FRAME_BUF_BASE +
                    ((fp_q2==6'd0) ? (NUM_FRAMES-1) : (fp_q2-6'd1)) * SLOT_STRIDE;
            end
        end
    end

    // ---- coeff CDC (quasi-static; pg_affine re-latches at sof) ----
    (* ASYNC_REG="TRUE" *) reg signed [CW-1:0] a1,b1,c1,d1,e1,f1, a2,b2,c2,d2,e2,f2;
    (* ASYNC_REG="TRUE" *) reg [23:0] mt1, mt2;
    always @(posedge clk) begin
        a1<=m_a;b1<=m_b;c1<=m_c;d1<=m_d;e1<=m_e;f1<=m_f; mt1<=matte_rgb;
        a2<=a1;b2<=b1;c2<=c1;d2<=d1;e2<=e1;f2<=f1; mt2<=mt1;
    end

    // ---- engine + tile DMA ----
    wire        wreq; wire [11:0] wtx, wty;
    wire        fv; wire [95:0] fblk; wire fl;
    wire        o_valid; wire [23:0] o_pix; wire o_ready;
    wire        fetch_req; wire [31:0] fetch_addr; wire [11:0] fetch_len;
    wire        t_rdy;                    // tile_dma can accept a fetch (multi-outstanding handshake)
    wire        cmd_rdy;                  // DataMover command formatter can accept a row command

    pg_warp_engine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),
                     .LTILE(LTILE),.NTILE(NTILE),.WAY(WAY),.PD(PD),.CW(CW),.FB(FB),.LEAD(LEAD)) u_eng (
        .clk(clk),.rstn(rstn),.sof(sof),
        .m_a(a2),.m_b(b2),.m_c(c2),.m_d(d2),.m_e(e2),.m_f(f2),.matte(mt2),
        .o_valid(o_valid),.o_pix(o_pix),.o_ready(o_ready),
        .fetch_req(wreq),.fetch_tx(wtx),.fetch_ty(wty),.fetch_ready(t_rdy),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl));

    pg_tile_dma #(.IN_W(IN_W),.LTILE(LTILE),.DREQ(DREQ)) u_dma (
        .clk(clk),.rstn(rstn),.frame_base(frame_base),
        .t_req(wreq),.t_tx(wtx),.t_ty(wty),.t_ready(t_rdy),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(fetch_req),.fetch_addr(fetch_addr),.fetch_len(fetch_len),.fetch_ready(cmd_rdy),
        .beat_data(s_axis_dm_tdata),.beat_valid(s_axis_dm_tvalid),
        .beat_ready(s_axis_dm_tready),.beat_last(s_axis_dm_tlast));

    // ---- DataMover command formatter (one row per fetch) ----
    // tile_dma holds fetch_req (combinational) and a row is consumed on cmd_rdy. The formatter buffers
    // one command; cmd_rdy=!cmd_valid is the row-command handshake back to tile_dma. The DataMover IP's
    // own command FIFO buffers the rest, keeping the row stream gap-free.
    reg cmd_valid; reg [71:0] cmd_data;
    assign cmd_rdy = !cmd_valid;
    assign m_axis_cmd_tvalid = cmd_valid;
    assign m_axis_cmd_tdata  = cmd_data;
    wire [22:0] btt = fetch_len * 3;
    always @(posedge clk) begin
        if(!rstn) begin cmd_valid<=1'b0; cmd_data<=72'd0; end
        else begin
            if(cmd_valid && m_axis_cmd_tready) cmd_valid<=1'b0;
            if(fetch_req && !cmd_valid) begin
                cmd_data <= {4'd0,4'd0, fetch_addr, 1'b0,1'b1,6'd0,1'b1, btt};
                cmd_valid<=1'b1;
            end
        end
    end

    // ---- output AXIS framing: TUSER=SOF (first pixel), TLAST=EOL (every OUT_W) ----
    reg [11:0] ocol; reg fr_first;
    assign m_axis_tdata  = o_pix;
    assign m_axis_tvalid = o_valid;
    assign o_ready       = m_axis_tready;
    assign m_axis_tlast  = (ocol == OUT_W[11:0]-12'd1);
    assign m_axis_tuser  = fr_first;
    always @(posedge clk) begin
        if(!rstn) begin ocol<=12'd0; fr_first<=1'b1; end
        else begin
            if(sof) begin ocol<=12'd0; fr_first<=1'b1; end
            else if(o_valid && m_axis_tready) begin
                fr_first<=1'b0;
                ocol <= (ocol==OUT_W[11:0]-12'd1) ? 12'd0 : ocol+12'd1;
            end
        end
    end
endmodule

`default_nettype wire
