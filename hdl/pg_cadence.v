// pg_cadence.v — FRC cadence controller (read-engine-B). Drop-in superset of pg_genlock.
//
// Replaces pg_genlock's FIXED read = frame_ptr-READ_DELAY follower with an
// occupancy-servo'd fractional resampler — the proper frame-rate-conversion cadence for
// an ASYNC source (the box is a genlock CONVERTER; the source is never the output
// reference). Fixed-point RTL of the algorithm proven + gate-hardened in
// sim/frc_cadence_model_tb.v (see docs/dual-engine-frc-plan.md §13).
//
// GATED 2026-06-03 by sim/pg_cadence_tb.v: PASS at N>=6 (720p + 1080p-scaled-BW, blend
// and blend-disable); correctly FAILs the 1080p-starvation case on writer_overflow. NOT
// yet integrated into pg_read_engine_top / the BD — awaiting the adversarial Q7 review.
//
// NB: the behavioral model computed ceil(R) from the true period ratio, masking that the
// RTL must ESTIMATE the async rate. A pure occupancy servo DEADLOCKS (the clamp's
// ceil(inc) pins occupancy in the deadband so inc never learns R). Fix = feedforward:
// inc tracks measured R = (Δnewest per output frame) via an IIR, plus a gentle occupancy
// phase-trim. This is the one place the RTL genuinely departs from the model.
//
// Algorithm (frame-atomic, on the output-vsync edge = during vblank):
//   acc += inc;  n_adv = floor(acc);  acc -= n_adv;          // Q12.20
//     n_adv : 0 = repeat, 1 = advance, >=2 = drop  (the cadence)
//     frac  : top 8 bits = Mackin blend alpha between read frame S and S+1
//   inc = the MEASURED source rate; the source is async so a PI loop servos inc to hold
//         ring occupancy at a SMALL SETPOINT (read near the head — ring depth is then
//         safety margin + blend coverage, NOT lag). PI has a deadband (no integrate when
//         |err|<=1) and an anti-windup clamp on the integral.
//   SAFETY clamp (hard invariant): read frame S stays in [newest-max_lag .. newest-1],
//     newest   = write_idx - 1                    (never read the in-progress slot)
//     max_lag  = NUM_FRAMES - ceil(inc) - 1 - J - O - MARGIN   (= occ_collide - MARGIN)
//   so the writer can never lap a read slot within MARGIN frames. The model proved this
//   gives min_lap >= MARGIN; the ceil(inc) term is conservatively safe (the real read
//   takes ~1/4 frame, so the writer advances far less during it). N=6 is the depth floor
//   for full blended FRC at 720p AND 1080p; 1080p is bandwidth-bound, not depth-bound.
//
// BRACKETING-PAIR fetch: read is capped at newest-1 so the blend partner S+1 = newest
//   always EXISTS (the repeat case can't lose its blend — the §13 review fix).
// BLEND-DISABLE / alpha-snap (blend_mode=0): round to the nearest frame (single fetch),
//   which halves engine A's DDR read demand and drops its ring footprint 2 slots -> 1
//   (the 1080p bandwidth lever).
//
// frame_ptr (S2MM in-progress framestore) is async (FCLK_CLK1); CDC = 2-FF + debounce
// (same as pg_genlock). An absolute write index is reconstructed from frame_ptr's
// increments so the cadence math is wrap-free even if VDMA advances it non-linearly.
// XDC false-paths fp_q1_reg[*]/D and bm_q1_reg/D.

`default_nettype none
`timescale 1ns / 1ps

