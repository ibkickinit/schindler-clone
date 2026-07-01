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
    input  wire [3:0]  pattern,            // 0 bars100 1 SMPTE 2 rgb-bw-split 3 h-ramp 4 v-ramp 5 staircase
                                           // 6 mirror-ramp 7 gray50 8 white 9 crosshatch 10 checker64 11 checker1
                                           // 12 vj-card 13 multi-ref 14 multiburst 15 pathological (async; quasi-static)
    input  wire [23:0] osd_load,           // OSD banner load (FCLK GPIO): {boxR[23:19], boxL[18:14], strobe[13], idx[12:8], char[7:0]}
                                           //   char/idx/strobe = char-buffer write; boxL/boxR = occupied-cell range (box hugs the text)
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

    // pattern[2:0] is a quasi-static GPIO bit in FCLK_CLK0 crossing into this (clk_wiz_tsg) clock.
    // 2-FF ASYNC_REG synchronizer so a pattern-change edge can't metastable-glitch the px mux. The
    // FCLK<->TSG path is already declared async (set_clock_groups in tsg_place_pre.tcl), so no extra
    // false-path is needed. Use pat_q2 everywhere the pattern selects.
    (* ASYNC_REG = "TRUE" *) reg [3:0] pat_q1, pat_q2;
    always @(posedge clk) begin
        if(!rstn) begin pat_q1<=4'd0; pat_q2<=4'd0; end
        else begin pat_q1<=pattern; pat_q2<=pat_q1; end
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

    // ---- OSD-0: runtime-editable text banner (font ROM + firmware-writable char buffer) ----
    // Replaces the baked bitmap ROM: firmware writes ASCII codes into char_buf; an 8x16 font ROM
    // supplies the glyphs, drawn at 2x. 32 char cells (16px each) across a 512px box @ TX0.
    // char_buf write is a data-then-strobe CDC from the FCLK GPIO (osd_load) -- see gamma-load lesson.
    localparam integer TX0 = (H_ACT-512)/2;   // banner left  (704 @ 1920)
    localparam integer TYT = 12'd44;          // text top; 16 font rows x2 = 32px tall -> [44,76)
    localparam integer BY0 = 12'd36, BY1 = 12'd84;  // black box vertical extent (padded)

    // 8x16 ASCII font ROM (128 chars x16 rows, 8-bit) -> 1 RAMB18. Rendered offline (DejaVuSansMono-Bold).
    reg [7:0] font_rom [0:2047];
    initial $readmemh("pg_font8x16.mem", font_rom);

    // char buffer: 32 cells of 8-bit ASCII, firmware-writable. Default "EDGERLY TSG" (centered).
    reg [7:0] char_buf [0:31];
    integer ci;
    initial begin
        for(ci=0;ci<32;ci=ci+1) char_buf[ci] = 8'd32;   // space
        char_buf[10]="E"; char_buf[11]="D"; char_buf[12]="G"; char_buf[13]="E"; char_buf[14]="R";
        char_buf[15]="L"; char_buf[16]="Y"; char_buf[17]=" "; char_buf[18]="T"; char_buf[19]="S";
        char_buf[20]="G";
    end
    // load port CDC (data-then-strobe): sync osd_load, latch char_buf[idx]<=char on the strobe edge.
    // boxL/boxR (ld_q2[18:14]/[23:19]) are quasi-static occupied-cell bounds -> read continuously (2-FF
    // synced), no strobe needed; firmware holds them constant across the per-char writes.
    (* ASYNC_REG="TRUE" *) reg [23:0] ld_q1, ld_q2; reg [23:0] ld_q3;
    always @(posedge clk) begin
        ld_q1 <= osd_load; ld_q2 <= ld_q1; ld_q3 <= ld_q2;
        if (ld_q2[13] != ld_q3[13]) char_buf[ld_q2[12:8]] <= ld_q2[7:0];  // strobe toggled -> commit
    end
    wire [4:0] box_l = ld_q2[18:14];
    wire [4:0] box_r = ld_q2[23:19];
    // box hugs the text: [box_l, box_r] occupied cells, 16px/cell @ TX0, +/-8px pad. box_r<box_l -> hidden.
    wire [11:0] box_hs = TX0 + ({7'd0,box_l} << 4) - 12'd8;
    wire [11:0] box_he = TX0 + ({7'd0,box_r+5'd1} << 4) + 12'd8;

    // pixel -> cell math (divide-free: 16px cells = >>4, 8 font cols at 2x = >>1 &7, 16 rows at 2x = >>1).
    wire        in_text = (hc>=TX0) && (hc<TX0+512) && (vc>=TYT) && (vc<TYT+32);
    wire        in_box  = (box_r>=box_l) && (hc>=box_hs) && (hc<box_he) && (vc>=BY0) && (vc<BY1);
    wire [4:0]  ch_col  = (hc - TX0) >> 4;                 // 0..31 char cell
    wire [2:0]  g_col   = ((hc - TX0) >> 1) & 3'd7;        // 0..7 font column
    wire [3:0]  g_row   = (vc - TYT) >> 1;                 // 0..15 font row
    wire [7:0]  ch_code = char_buf[ch_col];                // 32:1 mux (combinational)
    wire [10:0] f_addr  = {ch_code[6:0], g_row};           // char*16 + row
    // 1-stage registered font read + delayed selects, so the banner aligns with the pattern's 2-cycle path.
    reg  [7:0]  f_byte; reg [2:0] g_col_d; reg t_inbox, t_intext;
    always @(posedge clk) begin
        f_byte  <= font_rom[f_addr];
        g_col_d <= g_col;
        t_inbox <= in_box;
        t_intext<= in_text;
    end
    wire t_glyph = t_intext & f_byte[7 - g_col_d];         // MSB=leftmost pixel; only inside the text region

    reg        act_q, hs_q, vs_q;
    reg [2:0]  bar_q;
    reg [7:0]  hramp_q, vramp_q;
    reg        grid_q, chk64_q, chk1_q;       // geometry/scaling patterns (all divide-free, registered)
    reg [2:0]  bar7_q;                         // SMPTE 7-bar column index (1920/7 boundaries)
    reg [1:0]  vsec_q;                         // SMPTE vertical section: 0 top bars / 1 castellation / 2 pluge row
    reg [2:0]  hbot_q;                         // SMPTE pluge-row horizontal segment index
    reg [7:0]  stair_q;                        // grayscale staircase luma (16 steps across width)
    reg        mburst_q;                        // multiburst on/off pixel (spatial-freq sweep)
    // ---- testpattern.app cards (ported from the JS generators; simplified procedural) ----
    reg [1:0]  rb_sec_q;                        // RGB+B&W split: 0 top(RGB) / 1 mid(blk|wht) / 2 bottom ramp
    reg [1:0]  rb_col_q;                        // RGB+B&W top column: 0 R / 1 G / 2 B
    reg        rb_midw_q;                       // RGB+B&W mid: right (white) half
    reg [3:0]  mr_step_q;                       // mirror-ramp 11-step wedge index (0..10)
    reg        mr_band_q, mr_top_q, mr_hair_q;  // in wedge band / above midline / hairline
    reg [7:0]  mr_inv_q;                        // 255-hramp (the mirrored ramp)
    reg        vj_par_q, vj_cross_q, vj_ring_q; // VJ: checker parity / crosshair / circle ring
    reg        vj_lstrip_q, vj_rstrip_q;        // VJ: in left(rainbow) / right(bw) edge strip
    reg [2:0]  vj_hue_q;                        // VJ rainbow hue index (0..7)
    reg [7:0]  vj_rval_q;                       // VJ right-strip bw value
    reg [2:0]  mref_band_q;                     // multi-ref: 0 none/1 hue/2 R/3 G/4 B/5 shadow/6 wedge
    reg [3:0]  mref_seg_q;                      // multi-ref: segment index within a band (0..11)
    reg [7:0]  mref_grad_q;                     // multi-ref: gradient value across the content column
    reg        patho_top_q, patho_split_q;      // SDI pathological: top(EQ) half / centre split line
    // circle radial term for the VJ card (DSP products; the ring boolean is registered below).
    wire signed [12:0] vj_dx = $signed({1'b0,hc}) - 13'sd960;
    wire signed [12:0] vj_dy = $signed({1'b0,vc}) - 13'sd540;
    wire signed [26:0] vj_r2 = vj_dx*vj_dx + vj_dy*vj_dy;
    wire ringband = (vj_r2 > 27'sd71300) && (vj_r2 < 27'sd74500);   // |r2 - 72900| < ~1600 -> ~1px ring
    always @(posedge clk) begin
        if(!rstn) begin
            act_q<=1'b0; hs_q<=1'b0; vs_q<=1'b0; bar_q<=3'd0; hramp_q<=8'd0; vramp_q<=8'd0;
            grid_q<=1'b0; chk64_q<=1'b0; chk1_q<=1'b0; bar7_q<=3'd0; vsec_q<=2'd0; hbot_q<=3'd0;
            stair_q<=8'd0; mburst_q<=1'b0;
            rb_sec_q<=2'd0; rb_col_q<=2'd0; rb_midw_q<=1'b0; mr_step_q<=4'd0; mr_band_q<=1'b0;
            mr_top_q<=1'b0; mr_hair_q<=1'b0; mr_inv_q<=8'd0; vj_par_q<=1'b0; vj_cross_q<=1'b0;
            vj_ring_q<=1'b0; vj_lstrip_q<=1'b0; vj_rstrip_q<=1'b0; vj_hue_q<=3'd0; vj_rval_q<=8'd0;
            mref_band_q<=3'd0; mref_seg_q<=4'd0; mref_grad_q<=8'd0; patho_top_q<=1'b0; patho_split_q<=1'b0;
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
            // grayscale staircase: 16 equal steps 0..255 across the width. step = hc/120 (1920/16),
            // level = step*17 (0,17,..,255). divide-free: step index via /128 approx -> use hc[10:7]
            // (1920/16=120; hc>>7 gives 0..14 over 0..1919, close enough for a 16-step bar -> *17).
            stair_q <= ({4'd0, hc[10:7]} * 8'd17);      // 0,17,34,...,238 (16 steps; calibration)
            // multiburst: vertical bursts whose spatial frequency increases by band. 6 bands of 320px;
            // band k toggles every (1<<(k>=5?5:k+1)) px-ish -> pick a frequency bit per band (divide-free).
            mburst_q <= (hc < 12'd320)  ? hc[3] :        // ~16px period
                        (hc < 12'd640)  ? hc[2] :        // ~8px
                        (hc < 12'd960)  ? hc[1] :        // ~4px
                        (hc < 12'd1280) ? hc[0] :        // 2px
                        (hc < 12'd1600) ? (hc[0]&vc[0]) : // 2px checker-ish
                                          1'b1;          // flat white reference
            // ===== RGB + B&W split (testpattern.app rgb-bw-split) =====
            // top 50% = 3 RGB columns; mid 25% = black|white; bottom 25% = B->W ramp (reuse hramp).
            rb_sec_q  <= (vc>=12'd810) ? 2'd2 : (vc>=12'd540) ? 2'd1 : 2'd0;
            rb_col_q  <= (hc>=12'd1280) ? 2'd2 : (hc>=12'd640) ? 2'd1 : 2'd0;
            rb_midw_q <= (hc>=12'd960);

            // ===== Mirror ramp + 11-step (testpattern.app mirror-ramp) =====
            // base ramp top half 0->255 (hramp), bottom half 255->0 (mr_inv). middle third = 11-step
            // wedge, top values 0..255, bottom mirrored. boundaries k*1920/11 (k=1..10).
            mr_inv_q  <= 8'd254 - ((hc * 19'd68) >> 9);
            mr_top_q  <= (vc < 12'd540);
            mr_band_q <= (vc >= 12'd360) && (vc < 12'd720);
            mr_hair_q <= (vc==12'd540) || (vc==12'd360) || (vc==12'd719);
            mr_step_q <= (hc>=12'd175)+(hc>=12'd349)+(hc>=12'd524)+(hc>=12'd698)+(hc>=12'd873)
                       + (hc>=12'd1047)+(hc>=12'd1222)+(hc>=12'd1396)+(hc>=12'd1571)+(hc>=12'd1745);

            // ===== VJ checker card (simplified: checker + crosshair + circle + edge strips) =====
            // 32x18 checker = 60px cells (1920/32=1080/18=60). parity via /60 multiply (1/60 ~ 17476/2^20).
            // (literal MUST be >=27-bit: hc*17476 ~38M needs 26 bits, else a*b=max(L) wraps -> ramp bug.)
            vj_par_q   <= ((hc*27'd17476)>>20) ^ ((vc*27'd17476)>>20);   // LSB of (hc/60) xor (vc/60)
            vj_cross_q <= (hc>=12'd959 && hc<=12'd960) || (vc>=12'd539 && vc<=12'd540);
            // left rainbow strip [29..106]x[216..864]; right B->W strip [1814..1891] same y.
            vj_lstrip_q <= (hc>=12'd29)   && (hc<12'd106)  && (vc>=12'd216) && (vc<12'd864);
            vj_rstrip_q <= (hc>=12'd1814) && (hc<12'd1891) && (vc>=12'd216) && (vc<12'd864);
            vj_hue_q    <= (((vc-12'd216) * 18'd202) >> 14);          // (vc-216)/81 -> 0..7 hue band
            vj_rval_q   <= (((vc-12'd216) * 19'd403) >> 10);          // (vc-216)*255/648 -> 0..254
            // circle ring r=270 about (960,540): |dx^2+dy^2 - 72900| < ~1600 -> ~1px ring (drop AA).
            vj_ring_q   <= ringband;

            // ===== Multi reference card (simplified: hue band + RGB grad strips + 2 staircases) =====
            // content column hc in [288,1632) (1344 wide). grad value across it = (hc-288)*255/1344.
            mref_grad_q <= (hc>=12'd288 && hc<12'd1632) ? (((hc-12'd288) * 19'd195) >> 10) : 8'd0;  // *255/1344 -> 0..255
            mref_seg_q  <= (hc>=12'd288 && hc<12'd1632) ? (((hc-12'd288) * 16'd18) >> 11) : 4'd0;   // /112 -> 0..11
            mref_band_q <= (hc<12'd288 || hc>=12'd1632) ? 3'd0 :
                           (vc>=12'd300 && vc<12'd420) ? 3'd1 :   // 12-hue band
                           (vc>=12'd430 && vc<12'd490) ? 3'd2 :   // R gradient
                           (vc>=12'd500 && vc<12'd560) ? 3'd3 :   // G gradient
                           (vc>=12'd570 && vc<12'd630) ? 3'd4 :   // B gradient
                           (vc>=12'd650 && vc<12'd730) ? 3'd5 :   // 1-12% shadow staircase
                           (vc>=12'd740 && vc<12'd820) ? 3'd6 : 3'd0; // 2-100% gray wedge

            // ===== SDI pathological (eq + pll) =====
            // SMPTE worst-case: top half = equalizer field, bottom half = PLL field. The stress is in the
            // post-scramble bitstream (relevant if fed to an SDI encoder); rendered as the two documented
            // luma fields + a 1px split. EQ ~Y 0x66, PLL ~Y 0x44 (8-bit equivalents).
            patho_top_q   <= (vc < 12'd540);
            patho_split_q <= (vc==12'd540);
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

    // ===== RGB + B&W split (testpattern.app rgb-bw-split) =====
    reg [23:0] rgbbw;
    always @(*) case(rb_sec_q)
        2'd0: rgbbw = (rb_col_q==2'd0)?24'hFF0000:(rb_col_q==2'd1)?24'h00FF00:24'h0000FF; // R/G/B 100%
        2'd1: rgbbw = rb_midw_q ? 24'hFFFFFF : 24'h000000;     // black | white
        default: rgbbw = {hramp_q,hramp_q,hramp_q};            // B->W ramp
    endcase

    // ===== Mirror ramp + 11-step =====
    reg [7:0]  mr_wedge; reg [23:0] mramp;
    always @(*) case(mr_step_q)               // 0..10 -> 0..255 (k*25.5 rounded)
        4'd0:mr_wedge=8'd0;  4'd1:mr_wedge=8'd26; 4'd2:mr_wedge=8'd51; 4'd3:mr_wedge=8'd77;
        4'd4:mr_wedge=8'd102;4'd5:mr_wedge=8'd128;4'd6:mr_wedge=8'd153;4'd7:mr_wedge=8'd179;
        4'd8:mr_wedge=8'd204;4'd9:mr_wedge=8'd230;default:mr_wedge=8'd255;
    endcase
    always @(*) begin
        if(mr_hair_q) mramp = 24'hFFFFFF;                              // hairlines
        else if(mr_band_q) mramp = mr_top_q ? {mr_wedge,mr_wedge,mr_wedge}
                                            : {(8'd255-mr_wedge),(8'd255-mr_wedge),(8'd255-mr_wedge)};
        else mramp = mr_top_q ? {hramp_q,hramp_q,hramp_q} : {mr_inv_q,mr_inv_q,mr_inv_q};
    end

    // ===== VJ checker card (simplified) =====
    reg [23:0] vj_rainbow, vjcard;
    always @(*) case(vj_hue_q)                // 8-hue vertical strip
        3'd0:vj_rainbow=24'hFF0000;3'd1:vj_rainbow=24'hFF8000;3'd2:vj_rainbow=24'hFFFF00;3'd3:vj_rainbow=24'h00FF00;
        3'd4:vj_rainbow=24'h00FFFF;3'd5:vj_rainbow=24'h0000FF;3'd6:vj_rainbow=24'h8000FF;default:vj_rainbow=24'hFF00FF;
    endcase
    always @(*) begin
        if(vj_lstrip_q)      vjcard = vj_rainbow;
        else if(vj_rstrip_q) vjcard = {vj_rval_q,vj_rval_q,vj_rval_q};
        else if(vj_cross_q || vj_ring_q) vjcard = 24'hFFFFFF;          // crosshair + circle ring
        else vjcard = vj_par_q ? 24'h7A7A7A : 24'h5A5A5A;             // 60px checker (#7a/#5a)
    end

    // ===== Multi reference card (simplified: hue band + R/G/B black->chan->white + 2 staircases) =====
    reg [23:0] mref_hue, mref; reg [7:0] mref_shadow, mref_wedge;
    wire [7:0] mr_lo  = (mref_grad_q < 8'd128) ? (mref_grad_q<<1) : 8'd255;       // black->channel
    wire [7:0] mr_oth = (mref_grad_q < 8'd128) ? 8'd0 : ((mref_grad_q-8'd128)<<1);// ->white
    always @(*) case(mref_seg_q)              // 12 pure hues
        4'd0:mref_hue=24'hFF0000;4'd1:mref_hue=24'hFF8000;4'd2:mref_hue=24'hFFFF00;4'd3:mref_hue=24'h80FF00;
        4'd4:mref_hue=24'h00FF00;4'd5:mref_hue=24'h00FF80;4'd6:mref_hue=24'h00FFFF;4'd7:mref_hue=24'h0080FF;
        4'd8:mref_hue=24'h0000FF;4'd9:mref_hue=24'h8000FF;4'd10:mref_hue=24'hFF00FF;default:mref_hue=24'hFF0080;
    endcase
    always @(*) begin
        mref_shadow = (mref_seg_q+4'd1)*8'd3;                         // ~1..12% shadow staircase
        case(mref_seg_q)                                              // 2..100% gray wedge
            4'd0:mref_wedge=8'd5;  4'd1:mref_wedge=8'd13; 4'd2:mref_wedge=8'd26; 4'd3:mref_wedge=8'd51;
            4'd4:mref_wedge=8'd77; 4'd5:mref_wedge=8'd102;4'd6:mref_wedge=8'd128;4'd7:mref_wedge=8'd153;
            4'd8:mref_wedge=8'd179;4'd9:mref_wedge=8'd204;4'd10:mref_wedge=8'd230;default:mref_wedge=8'd255;
        endcase
    end
    always @(*) case(mref_band_q)
        3'd1: mref = mref_hue;
        3'd2: mref = {mr_lo, mr_oth, mr_oth};                          // R: black->red->white
        3'd3: mref = {mr_oth, mr_lo, mr_oth};                          // G
        3'd4: mref = {mr_oth, mr_oth, mr_lo};                          // B
        3'd5: mref = {mref_shadow,mref_shadow,mref_shadow};
        3'd6: mref = {mref_wedge,mref_wedge,mref_wedge};
        default: mref = 24'h000000;
    endcase

    // ===== SDI pathological (eq top / pll bottom) =====
    wire [23:0] patho = patho_split_q ? 24'hFFFFFF : (patho_top_q ? 24'h666666 : 24'h444444);

    reg [23:0] px;
    always @(*) case(pat_q2)
        // --- bars & color ---
        4'd0:  px = bars;                              // color bars (100%)
        4'd1:  px = smpte;                             // SMPTE EG-1 bars
        4'd2:  px = rgbbw;                             // RGB + B&W split
        // --- ramps & grayscale ---
        4'd3:  px = {hramp_q, hramp_q, hramp_q};       // horizontal ramp
        4'd4:  px = {vramp_q, vramp_q, vramp_q};       // vertical ramp
        4'd5:  px = {stair_q, stair_q, stair_q};       // grayscale staircase
        4'd6:  px = mramp;                             // mirror ramp + 11-step
        4'd7:  px = 24'h808080;                        // 50% gray
        4'd8:  px = 24'hFFFFFF;                        // white (100%)
        // --- geometry & alignment ---
        4'd9:  px = grid_q  ? 24'hFFFFFF : 24'h000000; // crosshatch + border
        4'd10: px = chk64_q ? 24'hFFFFFF : 24'h000000; // checkerboard 64px
        4'd11: px = chk1_q  ? 24'hFFFFFF : 24'h000000; // checkerboard 1px (Nyquist)
        4'd12: px = vjcard;                            // VJ checker card
        4'd13: px = mref;                              // multi reference card
        // --- stress ---
        4'd14: px = mburst_q ? 24'hFFFFFF : 24'h000000; // multiburst
        default: px = patho;                           // 15: SDI pathological (eq+pll)
    endcase

    // text-banner overlay: black box with white "EDGERLY TSG" glyphs. White/black are
    // swap-invariant so they pass the R-B-G boundary swap below unchanged.
    wire [23:0] dpx = t_inbox ? (t_glyph ? 24'hFFFFFF : 24'h000000) : px;

    always @(posedge clk) begin
        if(!rstn) begin vid_data<=24'd0; vid_active<=1'b0; vid_hsync<=1'b0; vid_vsync<=1'b0; end
        else begin
            vid_active <= act_q;
            vid_hsync  <= hs_q;
            vid_vsync  <= vs_q;
            // The Schindler AXIS pipeline carries pixels as R-B-G ([23:16]=R, [15:8]=B,
            // [7:0]=G), NOT standard RGB (see schindler_pipeline_rbg_byte_order). dpx above
            // is built in readable standard {R,G,B}; swap G<->B here at the boundary so the
            // colors come out right. Bench-confirmed: without this, bars read white/magenta/
            // cyan/blue/yellow/red/green (a clean green<->blue swap).
            vid_data   <= act_q ? {dpx[23:16], dpx[7:0], dpx[15:8]} : 24'd0;   // -> R,B,G; blank outside active
        end
    end
endmodule

`default_nettype wire
