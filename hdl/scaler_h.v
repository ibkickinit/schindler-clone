// scaler_h.v — 8-tap polyphase horizontal scaler.
//
// Hard-coded for 1920 → 720 downscale (Phase C.1 first-light target).
// Per-channel MAC over 8 input pixels using phase-indexed coefficients.
// Per-phase coefficients sum to 1.0, so no brightness ripple.
//
// Streaming model (input runs faster than output, downscale):
//   for each input pixel that handshakes:
//     shift it into the 8-pixel window
//     accum += OUT_W (= 720)
//     if accum >= IN_W (= 1920):
//       emit one output pixel using current window + phase coefficients
//       accum -= IN_W
//       phase = (excess * PHASES) / OUT_W
//
// Phase pattern for 1920/720: cycles through {0, 21, 42} (with small
// integer-divide error) — 3 outputs per 8 inputs.
//
// Caveats / first-cut simplifications:
//   - Window starts at zero, so first ~4 output pixels per line are
//     attenuated. Visual: slightly darker pixels at the left edge.
//   - Output is one cycle late relative to "ideal" — slight pixel shift.
//   - TLAST/TUSER passed through to emit on the input cycle that triggers
//     output; not bit-exact but close enough for first-light.

`default_nettype none
`timescale 1ns / 1ps

