// pg_addrgen.v — present-geometry address generator (read-engine-B, Module 1).
//
// Walks the OUTPUT raster (OUT_W × OUT_H) and, for every output pixel, emits:
//   - in_window : is this output pixel inside the placed picture window?
//   - src_col   : which MASTER column to read (downscale map), valid in-window
//   - src_row   : which MASTER row to read,    valid in-window
//   - new_row   : 1-cycle hint at the first in-window pixel of a row whose
//                 src_row is needed (prefetch trigger for pg_linecache, M3).
//
// The picture is the un-windowed 1280×720 colored master in DDR. This module
// shrinks it to (out_w_win × out_h_win) and places it at (pos_x, pos_y) in the
// OUT_W×OUT_H raster; outside that window the compositor (M4) paints matte.
//
// DOWNSCALE MAP (per axis, here shown for H; V is identical with IN_H/out_h):
//   src_col(wx) = floor(wx * IN_W / out_w_win),   wx = ox - pos_x
// Implemented as a divider-free DDA using firmware-computed steps:
//   h_step_int  = IN_W / out_w_win        (integer quotient)
//   h_step_frac = IN_W % out_w_win        (remainder numerator, denom = out_w_win)
// so   src_col(wx) = wx*h_step_int + floor(wx*h_step_frac / out_w_win).
// Firmware computes the four step values once per geometry change and feeds
// them via GPIO — no hardware divide, just adders + a compare.
//
// This module touches NO DDR and has NO AXI — it is pure raster math, fully
// verifiable in sim against a floor() golden. Genlock/slot selection (M2),
// line fetch (M3), and resample/matte/compositing (M4) are separate modules.
//
// Output timing: results are registered; for a px_valid asserted in cycle T,
// o_valid + the o_* fields are valid in cycle T+1.

`default_nettype none
`timescale 1ns / 1ps

