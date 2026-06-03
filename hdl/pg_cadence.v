// pg_cadence.v — FRC cadence controller (read-engine-B). Drop-in superset of pg_genlock.
//
// Replaces pg_genlock's FIXED read = frame_ptr-READ_DELAY follower with an FRC cadence
// for an ASYNC source (the box is a genlock CONVERTER; the source is never the output
// reference). Behavioral algorithm proven + gate-hardened in sim/frc_cadence_model_tb.v
// (docs/dual-engine-frc-plan.md §13); RTL gated by sim/pg_cadence_tb.v.
//
// ROBUST POINTER-FOLLOW (v2-style, 2026-06-03) — the safety-critical fix:
//   An earlier draft reconstructed an ABSOLUTE write index by summing frame_ptr deltas.
//   That reintroduced pg_genlock-v1's linear-pointer assumption, which was BENCH-DISPROVEN
//   (2026-06-01: S2MM Dynamic-Genlock does NOT cycle framestores linearly). A single
//   backward/irregular pointer move corrupted the absolute index permanently.
//   This version does NO absolute reconstruction. Like pg_genlock v2 it works purely in
//   mod-N space relative to the CURRENT pointer:
//
//       read_slot  = (frame_ptr - lag)     mod N        // S   (primary fetch)
//       read2_slot = (frame_ptr - lag + 1) mod N        // S+1 (blend partner, newer)
//
//   read_slot is ALWAYS `lag` (>=1) behind the in-progress slot, regardless of frame_ptr
//   history — so it can NEVER be the slot the writer is currently on. Safety is by
//   construction and robust to skips / repeats / backward moves / CDC glitches.
//
//   `lag` is sized conservatively from the rate so the writer can't lap the read slot
//   mid-frame:  lag = clamp( N - eff - 1 - J - O - MARGIN , LAG_MIN , N-2 ),
//   where eff = max( ceil(inc) , dnew ) and dnew = the forward pointer delta THIS frame.
//   A glitch/backward move shows as a LARGE dnew -> eff large -> lag SMALL (read nearer the
//   head) -> conservatively SAFE. So an irregular pointer degrades to a safe read, never a
//   collision. inc is an IIR estimate of the source rate (R) used for lag sizing + the
//   Mackin blend weight alpha; alpha is NON-safety-critical (it only weights two slots that
//   are both already safely chosen), so a transient rate error can't cause a collision.
//
// BLEND needs lag>=2 (so S+1 is a completed frame). BLEND-DISABLE / alpha-snap (blend_mode
// =0) rounds to the nearer completed frame (single fetch) — halves engine A's DDR read.
//
// frame_ptr is async (FCLK_CLK1); CDC = 2-FF + debounce. XDC false-paths fp_q1_reg[*]/D,
// bm_q1_reg/D.

`default_nettype none
`timescale 1ns / 1ps