module scaler_h #(
    parameter integer IN_W_MAX = 4096,  // sizing/sanity only; runtime IN_W from in_w_runtime
    parameter integer IN_W_DEFAULT = 1920,  // used pre-firmware-write (latched reset value)
    parameter integer OUT_W  = 720,
    parameter integer PHASES = 64,
    parameter integer TAPS   = 8
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

    /* Runtime source-horizontal-active count, driven by firmware from VTC
     * detector's DASIZE register via AXI GPIO (CDC'd into clk domain in
     * scaler_top). Latched into in_w_active at each input TUSER so the
     * value used for emit_now/excess is frame-atomic. */
    input  wire [11:0] in_w_runtime,

    /* G1 adjustable-scaler (2026-06-01): runtime OUTPUT width = the DDA
     * accumulator step. ratio = out_w_runtime / in_w_active. Smaller value →
     * fewer emits per line → narrower picture (the rest of the raster is
     * matte, filled downstream). Latched at TUSER for frame-atomic commit,
     * exactly like in_w_runtime. scaler_top zero-clamps to OUT_W so an
     * undriven/zero GPIO == full size == pre-G1 behavior (bit-identical). */
    input  wire [11:0] out_w_runtime,

    /* iter14 (2026-05-31): runtime kernel-mode selector.
     *   2'd0 = NN single-tap (newest pixel only) — sharpest; loses cols at non-1:1
     *   2'd1 = 2-tap boxcar (iter12+iter13b production default; rounded)
     *   2'd2 = 4-tap boxcar (softer; useful for noisy/motion content)
     *   2'd3 = reserved (future: polyphase MAC via existing coefficient ROM)
     * Sourced from AXI GPIO 7 bit field; CDC handled in scaler_top.
     * Default tied to 2'd1 (production behavior preserved). */
    input  wire [1:0]  kernel_mode,

    /* iter4g DIAG counter: count s_axis_tlast events between TUSERs.
     * Latched at TUSER into snap output for firmware to read. Tells us
     * how many input rows v_vid_in_axi4s actually delivered per frame. */
    output reg  [15:0] in_tlast_count_snap
);
    // Window: 8 pixels, [0] = newest, [7] = oldest
    reg [23:0] window [0:TAPS-1];

    // Pending TUSER — latched from input until the next emit consumes it
    reg pending_tuser;

    // Runtime IN_W, latched at TUSER for frame-atomic commit. Default value
    // covers boot before firmware programs it.
    reg [11:0] in_w_active;

    /* iter4g DIAG: TLAST counter. Increments per s_axis_tlast event,
     * snapshotted at TUSER (so reads after TUSER return previous frame's
     * count). */
    reg [15:0] in_tlast_count;

    // Runtime OUTPUT width (DDA step), latched at TUSER. Default OUT_W so
    // pre-firmware-write behavior == compile-time OUT_W.
    reg [11:0] out_w_active;

    // Accumulator. Step is the runtime out_w_active (was the OUT_W param).
    reg  [11:0] accum;
    wire [11:0] accum_next = accum + out_w_active;
    wire        emit_now   = accum_next >= in_w_active;
    wire [11:0] excess     = accum_next - in_w_active;   // valid when emit_now=1

    // Phase = excess * PHASES / OUT_W. Precomputed at elaboration as a
    // Q10 multiplier, rounded to nearest:
    //   PHASE_MUL_Q10 = round(PHASES * 1024 / OUT_W)
    // (PHASES=64, OUT_W=1280 → 51; OUT_W=1920 → 34; OUT_W=960 → 68.)
    localparam [16:0] PHASE_MUL_Q10 = (PHASES * 1024 + OUT_W/2) / OUT_W;
    wire [5:0] phase = ((excess * PHASE_MUL_Q10) >> 10);

    // Coefficient ROM
    wire [95:0] coeffs_flat;
    scaler_coeffs_h coeff_rom_inst (.phase(phase), .taps_flat(coeffs_flat));

    // Per-tap signed coefficient extraction
    wire signed [11:0] c0 = $signed(coeffs_flat[ 11: 0]);
    wire signed [11:0] c1 = $signed(coeffs_flat[ 23:12]);
    wire signed [11:0] c2 = $signed(coeffs_flat[ 35:24]);
    wire signed [11:0] c3 = $signed(coeffs_flat[ 47:36]);
    wire signed [11:0] c4 = $signed(coeffs_flat[ 59:48]);
    wire signed [11:0] c5 = $signed(coeffs_flat[ 71:60]);
    wire signed [11:0] c6 = $signed(coeffs_flat[ 83:72]);
    wire signed [11:0] c7 = $signed(coeffs_flat[ 95:84]);

    // Per-channel MAC and saturation. Pixel values are unsigned 8-bit;
    // signed product is in Q1.11 (12 bits) × U8 = 20 bits signed. Sum of 8
    // products = 23 bits signed. Shift right 11 to integer, saturate 0..255.
    function automatic [7:0] mac8_sat;
        input [7:0] p0, p1, p2, p3, p4, p5, p6, p7;
        input signed [11:0] k0, k1, k2, k3, k4, k5, k6, k7;
        reg signed [22:0] sum;
        begin
            sum =  $signed({1'b0, p0}) * k0
                 + $signed({1'b0, p1}) * k1
                 + $signed({1'b0, p2}) * k2
                 + $signed({1'b0, p3}) * k3
                 + $signed({1'b0, p4}) * k4
                 + $signed({1'b0, p5}) * k5
                 + $signed({1'b0, p6}) * k6
                 + $signed({1'b0, p7}) * k7;
            if (sum < 23'sd0)
                mac8_sat = 8'h00;
            else if (sum > 23'sd522239)   // 255 << 11 - 1
                mac8_sat = 8'hFF;
            else
                // Round-to-nearest: add 0.5 LSB (1024 in Q.11) before truncation.
                // Removes the -0.5 LSB DC bias of straight floor(sum>>11).
                mac8_sat = (sum + 23'sd1024) >>> 11;
        end
    endfunction

    /* SHIPPED CONFIG (iter3o/iter3q): MAC bypassed — output is a single
     * nearest-neighbor pick from the 8-pixel shift register. Eliminates
     * kernel ringing AND source-noise amplification at edges. Why this
     * instead of a kernel:
     *   - Mitchell with -0.036 sidelobe coefficients amplified ±1 LSB
     *     source/TMDS noise into ±35 LSB output excursions at high-contrast
     *     edges (visible as colored specks at color-bar boundaries — see
     *     ILA-confirmed iter3n data + memory schindler_phase_d_chroma_noise).
     *   - All-positive kernels (Linear, Gaussian sigma=0.7) eliminated the
     *     overshoot but produced visible interior texture from preserving
     *     source noise with insufficient averaging.
     *   - Nearest-neighbor: no amplification (1-to-1 source pixel pass), no
     *     interior texture, no edge ringing. Trade-off: no anti-aliasing on
     *     diagonals / fine text. Acceptable for current broadcast-style
     *     content; revisit when a wider-support all-positive kernel with
     *     enough smoothing for clean interiors gets designed.
     *
     * iter8 (2026-05-24): tap pick changed from window[3] (= pixel K-4 at
     * emit cycle K) to window[0] (= pixel K-1). Eliminated the 2-pixel
     * left margin but introduced a ~3-col right margin (source's right
     * edge runs off-screen because output col 1279 reads source col 1918
     * rather than source col 1915 like iter7 did).
     *
     * iter10 (2026-05-24): switched from single-tap NN to 8-tap boxcar
     * MAC. Bench result: too soft for vertical lines (~7-col fade), and
     * source's right-edge content past col ~1910 still not seen. The
     * 8-col blend was over-aggressive for sharp grid patterns.
     *
     * iter11 (2026-05-24): 2-tap boxcar = (window[0] + window[1]) / 2.
     * Bench confirmed tighter blur (~2-col fade), left line at col 0,1.
     * But last emit at cycle 1919 reads source cols 1917,1918 — col 1919's
     * vertical line never sampled. Right edge still black.
     *
     * iter12 (2026-05-24): 2-tap boxcar with newest tap = s_axis_tdata
     * (the just-arriving pixel) instead of window[1]. Output at emit
     * cycle K = avg(pixel K, pixel K-1). First emit (K=1) reads source
     * cols 0,1; last emit (K=1919) reads source cols 1918,1919. Full
     * source col range 0..1919 is now sampled. Same 2-tap blur level
     * just shifted by one source col to the right.
     *
     * iter13b (2026-05-30): added +1 round-to-nearest before the >>1.
     * Original `(a+b)>>1` truncates, biasing the output -0.5 LSB per
     * pixel; cumulative with iter13's V-side shift = -1 LSB per channel
     * across the H+V cascade = slight dark shift on every frame. The
     * MAC path (mac8_sat below) already does this rounding at line 127.
     * Cost: 3 LUTs (one +1 saturation per channel). Per audit-panel HDL
     * Agent finding 2026-05-30. */
    /* iter14 (2026-05-31): runtime kernel-mode mux. Three forms computed
     * in parallel; combinational mux on kernel_mode selects which feeds
     * m_axis_tdata. Mode 1 is the iter12/iter13b production default. */
    // Mode 0 — NN single-tap (newest = s_axis_tdata)
    wire [7:0] mode0_r = s_axis_tdata[23:16];
    wire [7:0] mode0_g = s_axis_tdata[15: 8];
    wire [7:0] mode0_b = s_axis_tdata[ 7: 0];

    // Mode 1 — 2-tap boxcar with iter13b round-to-nearest (production)
    wire [8:0] s2r = s_axis_tdata[23:16] + window[0][23:16] + 9'd1;
    wire [8:0] s2g = s_axis_tdata[15: 8] + window[0][15: 8] + 9'd1;
    wire [8:0] s2b = s_axis_tdata[ 7: 0] + window[0][ 7: 0] + 9'd1;
    wire [7:0] mode1_r = s2r[8:1];
    wire [7:0] mode1_g = s2g[8:1];
    wire [7:0] mode1_b = s2b[8:1];

    // Mode 2 — 4-tap boxcar (newest + window[0..2]) with +2 round-to-nearest
    wire [9:0] s4r = s_axis_tdata[23:16] + window[0][23:16]
                   + window[1][23:16]    + window[2][23:16] + 10'd2;
    wire [9:0] s4g = s_axis_tdata[15: 8] + window[0][15: 8]
                   + window[1][15: 8]    + window[2][15: 8] + 10'd2;
    wire [9:0] s4b = s_axis_tdata[ 7: 0] + window[0][ 7: 0]
                   + window[1][ 7: 0]    + window[2][ 7: 0] + 10'd2;
    wire [7:0] mode2_r = s4r[9:2];
    wire [7:0] mode2_g = s4g[9:2];
    wire [7:0] mode2_b = s4b[9:2];

    // Combinational mux. Mode 3 reserved → falls through to mode 1 default.
    reg [7:0] out_r, out_g, out_b;
    always @* begin
        case (kernel_mode)
            2'd0: begin out_r = mode0_r; out_g = mode0_g; out_b = mode0_b; end
            2'd1: begin out_r = mode1_r; out_g = mode1_g; out_b = mode1_b; end
            2'd2: begin out_r = mode2_r; out_g = mode2_g; out_b = mode2_b; end
            default: begin out_r = mode1_r; out_g = mode1_g; out_b = mode1_b; end
        endcase
    end
    // Reference unused coefficient wires so synthesis doesn't drop the ROM:
    wire _coef_keep = |{c0, c1, c2, c3, c4, c5, c6, c7};

    // AXIS handshake: ready when output stage is empty or being drained.
    assign s_axis_tready = !m_axis_tvalid || m_axis_tready;

    integer i;
    always @(posedge clk) begin
        if (!rstn) begin
            for (i = 0; i < TAPS; i = i + 1) window[i] <= 24'h0;
            accum         <= 12'd0;
            pending_tuser <= 1'b0;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 24'h0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
            in_w_active   <= IN_W_DEFAULT[11:0];
            out_w_active  <= OUT_W[11:0];
            in_tlast_count       <= 16'd0;
            in_tlast_count_snap  <= 16'd0;
        end else begin
            // Output side: clear valid when downstream takes
            if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                m_axis_tuser  <= 1'b0;
            end

            // Input side: when we accept a pixel
            if (s_axis_tvalid && s_axis_tready) begin
                // Shift window (window[0] newest)
                window[7] <= window[6];
                window[6] <= window[5];
                window[5] <= window[4];
                window[4] <= window[3];
                window[3] <= window[2];
                window[2] <= window[1];
                window[1] <= window[0];
                window[0] <= s_axis_tdata;

                // Update accumulator and possibly emit
                if (s_axis_tuser) begin
                    // Start of frame: prime accum with the (new) step + latch
                    // TUSER for next emit. Priming with out_w_active's new value
                    // keeps the DDA self-consistent at any size; at size=100%
                    // (out_w_runtime==OUT_W) this is identical to the old
                    // `accum <= OUT_W`.
                    accum         <= out_w_runtime;
                    pending_tuser <= 1'b1;
                    // Frame-atomic commit of runtime IN_W + OUT_W (AXI-Lite
                    // changes between frames take effect here, not mid-frame).
                    in_w_active   <= in_w_runtime;
                    out_w_active  <= out_w_runtime;
                    /* iter4g DIAG: snapshot previous frame's TLAST count
                     * for firmware to read, then reset for new frame.
                     * If TUSER and TLAST coincide on same pixel, count
                     * the TLAST too (start fresh frame already at 1). */
                    in_tlast_count_snap <= in_tlast_count;
                    in_tlast_count      <= s_axis_tlast ? 16'd1 : 16'd0;
                end else if (emit_now) begin
                    accum <= excess;
                end else begin
                    accum <= accum_next;
                end

                /* iter4g DIAG: count s_axis_tlast events between TUSERs
                 * (TUSER branch above resets/restarts count). This branch
                 * only fires for non-TUSER pixels with TLAST. */
                if (s_axis_tlast && !s_axis_tuser) begin
                    in_tlast_count <= in_tlast_count + 16'd1;
                end

                // Emit output if accum crossed
                if (emit_now) begin
                    m_axis_tdata  <= {out_r, out_g, out_b};
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= s_axis_tlast;     // last input pixel of line → last output pixel
                    m_axis_tuser  <= pending_tuser | s_axis_tuser;
                    pending_tuser <= 1'b0;             // consumed by this emit
                end

                /* iter6 H-shift fix (2026-05-23, simplified 2026-05-31):
                 * clear the H-window on TLAST so the next row's emit
                 * pipeline starts with an empty window. Eliminates the
                 * per-row "smear" / "wrap-look" artifact where each row's
                 * first 2-3 output pixels were weighted-average of the
                 * PREVIOUS row's last input pixels (visible on grid
                 * patterns at horizontal-line→normal-row boundaries).
                 *
                 * 2026-05-31 simplification (HDL audit follow-up): iter12's
                 * output uses only `s_axis_tdata + window[0]`, so we only
                 * need to clear window[0]. Taps window[1..7] are dead code
                 * kept alive by `_coef_keep` synth-keep — they shift but
                 * aren't read. Clearing only window[0] saves 7 × 24 = 168
                 * flop-loads per row. No functional change. */
                if (s_axis_tlast) begin
                    window[0] <= 24'h0;
                end
            end
        end
    end
endmodule

`default_nettype wire
