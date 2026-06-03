// pg_cadence.v — FRC cadence controller (read-engine-B). Drop-in superset of pg_genlock.
//
// ⚠️ WIP DRAFT — NOT YET GATED, DO NOT INTEGRATE. (2026-06-02)
// Known issues to fix next session, before this is trusted:
//   1. PI servo has NO deadband (integrates on every ±1 occupancy wiggle → hunts) and
//      NO anti-windup clamp on `integ` (sustained transient overshoots). Add: skip
//      integrate when |err|<=1; clamp integ; KP/KI are already power-of-two shifts.
//   2. Safety clamp uses max_lag = NUM_FRAMES-ceil(inc)-2, which the hardened model
//      suggests is TOO LOOSE (doesn't account for in-frame writer advance + jitter).
//      Pin the correct margin + true min-N via sim/frc_cadence_model_tb.v FIRST.
//   3. No blend-disable / alpha-snap-to-nearest mode yet (needed for 1080p DDR margin:
//      round alpha->{0,1} => single fetch, drops A's ring footprint 2 slots -> 1).
//   4. No companion TB yet (sim/pg_cadence_tb.v) wrapping this in the writer+ring+
//      safety harness. Gate the RTL against the (hardened) model before integration.
// The algorithm/structure below matches the reviewed canonical form; the above are
// translation details + the still-open clamp/depth question. Kept as the starting draft.
//
// Replaces pg_genlock's FIXED read = frame_ptr-READ_DELAY follower with an
// occupancy-servo'd fractional resampler — the proper frame-rate-conversion cadence
// for an ASYNC source (the box is a genlock CONVERTER; the source is never the
// output reference). Behavioral form proven in sim/frc_cadence_model_tb.v; this is the
// fixed-point RTL of that algorithm, gated by sim/pg_cadence_tb.v.
//
// Algorithm (frame-atomic, evaluated on the output-vsync edge = during vblank):
//   acc += inc;  n_adv = floor(acc);  acc -= n_adv;        // Q12.20 fixed point
//     n_adv  : 0 = repeat, 1 = advance, >=2 = drop  (the cadence)
//     frac   : top 8 bits = Mackin blend alpha between read frame S and S+1
//   inc = the MEASURED source rate. Source is async, so a PI loop servos inc to hold
//         ring occupancy (read distance behind the writer) at SETPOINT (~N/2).
//   SAFETY (hard invariant): read frame must stay in [newest-max_lag .. newest], where
//   newest = write_idx-1 (can't read the in-progress slot) and
//   max_lag = NUM_FRAMES - ceil(inc) - 2 (the writer advances ~ceil(inc) slots during
//   one output frame, so anything older laps mid-read). If the resampler wants a frame
//   outside that window, CLAMP it (force-advance = drop, or hold = repeat) — never read
//   a slot the writer can reach before the frame completes. N=5 is unsafe for >=2x
//   down-conversion (model-proven); use NUM_FRAMES>=7 for HD blend + a second reader.
//
// frame_ptr (S2MM in-progress framestore) is async (FCLK_CLK1); CDC = 2-FF + debounce
// (same as pg_genlock). An absolute write index is reconstructed from its increments so
// the cadence math is wrap-free even if VDMA advances frame_ptr non-linearly.
//
// Blend outputs (read2_*, alpha, blend_en) are produced now but unused until the Mackin
// dual-fetch path is wired; gen-lock (drop/repeat) mode uses read_base_addr alone.

`default_nettype none
`timescale 1ns / 1ps

