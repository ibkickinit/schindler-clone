// pg_warp_engine.v — M3c integration: full warp datapath.
//   consumer pg_affine ─┐
//                       ├─► pg_tilecache_rt2 ─► bilinear (2-stage lerp) ─► AXIS out
//   prefetch pg_affine ─┘   (consumer gathers / prefetch warms)
//
// Both affines walk the same output raster from the same coeffs; the prefetch one free-runs (only
// gated by the cache prefetch port) so it leads the consumer (which is gated by the output rate).
// Bilinear: top=lerp(p00,p10,fx); bot=lerp(p01,p11,fx); out=lerp(top,bot,fy)  (weight = frac[11:4]).
// DMA fill is the cache's 2x2-block interface (the BD supplies a DataMover + reorder; sim uses a
// behavioral DMA). This module is the datapath; genlock/FRC/Mackin wrap at the top later.

`default_nettype none
`timescale 1ns / 1ps

module pg_warp_engine #(
    parameter integer OUT_W=1280, OUT_H=720, IN_W=1920, IN_H=1080,
    parameter integer LTILE=4, NTILE=64, CW=32, FB=12,
    parameter integer LEAD=512                       // bound prefetch run-ahead so rr never evicts an unconsumed tile
) (
    input  wire        clk, rstn,
    input  wire        sof,                        // 1-cyc: start the raster walk (affines self-pace via ready)
    // affine coeffs (signed Q(CW-FB).FB), firmware-computed
    input  wire signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f,
    input  wire [23:0] matte,                     // out-of-window fill
    // output AXIS-ish
    output wire        o_valid,
    output wire [23:0] o_pix,
    input  wire        o_ready,
    // DMA (2x2-block fill)
    output wire        fetch_req,
    output wire [11:0] fetch_tx, fetch_ty,
    input  wire        fetch_ready,       // tile_dma can accept a fetch (multi-outstanding handshake)
    input  wire        fill_valid,
    input  wire [95:0] fill_blk,
    input  wire        fill_last
);
    // Skid buffers between each affine and the cache decouple the affine's o_ready from the cache's
    // live tag lookup (which was the -3.5ns combinational handshake loop through the affine DDA).
    wire        tc_ready, pf_ready;

    // ---- consumer affine -> skid -> cache ----
    wire        ca_v, ca_in, ca_nr; wire [11:0] ca_col, ca_row, ca_fx, ca_fy; wire ca_sr;
    wire        cm_v; wire [48:0] cm_d;
    pg_affine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.CW(CW),.FB(FB)) u_aff_c (
        .clk(clk),.rstn(rstn),.sof(sof),.o_valid(ca_v),.o_ready(ca_sr),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),
        .o_in_window(ca_in),.o_src_col(ca_col),.o_src_row(ca_row),
        .o_h_frac(ca_fx),.o_v_frac(ca_fy),.o_new_row(ca_nr));
    pg_skid #(.W(49)) u_skid_c (.clk(clk),.rstn(rstn),
        .s_valid(ca_v),.s_data({ca_col,ca_row,ca_fx,ca_fy,ca_in}),.s_ready(ca_sr),
        .m_valid(cm_v),.m_data(cm_d),.m_ready(tc_ready));

    // ---- prefetch affine -> skid -> cache (lead-bounded so eviction only hits consumed tiles) ----
    wire        pa_v, pa_in; wire [11:0] pa_col, pa_row; wire pa_sr;
    wire        pm_v; wire [24:0] pm_d;
    reg  [15:0] lead_cnt; reg pf_acc_r, c_acc_r;
    wire        pf_gate = (lead_cnt < LEAD[15:0]);          // reg-based -> not in the lookup path
    // register the accept events so the 16-bit counter add isn't fed by the live lookup (pf_ready).
    // 1-cycle-stale count only shifts the coarse lead bound by ~1 — harmless.
    always @(posedge clk) begin
        if(!rstn || sof) begin pf_acc_r<=1'b0; c_acc_r<=1'b0; lead_cnt<=16'd0; end
        else begin
            pf_acc_r <= pm_v && pf_ready; c_acc_r <= cm_v && tc_ready;
            lead_cnt <= lead_cnt + (pf_acc_r?16'd1:16'd0) - (c_acc_r?16'd1:16'd0);
        end
    end
    pg_affine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.CW(CW),.FB(FB)) u_aff_p (
        .clk(clk),.rstn(rstn),.sof(sof),.o_valid(pa_v),.o_ready(pa_sr && pf_gate),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),
        .o_in_window(pa_in),.o_src_col(pa_col),.o_src_row(pa_row),
        .o_h_frac(),.o_v_frac(),.o_new_row());
    pg_skid #(.W(25)) u_skid_p (.clk(clk),.rstn(rstn),
        .s_valid(pa_v && pf_gate),.s_data({pa_col,pa_row,pa_in}),.s_ready(pa_sr),
        .m_valid(pm_v),.m_data(pm_d),.m_ready(pf_ready));

    // ---- tile cache ----
    wire        tc_v; wire [23:0] tp00,tp10,tp01,tp11; wire [11:0] tfx,tfy; wire tin; wire [3:0] tsb;
    pg_tilecache_rt2 #(.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.SB(4)) u_tc (
        .clk(clk),.rstn(rstn),
        .pf_valid(pm_v),.pf_x(pm_d[24:13]),.pf_y(pm_d[12:1]),.pf_inwin(pm_d[0]),.pf_ready(pf_ready),
        .c_valid(cm_v),.c_x(cm_d[48:37]),.c_y(cm_d[36:25]),.c_fx(cm_d[24:13]),.c_fy(cm_d[12:1]),.c_inwin(cm_d[0]),.c_sb(4'd0),.c_ready(tc_ready),
        .out_valid(tc_v),.out_p00(tp00),.out_p10(tp10),.out_p01(tp01),.out_p11(tp11),
        .out_fx(tfx),.out_fy(tfy),.out_inwin(tin),.out_sb(tsb),.out_ready(b_ready),
        .fetch_req(fetch_req),.fetch_tx(fetch_tx),.fetch_ty(fetch_ty),.t_ready(fetch_ready),
        .fill_valid(fill_valid),.fill_blk(fill_blk),.fill_last(fill_last));

    // ---- bilinear (2-stage lerp), registered; matte when out-of-window ----
    function [7:0] lerp8; input [7:0] a,b; input [7:0] w;
        reg signed [19:0] d,p,r; begin d=$signed({1'b0,b})-$signed({1'b0,a});
            p=d*$signed({1'b0,w}); r=$signed({1'b0,a})+((p+20'sd128)>>>8); lerp8=r[7:0]; end
    endfunction
    function [23:0] lerp24; input [23:0] a,b; input [7:0] w;
        lerp24={lerp8(a[23:16],b[23:16],w),lerp8(a[15:8],b[15:8],w),lerp8(a[7:0],b[7:0],w)}; endfunction
    wire [7:0] wx=tfx[11:4], wy=tfy[11:4];

    // PIPELINED bilinear: stage H (the two row lerps) -> stage V (the column lerp). Splits the
    // chained 2x lerp24 critical path. Backpressured: cache out_ready = h_ready.
    reg        h_v, h_in; reg [23:0] h_top, h_bot; reg [7:0] h_wy;
    reg        ov; reg [23:0] opix;
    wire       v_ready = !ov || o_ready;
    wire       h_ready = !h_v || v_ready;
    wire       b_ready = h_ready;
    assign o_valid = ov; assign o_pix = opix;
    always @(posedge clk) begin
        if(!rstn) begin h_v<=1'b0; ov<=1'b0; end
        else begin
            if(ov && o_ready) ov<=1'b0;
            if(v_ready) begin ov<=h_v; opix <= h_in ? lerp24(h_top,h_bot,h_wy) : matte; end
            if(h_ready) begin
                h_v<=tc_v; h_in<=tin; h_wy<=wy;
                h_top<=lerp24(tp00,tp10,wx); h_bot<=lerp24(tp01,tp11,wx);
            end
        end
    end
endmodule

`default_nettype wire