module pg_addrgen #(
    parameter integer OUT_W = 1280,   // output raster width
    parameter integer OUT_H = 720,    // output raster height
    parameter integer IN_W  = 1280,   // master source width
    parameter integer IN_H  = 720     // master source height
) (
    input  wire        clk,
    input  wire        rstn,

    // Output-raster walk control (driven by the compositor / VTC timing).
    input  wire        sof,        // 1-cycle pulse the cycle BEFORE the first active pixel
    input  wire        px_valid,   // 1 cycle per active output pixel (raster order)

    // Runtime geometry. Latched at sof so a mid-frame GPIO change is frame-atomic.
    input  wire [11:0] out_w_win,  // window width  (1..OUT_W)
    input  wire [11:0] out_h_win,  // window height (1..OUT_H)
    input  wire [11:0] pos_x,      // window left  — SIGNED 12b (two's complement); may be <0 (image off the left edge)
    input  wire [11:0] pos_y,      // window top   — SIGNED 12b; may be <0 (image off the top edge)
    input  wire [11:0] src_col0,   // DDA seed: source COLUMN shown at the first on-screen in-window pixel
    input  wire [11:0] src_row0,   // DDA seed: source ROW    shown at the first on-screen in-window pixel
    input  wire [11:0] h_step_int, // IN_W / out_w_win
    input  wire [11:0] h_step_frac,// IN_W % out_w_win
    input  wire [11:0] v_step_int, // IN_H / out_h_win
    input  wire [11:0] v_step_frac,// IN_H % out_h_win

    // Per-pixel result (registered; valid the cycle after px_valid).
    output reg         o_valid,
    output reg         o_in_window,
    output reg  [11:0] o_src_col,
    output reg  [11:0] o_src_row,
    output reg         o_new_row
);
    // ---- latched (frame-atomic) geometry ----
    reg [11:0] win_w, win_h, px0, py0;
    reg [11:0] hsi, hsf, vsi, vsf;
    reg [11:0] sc0, sr0;           // #29 latched source-crop offset (pan); DDA starts here not 0

    // ---- output-raster position ----
    reg [11:0] ox, oy;

    // ---- horizontal DDA state (current pixel's src_col + fractional accum) ----
    reg [11:0] h_src, h_frac;
    // ---- vertical DDA state (current row's src_row + fractional accum) ----
    reg [11:0] v_src, v_frac;

    // window membership for the CURRENT (ox, oy). pos is SIGNED: the window may
    // start off the left/top edge (px0<0), so the visible region begins at output 0
    // and the matte appears on the OPPOSITE edge. All membership compares are signed.
    wire signed [15:0] ox_s   = $signed({4'b0, ox});       // 0..OUT_W-1 (always >=0)
    wire signed [15:0] oy_s   = $signed({4'b0, oy});
    wire signed [15:0] px0_s  = {{4{px0[11]}}, px0};       // sign-extend 12b two's complement
    wire signed [15:0] py0_s  = {{4{py0[11]}}, py0};
    wire signed [15:0] winw_s = $signed({4'b0, win_w});
    wire signed [15:0] winh_s = $signed({4'b0, win_h});
    wire ox_in  = (ox_s >= px0_s) && (ox_s < (px0_s + winw_s));
    wire oy_in  = (oy_s >= py0_s) && (oy_s < (py0_s + winh_s));
    wire in_win = ox_in && oy_in;

    // first ON-SCREEN in-window column/row (= 0 when the window starts off-screen)
    wire signed [15:0] first_ox_s = (px0_s < 0) ? 16'sd0 : px0_s;

    // next output column / row
    wire        eol      = (ox == OUT_W[11:0] - 12'd1);
    wire [11:0] next_oy  = oy + 12'd1;
    wire signed [15:0] next_oy_s = oy_s + 16'sd1;

    // horizontal advance (for the NEXT in-window column)
    wire [12:0] h_frac_sum = {1'b0, h_frac} + {1'b0, hsf};
    wire        h_carry    = (h_frac_sum >= {1'b0, win_w});

    // vertical advance (for the NEXT in-window row)
    wire [12:0] v_frac_sum = {1'b0, v_frac} + {1'b0, vsf};
    wire        v_carry    = (v_frac_sum >= {1'b0, win_h});
    wire        next_oy_top = (next_oy_s == py0_s);
    wire        next_oy_in  = (next_oy_s > py0_s) && (next_oy_s < (py0_s + winh_s));

    // first in-window pixel of a row → prefetch hint (fires at output col 0 when off-screen-left)
    wire row_first_inwin = px_valid && in_win && (ox_s == first_ox_s);

    always @(posedge clk) begin
        if (!rstn) begin
            ox <= 12'd0; oy <= 12'd0;
            h_src <= 12'd0; h_frac <= 12'd0;
            v_src <= 12'd0; v_frac <= 12'd0;
            o_valid <= 1'b0; o_in_window <= 1'b0;
            o_src_col <= 12'd0; o_src_row <= 12'd0; o_new_row <= 1'b0;
            win_w <= OUT_W[11:0]; win_h <= OUT_H[11:0]; px0 <= 12'd0; py0 <= 12'd0;
            hsi <= 12'd1; hsf <= 12'd0; vsi <= 12'd1; vsf <= 12'd0;
        end else begin
            o_valid   <= 1'b0;
            o_new_row <= 1'b0;

            if (sof) begin
                // frame-atomic latch of geometry + reset of the raster walk
                win_w <= out_w_win; win_h <= out_h_win; px0 <= pos_x; py0 <= pos_y;
                hsi <= h_step_int; hsf <= h_step_frac;
                vsi <= v_step_int; vsf <= v_step_frac;
                sc0 <= src_col0; sr0 <= src_row0;          // #29 latch pan offset
                ox <= 12'd0; oy <= 12'd0;
                h_src <= src_col0; h_frac <= 12'd0;        // DDA starts at the crop offset
                v_src <= src_row0; v_frac <= 12'd0;
            end else if (px_valid) begin
                // ---- register this pixel's result ----
                o_valid     <= 1'b1;
                o_in_window <= in_win;
                o_src_col   <= h_src;
                o_src_row   <= v_src;
                o_new_row   <= row_first_inwin;

                // ---- advance horizontal DDA for the next column ----
                if (ox_in) begin
                    if (h_carry) begin
                        h_src  <= h_src + hsi + 12'd1;
                        h_frac <= h_frac_sum[11:0] - win_w;
                    end else begin
                        h_src  <= h_src + hsi;
                        h_frac <= h_frac_sum[11:0];
                    end
                end

                // ---- advance column / wrap row ----
                if (eol) begin
                    ox <= 12'd0;
                    oy <= next_oy;
                    // reset H DDA for the new row (overrides the advance above) — to the pan offset
                    h_src <= sc0; h_frac <= 12'd0;
                    // advance V DDA for the new row
                    if (next_oy_top) begin
                        v_src <= sr0; v_frac <= 12'd0;
                    end else if (next_oy_in) begin
                        if (v_carry) begin
                            v_src  <= v_src + vsi + 12'd1;
                            v_frac <= v_frac_sum[11:0] - win_h;
                        end else begin
                            v_src  <= v_src + vsi;
                            v_frac <= v_frac_sum[11:0];
                        end
                    end
                end else begin
                    ox <= ox + 12'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire
