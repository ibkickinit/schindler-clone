// pg_linefetch.v — N-line ring buffer, PACKED-BEAT fill, DUAL-FRAME (Mackin blend).
//
// PACKED-BEAT (2026-06-02, build #15): stores raw 64-bit DataMover beats at 1
// beat/clk (~ceil(IN_W*3/8) cyc/line « htotal) in EVEN/ODD banks; extracts the
// 24-bit pixel on the READ side by byte address. See header history in git.
//
// DUAL-FRAME (2026-06-04, task #103 — Mackin blend): when `blend_en` is asserted
// each prefetch fills TWO lines for the SAME pf_row:
//   frame A (older, slot S)   from frame_base_addr   -> bank A (mem_e /mem_o )
//   frame B (newer, slot S+1) from frame_base_addr2  -> bank B (mem_e2/mem_o2)
// and the read side returns rd_data (A) AND rd_data2 (B) for one rd_col. The
// compositor blends them with the cadence alpha. When blend_en=0 only bank A is
// filled and rd_data2 mirrors rd_data — i.e. EXACT single-fetch build #23 behaviour
// (zero regression on the gen-lock path). The 2nd fetch is therefore conditional =
// the alpha-gated bandwidth lever: only frames that actually blend pay the 2x fill.
//
// One DataMover (per engine): the two lines are time-multiplexed on the single
// command/beat port (A command + beats, then B command + beats). A slot is marked
// resident only after BOTH lines land, so rd_resident covers both banks.
//
// LINE_W*3 must be <= BSTRIDE_BYTES (per-buffer byte stride, power-of-2).

`default_nettype none
`timescale 1ns / 1ps

