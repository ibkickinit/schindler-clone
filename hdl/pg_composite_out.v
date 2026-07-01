// pg_composite_out.v — minimal FPGA-side COMPOSITE video encoder (2026-06-28).
//
// Engine B has no ADV7393 yet, so the FPGA does the composite encode itself: it folds the raster
// (luma + the video sync/blank timing) into ONE 8-bit sample stream destined for a single external
// R-2R resistor ladder -> a composite-format analog waveform on a scope. STAGE 1 = LUMA + SYNC only
// (monochrome composite): you see the per-bar luma staircase plus the sync/back-porch/active line
// structure. STAGE 2 (chroma 3.58 MHz modulation + color burst) is a follow-on; the hooks (cphase,
// burst window) are stubbed below so adding it doesn't re-shape the datapath.
//
// Levels are 8-bit DAC codes for the ladder (NOT IRE-accurate — timing is "wrong" by design here,
// this is a bring-up/scope aid): sync tip = 0, blank/black = BLANK_LVL, peak white = 255. Active
// luma maps Y in [0,255] into [BLANK_LVL, 255]. A runtime BRIGHTNESS gain (Q4.8, 256 = 1.0) scales Y.
//
// Timing inputs are the standard raster strobes from axis_to_vid_io / the VTC: `active` (visible
// pixel), `hsync`, `vsync` (active-high). sync = hsync|vsync (crude — no equalizing/serration pulses;
// fine for a scope). One sample per pixel clock; `comp` is registered.

`default_nettype none
`timescale 1ns / 1ps

module pg_composite_out #(
    parameter [7:0] BLANK_LVL = 8'd72    // black/blank pedestal in DAC codes (sync-to-blank ~= -40 IRE span)
) (
    input  wire        clk, rstn,
    // raster from axis_to_vid_io / VTC (this pixel-clock domain)
    input  wire [23:0] vid_rgb,          // {R[23:16], G[15:8], B[7:0]}  (NOTE: pipeline RBG order handled by caller)
    input  wire        vid_active,
    input  wire        vid_hsync,
    input  wire        vid_vsync,
    // runtime control (AXI GPIO, async — caller may 2-FF; quasi-static)
    input  wire [15:0] brightness,       // Q8.8 gain on luma, 256 = 1.0  (0..~4.0)
    input  wire        chroma_en,        // STAGE 2: 1 = add NTSC color subcarrier + burst; 0 = mono (stage 1)
    // composite sample to the external R-2R ladder pins
    output reg  [7:0]  comp,
    output reg         comp_blank,       // 1 during sync/blank (telemetry / future chroma gate)
    output wire        burst_window      // color-burst gate (from the chroma modulator)
);
    // ---- luma: Y = 0.299R + 0.587G + 0.114B  (Q0.8 coeffs: 77/150/29 = 256) ----
    wire [7:0] r = vid_rgb[23:16];
    wire [7:0] g = vid_rgb[15:8];
    wire [7:0] b = vid_rgb[7:0];
    reg [15:0] y0;                        // 8.8 luma accumulate, registered (keeps the 3 mults off the level path)
    wire pen_y = 1'b1;
    always @(posedge clk) if(pen_y) y0 <= (16'd77*r + 16'd150*g + 16'd29*b);
    wire [7:0] y = y0[15:8];

    // ---- brightness gain (Q8.8), clamp to 8-bit ----
    reg [23:0] yb1;                       // y * brightness, registered raw
    always @(posedge clk) yb1 <= y * brightness;   // 8b * 16b(Q8.8) -> 24b
    wire [15:0] yg = yb1[23:8];           // >>8 back to integer luma, 16-bit headroom
    wire [7:0]  y_clamp = (yg > 16'd255) ? 8'd255 : yg[7:0];

    // ---- active-luma into [BLANK_LVL, 255] ----
    wire [15:0] y_active = BLANK_LVL + ((y_clamp * (16'd255 - BLANK_LVL)) >> 8);
    wire [7:0]  y_lvl = (y_active > 16'd255) ? 8'd255 : y_active[7:0];

    // ---- STAGE 2: NTSC chroma (QAM color subcarrier + back-porch burst), signed offset ----
    wire signed [11:0] chroma_sig;
    pg_chroma_mod u_chroma (
        .clk(clk), .rstn(rstn), .vid_rgb(vid_rgb),
        .active(vid_active), .hsync(vid_hsync), .chroma(chroma_sig));
    assign burst_window = 1'b0;   // (the burst gate now lives inside pg_chroma_mod; kept for the port)

    // ---- base level (sync tip / blank pedestal / active luma) + chroma ----
    wire sync = vid_hsync | vid_vsync;
    reg [7:0] base_lvl; reg base_blank;
    always @(*) begin
        if(sync)            begin base_lvl = 8'd0;      base_blank = 1'b1; end  // sync tip
        else if(!vid_active) begin base_lvl = BLANK_LVL; base_blank = 1'b1; end  // blank pedestal
        else                begin base_lvl = y_lvl;     base_blank = 1'b0; end  // active luma
    end
    // add chroma everywhere EXCEPT sync (sync tip stays 0); chroma is itself 0 outside burst+active.
    wire signed [12:0] lvl_c = (sync || !chroma_en) ? $signed({5'd0, base_lvl})
                                                     : $signed({5'd0, base_lvl}) + $signed(chroma_sig);
    wire [7:0] comp_next = (lvl_c < 13'sd0) ? 8'd0 : (lvl_c > 13'sd255) ? 8'd255 : lvl_c[7:0];
    always @(posedge clk) begin
        if(!rstn) begin comp <= BLANK_LVL; comp_blank <= 1'b1; end
        else      begin comp <= comp_next; comp_blank <= base_blank; end
    end
endmodule

`default_nettype wire
