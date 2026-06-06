// pg_compose.v — present-geometry compositor / read-engine core (read-engine-B, M4).
//
// Ties the verified pieces into the full route-B read-engine:
//   pg_addrgen (M1)  → per output pixel: in_window? + master src_col/src_row
//   pg_linefetch (M3)→ DDR line fetch + 2-line ping-pong buffer
//   this module      → output-raster walk, prefetch scheduling, residency-stall
//                      compositor, matte/window mux, and the AXIS output stream
//                      that axis_to_vid_io pulls.
//
// Pipeline / backpressure:
//   addrgen emits a 1-cycle-valid pixel descriptor and cannot be back-pressured,
//   so its output is captured into a small SKID FIFO. A stallable consumer reads
//   the skid head, looks up the master pixel in pg_linefetch, and pushes to the
//   output FIFO. If the head is an in-window pixel whose source line is NOT yet
//   resident, the consumer STALLS (and the skid fills, freezing addrgen) until
//   prefetch lands — so a non-resident line is never emitted as garbage. The
//   output FIFO decouples the consumer from the AXIS sink (axis_to_vid_io,
//   tready=active_video); during blanking it primes so active video never starves.
//
// Prefetch contract (keep pg_linefetch 1 window-row ahead of production):
//   - At SOF prime window rows 0,1 during vblank.
//   - Thereafter prefetch window-row k while k <= (#window rows started)+1.
//   A vertical DDA computes each window row's master src row identically to
//   pg_addrgen's vertical map.
//
// frame_base_addr comes from pg_genlock (frame-stable, completed slot).

`default_nettype none
`timescale 1ns / 1ps

