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

    // ---- text banner overlay ("SCHINDLER TSG") so the pattern can't be mistaken for a
    // capture-stick no-signal screen. 256x32 1bpp ROM, drawn at 2x (512x64) on a black box,
    // top-centered. Bitmap rendered offline (DejaVuSansMono-Bold) -> tools/gen pg_tsg text. ----
    localparam integer TX0 = (H_ACT-512)/2;   // banner left  (704 @ 1920)
    localparam integer TY0 = 12'd28;          // banner top
    reg [31:0] txt_mem [0:255];               // 256 x 32-bit (8Kbit) -> 1 RAMB18, registered read
    initial begin
        txt_mem[  0] = 32'h00000000;
        txt_mem[  1] = 32'h00000000;
        txt_mem[  2] = 32'h00000000;
        txt_mem[  3] = 32'h00000000;
        txt_mem[  4] = 32'h00000000;
        txt_mem[  5] = 32'h00000000;
        txt_mem[  6] = 32'h00000000;
        txt_mem[  7] = 32'h00000000;
        txt_mem[  8] = 32'h00000000;
        txt_mem[  9] = 32'h00000000;
        txt_mem[ 10] = 32'h00000000;
        txt_mem[ 11] = 32'h00000000;
        txt_mem[ 12] = 32'h00000000;
        txt_mem[ 13] = 32'h00000000;
        txt_mem[ 14] = 32'h00000000;
        txt_mem[ 15] = 32'h00000000;
        txt_mem[ 16] = 32'h00000000;
        txt_mem[ 17] = 32'h00000000;
        txt_mem[ 18] = 32'h00000000;
        txt_mem[ 19] = 32'h00000000;
        txt_mem[ 20] = 32'h00000000;
        txt_mem[ 21] = 32'h00000000;
        txt_mem[ 22] = 32'h00000000;
        txt_mem[ 23] = 32'h00000000;
        txt_mem[ 24] = 32'h00000000;
        txt_mem[ 25] = 32'h00000000;
        txt_mem[ 26] = 32'h00000000;
        txt_mem[ 27] = 32'h00000000;
        txt_mem[ 28] = 32'h00000000;
        txt_mem[ 29] = 32'h00000000;
        txt_mem[ 30] = 32'h00000000;
        txt_mem[ 31] = 32'h00000000;
        txt_mem[ 32] = 32'h007f8003;
        txt_mem[ 33] = 32'hfc0f83e1;
        txt_mem[ 34] = 32'hfffc3f07;
        txt_mem[ 35] = 32'hc7fe001f;
        txt_mem[ 36] = 32'h0007fff1;
        txt_mem[ 37] = 32'hffc00000;
        txt_mem[ 38] = 32'h07fffc07;
        txt_mem[ 39] = 32'hf8003f00;
        txt_mem[ 40] = 32'h01ffe00f;
        txt_mem[ 41] = 32'hfe0f83e1;
        txt_mem[ 42] = 32'hfffc3f07;
        txt_mem[ 43] = 32'hc7ff801f;
        txt_mem[ 44] = 32'h0007fff1;
        txt_mem[ 45] = 32'hfff00000;
        txt_mem[ 46] = 32'h07fffc1f;
        txt_mem[ 47] = 32'hfe00ffc0;
        txt_mem[ 48] = 32'h03ffe01f;
        txt_mem[ 49] = 32'hfe0f83e1;
        txt_mem[ 50] = 32'hfffc3f87;
        txt_mem[ 51] = 32'hc7ffc01f;
        txt_mem[ 52] = 32'h0007fff1;
        txt_mem[ 53] = 32'hfff80000;
        txt_mem[ 54] = 32'h07fffc3f;
        txt_mem[ 55] = 32'hfe01ffe0;
        txt_mem[ 56] = 32'h03ffe03f;
        txt_mem[ 57] = 32'hfe0f83e1;
        txt_mem[ 58] = 32'hfffc3f87;
        txt_mem[ 59] = 32'hc7ffe01f;
        txt_mem[ 60] = 32'h0007fff1;
        txt_mem[ 61] = 32'hfff80000;
        txt_mem[ 62] = 32'h07fffc3f;
        txt_mem[ 63] = 32'hfe03ffe0;
        txt_mem[ 64] = 32'h07e0e07f;
        txt_mem[ 65] = 32'h060f83e0;
        txt_mem[ 66] = 32'h0f803f87;
        txt_mem[ 67] = 32'hc7c3f01f;
        txt_mem[ 68] = 32'h0007c001;
        txt_mem[ 69] = 32'hf0fc0000;
        txt_mem[ 70] = 32'h001f007e;
        txt_mem[ 71] = 32'h0e07f0e0;
        txt_mem[ 72] = 32'h07c0207e;
        txt_mem[ 73] = 32'h020f83e0;
        txt_mem[ 74] = 32'h0f803fc7;
        txt_mem[ 75] = 32'hc7c1f01f;
        txt_mem[ 76] = 32'h0007c001;
        txt_mem[ 77] = 32'hf07c0000;
        txt_mem[ 78] = 32'h001f007c;
        txt_mem[ 79] = 32'h0207e020;
        txt_mem[ 80] = 32'h07c0007c;
        txt_mem[ 81] = 32'h000f83e0;
        txt_mem[ 82] = 32'h0f803fc7;
        txt_mem[ 83] = 32'hc7c1f01f;
        txt_mem[ 84] = 32'h0007c001;
        txt_mem[ 85] = 32'hf07c0000;
        txt_mem[ 86] = 32'h001f007c;
        txt_mem[ 87] = 32'h0007c000;
        txt_mem[ 88] = 32'h07e000fc;
        txt_mem[ 89] = 32'h000f83e0;
        txt_mem[ 90] = 32'h0f803fc7;
        txt_mem[ 91] = 32'hc7c0f81f;
        txt_mem[ 92] = 32'h0007c001;
        txt_mem[ 93] = 32'hf07c0000;
        txt_mem[ 94] = 32'h001f007e;
        txt_mem[ 95] = 32'h000f8000;
        txt_mem[ 96] = 32'h07fc00f8;
        txt_mem[ 97] = 32'h000f83e0;
        txt_mem[ 98] = 32'h0f803ee7;
        txt_mem[ 99] = 32'hc7c0f81f;
        txt_mem[100] = 32'h0007c001;
        txt_mem[101] = 32'hf07c0000;
        txt_mem[102] = 32'h001f007f;
        txt_mem[103] = 32'hc00f8000;
        txt_mem[104] = 32'h03ff00f8;
        txt_mem[105] = 32'h000fffe0;
        txt_mem[106] = 32'h0f803ee7;
        txt_mem[107] = 32'hc7c0f81f;
        txt_mem[108] = 32'h0007ffe1;
        txt_mem[109] = 32'hf0f80000;
        txt_mem[110] = 32'h001f003f;
        txt_mem[111] = 32'hf00f8000;
        txt_mem[112] = 32'h01ffc0f8;
        txt_mem[113] = 32'h000fffe0;
        txt_mem[114] = 32'h0f803ee7;
        txt_mem[115] = 32'hc7c0f81f;
        txt_mem[116] = 32'h0007ffe1;
        txt_mem[117] = 32'hfff80000;
        txt_mem[118] = 32'h001f001f;
        txt_mem[119] = 32'hfc0f87f0;
        txt_mem[120] = 32'h007fe0f8;
        txt_mem[121] = 32'h000fffe0;
        txt_mem[122] = 32'h0f803e77;
        txt_mem[123] = 32'hc7c0f81f;
        txt_mem[124] = 32'h0007ffe1;
        txt_mem[125] = 32'hffe00000;
        txt_mem[126] = 32'h001f0007;
        txt_mem[127] = 32'hfe0f87f0;
        txt_mem[128] = 32'h001fe0f8;
        txt_mem[129] = 32'h000fffe0;
        txt_mem[130] = 32'h0f803e77;
        txt_mem[131] = 32'hc7c0f81f;
        txt_mem[132] = 32'h0007ffe1;
        txt_mem[133] = 32'hffc00000;
        txt_mem[134] = 32'h001f0001;
        txt_mem[135] = 32'hfe0f87f0;
        txt_mem[136] = 32'h0003f0f8;
        txt_mem[137] = 32'h000f83e0;
        txt_mem[138] = 32'h0f803e77;
        txt_mem[139] = 32'hc7c0f81f;
        txt_mem[140] = 32'h0007c001;
        txt_mem[141] = 32'hffe00000;
        txt_mem[142] = 32'h001f0000;
        txt_mem[143] = 32'h3f0f87f0;
        txt_mem[144] = 32'h0001f0f8;
        txt_mem[145] = 32'h000f83e0;
        txt_mem[146] = 32'h0f803e77;
        txt_mem[147] = 32'hc7c0f81f;
        txt_mem[148] = 32'h0007c001;
        txt_mem[149] = 32'hf3f00000;
        txt_mem[150] = 32'h001f0000;
        txt_mem[151] = 32'h1f0f80f0;
        txt_mem[152] = 32'h0001f0fc;
        txt_mem[153] = 32'h000f83e0;
        txt_mem[154] = 32'h0f803e3f;
        txt_mem[155] = 32'hc7c0f81f;
        txt_mem[156] = 32'h0007c001;
        txt_mem[157] = 32'hf1f00000;
        txt_mem[158] = 32'h001f0000;
        txt_mem[159] = 32'h1f0fc0f0;
        txt_mem[160] = 32'h0401f07c;
        txt_mem[161] = 32'h000f83e0;
        txt_mem[162] = 32'h0f803e3f;
        txt_mem[163] = 32'hc7c1f01f;
        txt_mem[164] = 32'h0007c001;
        txt_mem[165] = 32'hf0f80000;
        txt_mem[166] = 32'h001f0040;
        txt_mem[167] = 32'h1f07c0f0;
        txt_mem[168] = 32'h0601f07e;
        txt_mem[169] = 32'h020f83e0;
        txt_mem[170] = 32'h0f803e3f;
        txt_mem[171] = 32'hc7c1f01f;
        txt_mem[172] = 32'h0007c001;
        txt_mem[173] = 32'hf0f80000;
        txt_mem[174] = 32'h001f0060;
        txt_mem[175] = 32'h1f07e0f0;
        txt_mem[176] = 32'h0783f07f;
        txt_mem[177] = 32'h060f83e0;
        txt_mem[178] = 32'h0f803e1f;
        txt_mem[179] = 32'hc7c3f01f;
        txt_mem[180] = 32'h0007c001;
        txt_mem[181] = 32'hf07c0000;
        txt_mem[182] = 32'h001f0078;
        txt_mem[183] = 32'h3f07f0f0;
        txt_mem[184] = 32'h07ffe03f;
        txt_mem[185] = 32'hfe0f83e1;
        txt_mem[186] = 32'hfffc3e1f;
        txt_mem[187] = 32'hc7ffe01f;
        txt_mem[188] = 32'hff87fff1;
        txt_mem[189] = 32'hf07c0000;
        txt_mem[190] = 32'h001f007f;
        txt_mem[191] = 32'hfe03fff0;
        txt_mem[192] = 32'h07ffe01f;
        txt_mem[193] = 32'hfe0f83e1;
        txt_mem[194] = 32'hfffc3e1f;
        txt_mem[195] = 32'hc7ffc01f;
        txt_mem[196] = 32'hff87fff1;
        txt_mem[197] = 32'hf03e0000;
        txt_mem[198] = 32'h001f007f;
        txt_mem[199] = 32'hfe01fff0;
        txt_mem[200] = 32'h03ffc00f;
        txt_mem[201] = 32'hfe0f83e1;
        txt_mem[202] = 32'hfffc3e0f;
        txt_mem[203] = 32'hc7ff801f;
        txt_mem[204] = 32'hff87fff1;
        txt_mem[205] = 32'hf03e0000;
        txt_mem[206] = 32'h001f003f;
        txt_mem[207] = 32'hfc00ffe0;
        txt_mem[208] = 32'h00ff0003;
        txt_mem[209] = 32'hfc0f83e1;
        txt_mem[210] = 32'hfffc3e0f;
        txt_mem[211] = 32'hc7fe001f;
        txt_mem[212] = 32'hff87fff1;
        txt_mem[213] = 32'hf01f0000;
        txt_mem[214] = 32'h001f000f;
        txt_mem[215] = 32'hf0003f80;
        txt_mem[216] = 32'h00000000;
        txt_mem[217] = 32'h00000000;
        txt_mem[218] = 32'h00000000;
        txt_mem[219] = 32'h00000000;
        txt_mem[220] = 32'h00000000;
        txt_mem[221] = 32'h00000000;
        txt_mem[222] = 32'h00000000;
        txt_mem[223] = 32'h00000000;
        txt_mem[224] = 32'h00000000;
        txt_mem[225] = 32'h00000000;
        txt_mem[226] = 32'h00000000;
        txt_mem[227] = 32'h00000000;
        txt_mem[228] = 32'h00000000;
        txt_mem[229] = 32'h00000000;
        txt_mem[230] = 32'h00000000;
        txt_mem[231] = 32'h00000000;
        txt_mem[232] = 32'h00000000;
        txt_mem[233] = 32'h00000000;
        txt_mem[234] = 32'h00000000;
        txt_mem[235] = 32'h00000000;
        txt_mem[236] = 32'h00000000;
        txt_mem[237] = 32'h00000000;
        txt_mem[238] = 32'h00000000;
        txt_mem[239] = 32'h00000000;
        txt_mem[240] = 32'h00000000;
        txt_mem[241] = 32'h00000000;
        txt_mem[242] = 32'h00000000;
        txt_mem[243] = 32'h00000000;
        txt_mem[244] = 32'h00000000;
        txt_mem[245] = 32'h00000000;
        txt_mem[246] = 32'h00000000;
        txt_mem[247] = 32'h00000000;
        txt_mem[248] = 32'h00000000;
        txt_mem[249] = 32'h00000000;
        txt_mem[250] = 32'h00000000;
        txt_mem[251] = 32'h00000000;
        txt_mem[252] = 32'h00000000;
        txt_mem[253] = 32'h00000000;
        txt_mem[254] = 32'h00000000;
        txt_mem[255] = 32'h00000000;
    end
    wire        in_ban  = (hc>=TX0) && (hc<TX0+512) && (vc>=TY0) && (vc<TY0+64);
    wire [4:0]  t_row   = (vc - TY0) >> 1;                 // 0..31 (2x vertical)
    wire [7:0]  t_col   = (hc - TX0) >> 1;                 // 0..255 (2x horizontal)
    wire [7:0]  t_raddr = {t_row, t_col[7:5]};             // word addr = row*8 + (col/32)
    // BRAM registered read: addr@T -> data@T+1 = hc_T, aligning with the pattern's A1 stage.
    reg [31:0] txt_dout; reg [4:0] t_bitsel; reg t_inban;
    always @(posedge clk) begin
        txt_dout <= txt_mem[t_raddr];
        t_bitsel <= t_col[4:0];
        t_inban  <= in_ban;
    end
    wire t_glyph = txt_dout[5'd31 - t_bitsel];             // MSB = leftmost pixel

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

    // text-banner overlay: black box with white "SCHINDLER TSG" glyphs. White/black are
    // swap-invariant so they pass the R-B-G boundary swap below unchanged.
    wire [23:0] dpx = t_inban ? (t_glyph ? 24'hFFFFFF : 24'h000000) : px;

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
