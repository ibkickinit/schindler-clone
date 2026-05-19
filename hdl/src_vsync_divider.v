// src_vsync_divider.v — Phase E2.1 source-vsync-derived loop reference.
//
// Takes the HDMI source's vsync signal (from dvi2rgb_0/vid_pVSync, on the
// PixelClk domain) and produces a stream of pulses (on FCLK_CLK0) at rate
// (source_rate × M / N) using a Bresenham fractional divider. This output
// feeds the ref_mux's ref_ext1 input (sel=11), letting the loop's phase
// detector lock against a source-derived reference instead of the fixed
// synth_vsync_gen.
//
// Why this matters (per Phase E1.8 finding): with a fixed 50 Hz synth ref,
// the loop pulls the output to 50.000 Hz exactly, and source-to-output
// ratio drifts with the actual source rate (Mac at 59.94 Hz → tear in
// ~50 sec; Apple TV at 60.001 → tear in ~50 min). With source-derived
// reference scaled by exactly the desired FRC ratio (M/N = 5/6 for the
// 60→50 case), the loop locks output to source × M/N — ratio is then
// locked-by-construction and drift is zero regardless of source rate.
//
// Architecture:
//   source_vsync_async (PixelClk domain)
//     → 2-FF sync to FCLK_CLK0
//     → rising-edge detector
//     → Bresenham accumulator: on each source edge, acc += M;
//       while acc >= N, acc -= N and emit a 1-cycle pulse
//     → pulse output (each pulse → one ref edge in vsync_timestamp)
//
// Bresenham guarantees zero long-term drift: exactly M output pulses per
// N source edges. Short-term jitter ±1 source period (= 16.67 ms for
// 60 Hz source); the loop's PI controller filters this out over time.
//
// Common configurations:
//   M=1, N=1: passthrough (output edge per source edge). Use for 1:1
//             modes (60→60, 50→50) where output matches source rate.
//   M=5, N=6: 60→50. 5 output pulses per 6 source edges → 50 Hz from
//             60 Hz source.
//   M=2, N=5: 60→24. 2 output pulses per 5 source edges → 24 Hz from
//             60 Hz source.
//   M=1, N=2: 60→30. Etc.
//
// CDC handling: source_vsync_async transitions are asynchronous from
// FCLK_CLK0's perspective. The 2-FF synchronizer with ASYNC_REG=TRUE
// handles metastability. Source vsync pulse is ~74 µs HIGH per frame, so
// even a one-cycle FCLK_CLK0 sample is guaranteed to catch it.
//
// Output is a 1-cycle FCLK_CLK0 pulse per ref event. Width=1 cycle is
// fine because vsync_timestamp's internal 3-FF sync chain (which already
// exists for the legacy async-input contract) re-samples on FCLK_CLK0,
// and our pulse is already synchronous to that clock — no edge-loss risk.

`default_nettype none
`timescale 1ns / 1ps

module src_vsync_divider #(
    parameter integer COUNT_WIDTH = 8,                    // enough for ratios up to 255:1
    parameter [COUNT_WIDTH-1:0] DEFAULT_M = 8'd1,        // numerator   (output count)
    parameter [COUNT_WIDTH-1:0] DEFAULT_N = 8'd1         // denominator (source count)
)(
    input  wire                       clk,                  // FCLK_CLK0 (100 MHz)
    input  wire                       aresetn,              // active-low, sync to clk
    input  wire                       source_vsync_async,   // from dvi2rgb/vid_pVSync
    input  wire [COUNT_WIDTH-1:0]     m_in,                 // runtime M (0 → use DEFAULT_M)
    input  wire [COUNT_WIDTH-1:0]     n_in,                 // runtime N (0 → use DEFAULT_N)
    output wire                       vsync_out             // 1-cycle pulses at source × M/N
);

    // ----- 2-FF CDC synchronizer for source vsync -----
    (* ASYNC_REG = "TRUE" *) reg src_sync_q1, src_sync_q2;
    always @(posedge clk) begin
        if (!aresetn) begin
            src_sync_q1 <= 1'b0;
            src_sync_q2 <= 1'b0;
        end else begin
            src_sync_q1 <= source_vsync_async;
            src_sync_q2 <= src_sync_q1;
        end
    end

    // ----- Rising-edge detector -----
    reg src_sync_d;
    always @(posedge clk) begin
        if (!aresetn) src_sync_d <= 1'b0;
        else          src_sync_d <= src_sync_q2;
    end
    wire src_rising = src_sync_q2 && !src_sync_d;

    // ----- Effective M and N -----
    // Inputs of 0 fall back to the parameter defaults. This lets the BD
    // wire AXI GPIO outputs through without needing firmware to write a
    // sensible value before things work at boot.
    wire [COUNT_WIDTH-1:0] m_eff = (m_in == {COUNT_WIDTH{1'b0}}) ? DEFAULT_M : m_in;
    wire [COUNT_WIDTH-1:0] n_eff = (n_in == {COUNT_WIDTH{1'b0}}) ? DEFAULT_N : n_in;

    // ----- Bresenham fractional accumulator -----
    // On each source rising edge: acc += M. While acc >= N: acc -= N and
    // emit a pulse. Guaranteed exactly M pulses per N source edges over
    // the long run.
    //
    // For M ≤ N (the FRC down-conversion case), the inner `while acc >= N`
    // fires at most once per source edge (acc starts < N, adds ≤ N, stays
    // < 2N). For M > N (up-conversion), it could fire multiple times per
    // source edge — but our FRC use cases are always M ≤ N (output rate
    // ≤ source rate for 60→50, 60→24, etc.), so a single-shot deduction
    // per source edge is sufficient. M > N is not supported by this
    // implementation; firmware should enforce M ≤ N at config time.
    //
    // ACC_WIDTH = COUNT_WIDTH + 1 so the acc+M can hold up to 2N-1
    // without overflow.
    localparam integer ACC_WIDTH = COUNT_WIDTH + 1;
    reg [ACC_WIDTH-1:0] acc;
    reg                  pulse_q;

    always @(posedge clk) begin
        if (!aresetn) begin
            acc     <= {ACC_WIDTH{1'b0}};
            pulse_q <= 1'b0;
        end else if (src_rising) begin
            // Increment acc by M.
            // If new acc >= N, subtract N and emit pulse this cycle.
            // Otherwise no pulse, just advance acc.
            if ((acc + m_eff) >= n_eff) begin
                acc     <= (acc + m_eff) - n_eff;
                pulse_q <= 1'b1;
            end else begin
                acc     <= acc + m_eff;
                pulse_q <= 1'b0;
            end
        end else begin
            // No source edge this cycle → no pulse.
            pulse_q <= 1'b0;
        end
    end

    assign vsync_out = pulse_q;

endmodule

`default_nettype wire
