// scaler_v.v — 4-tap polyphase vertical scaler (1280 in -> 720 out).
//
// 1-cycle-throughput output pipeline.
//
// Output pipeline (stages advance together when `pipe_advance`):
//   Stage 0 (cycle N):   latch tap_lbuf*_q <= lbuf*[out_col]; advance out_col;
//                        latch stage0_valid_q + tlast/tuser flags
//   Stage 1 (cycle N+1): m_axis_tdata <= MAC(tap_lbuf*_q, coeffs);
//                        m_axis_tvalid <= stage0_valid_q
//
// 1280 emit pixels now take 1280 cycles, which fits well inside the
// ~1970-cycle input-row time. So when consecutive input rows both trigger
// `v_cross` (which happens every 3rd row at 1.5x downscale: rows 1+2, 4+5,
// 7+8, ...), the first emit completes before the second cross arrives —
// no more out_col reset clobbering the in-progress emit.
//
// Line-buffer write logic + v_cross detection unchanged from the previous
// 2-cycle pipeline. Same 4-slot lbuf, same slot-rotation scheme.
//
// First-cut simplifications still present:
//   - First emit row of frame: tap0/tap1 may read uninitialized lbufs
//     (lbuf2/lbuf3 holding pre-frame garbage). Cosmetic top-of-frame.

`default_nettype none
`timescale 1ns / 1ps

