// pg_tsg.v — internal Test Signal Generator (color bars + ramp) on the WRITE side (2026-06-28).
//
// Generates a self-contained 1080p video raster (RGB + sync) so the pipeline has a known source with
// NO HDMI input. Wired into the write path (muxed against dvi2rgb at the v_vid_in_axi4s input, on an
// internal clock via a BUFGMUX clock-mux): the generated pattern is WRITTEN to DDR by the VDMA S2MM and
// then read by BOTH engines (warp→HDMI, composite→JC) — it flows through the WHOLE path to both outputs.
//
// Timing = CEA-861 1080p (1920×1080 active, HTOTAL 2200, VTOTAL 1125), positive H/V sync — matches what
// the pipeline already detects from a 1080p HDMI source (VTC_RX HACTIVE=1920 ...), so the firmware's
// runtime IN_W/IN_H path needs no change. Drive `clk` at the pixel rate (74.25 MHz = 1080p30, or 148.5 =
// 1080p60); the rate only sets frame cadence, not correctness.
//
// pattern: 0 = 100% color bars (8 × 240px: white/yellow/cyan/green/magenta/red/blue/black),
//          1 = horizontal luma ramp (0..255 across the active width),
//          2 = vertical luma ramp,  3 = flat 50% gray (DAC/level check).
//
// Output is the SAME bundle dvi2rgb presents to v_vid_in_axi4s: vid_data[23:0], vid_active, vid_hsync,
// vid_vsync (so the source mux is signal-for-signal). RGB order is standard {R,G,B}; the pipeline's
// RBG-byte quirk is downstream of the S2MM write and unaffected (the input is captured as RGB).

`default_nettype none
`timescale 1ns / 1ps

