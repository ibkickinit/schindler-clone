// pg_osd.v — OUTPUT-side on-screen-display compositor (OSD-1/2, 2026-07-01).
//
// Overlays a firmware-writable text GRID on the HDMI output pixel stream, AFTER the warp + color
// pipeline, so the menu is visible over ANY source (HDMI passthrough, warped content, TSG). Inserts
// on the parallel video bus: axis_to_vid_io_0/vid_data -> pg_osd -> rgb2dvi/vid_pData. Derives the
// active-pixel position (hc,vc) from the incoming sync (like pg_composite_out), so no extra timing wiring.
//
// Reuses the OSD-0 font ROM (pg_font8x16.mem, 8x16 ASCII), drawn at 2x -> 16x32 px cells.
// Grid: COLS x ROWS cells of {inv, char[7:0]} in a BRAM firmware writes via osd_load (data-then-strobe
// CDC, same as OSD-0). Per-cell inverse bit = selection highlight (OSD-2). Box has a solid bg so it's
// readable over any content; osd_en gates the whole overlay (0 = pure passthrough, bit-identical).
//
// vid_data is R-B-G pipeline order (schindler_pipeline_rbg_byte_order); OSD uses white/black/highlight
// which are swap-invariant, so no per-channel care needed here.

`default_nettype none
`timescale 1ns / 1ps

