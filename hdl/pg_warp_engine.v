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
    parameter integer LTILE=4, NTILE=64, WAY=4, PD=16, CW=32, FB=12,
    parameter integer LEAD=512,                      // bound prefetch run-ahead so rr never evicts an unconsumed tile
    // ---- projective front-end (P2). PROJECTIVE=0 + FB=12 + m_g/m_h tied 0 == byte-for-byte pg_affine. ----
    parameter integer PROJECTIVE=0,                  // 0 = affine; 1 = keystone/corner-pin (wider coeffs + reciprocal)
    parameter integer GCW=40, GFB=36,                // perspective coeff word width + frac bits (P1 budget)
    parameter integer RF=28, LUT_BITS=9, NR_ITERS=2, // reciprocal datapath frac / seed-LUT / Newton steps
    parameter integer AW=44, WW=48                   // numerator / denominator accumulator widths
) (
    input  wire        clk, rstn,
    input  wire        sof,                        // 1-cyc: start the raster walk (addr-gens self-pace via ready)
    input  wire [19:0] lead_rt,                    // runtime prefetch lead (0 -> use build-param LEAD)
    input  wire [3:0]  hsel,                       // task-57: per-angle set-hash select (9 variants; 0=*33)
    input  wire [11:0] in_w_rt, in_h_rt,           // DYNAMIC RING: runtime active source dims (0 -> build MAX)
    input  wire [11:0] out_w_rt, out_h_rt,         // RUNTIME OUTPUT: warp output raster (eol/last; 0 -> build MAX)
    // numerator coeffs (signed Q(CW-FB).FB), firmware-computed
    input  wire signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f,
    // perspective coeffs (signed Q(GCW-GFB).GFB); tie 0 for affine (w=1 -> byte-for-byte pg_affine)
    input  wire signed [GCW-1:0] m_g, m_h,
    // BITE 1 (2026-06-26): PLACEMENT affine (sheet -> LOD), signed Q(CW-FB).FB. m_*
    // are now the CORNER-PIN (output -> sheet); pa..pf place the source on the sheet.
    input  wire signed [CW-1:0] pa,pb,pc,pd,pe,pf,
    // BITE 2 (2026-06-26): PINCUSHION radial coeff (signed Q(FB+KPSH); 0 -> transparent). Applied to the
    // sheet coord between the corner-pin (projective) and the placement, in BOTH legs. Centre = output/2.
    // 2026-06-28: independent per-axis coeffs (kx=horizontal bow, ky=vertical bow). kx==ky == symmetric.
    input  wire signed [31:0] kx, ky,
    input  wire [23:0] matte,                     // GRAY matte fill (on-sheet, off-content)
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
    // Skid buffers between each placement stage and the cache decouple its o_ready from the cache's
    // live tag lookup (which was the -3.5ns combinational handshake loop through the affine DDA).
    wire        tc_ready, pf_ready;

    // DYNAMIC RING: effective LOD bounds for the placement bounds-test (0 -> build max). The place
    // stage tests these directly (no internal 0->max), so resolve here once for both legs.
    wire [11:0] inw_e = (in_w_rt==12'd0) ? IN_W[11:0] : in_w_rt;
    wire [11:0] inh_e = (in_h_rt==12'd0) ? IN_H[11:0] : in_h_rt;

    // BITE 2: pincushion centre = output-raster centre (= the lens axis when corner-pin is identity).
    wire [11:0] outw_e = (out_w_rt==12'd0) ? OUT_W[11:0] : out_w_rt;
    wire [11:0] outh_e = (out_h_rt==12'd0) ? OUT_H[11:0] : out_h_rt;
    wire [11:0] pin_cx = outw_e >> 1;
    wire [11:0] pin_cy = outh_e >> 1;

    // ---- consumer: projective (CORNER-PIN, output->sheet) -> place (sheet->LOD) -> skid -> cache ----
    // u_aff_c walks the output raster and emits the full-Q SHEET coord (ca_sx/ca_sy) + sheet-in (ca_in).
    // u_place_c maps sheet->LOD and bounds BOTH spaces: cp_sheet_in (off=black), cp_lod_in (off=matte).
    wire        ca_v, ca_in, ca_nr; wire signed [AW-1:0] ca_sx, ca_sy;
    wire        cp_v, cp_sheet_in, cp_lod_in, cp_nr; wire [11:0] cp_col, cp_row, cp_fx, cp_fy;
    wire [7:0]  cp_alpha;                              // #48: LOD-content coverage for edge AA
    wire        cp_skid_sready;
    wire        cm_v; wire [56:0] cm_d;
    // pen depends only on the skid's (s_valid-independent) ready + place's own output reg -> no
    // combinational tready loop. Projective o_ready = same pen so the whole consumer chain moves as one.
    wire        cp_pen = cp_skid_sready || !cp_v;
    pg_projective #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.CW(CW),.FB(FB),
                    .GCW(GCW),.GFB(GFB),.RF(RF),.LUT_BITS(LUT_BITS),.NR_ITERS(NR_ITERS),
                    .AW(AW),.WW(WW),.PROJECTIVE(PROJECTIVE)) u_aff_c (
        .clk(clk),.rstn(rstn),.sof(sof),.in_w_rt(in_w_rt),.in_h_rt(in_h_rt),.out_w_rt(out_w_rt),.out_h_rt(out_h_rt),.o_valid(ca_v),.o_ready(cp_pen),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.m_g(m_g),.m_h(m_h),
        .o_in_window(ca_in),.o_src_col(),.o_src_row(),
        .o_h_frac(),.o_v_frac(),.o_new_row(ca_nr),
        .o_sheet_x(ca_sx),.o_sheet_y(ca_sy));
    // BITE 2: pincushion radial warp on the sheet coord (k_pin=0 -> transparent passthrough == Bite 1).
    wire        cw_v, cw_in, cw_nr; wire signed [AW-1:0] cw_sx, cw_sy;
    pg_pincushion #(.FB(FB),.AW(AW)) u_pin_c (
        .clk(clk),.rstn(rstn),.pen(cp_pen),
        .i_valid(ca_v),.i_sheet_x(ca_sx),.i_sheet_y(ca_sy),.i_sheet_in(ca_in),.i_new_row(ca_nr),
        .kx(kx),.ky(ky),.cx(pin_cx),.cy(pin_cy),
        .o_valid(cw_v),.o_sheet_x(cw_sx),.o_sheet_y(cw_sy),.o_sheet_in(cw_in),.o_new_row(cw_nr));
    pg_place_affine #(.CW(CW),.FB(FB),.AW(AW)) u_place_c (
        .clk(clk),.rstn(rstn),.pen(cp_pen),
        .i_valid(cw_v),.i_sheet_x(cw_sx),.i_sheet_y(cw_sy),.i_sheet_in(cw_in),.i_new_row(cw_nr),
        .a2(pa),.b2(pb),.c2(pc),.d2(pd),.e2(pe),.f2(pf),
        .in_w_rt(inw_e),.in_h_rt(inh_e),
        .o_valid(cp_v),.o_lod_col(cp_col),.o_lod_row(cp_row),
        .o_h_frac(cp_fx),.o_v_frac(cp_fy),
        .o_sheet_in(cp_sheet_in),.o_lod_in(cp_lod_in),.o_alpha(cp_alpha),.o_new_row(cp_nr));
    // #48 edge AA: skid carries {col,row,fx,fy, alpha[8], offsheet}. offsheet=~sheet_in -> black;
    // alpha (8-bit coverage) -> bilinear blends content<->matte (alpha 0=matte, 255=content).
    pg_skid #(.W(57)) u_skid_c (.clk(clk),.rstn(rstn),
        .s_valid(cp_v),.s_data({cp_col,cp_row,cp_fx,cp_fy,cp_alpha,~cp_sheet_in}),.s_ready(cp_skid_sready),
        .m_valid(cm_v),.m_data(cm_d),.m_ready(tc_ready));

    // ---- prefetch: same projective+place geometry, lead-bounded so eviction only hits consumed tiles --
    wire        pa_v, pa_in, pa_nr; wire signed [AW-1:0] pa_sx, pa_sy;
    wire        pp_v, pp_sheet_in, pp_lod_in; wire [11:0] pp_col, pp_row;
    wire        pp_skid_sready;
    wire        pm_v; wire [24:0] pm_d;
    reg  [19:0] lead_cnt; reg pf_acc_r, c_acc_r;            // 20-bit: lead can span a full frame
    // runtime per-geometry lead: firmware sets lead_rt from the affine (shallow for gentle rotation,
    // deep for downscale/steep). 0 -> fall back to the build-param LEAD (safe boot default).
    wire [19:0] lead_eff = (lead_rt==20'd0) ? LEAD[19:0] : lead_rt;
    // REGISTERED gate: the 20-bit compare (dynamic since lead_rt became a runtime GPIO) is now a reg-to-reg
    // path feeding a FF, NOT combinational into the prefetch chain's o_ready — keeps the runtime-LEAD
    // comparator out of (and its congestion away from) the marginal prefetch-issue cone. 1-cycle-stale gate
    // only shifts the coarse lead bound by ~1 (harmless; same rationale as pf_acc_r/c_acc_r below).
    reg pf_gate;
    always @(posedge clk) pf_gate <= (!rstn) ? 1'b1 : (lead_cnt < lead_eff);
    // register the accept events so the 16-bit counter add isn't fed by the live lookup (pf_ready).
    // 1-cycle-stale count only shifts the coarse lead bound by ~1 — harmless.
    always @(posedge clk) begin
        if(!rstn || sof) begin pf_acc_r<=1'b0; c_acc_r<=1'b0; lead_cnt<=20'd0; end
        else begin
            pf_acc_r <= pm_v && pf_ready; c_acc_r <= cm_v && tc_ready;
            lead_cnt <= lead_cnt + (pf_acc_r?20'd1:20'd0) - (c_acc_r?20'd1:20'd0);
        end
    end
    // PREFETCH uses IDENTICAL geometry (same params + coeffs incl. m_g/m_h AND placement pa..pf) as the
    // consumer so the tile set the prefetch warms is exactly the set the consumer gathers -> coherent.
    // pf_gate folds into pp_pen so a closed gate freezes the WHOLE prefetch chain (projective + place).
    wire        pp_pen = (pp_skid_sready || !pp_v) && pf_gate;
    pg_projective #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.CW(CW),.FB(FB),
                    .GCW(GCW),.GFB(GFB),.RF(RF),.LUT_BITS(LUT_BITS),.NR_ITERS(NR_ITERS),
                    .AW(AW),.WW(WW),.PROJECTIVE(PROJECTIVE)) u_aff_p (
        .clk(clk),.rstn(rstn),.sof(sof),.in_w_rt(in_w_rt),.in_h_rt(in_h_rt),.out_w_rt(out_w_rt),.out_h_rt(out_h_rt),.o_valid(pa_v),.o_ready(pp_pen),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.m_g(m_g),.m_h(m_h),
        .o_in_window(pa_in),.o_src_col(),.o_src_row(),
        .o_h_frac(),.o_v_frac(),.o_new_row(pa_nr),
        .o_sheet_x(pa_sx),.o_sheet_y(pa_sy));
    // BITE 2: SAME pincushion in the prefetch leg (identical latency + geometry -> cache stays coherent).
    wire        pw_v, pw_in, pw_nr; wire signed [AW-1:0] pw_sx, pw_sy;
    pg_pincushion #(.FB(FB),.AW(AW)) u_pin_p (
        .clk(clk),.rstn(rstn),.pen(pp_pen),
        .i_valid(pa_v),.i_sheet_x(pa_sx),.i_sheet_y(pa_sy),.i_sheet_in(pa_in),.i_new_row(pa_nr),
        .kx(kx),.ky(ky),.cx(pin_cx),.cy(pin_cy),
        .o_valid(pw_v),.o_sheet_x(pw_sx),.o_sheet_y(pw_sy),.o_sheet_in(pw_in),.o_new_row(pw_nr));
    pg_place_affine #(.CW(CW),.FB(FB),.AW(AW)) u_place_p (
        .clk(clk),.rstn(rstn),.pen(pp_pen),
        .i_valid(pw_v),.i_sheet_x(pw_sx),.i_sheet_y(pw_sy),.i_sheet_in(pw_in),.i_new_row(pw_nr),
        .a2(pa),.b2(pb),.c2(pc),.d2(pd),.e2(pe),.f2(pf),
        .in_w_rt(inw_e),.in_h_rt(inh_e),
        .o_valid(pp_v),.o_lod_col(pp_col),.o_lod_row(pp_row),
        .o_h_frac(),.o_v_frac(),
        .o_sheet_in(pp_sheet_in),.o_lod_in(pp_lod_in),.o_new_row());
    // only warm tiles that will be SAMPLED (on-content); matte/black pixels touch no LOD -> bit = lod_in.
    pg_skid #(.W(25)) u_skid_p (.clk(clk),.rstn(rstn),
        .s_valid(pp_v && pf_gate),.s_data({pp_col,pp_row,pp_lod_in}),.s_ready(pp_skid_sready),
        .m_valid(pm_v),.m_data(pm_d),.m_ready(pf_ready));

    // ---- tile cache. #48: c_inwin = sheet_in && alpha>0 (= the fetch/gather gate); c_sb carries the
    // 8-bit edge-AA alpha + the offsheet bit through the cache latency to the bilinear (SB=9). ----
    wire        tc_v; wire [23:0] tp00,tp10,tp01,tp11; wire [11:0] tfx,tfy; wire tin; wire [8:0] tsb;
    wire        c_inwin = (~cm_d[0]) && (|cm_d[8:1]);   // on-sheet AND any LOD coverage
    pg_tilecache_rt2 #(.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.WAY(WAY),.PD(PD),.SB(9)) u_tc (
        .clk(clk),.rstn(rstn),.in_w_rt(in_w_rt),.in_h_rt(in_h_rt),.hsel(hsel),
        .pf_valid(pm_v),.pf_x(pm_d[24:13]),.pf_y(pm_d[12:1]),.pf_inwin(pm_d[0]),.pf_ready(pf_ready),
        .c_valid(cm_v),.c_x(cm_d[56:45]),.c_y(cm_d[44:33]),.c_fx(cm_d[32:21]),.c_fy(cm_d[20:9]),.c_inwin(c_inwin),.c_sb({cm_d[8:1],cm_d[0]}),.c_ready(tc_ready),
        .out_valid(tc_v),.out_p00(tp00),.out_p10(tp10),.out_p01(tp01),.out_p11(tp11),
        .out_fx(tfx),.out_fy(tfy),.out_inwin(tin),.out_sb(tsb),.out_ready(b_ready),
        .fetch_req(fetch_req),.fetch_tx(fetch_tx),.fetch_ty(fetch_ty),.t_ready(fetch_ready),
        .fill_valid(fill_valid),.fill_blk(fill_blk),.fill_last(fill_last));

    function [7:0] lerp8; input [7:0] a,b; input [7:0] w;
        reg signed [19:0] d,p,r; begin d=$signed({1'b0,b})-$signed({1'b0,a});
            p=d*$signed({1'b0,w}); r=$signed({1'b0,a})+((p+20'sd128)>>>8); lerp8=r[7:0]; end
    endfunction
    function [23:0] lerp24; input [23:0] a,b; input [7:0] w;
        lerp24={lerp8(a[23:16],b[23:16],w),lerp8(a[15:8],b[15:8],w),lerp8(a[7:0],b[7:0],w)}; endfunction
    wire [7:0] wx=tfx[11:4], wy=tfy[11:4];

    // #48 EDGE-AA 3-stage bilinear: H (two row lerps) -> V (column lerp = content) -> M (matte blend).
    // M stage: off-sheet -> BLACK; else lerp24(matte, content, alpha) — alpha is the LOD-content coverage
    // so the matte/content edge ANTI-ALIASES over 1px. alpha==255 (the vast-majority interior) bypasses
    // the blend -> bit-EXACT content preserved (identity passthrough unchanged); only edge px (alpha<255)
    // blend. Splitting into 3 registered stages keeps each lerp24 off the others' critical path.
    reg        h_v, h_offsheet; reg [7:0] h_alpha, h_wy; reg [23:0] h_top, h_bot;
    reg        v_v, v_offsheet; reg [7:0] v_alpha; reg [23:0] v_content;
    reg        ov; reg [23:0] opix;
    wire       m_ready = !ov   || o_ready;
    wire       v_ready = !v_v  || m_ready;
    wire       h_ready = !h_v  || v_ready;
    wire       b_ready = h_ready;
    assign o_valid = ov; assign o_pix = opix;
    always @(posedge clk) begin
        if(!rstn) begin h_v<=1'b0; v_v<=1'b0; ov<=1'b0; end
        else begin
            if(ov && o_ready) ov<=1'b0;
            if(m_ready) begin
                ov<=v_v;
                opix <= v_offsheet ? 24'h000000
                        : (v_alpha==8'hFF) ? v_content
                        : lerp24(matte, v_content, v_alpha);
            end
            if(v_ready) begin
                v_v<=h_v; v_offsheet<=h_offsheet; v_alpha<=h_alpha;
                v_content<=lerp24(h_top,h_bot,h_wy);
            end
            if(h_ready) begin
                h_v<=tc_v; h_offsheet<=tsb[0]; h_alpha<=tsb[8:1]; h_wy<=wy;
                h_top<=lerp24(tp00,tp10,wx); h_bot<=lerp24(tp01,tp11,wx);
            end
        end
    end
endmodule

`default_nettype wire