module pg_tsg #(
    parameter integer H_ACT = 1920, parameter integer H_TOT = 2200,
    parameter integer H_FP  = 88,   parameter integer H_SYNC = 44,
    parameter integer V_ACT = 1080, parameter integer V_TOT = 1125,
    parameter integer V_FP  = 4,    parameter integer V_SYNC = 5
) (
    input  wire        clk, rstn,
    input  wire [2:0]  pattern,            // 0 bars100 / 1 h-ramp / 2 v-ramp / 3 gray / 4 SMPTE bars /
                                           // 5 crosshatch+border / 6 checker64 / 7 checker1 (async GPIO; quasi-static)
    output reg  [23:0] vid_data,           // {R[23:16], G[15:8], B[7:0]}
    output reg         vid_active,
    output reg         vid_hsync,
    output reg         vid_vsync
);
    reg [11:0] hc, vc;
    always @(posedge clk) begin
        if(!rstn) begin hc<=12'd0; vc<=12'd0; end
        else begin
            if(hc==H_TOT-1) begin hc<=12'd0;
                vc <= (vc==V_TOT-1) ? 12'd0 : vc+12'd1;
            end else hc <= hc+12'd1;
        end
    end

    wire act = (hc < H_ACT) && (vc < V_ACT);
    // sync after front porch (positive polarity)
    wire hs  = (hc >= H_ACT + H_FP) && (hc < H_ACT + H_FP + H_SYNC);
    wire vs  = (vc >= V_ACT + V_FP) && (vc < V_ACT + V_FP + V_SYNC);

    // -------------------------------------------------------------------------
    // 2-stage pipeline, DIVIDE-FREE. The original used runtime division (hc*255/
    // H_ACT, hc/(H_ACT/8)) combinationally into vid_data -- a constant divider is a
    // long combinational cone that blew the 74.25 MHz (13.46 ns) budget (WNS -1.639
    // on vramp -> vid_data). Replace with: bar index = count of threshold crossings,
    // ramps = constant multiply + shift; register each (stage 1) so the only logic
    // into the output regs (stage 2) is the small pattern mux. The 2-cycle latency
    // is invisible (sync + data are pipelined together, raster stays self-consistent).
    // Ramp constants are tuned for 1080p (H_ACT=1920, V_ACT=1080); a non-1080p
    // instantiation would just get a differently-scaled diagnostic ramp.
    // -------------------------------------------------------------------------
    localparam integer BW = H_ACT/8;          // bar width (240 @ 1920)

    reg        act_q, hs_q, vs_q;
    reg [2:0]  bar_q;
    reg [7:0]  hramp_q, vramp_q;
    reg        grid_q, chk64_q, chk1_q;       // geometry/scaling patterns (all divide-free, registered)
    reg [2:0]  bar7_q;                         // SMPTE 7-bar column index (1920/7 boundaries)
    reg [1:0]  vsec_q;                         // SMPTE vertical section: 0 top bars / 1 castellation / 2 pluge row
    reg [2:0]  hbot_q;                         // SMPTE pluge-row horizontal segment index
    always @(posedge clk) begin
        if(!rstn) begin
            act_q<=1'b0; hs_q<=1'b0; vs_q<=1'b0; bar_q<=3'd0; hramp_q<=8'd0; vramp_q<=8'd0;
            grid_q<=1'b0; chk64_q<=1'b0; chk1_q<=1'b0; bar7_q<=3'd0; vsec_q<=2'd0; hbot_q<=3'd0;
        end else begin
            act_q <= act; hs_q <= hs; vs_q <= vs;
            // 8 color bars: index = number of bar-boundaries crossed (divide-free)
            bar_q <= (hc>=BW) + (hc>=2*BW) + (hc>=3*BW) + (hc>=4*BW)
                   + (hc>=5*BW) + (hc>=6*BW) + (hc>=7*BW);
            // SMPTE EG-1 geometry (1080p-specific boundaries, divide-free):
            //  7 main bars at k*1920/7 (274,549,823,1097,1371,1646); vertical sections at
            //  2/3 (720) and 3/4 (810); pluge-row segments (-I / 100% / +Q / black / pluge bars).
            bar7_q <= (hc>=12'd274)+(hc>=12'd549)+(hc>=12'd823)+(hc>=12'd1097)+(hc>=12'd1371)+(hc>=12'd1646);
            vsec_q <= (vc>=12'd720) + (vc>=12'd810);
            hbot_q <= (hc>=12'd320)+(hc>=12'd640)+(hc>=12'd960)+(hc>=12'd1280)+(hc>=12'd1413)+(hc>=12'd1546);
            // luma ramps ~hc*255/1920 and ~vc*255/1080 (divide-free; overflow during
            // blanking is masked by act_q=0 downstream). NOTE: the multiplier literal MUST
            // be wide (19'd..) -- Verilog sizes a*b to max(L(a),L(b)), so `hc * 12'd68`
            // evaluates in 12 bits and WRAPS (hc*68 needs 18 bits) -> black ramp. The 19-bit
            // literal forces a full-width multiply.
            hramp_q <= (hc * 19'd68) >> 9;     // 0..254 across 1920
            vramp_q <= (vc * 19'd60) >> 8;     // 0..252 across 1080
            // crosshatch: 2px lines every 128px (low 7 bits) + a 2px outer border. Pure
            // bit-mask/compare -> the best geometry/keystone alignment reference for warp.
            grid_q  <= (hc[6:0] < 7'd2) | (vc[6:0] < 7'd2)
                     | (hc < 12'd2) | (hc >= H_ACT-12'd2) | (vc < 12'd2) | (vc >= V_ACT-12'd2);
            chk64_q <= hc[6] ^ vc[6];          // 64px checkerboard (scaling/sharpness)
            chk1_q  <= hc[0] ^ vc[0];          // 1px checkerboard (Nyquist / DAC-eye stress)
        end
    end

    reg [23:0] bars;                          // 100% color bars
    always @(*) case(bar_q)
        3'd0: bars = 24'hFFFFFF;  // white
        3'd1: bars = 24'hFFFF00;  // yellow
        3'd2: bars = 24'h00FFFF;  // cyan
        3'd3: bars = 24'h00FF00;  // green
        3'd4: bars = 24'hFF00FF;  // magenta
        3'd5: bars = 24'hFF0000;  // red
        3'd6: bars = 24'h0000FF;  // blue
        default: bars = 24'h000000; // black
    endcase

    // Proper SMPTE EG-1 color bars: 75% top bars / reverse-blue castellation / PLUGE row.
    // 0xBF = 191 = 75% amplitude. Top: gray,yellow,cyan,green,magenta,red,blue. Castellation
    // (chroma-align strip): blue,black,magenta,black,cyan,black,gray. Pluge row: -I, 100%
    // white, +Q, black, then the pluge bars (ref-black vs just-above-black for brightness set).
    reg [23:0] smpte;
    always @(*) begin
        case(vsec_q)
        2'd0: case(bar7_q)                    // top 2/3: 75% color bars
            3'd0: smpte = 24'hBFBFBF;  // gray
            3'd1: smpte = 24'hBFBF00;  // yellow
            3'd2: smpte = 24'h00BFBF;  // cyan
            3'd3: smpte = 24'h00BF00;  // green
            3'd4: smpte = 24'hBF00BF;  // magenta
            3'd5: smpte = 24'hBF0000;  // red
            default: smpte = 24'h0000BF; // blue
        endcase
        2'd1: case(bar7_q)                    // castellation strip (reverse-blue)
            3'd0: smpte = 24'h0000BF;  // blue
            3'd1: smpte = 24'h000000;  // black
            3'd2: smpte = 24'hBF00BF;  // magenta
            3'd3: smpte = 24'h000000;  // black
            3'd4: smpte = 24'h00BFBF;  // cyan
            3'd5: smpte = 24'h000000;  // black
            default: smpte = 24'hBFBFBF; // gray
        endcase
        default: case(hbot_q)                 // bottom 1/4: PLUGE / reference row
            3'd0: smpte = 24'h001E40;  // -I (dark blue)
            3'd1: smpte = 24'hFFFFFF;  // 100% white
            3'd2: smpte = 24'h35006A;  // +Q (dark purple)
            3'd3: smpte = 24'h000000;  // black
            3'd4: smpte = 24'h000000;  // pluge: reference black
            3'd5: smpte = 24'h0F0F0F;  // pluge: just-above-black (set brightness to just see this)
            default: smpte = 24'h000000; // black
        endcase
        endcase
    end

    reg [23:0] px;
    always @(*) case(pattern)
        3'd0: px = bars;                              // 100% color bars
        3'd1: px = {hramp_q, hramp_q, hramp_q};       // horizontal luma ramp
        3'd2: px = {vramp_q, vramp_q, vramp_q};       // vertical luma ramp
        3'd3: px = 24'h808080;                        // 50% gray (level check)
        3'd4: px = smpte;                             // proper SMPTE EG-1 color bars
        3'd5: px = grid_q  ? 24'hFFFFFF : 24'h000000; // crosshatch grid + border (geometry)
        3'd6: px = chk64_q ? 24'hFFFFFF : 24'h000000; // 64px checkerboard
        default: px = chk1_q ? 24'hFFFFFF : 24'h000000; // 1px checkerboard (Nyquist)
    endcase

    always @(posedge clk) begin
        if(!rstn) begin vid_data<=24'd0; vid_active<=1'b0; vid_hsync<=1'b0; vid_vsync<=1'b0; end
        else begin
            vid_active <= act_q;
            vid_hsync  <= hs_q;
            vid_vsync  <= vs_q;
            vid_data   <= act_q ? px : 24'd0;   // blank outside active
        end
    end
endmodule

`default_nettype wire