module pg_osd #(
    parameter integer COLS = 40, parameter integer ROWS = 16,   // 40x16 cells
    parameter integer X0   = 320, parameter integer Y0 = 200,   // menu box top-left (px, active-relative)
    parameter integer CW   = 16, parameter integer CH = 32      // cell size (8x16 font @ 2x)
) (
    input  wire        clk, rstn,
    input  wire        osd_en,               // 1 = overlay active; 0 = passthrough (bit-identical)
    // parallel video in (from axis_to_vid_io) — sync passes through untouched
    input  wire [23:0] vid_in,
    input  wire        vid_active, vid_hsync, vid_vsync,
    // firmware grid load: {strobe[19], inv[18], addr[17:8]=cell, char[7:0]}
    input  wire [19:0] osd_load,
    output reg  [23:0] vid_out,
    output reg         vid_active_o, vid_hsync_o, vid_vsync_o
);
    localparam integer NCELL = COLS*ROWS;

    // ---- active-pixel position tracker (derive hc,vc from sync edges) ----
    reg [11:0] hc, vc; reg act_d, vs_d;
    always @(posedge clk) begin
        if(!rstn) begin hc<=12'd0; vc<=12'hFFF; act_d<=1'b0; vs_d<=1'b0; end
        else begin
            act_d <= vid_active; vs_d <= vid_vsync;
            if (vid_vsync & ~vs_d) vc <= 12'hFFF;          // vsync rising -> frame restart (next active line = 0)
            if (vid_active & ~act_d) begin hc <= 12'd0; vc <= vc + 12'd1; end  // active rising -> new line
            else if (vid_active)      hc <= hc + 12'd1;
        end
    end

    // ---- font ROM (shared with OSD-0) ----
    reg [7:0] font_rom [0:2047];
    initial $readmemh("pg_font8x16.mem", font_rom);

    // ---- char grid BRAM: {inv, char[7:0]} per cell; firmware-written via CDC data-then-strobe ----
    reg [8:0] grid [0:NCELL-1];
    integer gi;
    initial for(gi=0;gi<NCELL;gi=gi+1) grid[gi] = 9'd32;      // all spaces
    (* ASYNC_REG="TRUE" *) reg [19:0] ld_q1, ld_q2; reg [19:0] ld_q3;
    always @(posedge clk) begin
        ld_q1 <= osd_load; ld_q2 <= ld_q1; ld_q3 <= ld_q2;
        if (ld_q2[19] != ld_q3[19]) grid[ld_q2[17:8]] <= {ld_q2[18], ld_q2[7:0]};  // strobe -> commit cell
    end

    // osd_en is a quasi-static FCLK GPIO bit crossing into this pixel clock -> 2-FF sync (false-path
    // en_q1/D in XDC). Without this the timer chases the unconstrained FCLK->pixclk crossing (WNS -3.4).
    (* ASYNC_REG="TRUE" *) reg en_q1, en_q2;
    always @(posedge clk) begin en_q1 <= osd_en; en_q2 <= en_q1; end

    // ---- measure the active region so the OSD auto-adapts to the output resolution ----
    // (720p vs 1080p etc.) Latch active width at line-end, height at vsync. Default 1080p until measured.
    reg [11:0] aw, ah;
    always @(posedge clk) begin
        if(!rstn) begin aw<=12'd1920; ah<=12'd1080; end
        else begin
            if (~vid_active & act_d) aw <= hc;             // active falling -> width = pixels drawn this line
            if (vid_vsync & ~vs_d)   ah <= vc + 12'd1;     // vsync -> height = active line count
        end
    end
    // auto scale: 2x cells for >=1600-wide (1080p), 1x for smaller (720p). Box auto-CENTERED in the active
    // region so it looks right at any resolution (no hardcoded origin). Divide-free: cell = 8<<s2 wide.
    wire        s2   = (aw >= 12'd1600);
    wire [11:0] boxW = s2 ? (COLS*16) : (COLS*8);
    wire [11:0] boxH = s2 ? (ROWS*32) : (ROWS*16);
    reg  [11:0] X0d, Y0d;
    always @(posedge clk) begin
        X0d <= (aw > boxW) ? ((aw - boxW) >> 1) : 12'd0;
        Y0d <= (ah > boxH) ? ((ah - boxH) >> 1) : 12'd0;
    end

    // ---- region test + cell/glyph coordinates (divide-free; variable shift by the auto scale s2) ----
    wire in_x = (hc >= X0d) && (hc < X0d + boxW);
    wire in_y = (vc >= Y0d) && (vc < Y0d + boxH);
    wire in_box = en_q2 && in_x && in_y;
    wire [11:0] rx = hc - X0d;
    wire [11:0] ry = vc - Y0d;
    wire [5:0]  col  = s2 ? (rx >> 4)          : (rx >> 3);        // / cell width (16 or 8)
    wire [4:0]  row  = s2 ? (ry >> 5)          : (ry >> 4);        // / cell height (32 or 16)
    wire [2:0]  gcol = s2 ? ((rx >> 1) & 3'd7) : (rx & 3'd7);      // font column 0..7
    wire [3:0]  grow = s2 ? ((ry >> 1) & 4'd15): (ry & 4'd15);     // font row 0..15
    wire [9:0]  cell_i = row*COLS + col;
    wire [8:0]  cbits = grid[cell_i];          // {inv, char}
    wire [10:0] f_addr = {cbits[6:0], grow};

    // ---- 1-stage registered read (font + selects), aligned to a 1-cycle passthrough delay ----
    reg [7:0] f_byte; reg [2:0] gcol_d; reg inbox_d, inv_d;
    reg [23:0] vid_d; reg act_dd, hs_d, vs_dd;
    always @(posedge clk) begin
        f_byte <= font_rom[f_addr]; gcol_d <= gcol; inbox_d <= in_box; inv_d <= cbits[8];
        vid_d  <= vid_in; act_dd <= vid_active; hs_d <= vid_hsync; vs_dd <= vid_vsync;
    end
    wire glyph = f_byte[7 - gcol_d];           // MSB = leftmost pixel
    // composite: inside box -> glyph pixel = fg, else bg. inverse swaps fg/bg (selection highlight).
    wire [23:0] fg = 24'hFFFFFF, bg = 24'h000000;
    wire [23:0] osd_px = inv_d ? (glyph ? bg : fg) : (glyph ? fg : bg);

    always @(posedge clk) begin
        if(!rstn) begin vid_out<=24'd0; vid_active_o<=1'b0; vid_hsync_o<=1'b0; vid_vsync_o<=1'b0; end
        else begin
            vid_out      <= inbox_d ? osd_px : vid_d;   // 1-cycle-delayed video, OSD composited
            vid_active_o <= act_dd; vid_hsync_o <= hs_d; vid_vsync_o <= vs_dd;
        end
    end
endmodule

`default_nettype wire