module pg_linefetch #(
    parameter integer LINE_W = 1280,   // master line width (pixels)
    parameter integer STRIDE = 3840,   // master line stride (bytes) = LINE_W*3
    parameter integer NBUF   = 5        // resident line buffers (>=2)
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [31:0] frame_base_addr,    // frame A (older, slot S)
    input  wire [31:0] frame_base_addr2,   // frame B (newer, slot S+1) — used iff blend_en
    input  wire        blend_en,           // 1 = fetch+store both frames (level, frame-stable)

    // prefetch request (compositor -> engine): ensure src row pf_row is resident
    input  wire        pf_req,
    input  wire [11:0] pf_row,

    // pixel read (compositor -> engine)
    input  wire [11:0] rd_row,
    input  wire [11:0] rd_col,
    output reg  [23:0] rd_data,        // frame A pixel (registered, valid 1 cyc after rd_col)
    output reg  [23:0] rd_data2,       // frame B pixel (= rd_data when blend_en=0)
    output reg  [23:0] rd_data_h1,     // frame A pixel at rd_col+1 (read-side 2-tap H filter; free, in-window)
    output reg  [23:0] rd_data2_h1,    // frame B pixel at rd_col+1
    output reg         rd_resident,    // combinational: rd_row present & valid (both banks)

    // DDR fetch command (to pg_read_engine_top's DataMover command formatter)
    output reg         fetch_req,
    output reg [31:0]  fetch_addr,
    output reg [11:0]  fetch_len,      // line width in PIXELS (formatter -> BTT=len*3 bytes)

    // DDR beat stream (from DataMover M_AXIS_MM2S, 64-bit)
    input  wire [63:0] beat_data,
    input  wire        beat_valid,
    output wire        beat_ready,
    input  wire        beat_last,

    output wire        busy,          // debug: fetch in progress

    // ---- debug taps (ILA) ----
    output wire [3:0]  dbg_fill_sel,
    output wire [3:0]  dbg_rd_sel,
    output wire        dbg_have_row
);
    // ---- geometry of the beat store ----
    localparam integer BYTES_PER_LINE = LINE_W*3;
    localparam integer BEATS_PER_LINE = (BYTES_PER_LINE + 7) / 8;          // ceil
    localparam integer HALF_BEATS     = (BEATS_PER_LINE + 1) / 2;          // per bank
    localparam integer BSTRIDE = (HALF_BEATS <= 256)  ? 256  :
                                 (HALF_BEATS <= 512)  ? 512  :
                                 (HALF_BEATS <= 1024) ? 1024 : 2048;
    localparam integer SELW    = (NBUF <= 2) ? 1 : $clog2(NBUF);
    localparam integer IXW     = $clog2(BSTRIDE);

    reg [63:0]     mem_e  [0:NBUF*BSTRIDE-1];  // frame A even beats
    reg [63:0]     mem_o  [0:NBUF*BSTRIDE-1];  // frame A odd  beats
    reg [63:0]     mem_e2 [0:NBUF*BSTRIDE-1];  // frame B even beats (blend)
    reg [63:0]     mem_o2 [0:NBUF*BSTRIDE-1];  // frame B odd  beats (blend)
    reg [11:0]     tag [0:NBUF-1];
    reg [NBUF-1:0] val;
    reg [NBUF-1:0] hadB;                        // was this slot filled with a B line?
    reg [SELW-1:0] fill_sel;

    localparam S_IDLE=2'd0, S_FILL_A=2'd1, S_FILL_B=2'd2;
    reg [1:0]      state;
    reg [SELW-1:0] fill_buf;
    reg [11:0]     beat_cnt;                   // beats written this line
    reg [11:0]     pf_row_l;                   // latched row (for the B fetch addr)
    reg            blend_l;                     // latched blend_en for this fill
    assign busy = (state != S_IDLE);
    assign beat_ready = (state == S_FILL_A) || (state == S_FILL_B);

    integer i;

    // ---- residency ----
    reg have_row;
    always @* begin
        have_row = 1'b0;
        for (i=0;i<NBUF;i=i+1) if ((pf_row==tag[i]) && val[i]) have_row=1'b1;
    end

    // read-side buffer select (exclude the in-flight fill buffer)
    reg [SELW-1:0] rd_sel;
    reg            rd_hit;
    always @* begin
        rd_sel = {SELW{1'b0}}; rd_hit = 1'b0;
        for (i=0;i<NBUF;i=i+1)
            if ((rd_row==tag[i]) && val[i] &&
                !((state!=S_IDLE)&&(i[SELW-1:0]==fill_buf)) && !rd_hit) begin
                rd_sel=i[SELW-1:0]; rd_hit=1'b1;
            end
    end
    always @* rd_resident = rd_hit;

    // ---- byte-addressed read: two consecutive beats (b, b+1) -> straddle window ----
    wire [23:0] o      = {12'd0, rd_col} * 24'd3;   // byte offset of pixel
    wire [20:0] beat_b = o[23:3];                    // = o>>3
    wire [2:0]  sub    = o[2:0];                      // byte within beat
    wire [IXW-1:0] idx_e = beat_b[IXW:1] + {{(IXW-1){1'b0}}, beat_b[0]};
    wire [IXW-1:0] idx_o = beat_b[IXW:1];

    reg [63:0] beat_e_q, beat_o_q, beat_e2_q, beat_o2_q;
    reg [2:0]  sub_q;
    reg        b_odd_q, blendrd_q;
    always @(posedge clk) begin
        beat_e_q  <= mem_e [{rd_sel, idx_e}];
        beat_o_q  <= mem_o [{rd_sel, idx_o}];
        beat_e2_q <= mem_e2[{rd_sel, idx_e}];
        beat_o2_q <= mem_o2[{rd_sel, idx_o}];
        sub_q     <= sub;
        b_odd_q   <= beat_b[0];
        blendrd_q <= rd_hit ? hadB[rd_sel] : 1'b0;   // does the selected slot hold a B line?
    end
    wire [63:0]  lo_beat  = b_odd_q ? beat_o_q  : beat_e_q;
    wire [63:0]  hi_beat  = b_odd_q ? beat_e_q  : beat_o_q;
    wire [63:0]  lo_beat2 = b_odd_q ? beat_o2_q : beat_e2_q;
    wire [63:0]  hi_beat2 = b_odd_q ? beat_e2_q : beat_o2_q;
    wire [127:0] window   = {hi_beat,  lo_beat};
    wire [127:0] window2  = {hi_beat2, lo_beat2};
    always @* rd_data  = window [ {sub_q,3'b000} +: 24 ];
    // rd_data2 mirrors rd_data when this slot has no B line (single-fetch frame),
    // so a stale bank-B never leaks into a non-blend pixel.
    always @* rd_data2 = blendrd_q ? window2[ {sub_q,3'b000} +: 24 ] : rd_data;

    // ---- read-side 2-tap horizontal neighbour (rd_col+1) for the anti-alias filter ----
    // The col+1 pixel lives at byte offset sub+3, fully inside the same 128-bit window
    // (sub<=7 -> bytes 10..12 < 16) — so it costs no extra DDR/BRAM read. At the last
    // source column there is no real neighbour, so mirror the current pixel (no edge wrap).
    reg        lastcol_q;
    always @(posedge clk) lastcol_q <= (rd_col >= (LINE_W[11:0] - 12'd1));
    wire [7:0]  base_h1 = {sub_q, 3'b000} + 8'd24;            // sub*8 + 24 = next pixel
    wire [23:0] a_h1_raw = window [ base_h1 +: 24 ];
    wire [23:0] b_h1_raw = window2[ base_h1 +: 24 ];
    always @* rd_data_h1  = lastcol_q ? rd_data  : a_h1_raw;
    always @* rd_data2_h1 = blendrd_q ? (lastcol_q ? rd_data2 : b_h1_raw) : rd_data_h1;

    // ---- fill FSM: A line, then (if blend) B line, on one DataMover port ----
    always @(posedge clk) begin
        if (!rstn) begin
            state<=S_IDLE; fetch_req<=1'b0;
            fill_sel<={SELW{1'b0}}; fill_buf<={SELW{1'b0}}; beat_cnt<=12'd0;
            val<={NBUF{1'b0}}; hadB<={NBUF{1'b0}}; pf_row_l<=12'd0; blend_l<=1'b0;
            for (i=0;i<NBUF;i=i+1) tag[i]<=12'hF00+i[11:0];
            fetch_addr<=32'd0; fetch_len<=12'd0;
        end else begin
            fetch_req<=1'b0;
            case (state)
                S_IDLE:
                    if (pf_req && !have_row) begin
                        fill_buf      <= fill_sel;
                        tag[fill_sel] <= pf_row;
                        val[fill_sel] <= 1'b0;
                        hadB[fill_sel]<= blend_en;          // mark whether B will be present
                        pf_row_l      <= pf_row;
                        blend_l       <= blend_en;
                        fetch_addr    <= frame_base_addr + pf_row*STRIDE;
                        fetch_len     <= LINE_W[11:0];
                        fetch_req     <= 1'b1;
                        beat_cnt      <= 12'd0;
                        state         <= S_FILL_A;
                    end
                S_FILL_A:
                    if (beat_valid) begin
                        if (beat_cnt[0]==1'b0) mem_e[{fill_buf, beat_cnt[IXW:1]}] <= beat_data;
                        else                   mem_o[{fill_buf, beat_cnt[IXW:1]}] <= beat_data;
                        beat_cnt <= beat_cnt + 12'd1;
                        if (beat_last) begin
                            if (blend_l) begin
                                // issue the B-frame fetch for the same row
                                fetch_addr <= frame_base_addr2 + pf_row_l*STRIDE;
                                fetch_len  <= LINE_W[11:0];
                                fetch_req  <= 1'b1;
                                beat_cnt   <= 12'd0;
                                state      <= S_FILL_B;
                            end else begin
                                val[fill_buf] <= 1'b1;
                                fill_sel <= (fill_sel==NBUF-1) ? {SELW{1'b0}} : fill_sel+1'b1;
                                state    <= S_IDLE;
                            end
                        end
                    end
                S_FILL_B:
                    if (beat_valid) begin
                        if (beat_cnt[0]==1'b0) mem_e2[{fill_buf, beat_cnt[IXW:1]}] <= beat_data;
                        else                   mem_o2[{fill_buf, beat_cnt[IXW:1]}] <= beat_data;
                        beat_cnt <= beat_cnt + 12'd1;
                        if (beat_last) begin
                            val[fill_buf] <= 1'b1;
                            fill_sel <= (fill_sel==NBUF-1) ? {SELW{1'b0}} : fill_sel+1'b1;
                            state    <= S_IDLE;
                        end
                    end
            endcase
        end
    end

    assign dbg_fill_sel = {{(4-SELW){1'b0}}, fill_sel};
    assign dbg_rd_sel   = {{(4-SELW){1'b0}}, rd_sel};
    assign dbg_have_row = have_row;
endmodule

`default_nettype wire