module pg_cadence #(
    parameter [31:0]  FRAME_BUF_BASE = 32'h1000_0000,
    parameter integer NUM_FRAMES     = 7,
    parameter integer SLOT_STRIDE    = 2768640,
    parameter integer SETPOINT       = 3,     // target occupancy (~NUM_FRAMES/2)
    parameter integer KP_SH          = 11,    // PI proportional shift (~0.002 in Q20)
    parameter integer KI_SH          = 9,     // PI integral shift     (~0.0004 in Q20)
    parameter integer BLEND_EPS      = 64     // alpha deadband (Q20 frac < EPS<<12 => no blend)
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [5:0]  frame_ptr,   // S2MM current (in-progress) framestore, async
    input  wire        out_vsync,   // output VTC vsync (this clock domain)

    // gen-lock outputs (drop/repeat) — drop-in compatible with pg_genlock
    output reg  [2:0]  read_slot,
    output reg  [31:0] read_base_addr,
    output reg  [2:0]  write_slot,

    // blend outputs (for the Mackin dual-fetch path; ignored in gen-lock mode)
    output reg  [2:0]  read2_slot,
    output reg  [31:0] read2_base_addr,
    output reg  [7:0]  alpha,
    output reg         blend_en,

    // debug taps (ILA)
    output wire [15:0] dbg_inc,        // inc >> 4  (Q8.12 view)
    output wire [7:0]  dbg_occ,        // current occupancy
    output wire [3:0]  dbg_nadv        // last cadence step (0 rep /1 adv />=2 drop)
);
    localparam integer QF  = 20;
    localparam [47:0]  ONE = (48'd1 << QF);

    // ---------- CDC + debounce for frame_ptr (same pattern as pg_genlock) ----------
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

    // ---------- reconstruct absolute write index from frame_ptr increments ----------
    // write_idx counts in-progress frames; robust to non-linear VDMA advance as long as
    // frame_ptr advances < NUM_FRAMES between samples (it does — sampled at pixel clock).
    reg  [5:0]  fp_prev;
    reg         seen_fp;
    reg [31:0]  write_idx;
    wire [5:0]  fp_delta = (fp_use - fp_prev) % NUM_FRAMES[5:0];
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
    wire [31:0] newest = write_idx - 32'd1;   // newest completed frame index

    // ---------- output-vsync rising edge ----------
    reg ov_q;
    always @(posedge clk) ov_q <= (!rstn) ? 1'b0 : out_vsync;
    wire ov_pulse = out_vsync & ~ov_q;

    // ---------- cadence state ----------
    reg  signed [31:0] inc;         // Q12.20, source frames per output frame (servo'd)
    reg         [47:0] acc;         // Q?.20 phase accumulator (unsigned)
    reg         [31:0] read_idx;    // absolute read frame index
    reg  signed [31:0] integ;       // PI integral
    reg  signed [31:0] err_prev;
    reg         [3:0]  nadv_q;
    reg         [7:0]  occ_q;
    reg                primed;

    // ceil(inc): integer part + (frac != 0)
    wire [11:0] inc_int  = inc[31:QF];
    wire        inc_frac = |inc[QF-1:0];
    wire [11:0] ceil_inc = inc_int + (inc_frac ? 12'd1 : 12'd0);
    // max safe lag = NUM_FRAMES - ceil(inc) - 2  (clamp >= 0)
    wire signed [12:0] max_lag_s = NUM_FRAMES[12:0] - {1'b0,ceil_inc} - 13'd2;
    wire [11:0] max_lag = (max_lag_s < 0) ? 12'd0 : max_lag_s[11:0];

    // combinational next-step
    reg  [47:0] acc_sum;
    reg  [11:0] n_adv;
    reg  [31:0] want_idx, ridx_new, lo_idx;
    reg  signed [31:0] occ_s, err_s, dinc;

    always @(*) begin
        acc_sum = acc + {16'd0, inc};        // inc is positive
        n_adv   = acc_sum[47:QF];            // integer part (advance count)
        want_idx = read_idx + {20'd0, n_adv};
        // safety window [lo_idx .. newest]
        lo_idx  = newest - {20'd0, max_lag};
        if (want_idx > newest)       ridx_new = newest;        // output ahead -> repeat
        else if (want_idx < lo_idx)  ridx_new = lo_idx;        // fell behind -> force-advance (drop)
        else                         ridx_new = want_idx;
        // occupancy + PI error
        occ_s = $signed({1'b0, newest}) - $signed({1'b0, ridx_new});
        err_s = occ_s - SETPOINT;
        // velocity-form PI: d_inc = KP*(err-err_prev) + KI*err
        dinc  = ((err_s - err_prev) <<< (QF-KP_SH)) + (err_s <<< (QF-KI_SH));
    end

    // slot/address helper (read_idx mod NUM_FRAMES)
    function [2:0] slot_of; input [31:0] idx; begin slot_of = idx % NUM_FRAMES; end endfunction

    always @(posedge clk) begin
        if (!rstn) begin
            inc <= (32'd1 <<< QF);           // seed 1.0; servo learns the truth
            acc <= 48'd0; integ <= 0; err_prev <= 0; nadv_q <= 0; occ_q <= 0;
            read_idx <= 0; primed <= 1'b0;
            read_slot<=0; read_base_addr<=FRAME_BUF_BASE; write_slot<=0;
            read2_slot<=0; read2_base_addr<=FRAME_BUF_BASE; alpha<=0; blend_en<=0;
        end else if (ov_pulse && seen_fp) begin
            if (!primed) begin
                // center the reader at SETPOINT behind newest on first output frame
                primed   <= 1'b1;
                read_idx <= newest - SETPOINT;
                acc      <= 48'd0;
                read_slot      <= slot_of(newest - SETPOINT);
                read_base_addr <= FRAME_BUF_BASE + slot_of(newest - SETPOINT) * SLOT_STRIDE;
                write_slot     <= fp_use[2:0];
            end else begin
                read_idx <= ridx_new;
                acc      <= {32'd0, acc_sum[QF-1:0]};   // keep fractional remainder
                // PI servo update
                integ    <= integ + err_s;
                inc      <= inc + dinc;
                err_prev <= err_s;
                nadv_q   <= (n_adv > 4'hF) ? 4'hF : n_adv[3:0];
                occ_q    <= occ_s[7:0];

                // gen-lock outputs (frame S)
                read_slot      <= slot_of(ridx_new);
                read_base_addr <= FRAME_BUF_BASE + slot_of(ridx_new) * SLOT_STRIDE;
                write_slot     <= fp_use[2:0];

                // blend outputs (frame S+1, alpha) — used when the dual-fetch path is wired.
                // alpha-gated: only blend when frac is meaningfully fractional AND S+1 is a
                // safe, completed frame (within the same safety window).
                alpha    <= acc_sum[QF-1 -: 8];
                read2_slot      <= slot_of(ridx_new + 32'd1);
                read2_base_addr <= FRAME_BUF_BASE + slot_of(ridx_new + 32'd1) * SLOT_STRIDE;
                blend_en <= (acc_sum[QF-1:0] > BLEND_EPS[19:0]) &&
                            ((ridx_new + 32'd1) <= newest) &&
                            ((newest - (ridx_new + 32'd1)) <= {20'd0, max_lag});
            end
        end
    end

    // clamp inc into [0.05 .. 5.0] (Q20) each cycle
    always @(posedge clk) begin
        if (rstn) begin
            if (inc < (32'sd52429))   inc <= 32'sd52429;     // 0.05
            if (inc > (32'sd5242880)) inc <= 32'sd5242880;   // 5.0
        end
    end

    assign dbg_inc  = inc[19:4];
    assign dbg_occ  = occ_q;
    assign dbg_nadv = nadv_q;
endmodule

`default_nettype wire
