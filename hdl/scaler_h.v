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

    // Accumulator
    reg  [11:0] accum;
    wire [11:0] accum_next = accum + OUT_W[11:0];
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

    /* SHIPPED CONFIG (iter3o/iter3q): MAC bypassed — output = window[3]
     * (center-tap nearest-neighbor pick). Eliminates kernel ringing AND
     * source-noise amplification at edges. Why this instead of a kernel:
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
     * To restore MAC: replace these 3 lines with the original mac8_sat calls
     * (still defined below; coefficient ROM still loaded with Mitchell coeffs
     * so the math is correct the moment the MAC is wired back in). */
    wire [7:0] out_r = window[3][23:16];
    wire [7:0] out_g = window[3][15: 8];
    wire [7:0] out_b = window[3][ 7: 0];
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
                    // Start of frame: reset accum and latch TUSER for next emit.
                    accum         <= OUT_W[11:0];
                    pending_tuser <= 1'b1;
                    // Frame-atomic commit of runtime IN_W (any AXI-Lite
                    // change between frames takes effect here, not mid-frame).
                    in_w_active   <= in_w_runtime;
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
            end
        end
    end
endmodule

`default_nettype wire
