// pg_chroma_mod.v — NTSC active-video chroma QAM modulator + color burst (composite STAGE 2, 2026-06-30).
//
// Engine B composite path runs at 27 MHz (clk_wiz_engb). This adds the color subcarrier that
// pg_composite_out (luma+sync, stage 1) left stubbed: RGB -> U/V color-difference, QAM-modulated onto
// the 3.579545 MHz subcarrier (chroma = U*sin(wt) + V*cos(wt)), plus the back-porch color burst.
// Output is a SIGNED chroma offset added to the luma DAC code by the caller.
//
// SAMPLE CLOCK = 27 MHz -> PHASE_INCREMENT = round(2^32 * 3.579545e6/27e6) = 0x21F07BD7 (0.000 ppm).
// Reuses chroma_lut_cos.hex (256-entry signed cos, peak +/-255); sin(x)=cos(x-90deg)=cos_lut[idx-64].
//
// INPUT byte order is the pipeline's R-B-G quirk: vid_rgb[23:16]=R, [15:8]=B, [7:0]=G (see
// schindler_pipeline_rbg_byte_order). U/V matrix coeffs are in that order.
//
// ARITHMETIC is golden-checked (python/encoder/gen_chroma_active_golden.py + pg_chroma_mod_tb).
// ABSOLUTE burst phase / U-V-vs-burst alignment is a SCOPE/TV-decode tuning job at the bench --
// CHROMA_SHIFT (chroma gain), BURST_AMP, and the burst axis are parameters for that.

`default_nettype none
`timescale 1ns / 1ps

module pg_chroma_mod #(
    parameter [31:0]  PHASE_INCREMENT = 32'h21F07BD7,  // 3.579545 MHz at 27 MHz
    parameter integer BURST_START     = 40,            // pixels after hsync fall (back porch)
    parameter integer BURST_END       = 100,           // ~9 subcarrier cycles wide
    parameter integer BURST_AMP       = 146,           // +/-20 IRE burst (DAC codes, tune on scope)
    parameter integer CHROMA_SHIFT    = 10             // active chroma gain: (U*sin+V*cos) >>> SHIFT (tune)
) (
    input  wire        clk, rstn,
    input  wire [23:0] vid_rgb,        // {R[23:16], B[15:8], G[7:0]}  (pipeline R-B-G order)
    input  wire        active,         // visible pixel
    input  wire        hsync,          // active-high; resets the per-line pixel counter
    output reg  signed [11:0] chroma   // signed chroma offset -> add to luma DAC code in the caller
);
    // ---- subcarrier NCO (free-running; non-line-locked, v1) ----
    reg [31:0] phase_acc;
    always @(posedge clk) phase_acc <= (!rstn) ? 32'd0 : phase_acc + PHASE_INCREMENT;
    wire [7:0] idx = phase_acc[31:24];

    // ---- cos LUT (shared with chroma_gen): cos(idx), sin(idx)=cos(idx-64) ----
    reg signed [9:0] cos_lut [0:255];
    initial $readmemh("chroma_lut_cos.hex", cos_lut);
    wire signed [9:0] cos_v = cos_lut[idx];
    wire signed [9:0] sin_v = cos_lut[(idx - 8'd64) & 8'hFF];

    // ---- RGB -> U,V (Q0.8 signed coeffs; R-B-G input order) ----
    wire signed [8:0] r = $signed({1'b0, vid_rgb[23:16]});
    wire signed [8:0] b = $signed({1'b0, vid_rgb[15:8]});
    wire signed [8:0] g = $signed({1'b0, vid_rgb[7:0]});
    // U = 0.492(B-Y) = -0.147R -0.289G +0.436B ; V = 0.877(R-Y) = 0.615R -0.515G -0.100B
    reg signed [17:0] u_acc, v_acc;    // Q0.8, registered (keep the 3-mult sum off the QAM path)
    // Q8 coeffs chosen so each row SUMS TO ZERO -> neutrals (R=B=G) carry no chroma exactly.
    // U: -38 +112 -74 = 0.  V: 157 -25 -132 = 0.  (V's B-coeff rounded -25.6->-25 not -26 to zero the sum.)
    always @(posedge clk) begin
        u_acc <= (-18'sd38)*r + ( 18'sd112)*b + (-18'sd74)*g;   // U = -0.147R +0.436B -0.289G  (R-B-G order)
        v_acc <= ( 18'sd157)*r + (-18'sd25)*b + (-18'sd132)*g;  // V =  0.615R -0.100B -0.515G
    end
    wire signed [9:0] u = u_acc >>> 8; // back to signed integer U,V (~+/-160)
    wire signed [9:0] v = v_acc >>> 8;

    // ---- QAM: chroma_active = (U*sin + V*cos) >>> CHROMA_SHIFT ----
    reg signed [20:0] qam;             // U*sin + V*cos, registered
    always @(posedge clk) qam <= (u * sin_v) + (v * cos_v);
    wire signed [11:0] chroma_active = qam >>> CHROMA_SHIFT;

    // ---- burst: -U axis (= -sin) during the back-porch window ----
    reg [11:0] pcnt;                   // pixels since hsync (per-line)
    reg hs_d;
    always @(posedge clk) begin
        hs_d <= hsync;
        if (!rstn)            pcnt <= 12'd0;
        else if (hsync)       pcnt <= 12'd0;         // held in reset through hsync
        else                  pcnt <= pcnt + 12'd1;
    end
    wire in_burst = (pcnt >= BURST_START[11:0]) && (pcnt < BURST_END[11:0]);
    wire signed [20:0] burst_full = (-sin_v) * $signed({11'd0, BURST_AMP[9:0]});
    wire signed [11:0] burst_sig  = burst_full >>> 8;

    // ---- output mux: burst (back porch) | active chroma | 0 ----
    always @(posedge clk) begin
        if (!rstn)         chroma <= 12'sd0;
        else if (in_burst) chroma <= burst_sig;
        else if (active)   chroma <= chroma_active;
        else               chroma <= 12'sd0;
    end
endmodule

`default_nettype wire