module pg_cadence #(
    parameter [31:0]  FRAME_BUF_BASE = 32'h1000_0000,
    parameter integer NUM_FRAMES     = 7,
    parameter integer SLOT_STRIDE    = 2768640,
    parameter integer SETPOINT       = 2,     // small occupancy target (read near head)
    parameter integer MARGIN         = 2,     // safety headroom (frames) below the lap bound
    parameter integer J_MARG         = 1,     // jitter allowance (writer burst beyond ceil(R))
    parameter integer O_MARG         = 0,     // read-overlap allowance (0 @720p, 1 @1080p)
    parameter integer FILT_SH        = 4,     // rate feedforward IIR: inc += (R_meas-inc)>>FILT_SH
    parameter integer KP_SH          = 6,     // occupancy phase-trim gain = 2^-KP_SH
    parameter integer BLEND_EPS      = 4096   // alpha deadband in Q20 (frac<EPS or >ONE-EPS => no blend)
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [5:0]  frame_ptr,   // S2MM in-progress framestore (FCLK_CLK1, async)
    input  wire        out_vsync,   // output VTC vsync (this clock domain)
    input  wire        blend_mode,  // 1 = Mackin blend (dual-fetch), 0 = alpha-snap (single)

    // primary fetch (frame S, or the nearest frame when blend_mode=0) — drop-in for pg_genlock
    output reg  [2:0]  read_slot,
    output reg  [31:0] read_base_addr,
    output reg  [2:0]  write_slot,

    // blend partner (frame S+1) + weight — used only when blend_en
    output reg  [2:0]  read2_slot,
    output reg  [31:0] read2_base_addr,
    output reg  [7:0]  alpha,
    output reg         blend_en,

    // debug taps (ILA)
    output wire [15:0] dbg_inc,     // inc[19:4]  (Q8.12 view of the servo'd rate)
    output wire [7:0]  dbg_occ,     // last occupancy (newest - read_id)
    output wire [3:0]  dbg_nadv,    // last cadence step (0 rep /1 adv />=2 drop)
    output wire [7:0]  dbg_maxlag   // current clamp ceiling
);
    localparam integer QF  = 20;
    localparam [31:0]  ONE = (32'd1 << QF);

    // ---------- CDC + debounce for frame_ptr ----------
    (* ASYNC_REG = "TRUE" *) reg [5:0] fp_q1, fp_q2;
    reg [5:0] fp_q3, fp_stable;
    always @(posedge clk) begin
        if (!rstn) begin fp_q1<=0; fp_q2<=0; fp_q3<=0; fp_stable<=0; end
        else begin
            fp_q1 <= frame_ptr; fp_q2 <= fp_q1; fp_q3 <= fp_q2;
            if (fp_q2 == fp_q3) fp_stable <= fp_q2;
        end
    end
    wire [5:0] fp_use = (fp_stable >= NUM_FRAMES[5:0]) ? 6'd0 : fp_stable;

    // ---------- blend_mode CDC (slow GPIO bit) ----------
    (* ASYNC_REG = "TRUE" *) reg bm_q1, bm_q2;
    always @(posedge clk) begin bm_q1 <= blend_mode; bm_q2 <= bm_q1; end

    // ---------- reconstruct absolute write index from frame_ptr increments ----------
    reg  [5:0]  fp_prev;
    reg         seen_fp;
    reg [31:0]  write_idx;
    // +NUM_FRAMES before the mod so a wrap (e.g. N-1 -> 0) yields +1, not the 6-bit
    // two's-complement wrap (mod 64). NUM_FRAMES assumed < 32 so fp_use+N fits 6 bits.
    wire [5:0]  fp_delta = (fp_use + NUM_FRAMES[5:0] - fp_prev) % NUM_FRAMES[5:0];
    always @(posedge clk) begin
        if (!rstn) begin fp_prev<=0; seen_fp<=1'b0; write_idx<=0; end
        else begin
            if (!seen_fp) begin seen_fp<=1'b1; fp_prev<=fp_use; write_idx<=32'd0; end
            else if (fp_use != fp_prev) begin
                write_idx <= write_idx + {26'd0, fp_delta};
                fp_prev   <= fp_use;
            end
        end
    end
    wire [31:0] newest = write_idx - 32'd1;          // newest completed frame index

    // ---------- output-vsync rising edge ----------
    reg ov_q;
    always @(posedge clk) ov_q <= (!rstn) ? 1'b0 : out_vsync;
    wire ov_pulse = out_vsync & ~ov_q;

    // ---------- cadence state ----------
    reg  signed [31:0] inc;          // Q12.20 source frames per output frame (estimated)
    reg         [31:0] acc;          // Q12.20 phase accumulator
    reg         [31:0] read_id;      // absolute read frame index (= S, the floor)
    reg         [31:0] newest_prev;  // newest at the previous output frame (for R_meas)
    reg                primed;
    reg         [3:0]  nadv_q;
    reg         [7:0]  occ_q;

    // ceil(inc)
    wire [11:0] inc_int  = inc[31:QF];
    wire        inc_frac = |inc[QF-1:0];
    wire [11:0] ceil_inc = inc_int + (inc_frac ? 12'd1 : 12'd0);
    // clamp ceiling = occ_collide - MARGIN = N - ceil(inc) - 1 - J - O - MARGIN
    wire signed [13:0] ml_s = NUM_FRAMES[13:0] - {2'b0,ceil_inc} - J_MARG[13:0]
                              - O_MARG[13:0] - MARGIN[13:0] - 14'd1;
    wire [11:0] max_lag = (ml_s < 0) ? 12'd0 : ml_s[11:0];

    // ---------- combinational next-step ----------
    reg  [31:0] acc_sum, want, lo_idx, hi_idx, prim_id, s1_id;
    reg  [11:0] n_adv;
    reg  [19:0] frac;
    reg  signed [31:0] occ_s, err_s;
    reg         [31:0] dnew;          // measured source frames since last output frame = R
    reg  signed [31:0] inc_ff, occ_trim;
    reg         do_blend, snap_up;

    function [2:0] slot_of; input [31:0] idx; begin slot_of = idx % NUM_FRAMES; end endfunction
    function [31:0] base_of; input [31:0] idx; begin base_of = FRAME_BUF_BASE + (idx % NUM_FRAMES)*SLOT_STRIDE; end endfunction

    always @(*) begin
        acc_sum = acc + inc;                  // inc > 0
        n_adv   = acc_sum[31:QF];
        frac    = acc_sum[QF-1:0];
        want    = read_id + {20'd0, n_adv};

        // safety window [lo_idx .. hi_idx]; hi = newest-1 reserves the blend partner.
        hi_idx = (newest >= 32'd1) ? (newest - 32'd1) : 32'd0;
        lo_idx = (newest > {20'd0,max_lag}) ? (newest - {20'd0,max_lag}) : 32'd0;
        if (lo_idx > hi_idx) lo_idx = hi_idx;
        if (want > hi_idx) want = hi_idx;     // output ahead -> repeat
        if (want < lo_idx) want = lo_idx;     // fell behind -> force-advance (drop)

        s1_id    = want + 32'd1;              // blend partner = newest (in-window by construction)
        // blend only when alpha is meaningfully fractional
        do_blend = bm_q2 && (frac > BLEND_EPS[19:0]) && (frac < (ONE[19:0] - BLEND_EPS[19:0]));
        // alpha-snap (single-fetch) rounds to the nearer frame
        snap_up  = (!bm_q2) && frac[QF-1];    // frac >= 0.5
        prim_id  = snap_up ? s1_id : want;

        // rate estimate: R_meas = source frames produced since the last output frame.
        dnew   = newest - newest_prev;                 // monotonic; small integer ~ R
        // feedforward IIR toward R_meas (Q12.20): inc += (R_meas - inc) >> FILT_SH
        inc_ff = inc + ((($signed({dnew[11:0],20'd0})) - inc) >>> FILT_SH);
        // gentle proportional occupancy phase-trim (deadband |err|<=1 → no nudge)
        occ_s     = $signed({1'b0, newest}) - $signed({1'b0, want});
        err_s     = occ_s - SETPOINT;
        occ_trim  = (err_s > 1) ?  (32'sd1 <<< (QF-KP_SH)) :
                    (err_s < -1) ? -(32'sd1 <<< (QF-KP_SH)) : 32'sd0;
    end

    always @(posedge clk) begin
        if (!rstn) begin
            inc <= ONE; acc <= 0; read_id <= 0; newest_prev <= 0; primed <= 1'b0;
            nadv_q <= 0; occ_q <= 0;
            read_slot <= 0; read_base_addr <= FRAME_BUF_BASE; write_slot <= 0;
            read2_slot <= 0; read2_base_addr <= FRAME_BUF_BASE; alpha <= 0; blend_en <= 0;
        end else if (ov_pulse && seen_fp && newest != 32'hFFFF_FFFF) begin
            if (!primed) begin
                primed   <= 1'b1;
                read_id  <= (newest > SETPOINT) ? (newest - SETPOINT) : 32'd0;
                acc      <= 0; newest_prev <= newest;
                read_slot <= slot_of((newest > SETPOINT) ? (newest-SETPOINT) : 32'd0);
                read_base_addr <= base_of((newest > SETPOINT) ? (newest-SETPOINT) : 32'd0);
                write_slot <= fp_use[2:0];
            end else begin
                read_id     <= want;
                acc         <= {12'd0, frac};
                newest_prev <= newest;
                // rate = feedforward IIR toward measured R + gentle occupancy phase-trim.
                // Feedforward (not pure occupancy servo) is REQUIRED: the clamp's ceil(inc)
                // otherwise pins occupancy in the deadband and inc can never learn R.
                if      (inc_ff + occ_trim < 32'sd52429)   inc <= 32'sd52429;    // 0.05
                else if (inc_ff + occ_trim > 32'sd5242880) inc <= 32'sd5242880;  // 5.0
                else                                       inc <= inc_ff + occ_trim;
                nadv_q <= (n_adv > 4'hF) ? 4'hF : n_adv[3:0];
                occ_q  <= occ_s[7:0];

                // primary fetch (S, or nearest when blend off)
                read_slot      <= slot_of(prim_id);
                read_base_addr <= base_of(prim_id);
                write_slot     <= fp_use[2:0];
                // blend partner (S+1) + weight
                read2_slot      <= slot_of(s1_id);
                read2_base_addr <= base_of(s1_id);
                alpha    <= do_blend ? frac[QF-1 -: 8] : 8'd0;
                blend_en <= do_blend;
            end
        end
    end

    assign dbg_inc    = inc[19:4];
    assign dbg_occ    = occ_q;
    assign dbg_nadv   = nadv_q;
    assign dbg_maxlag = {4'd0, max_lag[3:0]};
endmodule

`default_nettype wire