module pg_compose #(
    parameter integer OUT_W = 1280,
    parameter integer OUT_H = 720,
    parameter integer IN_W  = 1280,
    parameter integer IN_H  = 720,
    parameter integer STRIDE = 3840,
    parameter integer FIFO_DEPTH = 16,
    parameter integer NBUF = 4          // line-buffer ring depth (see pg_linefetch)
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire        vtg_vsync,        // output frame sync (level; rising = SOF)
    input  wire [31:0] frame_base_addr,  // from pg_cadence: slot S (frame A, older)

    // Mackin blend (task #103): blend partner + weight from pg_cadence. Latched at
    // SOF (frame-atomic). blend_en=0 → single-fetch, exact build #23 behaviour.
    input  wire [31:0] frame_base_addr2, // slot S+1 (frame B, newer)
    input  wire [7:0]  blend_alpha,      // cadence alpha (8-bit, 0..255)
    input  wire        blend_en,         // 1 = Mackin blend this frame

    input  wire [11:0] out_w_win, out_h_win, pos_x, pos_y,   // pos SIGNED (image may go off-screen)
    input  wire [11:0] src_col0, src_row0,   // DDA seed: source col/row at the first on-screen in-window pixel
    input  wire [11:0] h_step_int, h_step_frac, v_step_int, v_step_frac,
    input  wire [23:0] matte_rgb,
    input  wire [1:0]  filt_mode,     // #107: 0=NN 1=2-tap box 2=H-bilinear 3=H+V-bilinear
    input  wire [15:0] inv_w,         // #107: Q0.16 reciprocal of out_w_win (firmware) → bilinear H weight
    input  wire        h_dir,         // 1 = horizontal flip (addrgen runs H DDA backward)
    input  wire        v_dir,         // 1 = vertical flip (addrgen + prefetch run V DDA backward)

    output wire [23:0] m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tuser,          // SOF: asserted on the frame's first pixel
    output wire        m_tlast,          // EOL: asserted on each output row's last pixel

    output wire        fetch_req,
    output wire [31:0] fetch_addr,
    output wire [11:0] fetch_len,
    // packed-beat fill (64-bit DataMover beats; pg_unpack removed from datapath)
    input  wire [63:0] beat_data,
    input  wire        beat_valid,
    output wire        beat_ready,
    input  wire        beat_last,

    // ---- debug taps (ILA) ----
    output wire [11:0] dbg_src_col,   // pg_addrgen o_src_col
    output wire [11:0] dbg_src_row,   // pg_addrgen o_src_row
    output wire        dbg_a_valid,   // pg_addrgen o_valid
    output wire        dbg_a_inwin,   // pg_addrgen o_in_window
    output wire        dbg_a_newrow,  // pg_addrgen o_new_row
    output wire        dbg_resident,  // line-buffer rd_resident for the skid head
    output wire [23:0] dbg_rd_data,   // line-buffer rd_data for the skid head
    // ---- prefetch-state taps (ILA, build #14) ----
    output wire [11:0] dbg_rd_row,    // skid head src_row = the row being READ
    output wire [11:0] dbg_pf_src,    // prefetch current src row
    output wire [11:0] dbg_pf_next_k, // prefetch window-row index
    output wire [11:0] dbg_served,    // served_count (window rows entered)
    output wire        dbg_m3_busy,   // fetch in progress
    output wire        dbg_pf_req,    // prefetch request pulse
    output wire        dbg_push_en,   // pixel actually pushed to output FIFO
    output wire [23:0] dbg_push_data, // the actually-pushed pixel
    output wire [3:0]  dbg_fill_sel,  // pg_linefetch round-robin fill buffer
    output wire [3:0]  dbg_rd_sel,    // pg_linefetch read buffer select
    output wire        dbg_have_row   // pg_linefetch: pf_row already resident
);
    // ---------- SOF edge + frame-atomic geometry latch ----------
    reg vs_q;
    always @(posedge clk) vs_q <= (!rstn) ? 1'b0 : vtg_vsync;
    wire sof = vtg_vsync & ~vs_q;

    // Ring flush on a vertical-flip toggle: v_dir changes the row FETCH ORDER, which
    // desyncs the line-ring's cross-frame have_row skip vs the round-robin recycle.
    // Pulse a flush at the first SOF after v_dir changes so the ring re-fetches fresh.
    reg vd_prev = 1'b0;
    wire ring_flush = sof && (v_dir != vd_prev);
    always @(posedge clk) if (sof) vd_prev <= v_dir;

    reg [11:0] win_h_l, vsi_l, vsf_l;
    reg [23:0] matte_l;
    reg [31:0] base2_l;     // frame B base (frame-atomic)
    reg [7:0]  alpha_l;     // cadence alpha (frame-atomic)
    reg        blend_l;     // blend enable (frame-atomic)
    reg        vd_l;        // vertical-flip dir (frame-atomic) — prefetch V DDA runs backward
    always @(posedge clk) if (sof) begin
        win_h_l <= out_h_win; vsi_l <= v_step_int; vsf_l <= v_step_frac; matte_l <= matte_rgb;
        base2_l <= frame_base_addr2; alpha_l <= blend_alpha; blend_l <= blend_en; vd_l <= v_dir;
    end
    // alpha 8-bit -> Q1.15 (0..~0x7FFF ≈ 1.0): {alpha,alpha[6:0]} = alpha<<7 | alpha[6:0]
    wire [15:0] alpha_q15 = {1'b0, alpha_l, alpha_l[6:0]};
    wire signed [16:0] aq = $signed({1'b0, alpha_q15});   // positive
    // final clamp for the Mackin lerp (see 3-stage pipeline in the consumer)
    function [7:0] clamp8; input signed [27:0] v;
        clamp8 = (v < 0) ? 8'd0 : (v > 28'sd255) ? 8'd255 : v[7:0];
    endfunction

    // ---------- output FIFO ----------
    // Each slot carries the pixel plus its frame-framing side-band:
    //   [25] = EOL (tlast, last pixel of an output row)
    //   [24] = SOF (tuser, first pixel of the frame)
    //   [23:0] = pixel data
    localparam integer AW = $clog2(FIFO_DEPTH);
    reg  [25:0] ofifo [0:FIFO_DEPTH-1];
    reg  [AW:0] ocount;
    reg  [AW-1:0] owr, ord;
    wire ofull  = (ocount == FIFO_DEPTH[AW:0]);
    wire oempty = (ocount == 0);
    wire ospace = (ocount < (FIFO_DEPTH-6));   // reserve 6: C1 + stage R (#107) + 3-stage blend in flight

    // ---------- skid FIFO at addrgen output (absorbs addrgen's 1-cyc latency) ----------
    localparam integer SK = 8, SKW = 3;
    reg  [33:0] skid [0:SK-1];     // {fw[7:0], new_row, inwin, src_row[11:0], src_col[11:0]}  (#107: precomputed Q0.8 H weight)
    reg  [SKW:0] scount;
    reg  [SKW-1:0] swr, srd;
    wire sfull  = (scount == SK[SKW:0]);
    wire sempty = (scount == 0);
    wire sspace = (scount < (SK-3));   // leave room for addrgen in-flight

    // ---------- frame walk gating ----------
    reg [21:0] produced;
    wire frame_active = (produced < OUT_W*OUT_H);
    wire gen_en = frame_active && sspace;

    // ---------- M1: address generator ----------
    wire        a_valid, a_inwin, a_newrow;
    wire [11:0] a_src_col, a_src_row, a_h_frac, a_v_frac;
    pg_addrgen #(.OUT_W(OUT_W), .OUT_H(OUT_H), .IN_W(IN_W), .IN_H(IN_H)) u_addr (
        .clk(clk), .rstn(rstn), .sof(sof), .px_valid(gen_en),
        .out_w_win(out_w_win), .out_h_win(out_h_win), .pos_x(pos_x), .pos_y(pos_y),
        .src_col0(src_col0), .src_row0(src_row0), .h_dir(h_dir), .v_dir(v_dir),
        .h_step_int(h_step_int), .h_step_frac(h_step_frac),
        .v_step_int(v_step_int), .v_step_frac(v_step_frac),
        .o_valid(a_valid), .o_in_window(a_inwin),
        .o_src_col(a_src_col), .o_src_row(a_src_row),
        .o_h_frac(a_h_frac), .o_v_frac(a_v_frac),
        .o_new_row(a_newrow)
    );
    always @(posedge clk) begin
        if (!rstn || sof) produced <= 22'd0;
        else if (a_valid) produced <= produced + 22'd1;
    end

    // ---------- skid push (from addrgen) ----------
    // #107: precompute the Q0.8 bilinear weight HERE (one multiply, registered into the skid)
    // so the live blend path carries only the lerp — keeps timing closure (the fw multiply +
    // lerp combinational together blew WNS -7.8).  fw = (h_frac/win_w) via firmware Q0.16 inv_w.
    wire [27:0] fwprod_p = a_h_frac * inv_w;
    wire [7:0]  fw_push   = fwprod_p[16] ? 8'd255 : fwprod_p[15:8];
    always @(posedge clk) begin
        if (!rstn || sof) begin swr <= 0; end
        else if (a_valid && !sfull) begin
            skid[swr] <= {fw_push, a_newrow, a_inwin, a_src_row, a_src_col};
            swr <= swr + 1'b1;
        end
    end

    // ---------- M3: line fetch + double buffer ----------
    reg         pf_req_r;
    reg  [11:0] pf_row_r;
    wire [23:0] m3_rd_data, m3_rd_data2, m3_rd_data_h1, m3_rd_data2_h1;
    wire        m3_resident, m3_busy;

    // 2-tap horizontal box: rounded average of a pixel and its rd_col+1 neighbour.
    function [7:0] avg8; input [7:0] a,b; reg [8:0] s; begin s = a + b + 9'd1; avg8 = s[8:1]; end endfunction
    function [23:0] avg2; input [23:0] a,b;
        avg2 = { avg8(a[23:16],b[23:16]), avg8(a[15:8],b[15:8]), avg8(a[7:0],b[7:0]) };
    endfunction
    // #107 H-bilinear lerp: out = clamp( a + ((b-a)*fw + 128) >>> 8 ), fw = Q0.8 weight (0..255).
    // Bit-identical to the unsigned reference (a*(256-fw)+b*fw+128)>>8 — see TB golden.
    function [7:0] lerp8; input [7:0] a,b; input [7:0] fw;
        reg signed [19:0] d, p, sh, r;
        begin
            d  = $signed({1'b0,b}) - $signed({1'b0,a});   // b - a
            p  = d * $signed({1'b0,fw});                  // (b-a)*fw
            sh = (p + 20'sd128) >>> 8;                     // round + arithmetic shift
            r  = $signed({1'b0,a}) + sh;                   // a + delta
            // Interpolating two [0,255] values (fw≤255) always lands in [0,255] → no clamp needed
            // (the compare+mux tail was the last 56 ps of WNS). r is provably in range.
            lerp8 = r[7:0];
        end
    endfunction
    function [23:0] lerp24; input [23:0] a,b; input [7:0] fw;
        lerp24 = { lerp8(a[23:16],b[23:16],fw), lerp8(a[15:8],b[15:8],fw), lerp8(a[7:0],b[7:0],fw) };
    endfunction
    // H weight (Q0.8) precomputed at skid-push, latched at pop.
    reg  [7:0]  c1_fw;
    // Stage R0 registers (assigned after the c1 pop): raw taps + weight + carries. m3_rd_data
    // carries linefetch-combinational depth, so register the taps HERE → the lerp (stage R)
    // then starts from registers and fits one clock.
    reg  [7:0]  t_fw; reg t_v, t_in; reg [23:0] t_matte, t_rd, t_rd_h1, t_rd2, t_rd2_h1;
    // filtered source samples off the REGISTERED taps (filt_mode==0 → exact NN, zero regression)
    wire [23:0] A_in = (filt_mode==2'd0) ? t_rd
                     : (filt_mode==2'd1) ? avg2  (t_rd,  t_rd_h1)
                     :                     lerp24(t_rd,  t_rd_h1, t_fw);
    wire [23:0] B_in = (filt_mode==2'd0) ? t_rd2
                     : (filt_mode==2'd1) ? avg2  (t_rd2, t_rd2_h1)
                     :                     lerp24(t_rd2, t_rd2_h1, t_fw);

    // skid head descriptor
    wire        h_new   = skid[srd][25];
    wire        h_inwin = skid[srd][24];
    wire [11:0] h_srow  = skid[srd][23:12];
    wire [11:0] h_scol  = skid[srd][11:0];
    wire [7:0]  h_fw    = skid[srd][33:26];   // #107: this pixel's precomputed Q0.8 bilinear weight

    pg_linefetch #(.LINE_W(IN_W), .STRIDE(STRIDE), .NBUF(NBUF)) u_fetch (
        .clk(clk), .rstn(rstn),
        .frame_base_addr(frame_base_addr), .frame_base_addr2(base2_l), .blend_en(blend_l),
        .pf_req(pf_req_r), .pf_row(pf_row_r), .flush(ring_flush),
        .rd_row(h_srow), .rd_col(h_scol),       // read keyed on skid head
        .rd_data(m3_rd_data), .rd_data2(m3_rd_data2),
        .rd_data_h1(m3_rd_data_h1), .rd_data2_h1(m3_rd_data2_h1), .rd_resident(m3_resident),
        .dbg_fill_sel(dbg_fill_sel), .dbg_rd_sel(dbg_rd_sel), .dbg_have_row(dbg_have_row),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr), .fetch_len(fetch_len),
        .beat_data(beat_data), .beat_valid(beat_valid), .beat_ready(beat_ready), .beat_last(beat_last),
        .busy(m3_busy)
    );

    // ---------- stallable consumer: skid head → (M3 read, 1cy) → output FIFO ----------
    // Stage C0: if head servable (matte OR resident) and output FIFO has space,
    //           present rd (already wired), pop skid, launch into C1.
    // Stage C1: m3_rd_data is now valid for that pixel → push to output FIFO.
    wire head_servable = !sempty && ospace && (!h_inwin || m3_resident);
    // C1: pop skid head. rd_data (A) + rd_data2 (B) are valid the cycle c1_valid is high.
    reg        c1_valid, c1_inwin;
    reg [23:0] c1_matte;
    always @(posedge clk) begin
        if (!rstn || sof) begin srd <= 0; c1_valid <= 1'b0; end
        else begin
            c1_valid <= 1'b0;
            if (head_servable) begin
                c1_valid <= 1'b1;
                c1_inwin <= h_inwin;
                c1_matte <= matte_l;
                c1_fw <= h_fw;                // #107: ride the precomputed weight with rd_data to c1_valid
                srd <= srd + 1'b1;            // pop head
            end
        end
    end
    // ---- 3-stage Mackin blend pipeline ----
    // Single-cycle lerp failed timing (WNS -3.5 @ 74.25 MHz on the -1 part: the
    // multiply+shift+clamp chain into one register). Split like mackin_blender:
    //   S1: diff = B - A per channel (signed). carry A, matte, inwin, valid.
    //   S2: prod = alpha * diff per channel (the DSP). carry A, matte, inwin, valid.
    //   S3: res = A + ((prod+0x4000)>>>15), clamp; select blend / A(drop-repeat) / matte.
    // alpha_q15 + blend_l are frame-constant (used directly, not pipelined). Functionally
    // identical to the gate-validated lerp; just pipelined. push lands 3 cyc after C1
    // (order-preserving → SOF/EOL bookkeeping below unaffected; ospace reserves the depth).
    // ---- Stage R0 (#107): register the raw taps + weight + carries (1 cyc after c1_valid),
    // so the lerp (stage R) below starts from registers (m3_rd_data has linefetch combinational depth). ----
    always @(posedge clk) begin
        if (!rstn || sof) t_v <= 1'b0;
        else begin
            t_v <= c1_valid; t_in <= c1_inwin; t_matte <= c1_matte; t_fw <= c1_fw;
            t_rd <= m3_rd_data; t_rd_h1 <= m3_rd_data_h1; t_rd2 <= m3_rd_data2; t_rd2_h1 <= m3_rd_data2_h1;
        end
    end
    // ---- Stage R (#107): register the H-resampled A/B samples (the lerp output) before the
    // Mackin S1 diff. Each boundary (R0→R lerp, R→S1 diff) is now one multiply. Framing is
    // push-time (latency-independent), so the two extra stages only need +2 ospace reserve. ----
    reg        r_v, r_in;
    reg [23:0] r_matte, r_A, r_B;
    always @(posedge clk) begin
        if (!rstn || sof) r_v <= 1'b0;
        else begin r_v <= t_v; r_in <= t_in; r_matte <= t_matte; r_A <= A_in; r_B <= B_in; end
    end
    reg               s1_v, s1_in, s2_v, s2_in, s3_v;
    reg [23:0]        s1_matte, s1_A, s2_matte, s2_A, s3_data;
    reg signed [10:0] s1_dR, s1_dB, s1_dG;
    reg signed [27:0] s2_pR, s2_pB, s2_pG;
    always @(posedge clk) begin
        if (!rstn || sof) begin s1_v<=1'b0; s2_v<=1'b0; s3_v<=1'b0; end
        else begin
            // S1: per-channel diff (B - A), on the stage-R resampled samples.
            s1_v <= r_v; s1_in <= r_in; s1_matte <= r_matte; s1_A <= r_A;
            s1_dR <= $signed({3'b0,r_B[23:16]}) - $signed({3'b0,r_A[23:16]});
            s1_dB <= $signed({3'b0,r_B[15:8]})  - $signed({3'b0,r_A[15:8]});
            s1_dG <= $signed({3'b0,r_B[7:0]})   - $signed({3'b0,r_A[7:0]});
            // S2: alpha * diff (DSP)
            s2_v <= s1_v; s2_in <= s1_in; s2_matte <= s1_matte; s2_A <= s1_A;
            s2_pR <= aq * s1_dR; s2_pB <= aq * s1_dB; s2_pG <= aq * s1_dG;
            // S3: A + rounded shift, clamp; mux blend / drop-repeat / matte
            s3_v <= s2_v;
            s3_data <= s2_in ? (blend_l ?
                { clamp8($signed({20'd0,s2_A[23:16]}) + ((s2_pR + 28'sd16384) >>> 15)),
                  clamp8($signed({20'd0,s2_A[15:8]})  + ((s2_pB + 28'sd16384) >>> 15)),
                  clamp8($signed({20'd0,s2_A[7:0]})   + ((s2_pG + 28'sd16384) >>> 15)) }
                : s2_A) : s2_matte;
        end
    end
    wire [23:0] push_data = s3_data;
    wire        push_en   = s3_v;

    // ---------- skid count bookkeeping ----------
    wire sk_push = a_valid && !sfull;
    wire sk_pop  = head_servable;
    always @(posedge clk) begin
        if (!rstn || sof) scount <= 0;
        else case ({sk_push, sk_pop})
            2'b10: scount <= scount + 1'b1;
            2'b01: scount <= scount - 1'b1;
            default: scount <= scount;
        endcase
    end

    // ---------- output FIFO read/write ----------
    // Frame-framing side-band, computed at push time (1 push == 1 output pixel,
    // strictly in raster order). SOF = first pushed pixel after sof; EOL = last
    // pixel of each OUT_W run. push_col/first_done track raster position on the
    // exact condition that writes the FIFO (push_en && !ofull).
    reg  [11:0] push_col;
    reg         first_done;
    wire        wr_en       = push_en && !ofull;
    wire        push_sof    = !first_done;                 // first pixel of frame
    wire        push_eol    = (push_col == OUT_W-1);       // last pixel of row
    always @(posedge clk) begin
        if (!rstn || sof) begin push_col <= 12'd0; first_done <= 1'b0; end
        else if (wr_en) begin
            first_done <= 1'b1;
            push_col   <= push_eol ? 12'd0 : (push_col + 12'd1);
        end
    end

    wire pop_out = m_tvalid && m_tready;
    always @(posedge clk) begin
        if (!rstn || sof) begin owr <= 0; ord <= 0; ocount <= 0; end
        else begin
            if (wr_en) begin ofifo[owr] <= {push_eol, push_sof, push_data}; owr <= owr + 1'b1; end
            if (pop_out)                 ord <= ord + 1'b1;
            case ({wr_en, pop_out})
                2'b10: ocount <= ocount + 1'b1;
                2'b01: ocount <= ocount - 1'b1;
                default: ocount <= ocount;
            endcase
        end
    end
    assign m_tvalid = !oempty;
    assign m_tdata  = ofifo[ord][23:0];
    assign m_tuser  = ofifo[ord][24];
    assign m_tlast  = ofifo[ord][25];

    // ---------- prefetch scheduler ----------
    reg [11:0] served_count, pf_next_k, pf_src, pf_frac;
    reg        issued_q;
    wire [12:0] pf_frac_sum = {1'b0, pf_frac} + {1'b0, vsf_l};
    wire        pf_carry    = (pf_frac_sum >= {1'b0, win_h_l});
    // served_count = #window rows the CONSUMER has entered (pop of a new_row).
    // Gate prefetch on consumption (not production) so the ring never clobbers a
    // row still being/awaiting read. The read row is (served_count-1) and the
    // round-robin recycle target for fetch pf_next_k last held row (pf_next_k-NBUF).
    // To keep that recycle at least ONE row behind the read row (a guard band so
    // a fill never laps onto the buffer the consumer is reading — the
    // read-during-write collision that produced the sparse "wavy ghost"), require
    // pf_next_k-NBUF <= read_row-2  ->  pf_next_k <= served_count + (NBUF-3).
    // (Paired with pg_linefetch excluding the in-flight fill buffer from the read
    //  select, this makes the ring safe by construction. NBUF<3 clamps to 0.)
    localparam [11:0] LOOKAHEAD = (NBUF >= 3) ? (NBUF - 3) : 12'd0;
    wire want_pf = (pf_next_k < win_h_l) && (pf_next_k <= served_count + LOOKAHEAD);
    wire do_pf   = want_pf && !m3_busy && !issued_q && !pf_req_r;

    always @(posedge clk) begin
        if (!rstn || sof) begin
            served_count <= 12'd0; pf_next_k <= 12'd0; pf_frac <= 12'd0;
            pf_src <= (!rstn) ? 12'd0 : src_row0;   // #29 prefetch starts at the panned row
            pf_req_r <= 1'b0; pf_row_r <= 12'd0; issued_q <= 1'b0;
        end else begin
            pf_req_r <= 1'b0;
            issued_q <= pf_req_r;
            if (sk_pop && h_new) served_count <= served_count + 12'd1;
            if (do_pf) begin
                pf_req_r <= 1'b1;
                pf_row_r <= pf_src;
                if (pf_carry) begin pf_src <= vd_l ? (pf_src - vsi_l - 12'd1) : (pf_src + vsi_l + 12'd1); pf_frac <= pf_frac_sum[11:0] - win_h_l; end
                else          begin pf_src <= vd_l ? (pf_src - vsi_l) : (pf_src + vsi_l);                 pf_frac <= pf_frac_sum[11:0]; end
                pf_next_k <= pf_next_k + 12'd1;
            end
        end
    end

    // ---- debug taps ----
    assign dbg_src_col  = a_src_col;
    assign dbg_src_row  = a_src_row;
    assign dbg_a_valid  = a_valid;
    assign dbg_a_inwin  = a_inwin;
    assign dbg_a_newrow = a_newrow;
    assign dbg_resident = m3_resident;
    assign dbg_rd_data  = m3_rd_data;
    // prefetch-state taps (build #14)
    assign dbg_rd_row    = h_srow;
    assign dbg_pf_src    = pf_src;
    assign dbg_pf_next_k = pf_next_k;
    assign dbg_served    = served_count;
    assign dbg_m3_busy   = m3_busy;
    assign dbg_pf_req    = pf_req_r;
    assign dbg_push_en   = push_en;
    assign dbg_push_data = push_data;
endmodule

`default_nettype wire
