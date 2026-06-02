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
    parameter integer FIFO_DEPTH = 16
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire        vtg_vsync,        // output frame sync (level; rising = SOF)
    input  wire [31:0] frame_base_addr,  // from pg_genlock

    input  wire [11:0] out_w_win, out_h_win, pos_x, pos_y,
    input  wire [11:0] h_step_int, h_step_frac, v_step_int, v_step_frac,
    input  wire [23:0] matte_rgb,

    output wire [23:0] m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready,

    output wire        fetch_req,
    output wire [31:0] fetch_addr,
    output wire [11:0] fetch_len,
    input  wire        fetch_pvalid,
    input  wire [23:0] fetch_pdata,
    input  wire        fetch_last
);
    // ---------- SOF edge + frame-atomic geometry latch ----------
    reg vs_q;
    always @(posedge clk) vs_q <= (!rstn) ? 1'b0 : vtg_vsync;
    wire sof = vtg_vsync & ~vs_q;

    reg [11:0] win_h_l, vsi_l, vsf_l;
    reg [23:0] matte_l;
    always @(posedge clk) if (sof) begin
        win_h_l <= out_h_win; vsi_l <= v_step_int; vsf_l <= v_step_frac; matte_l <= matte_rgb;
    end

    // ---------- output FIFO ----------
    localparam integer AW = $clog2(FIFO_DEPTH);
    reg  [23:0] ofifo [0:FIFO_DEPTH-1];
    reg  [AW:0] ocount;
    reg  [AW-1:0] owr, ord;
    wire ofull  = (ocount == FIFO_DEPTH[AW:0]);
    wire oempty = (ocount == 0);
    wire ospace = (ocount < (FIFO_DEPTH-2));

    // ---------- skid FIFO at addrgen output (absorbs addrgen's 1-cyc latency) ----------
    localparam integer SK = 8, SKW = 3;
    reg  [25:0] skid [0:SK-1];     // {new_row, inwin, src_row[11:0], src_col[11:0]}
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
    wire [11:0] a_src_col, a_src_row;
    pg_addrgen #(.OUT_W(OUT_W), .OUT_H(OUT_H), .IN_W(IN_W), .IN_H(IN_H)) u_addr (
        .clk(clk), .rstn(rstn), .sof(sof), .px_valid(gen_en),
        .out_w_win(out_w_win), .out_h_win(out_h_win), .pos_x(pos_x), .pos_y(pos_y),
        .h_step_int(h_step_int), .h_step_frac(h_step_frac),
        .v_step_int(v_step_int), .v_step_frac(v_step_frac),
        .o_valid(a_valid), .o_in_window(a_inwin),
        .o_src_col(a_src_col), .o_src_row(a_src_row), .o_new_row(a_newrow)
    );
    always @(posedge clk) begin
        if (!rstn || sof) produced <= 22'd0;
        else if (a_valid) produced <= produced + 22'd1;
    end

    // ---------- skid push (from addrgen) ----------
    always @(posedge clk) begin
        if (!rstn || sof) begin swr <= 0; end
        else if (a_valid && !sfull) begin
            skid[swr] <= {a_newrow, a_inwin, a_src_row, a_src_col};
            swr <= swr + 1'b1;
        end
    end

    // ---------- M3: line fetch + double buffer ----------
    reg         pf_req_r;
    reg  [11:0] pf_row_r;
    wire [23:0] m3_rd_data;
    wire        m3_resident, m3_busy;

    // skid head descriptor
    wire        h_new   = skid[srd][25];
    wire        h_inwin = skid[srd][24];
    wire [11:0] h_srow  = skid[srd][23:12];
    wire [11:0] h_scol  = skid[srd][11:0];

    pg_linefetch #(.LINE_W(IN_W), .STRIDE(STRIDE)) u_fetch (
        .clk(clk), .rstn(rstn), .frame_base_addr(frame_base_addr),
        .pf_req(pf_req_r), .pf_row(pf_row_r),
        .rd_row(h_srow), .rd_col(h_scol),       // read keyed on skid head
        .rd_data(m3_rd_data), .rd_resident(m3_resident),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr), .fetch_len(fetch_len),
        .fetch_pvalid(fetch_pvalid), .fetch_pdata(fetch_pdata), .fetch_last(fetch_last),
        .busy(m3_busy)
    );

    // ---------- stallable consumer: skid head → (M3 read, 1cy) → output FIFO ----------
    // Stage C0: if head servable (matte OR resident) and output FIFO has space,
    //           present rd (already wired), pop skid, launch into C1.
    // Stage C1: m3_rd_data is now valid for that pixel → push to output FIFO.
    wire head_servable = !sempty && ospace && (!h_inwin || m3_resident);
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
                srd <= srd + 1'b1;            // pop head
            end
        end
    end
    wire [23:0] push_data = c1_inwin ? m3_rd_data : c1_matte;
    wire        push_en   = c1_valid;

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
    wire pop_out = m_tvalid && m_tready;
    always @(posedge clk) begin
        if (!rstn || sof) begin owr <= 0; ord <= 0; ocount <= 0; end
        else begin
            if (push_en && !ofull) begin ofifo[owr] <= push_data; owr <= owr + 1'b1; end
            if (pop_out)                 ord <= ord + 1'b1;
            case ({push_en && !ofull, pop_out})
                2'b10: ocount <= ocount + 1'b1;
                2'b01: ocount <= ocount - 1'b1;
                default: ocount <= ocount;
            endcase
        end
    end
    assign m_tvalid = !oempty;
    assign m_tdata  = ofifo[ord];

    // ---------- prefetch scheduler ----------
    reg [11:0] served_count, pf_next_k, pf_src, pf_frac;
    reg        issued_q;
    wire [12:0] pf_frac_sum = {1'b0, pf_frac} + {1'b0, vsf_l};
    wire        pf_carry    = (pf_frac_sum >= {1'b0, win_h_l});
    // served_count = #window rows the CONSUMER has entered (pop of a new_row).
    // Gating prefetch on consumption (not production) keeps exactly 1 row ahead,
    // so the 2-buffer ping-pong never clobbers the row being read.
    wire want_pf = (pf_next_k < win_h_l) && (pf_next_k <= served_count);
    wire do_pf   = want_pf && !m3_busy && !issued_q && !pf_req_r;

    always @(posedge clk) begin
        if (!rstn || sof) begin
            served_count <= 12'd0; pf_next_k <= 12'd0; pf_src <= 12'd0; pf_frac <= 12'd0;
            pf_req_r <= 1'b0; pf_row_r <= 12'd0; issued_q <= 1'b0;
        end else begin
            pf_req_r <= 1'b0;
            issued_q <= pf_req_r;
            if (sk_pop && h_new) served_count <= served_count + 12'd1;
            if (do_pf) begin
                pf_req_r <= 1'b1;
                pf_row_r <= pf_src;
                if (pf_carry) begin pf_src <= pf_src + vsi_l + 12'd1; pf_frac <= pf_frac_sum[11:0] - win_h_l; end
                else          begin pf_src <= pf_src + vsi_l;          pf_frac <= pf_frac_sum[11:0]; end
                pf_next_k <= pf_next_k + 12'd1;
            end
        end
    end
endmodule

`default_nettype wire