module scaler_v #(
    parameter integer IN_W   = 1280,
    parameter integer IN_H_DEFAULT = 1080,  // latched reset value; runtime IN_H below
    parameter integer OUT_H  = 720,
    parameter integer PHASES = 64,
    parameter integer TAPS   = 4
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    output reg  [23:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser,

    /* Runtime source-vertical-active count, driven by firmware from VTC
     * detector's DASIZE register via AXI GPIO (CDC'd into clk domain in
     * scaler_top). Latched into in_h_active at each input TUSER so
     * v_cross/v_excess math is frame-atomic. */
    input  wire [11:0] in_h_runtime,

    /* iter14 (2026-05-31): runtime kernel-mode selector. Mirrors scaler_h
     * mode codes: 0=NN tap3 only, 1=2-tap tap2+tap3 (production), 2=4-tap
     * tap0..tap3, 3=reserved. */
    input  wire [1:0]  kernel_mode,

    /* iter4g DIAG: per-frame counter snapshots, latched at TUSER.
     *   in_tlast_count_snap   - how many TLASTs came IN from scaler_h
     *   emit_count_snap       - how many v_cross/emits triggered (internal)
     *   out_tlast_count_snap  - how many TLASTs went OUT on m_axis (iter5
     *                           2026-05-22): disambiguates A2-scaler from
     *                           A2-S2MM. 720 = scaler emits cleanly → bug
     *                           is downstream; <720 = scaler aborts emits
     *                           at frame boundary → bug is in scaler_v. */
    output reg  [15:0] in_tlast_count_snap,
    output reg  [15:0] emit_count_snap,
    output reg  [15:0] out_tlast_count_snap
);
    // Line buffers — 4 separate arrays, Vivado infers 4 BRAMs (1 each).
    reg [23:0] lbuf0 [0:IN_W-1];
    reg [23:0] lbuf1 [0:IN_W-1];
    reg [23:0] lbuf2 [0:IN_W-1];
    reg [23:0] lbuf3 [0:IN_W-1];

    // Input position
    reg [10:0] in_col;    // 0..IN_W-1
    reg [11:0] in_row;    // 0..IN_H-1

    // Runtime IN_H, latched at TUSER for frame-atomic commit.
    reg [11:0] in_h_active;

    /* iter4g DIAG: running counters of input TLAST and emit (v_cross)
     * events. Both reset on TUSER; previous frame's values latched into
     * the *_snap outputs above. */
    reg [15:0] in_tlast_count;
    reg [15:0] emit_count;
    reg [15:0] out_tlast_count;

    // Vertical accumulator
    reg  [11:0] v_accum;
    wire [11:0] v_accum_next = v_accum + OUT_H[11:0];
    wire        v_cross      = v_accum_next >= in_h_active;
    wire [11:0] v_excess     = v_accum_next - in_h_active;

    // Phase = v_excess * PHASES / OUT_H. Precomputed at elaboration as a
    // Q10 multiplier, rounded to nearest:
    //   PHASE_MUL_Q10 = round(PHASES * 1024 / OUT_H)
    // (PHASES=64, OUT_H=720 → 91; OUT_H=1080 → 61; OUT_H=540 → 121.)
    localparam [16:0] PHASE_MUL_Q10 = (PHASES * 1024 + OUT_H/2) / OUT_H;
    wire [11:0] v_phase_calc = (v_excess * PHASE_MUL_Q10) >> 10;

    // Emit state
    reg        emit;             // 0 idle, 1 emitting an output row
    reg [10:0] out_col;          // 0..IN_W-1
    reg [5:0]  v_phase_held;     // phase for current emit row
    reg [1:0]  tap0_slot;        // which lbuf is tap 0 of current emit
    reg        emit_first_row;   // 1 if this is the very first emit row of the frame

    // Per-lbuf "fresh" bit: cleared on TUSER, set when the corresponding lbuf
    // has been written with current-frame data. Stage 0 reads gate on these
    // bits and substitute zero for unrefreshed lbufs, avoiding the carryover
    // of previous-frame data into the first 2-3 emit rows of each frame.
    // (Failed iter3g approach gated m_axis_tdata directly with a ternary;
    // that broke the B channel via a hold-time violation. Gating on the input
    // side of the tap latches is structurally cleaner — 4 simple AND-style
    // input muxes rather than a wide output mux next to the MAC.)
    reg [3:0]  lbuf_fresh;

    // Stage-0 latches (BRAM read result + metadata captured at stage 0)
    reg [23:0] tap_lbuf0_q;
    reg [23:0] tap_lbuf1_q;
    reg [23:0] tap_lbuf2_q;
    reg [23:0] tap_lbuf3_q;
    reg [1:0]  tap0_slot_q;
    reg [5:0]  phase_q;
    reg        stage0_valid_q;
    reg        tlast_q;
    reg        tuser_q;

    // Reorder taps based on captured tap0_slot
    reg [23:0] tap0, tap1, tap2, tap3;
    always @* begin
        case (tap0_slot_q)
            2'd0: begin tap0 = tap_lbuf0_q; tap1 = tap_lbuf1_q; tap2 = tap_lbuf2_q; tap3 = tap_lbuf3_q; end
            2'd1: begin tap0 = tap_lbuf1_q; tap1 = tap_lbuf2_q; tap2 = tap_lbuf3_q; tap3 = tap_lbuf0_q; end
            2'd2: begin tap0 = tap_lbuf2_q; tap1 = tap_lbuf3_q; tap2 = tap_lbuf0_q; tap3 = tap_lbuf1_q; end
            2'd3: begin tap0 = tap_lbuf3_q; tap1 = tap_lbuf0_q; tap2 = tap_lbuf1_q; tap3 = tap_lbuf2_q; end
        endcase
    end

    // Coefficient ROM (combinational on phase_q)
    wire [47:0] coeffs_flat;
    scaler_coeffs_v coeff_rom_inst (.phase(phase_q), .taps_flat(coeffs_flat));

    wire signed [11:0] k0 = $signed(coeffs_flat[11: 0]);
    wire signed [11:0] k1 = $signed(coeffs_flat[23:12]);
    wire signed [11:0] k2 = $signed(coeffs_flat[35:24]);
    wire signed [11:0] k3 = $signed(coeffs_flat[47:36]);

    function automatic [7:0] mac4_sat;
        input [7:0] p0, p1, p2, p3;
        input signed [11:0] kk0, kk1, kk2, kk3;
        reg signed [21:0] sum;
        begin
            sum =  $signed({1'b0, p0}) * kk0
                 + $signed({1'b0, p1}) * kk1
                 + $signed({1'b0, p2}) * kk2
                 + $signed({1'b0, p3}) * kk3;
            if (sum < 22'sd0)
                mac4_sat = 8'h00;
            else if (sum > 22'sd522239)
                mac4_sat = 8'hFF;
            else
                // Round-to-nearest: add 0.5 LSB (1024 in Q.11) before truncation.
                mac4_sat = (sum + 22'sd1024) >>> 11;
        end
    endfunction

    /* SHIPPED CONFIG (iter3o/iter3q): V-MAC bypassed — see scaler_h.v for
     * full rationale. Output picks tap1 (one of the middle taps after slot
     * rotation, always points to a current-frame lbuf when lbuf_fresh allows). */
    /* iter13 (2026-05-24): V-scaler 2-tap boxcar = (tap2 + tap3) / 2.
     * Previously was NN single-tap (mac_r = tap1) which dropped 1 of every
     * 3 source rows for 1080->720, making 1-pixel-thick horizontal lines
     * land on dropped rows invisible. tap2/tap3 are the 2 NEWEST line
     * buffers post-rotation, so the final emit (after source row 1079) has
     * tap3 = row 1079 — full source row range covered, mirroring iter12 H.
     * Every source row now contributes to >=1 output row at >=half weight.
     *
     * iter13b (2026-05-30): added +1 round-to-nearest before the >>1.
     * Same fix as scaler_h.v — `(a+b)>>1` truncates, biasing -0.5 LSB per
     * output pixel; cumulative H+V cascade = -1 LSB per channel = slight
     * dark shift. Matches the mac4_sat path's existing +1024 rounding at
     * line 163. Cost: 3 LUTs. Per audit-panel HDL Agent 2026-05-30. */
    /* iter14 (2026-05-31): runtime kernel-mode mux for V scaler. */
    // Mode 0 — NN single-tap (newest = tap3 post-rotation)
    wire [7:0] mode0v_r = tap3[23:16];
    wire [7:0] mode0v_g = tap3[15: 8];
    wire [7:0] mode0v_b = tap3[ 7: 0];

    // Mode 1 — 2-tap boxcar (production)
    wire [8:0] vs_r = tap2[23:16] + tap3[23:16] + 9'd1;
    wire [8:0] vs_g = tap2[15: 8] + tap3[15: 8] + 9'd1;
    wire [8:0] vs_b = tap2[ 7: 0] + tap3[ 7: 0] + 9'd1;
    wire [7:0] mode1v_r = vs_r[8:1];
    wire [7:0] mode1v_g = vs_g[8:1];
    wire [7:0] mode1v_b = vs_b[8:1];

    // Mode 2 — 4-tap boxcar across all four rotated taps
    wire [9:0] v4_r = tap0[23:16] + tap1[23:16] + tap2[23:16] + tap3[23:16] + 10'd2;
    wire [9:0] v4_g = tap0[15: 8] + tap1[15: 8] + tap2[15: 8] + tap3[15: 8] + 10'd2;
    wire [9:0] v4_b = tap0[ 7: 0] + tap1[ 7: 0] + tap2[ 7: 0] + tap3[ 7: 0] + 10'd2;
    wire [7:0] mode2v_r = v4_r[9:2];
    wire [7:0] mode2v_g = v4_g[9:2];
    wire [7:0] mode2v_b = v4_b[9:2];

    reg [7:0] mac_r, mac_g, mac_b;
    always @* begin
        case (kernel_mode)
            2'd0: begin mac_r = mode0v_r; mac_g = mode0v_g; mac_b = mode0v_b; end
            2'd1: begin mac_r = mode1v_r; mac_g = mode1v_g; mac_b = mode1v_b; end
            2'd2: begin mac_r = mode2v_r; mac_g = mode2v_g; mac_b = mode2v_b; end
            default: begin mac_r = mode1v_r; mac_g = mode1v_g; mac_b = mode1v_b; end
        endcase
    end
    wire _vcoef_keep = |{k0, k1, k2, k3};

    // Always ready to accept input — internal 4-line BRAM absorbs bursts.
    assign s_axis_tready = 1'b1;

    // Pipeline advances when downstream isn't holding us
    wire pipe_advance = !m_axis_tvalid || m_axis_tready;

    always @(posedge clk) begin
        if (!rstn) begin
            in_col          <= 11'd0;
            in_row          <= 12'd0;
            v_accum         <= 12'd0;
            emit            <= 1'b0;
            out_col         <= 11'd0;
            v_phase_held    <= 6'd0;
            tap0_slot       <= 2'd0;
            emit_first_row  <= 1'b1;
            lbuf_fresh      <= 4'h0;
            tap_lbuf0_q     <= 24'd0;
            tap_lbuf1_q     <= 24'd0;
            tap_lbuf2_q     <= 24'd0;
            tap_lbuf3_q     <= 24'd0;
            tap0_slot_q     <= 2'd0;
            phase_q         <= 6'd0;
            stage0_valid_q  <= 1'b0;
            tlast_q         <= 1'b0;
            tuser_q         <= 1'b0;
            m_axis_tvalid   <= 1'b0;
            m_axis_tdata    <= 24'd0;
            m_axis_tlast    <= 1'b0;
            m_axis_tuser    <= 1'b0;
            in_h_active     <= IN_H_DEFAULT[11:0];
            in_tlast_count       <= 16'd0;
            in_tlast_count_snap  <= 16'd0;
            emit_count           <= 16'd0;
            emit_count_snap      <= 16'd0;
            out_tlast_count      <= 16'd0;
            out_tlast_count_snap <= 16'd0;
        end else begin
            // -----------------------------------------------------------------
            // INPUT side (lbuf write + v_accum tracking)
            // -----------------------------------------------------------------
            if (s_axis_tvalid && s_axis_tready) begin
                case (in_row[1:0])
                    2'd0: lbuf0[in_col] <= s_axis_tdata;
                    2'd1: lbuf1[in_col] <= s_axis_tdata;
                    2'd2: lbuf2[in_col] <= s_axis_tdata;
                    2'd3: lbuf3[in_col] <= s_axis_tdata;
                endcase
                if (s_axis_tuser) begin
                    in_row         <= 12'd0;
                    v_accum        <= 12'd0;
                    emit_first_row <= 1'b1;
                    lbuf_fresh     <= 4'h0;  // new frame: all lbufs are now stale
                    /* Frame-atomic commit of runtime IN_H — any AXI-Lite
                     * change between frames takes effect here, not mid-frame. */
                    in_h_active    <= in_h_runtime;
                    /* iter4g DIAG: snapshot + reset per-frame counters. */
                    in_tlast_count_snap  <= in_tlast_count;
                    in_tlast_count       <= s_axis_tlast ? 16'd1 : 16'd0;
                    emit_count_snap      <= emit_count;
                    emit_count           <= 16'd0;
                    /* iter5 (2026-05-22) DIAG: snapshot output TLAST count. */
                    out_tlast_count_snap <= out_tlast_count;
                    out_tlast_count      <= 16'd0;
                end
                /* iter4g DIAG: count input TLAST events (non-TUSER cycle).
                 * Doing this OUTSIDE the v_cross gate so we count the raw
                 * input count regardless of whether scaler emits or not. */
                if (s_axis_tlast && !s_axis_tuser) begin
                    in_tlast_count <= in_tlast_count + 16'd1;
                end
                if (s_axis_tlast) begin
                    in_col <= 11'd0;
                    in_row <= in_row + 12'd1;
                    // The lbuf that just got fully written is now fresh.
                    // Using non-blocking with the override on TUSER above:
                    // when both TLAST and TUSER fire on the same pixel (not
                    // expected in our pipeline), TUSER wins and clears all.
                    // Otherwise this single-bit set propagates.
                    case (in_row[1:0])
                        2'd0: lbuf_fresh[0] <= 1'b1;
                        2'd1: lbuf_fresh[1] <= 1'b1;
                        2'd2: lbuf_fresh[2] <= 1'b1;
                        2'd3: lbuf_fresh[3] <= 1'b1;
                    endcase
                    if (v_cross) begin
                        emit         <= 1'b1;
                        out_col      <= 11'd0;
                        v_phase_held <= v_phase_calc[5:0];
                        v_accum      <= v_excess;
                        tap0_slot    <= (in_row[1:0] + 2'd1);
                        /* iter4g DIAG: count v_cross events = emits per frame. */
                        emit_count   <= emit_count + 16'd1;
                    end else begin
                        v_accum <= v_accum_next;
                    end
                end else begin
                    in_col <= in_col + 11'd1;
                end
            end

            // -----------------------------------------------------------------
            // OUTPUT pipeline — both stages advance on pipe_advance
            // -----------------------------------------------------------------
            if (pipe_advance) begin
                // Stage 1: present MAC result of whatever stage 0 latched last cycle
                m_axis_tvalid <= stage0_valid_q;
                m_axis_tlast  <= tlast_q & stage0_valid_q;
                m_axis_tuser  <= tuser_q & stage0_valid_q;
                if (stage0_valid_q) begin
                    m_axis_tdata <= {mac_r, mac_g, mac_b};
                end

                // Stage 0: issue BRAM read at out_col, latch metadata.
                // Gate each tap by its fresh bit so unrefreshed lbufs (with
                // old-frame data leftover from the previous frame) contribute
                // 0 to the MAC instead of mixed garbage.
                if (emit) begin
                    tap_lbuf0_q    <= lbuf_fresh[0] ? lbuf0[out_col] : 24'h0;
                    tap_lbuf1_q    <= lbuf_fresh[1] ? lbuf1[out_col] : 24'h0;
                    tap_lbuf2_q    <= lbuf_fresh[2] ? lbuf2[out_col] : 24'h0;
                    tap_lbuf3_q    <= lbuf_fresh[3] ? lbuf3[out_col] : 24'h0;
                    tap0_slot_q    <= tap0_slot;
                    phase_q        <= v_phase_held;
                    /* iter13c rev2 (2026-05-31, HDL audit follow-up):
                     * suppress emit when both lbufs that will become
                     * tap2/tap3 post-rotation are unfresh. iter13's MAC is
                     * (tap2+tap3)/2; at frame start with neither fresh,
                     * we'd emit (0+0)/2 = black. Better to hold valid low
                     * so the picture sees a clean blank/hold rather than
                     * a black band that flickers at top-of-frame.
                     *
                     * v1 used variable bit-select with expression index
                     * (lbuf_fresh[(tap0_slot+2)&3]) — Vivado synth
                     * accepted it but impl_1 saw scaler_top as a black
                     * box (one of those "synth pass, downstream fail"
                     * cases). v2 uses an explicit case statement:
                     * identical behavior, all synthesizers handle it. */
                    case (tap0_slot)
                        2'd0: stage0_valid_q <= lbuf_fresh[2] | lbuf_fresh[3];
                        2'd1: stage0_valid_q <= lbuf_fresh[3] | lbuf_fresh[0];
                        2'd2: stage0_valid_q <= lbuf_fresh[0] | lbuf_fresh[1];
                        2'd3: stage0_valid_q <= lbuf_fresh[1] | lbuf_fresh[2];
                    endcase
                    tlast_q        <= (out_col == IN_W - 1);
                    tuser_q        <= (out_col == 0) && emit_first_row;

                    if (out_col == IN_W - 1) begin
                        emit           <= 1'b0;
                        emit_first_row <= 1'b0;
                        out_col        <= 11'd0;
                    end else begin
                        out_col <= out_col + 11'd1;
                    end
                end else begin
                    stage0_valid_q <= 1'b0;
                end
            end

            /* iter5 (2026-05-22) DIAG: count completed output TLAST
             * handshakes. Independent of pipe_advance / TUSER reset above:
             * if both fire same cycle, last-write-wins → next frame gets
             * +1 of charge; tolerable ±1 jitter for the 720-vs-694 verdict. */
            if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                out_tlast_count <= out_tlast_count + 16'd1;
            end
        end
    end
endmodule

`default_nettype wire