module pg_cadence #(
    parameter [31:0]  FRAME_BUF_BASE = 32'h1000_0000,
    parameter integer NUM_FRAMES     = 7,
    parameter integer SLOT_STRIDE    = 2768640,
    parameter integer MARGIN         = 2,     // safety headroom (frames) below the lap bound
    parameter integer J_MARG         = 1,     // jitter allowance (writer burst beyond ceil(R))
    parameter integer O_MARG         = 0,     // read-overlap allowance (0 @720p, 1 @1080p)
    parameter integer LAG_MIN        = 1,     // never read the in-progress slot (lag>=1)
    parameter integer FILT_SH        = 4,     // rate IIR: inc += (R_meas - inc) >> FILT_SH
    parameter integer DCAP           = 4,     // cap on dnew fed to the IIR (glitch immunity)
    parameter integer BLEND_EPS      = 4096   // alpha deadband in Q20
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [5:0]  frame_ptr,   // S2MM in-progress framestore (FCLK_CLK1, async)
    input  wire        out_vsync,   // output VTC vsync (this clock domain)
    input  wire        blend_mode,  // 1 = Mackin blend (dual-fetch), 0 = alpha-snap (single)

    output reg  [2:0]  read_slot,
    output reg  [31:0] read_base_addr,
    output reg  [2:0]  write_slot,

    output reg  [2:0]  read2_slot,
    output reg  [31:0] read2_base_addr,
    output reg  [7:0]  alpha,
    output reg         blend_en,

    output wire [15:0] dbg_inc,
    output wire [7:0]  dbg_dnew,
    output wire [3:0]  dbg_lag
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

    // ---------- blend_mode CDC ----------
    (* ASYNC_REG = "TRUE" *) reg bm_q1, bm_q2;
    always @(posedge clk) begin bm_q1 <= blend_mode; bm_q2 <= bm_q1; end

    // ---------- output-vsync rising edge ----------
    reg ov_q;
    always @(posedge clk) ov_q <= (!rstn) ? 1'b0 : out_vsync;
    wire ov_pulse = out_vsync & ~ov_q;

    // ---------- state ----------
    reg  [5:0]  fp_prev;          // fp_use at the previous output frame (mod-N, relative only)
    reg         seen;
    reg  signed [31:0] inc;       // Q12.20 IIR estimate of R (for lag sizing + alpha)
    reg         [31:0] acc;       // Q12.20 fractional phase for alpha
    reg         [3:0]  lag_q, dnew_q;

    // ---------- combinational next-step (all mod-N relative; NO absolute index) ----------
    reg  [5:0]  dnew, eff;
    reg  [11:0] ceil_inc;
    reg  signed [13:0] ml_s;
    reg  [5:0]  lag;
    reg  [31:0] acc_sum;
    reg  [19:0] frac;
    reg  [5:0]  s_lag, s_slot, s2_slot, prim_slot;
    reg         do_blend, snap_up;

    function [2:0] slot3; input [5:0] s; begin slot3 = s % NUM_FRAMES; end endfunction
    function [31:0] base6; input [5:0] s; begin base6 = FRAME_BUF_BASE + (s % NUM_FRAMES)*SLOT_STRIDE; end endfunction

    always @(*) begin
        // forward pointer delta this frame (mod N). A backward/irregular move shows up as a
        // LARGE delta -> larger eff -> SMALLER lag -> read nearer the head -> safe.
        dnew    = (fp_use + NUM_FRAMES[5:0] - fp_prev) % NUM_FRAMES[5:0];
        ceil_inc = inc[31:QF] + (|inc[QF-1:0] ? 12'd1 : 12'd0);
        // eff = conservative rate = max(filtered estimate, this-frame measured advance)
        eff     = (ceil_inc[5:0] > dnew) ? ceil_inc[5:0] : dnew;
        // max safe lag = N - eff - 1 - J - O - MARGIN, clamped to [LAG_MIN, N-2]
        ml_s    = NUM_FRAMES[13:0] - {8'd0,eff} - J_MARG[13:0] - O_MARG[13:0] - MARGIN[13:0] - 14'd1;
        if      (ml_s < LAG_MIN[13:0])      lag = LAG_MIN[5:0];
        else if (ml_s > (NUM_FRAMES-2))     lag = (NUM_FRAMES-2);
        else                                lag = ml_s[5:0];

        // alpha phase accumulator (non-safety)
        acc_sum = acc + inc;
        frac    = acc_sum[QF-1:0];

        // blend pair (pointer-relative): S = fp_use-lag, S+1 = fp_use-lag+1 (newer)
        s_slot  = (fp_use + 6'd2*NUM_FRAMES[5:0] - lag) % NUM_FRAMES[5:0];
        s2_slot = (fp_use + 6'd2*NUM_FRAMES[5:0] - lag + 6'd1) % NUM_FRAMES[5:0];
        do_blend = bm_q2 && (lag >= 6'd2) && (frac > BLEND_EPS[19:0]) && (frac < (ONE[19:0]-BLEND_EPS[19:0]));
        // alpha-snap (single-fetch): round to the nearer completed frame (only if lag>=2)
        snap_up  = (!bm_q2) && (lag >= 6'd2) && frac[QF-1];
        prim_slot = snap_up ? s2_slot : s_slot;
    end

    always @(posedge clk) begin
        if (!rstn) begin
            fp_prev <= 0; seen <= 1'b0; inc <= ONE; acc <= 0; lag_q <= 0; dnew_q <= 0;
            read_slot<=0; read_base_addr<=FRAME_BUF_BASE; write_slot<=0;
            read2_slot<=0; read2_base_addr<=FRAME_BUF_BASE; alpha<=0; blend_en<=0;
        end else if (ov_pulse) begin
            fp_prev <= fp_use;
            if (!seen) begin
                seen <= 1'b1;                 // first frame: just capture the pointer
            end else begin
                // rate IIR toward the (capped) measured advance
                if      (inc + ((($signed({{26{1'b0}}, ((dnew>DCAP[5:0])?DCAP[5:0]:dnew)}) <<< QF) - inc) >>> FILT_SH) < 32'sd52429)
                    inc <= 32'sd52429;
                else if (inc + ((($signed({{26{1'b0}}, ((dnew>DCAP[5:0])?DCAP[5:0]:dnew)}) <<< QF) - inc) >>> FILT_SH) > 32'sd5242880)
                    inc <= 32'sd5242880;
                else
                    inc <= inc + ((($signed({{26{1'b0}}, ((dnew>DCAP[5:0])?DCAP[5:0]:dnew)}) <<< QF) - inc) >>> FILT_SH);
                acc <= {12'd0, frac};

                read_slot      <= slot3(prim_slot);
                read_base_addr <= base6(prim_slot);
                write_slot     <= fp_use[2:0];
                read2_slot      <= slot3(s2_slot);
                read2_base_addr <= base6(s2_slot);
                alpha    <= do_blend ? frac[QF-1 -: 8] : 8'd0;
                blend_en <= do_blend;
                lag_q  <= lag[3:0];
                dnew_q <= dnew[3:0];
            end
        end
    end

    assign dbg_inc  = inc[19:4];
    assign dbg_dnew = {4'd0, dnew_q};
    assign dbg_lag  = lag_q;
endmodule

`default_nettype wire
