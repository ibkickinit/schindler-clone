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
    parameter integer TILED = 0,                  // 0=raster DDR source (legacy); 1=TILED DDR (1 burst/tile)
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
    input  wire [31:0] lead_cfg,          // runtime per-geometry prefetch LEAD (AXI GPIO, async; 0 -> build LEAD)
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
    output wire        s_axis_sts_tready,
    output wire [31:0] dbg                     // bring-up diag (routed to axi_gpio_2 readback)
);
    assign s_axis_sts_tready = 1'b1;          // drain status FIFO

    // ---- frame_ptr CDC + sof (vsync rising) + frame_base latch ----
    // s2mm_frame_ptr_out is GRAY-CODED (bench-confirmed 2026-06-03; see pg_genlock). It MUST be
    // gray2bin-decoded + debounced before the slot arithmetic — reading the Gray value as plain binary
    // (the old code did) gives wrong/out-of-range slots, so the warp periodically read garbage DDR ->
    // white/black frames beating at the source-vs-output rate diff (~2-3 Hz) AND intermittent black at boot.
    (* ASYNC_REG="TRUE" *) reg [5:0] fp_q1, fp_q2; reg [5:0] fp_q3, fp_stable;
    reg vs_d; wire sof = out_vsync & ~vs_d;
    reg [31:0] frame_base;
    function [5:0] gray2bin; input [5:0] g; begin
        gray2bin[5]=g[5];            gray2bin[4]=gray2bin[5]^g[4]; gray2bin[3]=gray2bin[4]^g[3];
        gray2bin[2]=gray2bin[3]^g[2]; gray2bin[1]=gray2bin[2]^g[1]; gray2bin[0]=gray2bin[1]^g[0];
    end endfunction
    wire [5:0] fp_bin  = gray2bin(fp_stable) % NUM_FRAMES[5:0];      // settled write slot (binary)
    wire [5:0] rd_slot = (fp_bin==6'd0) ? (NUM_FRAMES[5:0]-6'd1) : (fp_bin-6'd1);  // completed = ptr-1
    always @(posedge clk) begin
        if(!rstn) begin fp_q1<=0; fp_q2<=0; fp_q3<=0; fp_stable<=0; vs_d<=0; frame_base<=FRAME_BUF_BASE; end
        else begin
            fp_q1<=frame_ptr; fp_q2<=fp_q1; fp_q3<=fp_q2; vs_d<=out_vsync;
            if(fp_q2==fp_q3) fp_stable<=fp_q2;     // accept only a SETTLED value (debounce)
            if(sof) frame_base <= FRAME_BUF_BASE + rd_slot * SLOT_STRIDE;
        end
    end

    // ---- coeff CDC (quasi-static; pg_affine re-latches at sof) ----
    (* ASYNC_REG="TRUE" *) reg signed [CW-1:0] a1,b1,c1,d1,e1,f1, a2,b2,c2,d2,e2,f2;
    (* ASYNC_REG="TRUE" *) reg [23:0] mt1, mt2;
    // runtime LEAD CDC (quasi-static GPIO; firmware writes the per-geometry lead at sof-far). 2-FF sync;
    // lr1's D is false-pathed in the XDC (same as the coeff CDC). 0 -> engine falls back to build LEAD.
    // lead_cfg[19:0]=LEAD, [23:20]=dbg_sel (read-only telemetry view select, quasi-static).
    (* ASYNC_REG="TRUE" *) reg [19:0] lr1, lr2;
    (* ASYNC_REG="TRUE" *) reg [3:0]  dsel1, dsel2;
    // lead_cfg[31] = SOFT-RESET request (firmware pulses it on a geometry change). 2-FF synced -> srst.
    // engine_rstn resets the affines+cache+consumer; u_dma gets srst (resets + FLUSHes the DataMover); the
    // cmd formatter + output FIFO reset too. The DataMover is NOT reset (its in-flight beats are DRAINED by
    // the flush) so HP1 never hangs. This makes a live rotation change clean (no transition wedge).
    (* ASYNC_REG="TRUE" *) reg sr1, srst;
    wire engine_rstn = rstn & ~srst;
    always @(posedge clk) begin
        a1<=m_a;b1<=m_b;c1<=m_c;d1<=m_d;e1<=m_e;f1<=m_f; mt1<=matte_rgb;
        a2<=a1;b2<=b1;c2<=c1;d2<=d1;e2<=e1;f2<=f1; mt2<=mt1;
        lr1<=lead_cfg[19:0]; lr2<=lr1;
        dsel1<=lead_cfg[23:20]; dsel2<=dsel1;
        sr1<=lead_cfg[31]; srst<=sr1;
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
        .clk(clk),.rstn(engine_rstn),.sof(sof),.lead_rt(lr2),  // engine_rstn includes the soft-reset
        .m_a(a2),.m_b(b2),.m_c(c2),.m_d(d2),.m_e(e2),.m_f(f2),.matte(mt2),
        .o_valid(o_valid),.o_pix(o_pix),.o_ready(o_ready),
        .fetch_req(wreq),.fetch_tx(wtx),.fetch_ty(wty),.fetch_ready(t_rdy),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl));

    pg_tile_dma #(.IN_W(IN_W),.LTILE(LTILE),.TILED(TILED),.DREQ(DREQ)) u_dma (
        .clk(clk),.rstn(rstn),.srst(srst),.frame_base(frame_base),
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
        if(!rstn || srst) begin cmd_valid<=1'b0; cmd_data<=72'd0; end
        else begin
            if(cmd_valid && m_axis_cmd_tready) cmd_valid<=1'b0;
            if(fetch_req && !cmd_valid) begin
                cmd_data <= {4'd0,4'd0, fetch_addr, 1'b0,1'b1,6'd0,1'b1, btt};
                cmd_valid<=1'b1;
            end
        end
    end

    // ---- output LINE-FIFO + AXIS framing (TUSER=SOF, TLAST=EOL every OUT_W) ----
    // The engine's o_ready was tied to m_axis_tready, which axis_to_vid_io only opens during active-video /
    // its bounded blanking-flush. So the engine couldn't RUN AHEAD during vblank and its SOF (pixel 0)
    // arrived LATE -> axis_to_vid_io anchored it past pixel 0 -> per-line wrap = the diagonal SHEAR
    // (DIAG showed DRAIN delta_px huge, bflush saturated). FIX: a FIFO with o_ready=!full decouples the
    // engine from tready so it fills during blanking and delivers the SOF beat EARLY; the SOF tag rides the
    // FIFO and tlast is regenerated on drain. Engine emits exactly OUT_W*OUT_H/frame (counters verify).
    localparam integer OFD = 2048;                          // ~1.6 lines @720p; infers BRAM
    (* ram_style="block" *) reg [24:0] ofifo[0:OFD-1];      // {sof_tag, pix[23:0]}
    reg [10:0] of_wr, of_rd; reg [11:0] of_cnt;
    wire of_full  = (of_cnt >= OFD[11:0]-12'd4);
    wire of_empty = (of_cnt == 12'd0);
    reg  fr_first;                                          // SOF tag for the next engine pixel
    wire ow_en = o_valid && !of_full;                      // engine write accepted into the FIFO
    assign o_ready = !of_full;
    reg [24:0] of_q; reg of_qv; reg [11:0] dcol;            // 1-deep output holding reg + drain column
    wire od_rd = !of_empty && (!of_qv || m_axis_tready);   // pop FIFO when the holding reg is free/freeing
    // effective column of the beat in of_q: a SOF-tagged beat (of_q[24]) is frame pixel 0 -> RE-SYNCs the
    // per-line counter (so a count drift can't accumulate a shear). dcol/tlast use the REGISTERED of_q tag,
    // never a combinational BRAM read.
    wire [11:0] ecol = of_q[24] ? 12'd0 : dcol;
    assign m_axis_tvalid = of_qv;
    assign m_axis_tdata  = of_q[23:0];
    assign m_axis_tuser  = of_qv && of_q[24];              // SOF anchor for axis_to_vid_io
    assign m_axis_tlast  = of_qv && (ecol == OUT_W[11:0]-12'd1);
    always @(posedge clk) begin
        if(!rstn || srst) begin of_wr<=0; of_rd<=0; of_cnt<=0; fr_first<=1'b1; of_qv<=1'b0; dcol<=12'd0; end
        else begin
            if(sof) fr_first<=1'b1;
            if(ow_en) begin ofifo[of_wr] <= {fr_first, o_pix}; of_wr<=of_wr+1'b1; fr_first<=1'b0; end
            if(of_qv && m_axis_tready) dcol <= (ecol==OUT_W[11:0]-12'd1) ? 12'd0 : ecol+12'd1;  // next col
            if(of_qv && m_axis_tready) of_qv<=1'b0;
            if(od_rd) begin of_q <= ofifo[of_rd]; of_rd<=of_rd+1'b1; of_qv<=1'b1; end
            of_cnt <= of_cnt + (ow_en?12'd1:12'd0) - (od_rd?12'd1:12'd0);
        end
    end
    // ---- per-frame OUTPUT measurement (warp-specific; the DIAG v_emit/v_out_tlast are scaler-based, dead
    // in the warp build): opix should be OUT_W*OUT_H=921600, eol should be OUT_H=720, und = output-starved
    // cycles (m_axis_tready & !tvalid). Latched at sof, read via dbg views 6/7/8. ----
    reg [19:0] opix_cnt, opix_lat, und_cnt, und_lat; reg [11:0] eol_cnt, eol_lat;
    always @(posedge clk) begin
        if(!rstn) begin opix_cnt<=0; opix_lat<=0; eol_cnt<=0; eol_lat<=0; und_cnt<=0; und_lat<=0; end
        else if(sof) begin
            opix_lat<=opix_cnt; opix_cnt<= ow_en?20'd1:20'd0;
            eol_lat<=eol_cnt;  eol_cnt<=0;
            und_lat<=und_cnt;  und_cnt<=0;
        end else begin
            if(ow_en) opix_cnt<=opix_cnt+20'd1;
            if(m_axis_tvalid && m_axis_tready && m_axis_tlast) eol_cnt<=eol_cnt+12'd1;
            if(m_axis_tready && !m_axis_tvalid) und_cnt<=und_cnt+20'd1;
        end
    end
    // ---- bring-up diagnostic v2: the warp PRODUCES pixels (v1 showed fetch/fill/ovalid all active).
    // Now distinguish: full-frame-real-pixels (=> output framing/WRAP bug) vs stall (=> cache) vs
    // black pixels (=> fill-data bug). lines_per_frame = EOL count in the last frame (720 = full,
    // <720 = stalls); opix_nz = ever saw a non-black engine output pixel; free-running fill/fetch
    // low bits so a firmware double-read shows ongoing activity.
    // v3: classify the post-stall deadlock. stall_oc = free-running count of cycles where the output is
    // READY but the warp has NO pixel (o_ready && !o_valid) -> if it grows, the warp is cache/DMA-bound
    // (downstream waiting on us). o_rdy_live = is the output even pulling? If o_ready stays 0 -> the
    // deadlock is OUTPUT-side (axis_to_vid_io framing/blanking-flush stopped pulling -> backpressure).
    // v4: probe the DataMover handshake at the pg_warp_top boundary. v3 showed cache/DMA-bound +
    // fill_fr frozen + cmd_valid=0 -> the DataMover accepted the commands but returns no data (IP stall?).
    // beat_cnt/cmd_acc free-running (firmware double-read shows frozen). Live flags localize the stall:
    //   cmd_rdy=0 -> DataMover not accepting commands; dm_tvalid=0 + dm_tready=1 -> DataMover not returning
    //   data while we wait; sts_tv -> status flowing.  m_axis_cmd_tready / s_axis_dm_* are module pins.
    // STICKY PIPELINE-CHAIN telemetry (warp-bring-up v5): the engine works in sim but the consumer
    // produces NO output on silicon (o_valid=0, full black). To localize WHERE the chain breaks, latch a
    // sticky "ever happened" bit at each stage (hierarchical read-only taps — registered, so no combinational
    // load on the timing-critical gather). Read order tells the story: dmv->fill->resident->cmv->call->
    // gather->ovalid. e.g. resident=1 but call=0 => the consumer never SEES tiles resident (replica /
    // set-or-tag mismatch); resident=0 => fills never complete (DMA/tile_dma); call=1 ov=0 => bilinear/out.
    wire h_call    = u_eng.u_tc.c_all;          // consumer gather found all 4 neighbour tiles (a hit)
    wire h_fillpop = u_eng.u_tc.fill_pop;       // a tile fill completed -> tile became resident (vld<=1)
    wire h_cmv     = u_eng.cm_v;                // consumer coord stream valid into the cache
    wire h_gather  = u_eng.u_tc.out_valid;      // gather produced a result downstream of the cache
    reg st_dmv, st_fill, st_resident, st_cmv, st_call, st_gather, st_ovalid, st_sts;
    reg [15:0] beat_cnt;
    always @(posedge clk) begin
        if(!rstn) begin
            st_dmv<=0; st_fill<=0; st_resident<=0; st_cmv<=0; st_call<=0; st_gather<=0; st_ovalid<=0; st_sts<=0;
            beat_cnt<=0;
        end else begin
            if(s_axis_dm_tvalid)                     st_dmv<=1'b1;       // DataMover ever returned a beat
            if(fv)                                   st_fill<=1'b1;      // tile_dma ever emitted a fill block
            if(h_fillpop)                            st_resident<=1'b1;  // a tile ever became resident
            if(h_cmv)                                st_cmv<=1'b1;       // consumer affine ever produced a coord
            if(h_call)                               st_call<=1'b1;      // consumer ever found all-4-resident
            if(h_gather)                             st_gather<=1'b1;    // gather ever produced
            if(o_valid)                              st_ovalid<=1'b1;    // output ever valid
            if(s_axis_sts_tvalid)                    st_sts<=1'b1;       // DataMover ever posted a status
            if(s_axis_dm_tvalid && s_axis_dm_tready) beat_cnt <= beat_cnt + 16'd1;
        end
    end
    // DEEP WEDGE-STATE telemetry: dbg[15:0] is a SELECTABLE view (dbg_sel = lead_cfg[23:20]) of the
    // tile_dma + cache internals, so the post-wedge readback shows EXACTLY where it's stuck. Hierarchical
    // read-only taps (u_dma at this level; u_eng.u_tc.* one deeper). Firmware sweeps dsel and prints all.
    //   0: beat_cnt[15:0]                          (beats received; frozen => DMA idle)
    //   1: {rx_left[7:0], nbits[7:0]}              (tiles issued-not-received ; receiver accumulator)
    //   2: {pf_cnt[7:0], rq_cnt[7:0]}              (cache pending-fills ; tile_dma request queue)
    //   3: lead_cnt[15:0]                          (prefetch run-ahead; ==LEAD => prefetch gated)
    //   4: state flags {rx_act,iss_act,full1,full0,emit_act,fetch_req_tc,pf_full_tc,c_busy, 8'b0}
    //   5: {fetch_tx_tc[7:0], fetch_ty_tc[7:0]}    (tile the prefetch is trying to fetch when stuck)
    wire        tc_fetch_req = u_eng.u_tc.fetch_req;
    wire        tc_pf_full   = u_eng.u_tc.pf_full;
    reg [15:0]  dbg_lo;
    always @* begin
        case(dsel2)
            4'd1: dbg_lo = {u_dma.rx_left[7:0], u_dma.nbits[7:0]};
            4'd2: dbg_lo = {1'b0, u_eng.u_tc.pf_cnt[6:0], 1'b0, u_dma.rq_cnt[6:0]};
            4'd3: dbg_lo = u_eng.lead_cnt[15:0];
            4'd4: dbg_lo = {u_dma.rx_act, u_dma.iss_act, u_dma.full[1], u_dma.full[0], u_dma.emit_act,
                            tc_fetch_req, tc_pf_full, u_eng.u_tc.c_busy, 8'b0};
            4'd5: dbg_lo = {u_eng.u_tc.fetch_tx[7:0], u_eng.u_tc.fetch_ty[7:0]};
            4'd6: dbg_lo = opix_lat[15:0];                       // output pixels/frame low (expect 0xE1000)
            4'd7: dbg_lo = {eol_lat[11:0], opix_lat[19:16]};     // EOL/frame (expect 720) + opix high nibble
            4'd8: dbg_lo = und_lat[15:0];                        // output-starved cycles/frame
            default: dbg_lo = beat_cnt;
        endcase
    end
    // dbg[31:24]=sticky chain  [23:16]=live flags  [15:0]=selected deep view.
    // REGISTERED in pclk so the deep-tap mux (signals from all over u_tc) is a pclk-internal path, NOT a long
    // combinational route into the FCLK_CLK0 GPIO-input sampler. dbg_r_reg/C is false-pathed in the XDC
    // (quasi-static readback; coherent because the values are FROZEN at the wedge we read).
    reg [31:0] dbg_r;
    always @(posedge clk) dbg_r <= { st_sts, st_ovalid, st_gather, st_call, st_cmv, st_resident, st_fill, st_dmv,
                   o_ready, o_valid, s_axis_dm_tvalid, s_axis_dm_tready, m_axis_cmd_tvalid, m_axis_cmd_tready, h_call, h_cmv,
                   dbg_lo };
    assign dbg = dbg_r;
endmodule

`default_nettype wire
