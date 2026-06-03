// fp_mon_detector.v — sticky monitor: does s2mm_frame_ptr_out ever DECREASE (mod N)?
//
// The pg_cadence (FRC cadence controller) safety argument rests on ONE physical assumption:
// the VDMA S2MM write pointer is forward-monotonic. That's load-bearing and must be VALIDATED,
// not assumed. An ILA window (<1 s) can't catch a rare genlock-corner event; this LATCHES it in
// fabric, polled over UART for minutes/hours across drift + resolution change + hot-plug.
//
// v2 (2026-06-03) — HARDENED after the v1 simple debounce gave a false `decreased=1` at steady
// state (live read-engine on the same pointer is visually clean, so a real frequent decrease was
// implausible). s2mm_frame_ptr_out is a multi-bit BINARY pointer crossing an async CDC; during a
// ~1-cycle transition (e.g. 3→4 flips all bits) a 1-sample debounce can latch a transient mixed
// value → spurious large delta → false decrease. FIX: accept a new value only after it is STABLE
// for STABLE_CYC consecutive synced samples (the pointer is constant for ~ms between frames, so
// real values pass trivially; 1-2-cycle transition glitches never reach STABLE_CYC). Plus full
// DIAGNOSTICS so a real decrease is unmistakable: latch the first decrease's from→to slots and a
// saturating count.
//
// Clocked on FCLK_CLK0; frame_ptr_async (S2MM clock domain) brought over with a 2-FF sync feeding
// the stability filter. A forward delta (mod N) > N/2 is the signature of a decrease.

`default_nettype none
`timescale 1ns / 1ps

module fp_mon_detector #(
    parameter integer NUM_FRAMES = 5,
    parameter integer STABLE_CYC = 8       // consecutive equal samples required to accept a value
) (
    input  wire        clk,                // FCLK_CLK0
    input  wire        rstn,
    input  wire [5:0]  frame_ptr_async,    // s2mm_frame_ptr_out (async to clk)
    // 16-bit summary (diag GPIO's mm2s field):
    //   [0]      decreased  — STICKY: forward-delta > N/2 seen (decrease OR wrap of a <N cycle)
    //   [5:1]    visited    — bitmask of which slots 0..4 the pointer was EVER seen at
    //   [8:6]    max_slot   — highest slot value seen  (resolves the real cycle depth / modulus)
    //   [11:9]   max_fwd    — largest forward step <=N/2 (1=linear, 2+=skip)
    //   [15:12]  dec_count  — # of >N/2 events (4-bit saturating)
    output wire [15:0] mon
);
    // ---- 2-FF sync ----
    (* ASYNC_REG = "TRUE" *) reg [5:0] q1, q2;
    always @(posedge clk) begin
        if (!rstn) begin q1<=0; q2<=0; end
        else begin q1<=frame_ptr_async; q2<=q1; end
    end

    // ---- robust stability filter: accept `fp` only after q2 stable STABLE_CYC samples ----
    reg [5:0] cand, fp;
    reg [3:0] stbl;
    reg       seen;
    always @(posedge clk) begin
        if (!rstn) begin cand<=0; fp<=0; stbl<=0; seen<=0; end
        else if (q2 != cand) begin cand<=q2; stbl<=0; end       // value moving → restart count
        else if (stbl < STABLE_CYC[3:0]) stbl<=stbl+4'd1;       // counting up to stable
        else if (!seen) begin seen<=1'b1; fp<=cand; end          // first accepted value
        else fp<=cand;                                           // settled; fp tracks accepted value
    end

    // ---- decrease detector + range characterization on the robustly-accepted `fp` ----
    reg [5:0]  fp_seen;
    reg        seen2, decreased;
    reg [2:0]  max_fwd, max_slot;
    reg [4:0]  visited;            // bitmask: which of slots 0..4 the pointer was ever at
    reg [3:0]  dec_count;
    wire [5:0] d = (fp + NUM_FRAMES[5:0] - fp_seen) % NUM_FRAMES[5:0];   // forward delta [0..N-1]
    always @(posedge clk) begin
        if (!rstn) begin
            fp_seen<=0; seen2<=0; decreased<=0; max_fwd<=0; max_slot<=0; visited<=0; dec_count<=0;
        end else if (seen) begin
            // characterize range on every accepted value
            if (fp[2:0] <= 3'd4) visited <= visited | (5'd1 << fp[2:0]);
            if (fp[2:0] > max_slot) max_slot <= fp[2:0];
            if (!seen2) begin seen2<=1'b1; fp_seen<=fp; end
            else if (fp != fp_seen) begin
                if (d > (NUM_FRAMES[5:0]>>1)) begin                       // > N/2 ⇒ decrease OR wrap-of-<N-cycle
                    decreased <= 1'b1;
                    if (dec_count != 4'hF) dec_count <= dec_count + 4'd1;
                end else if (d[2:0] > max_fwd) max_fwd <= d[2:0];         // largest forward skip
                fp_seen <= fp;
            end
        end
    end

    assign mon = {dec_count, max_fwd, max_slot, visited, decreased};
endmodule

`default_nettype wire
