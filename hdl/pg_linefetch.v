// pg_linefetch.v — N-line ring buffer, PACKED-BEAT fill (read-engine-B, M3).
//
// PACKED-BEAT REWRITE (2026-06-02, build #15): the previous version stored
// 24-bit pixels filled at 1 px/clk via pg_unpack — that capped the line fill at
// ~IN_W cycles/line, which (ILA build #14, two review rounds) exceeds the output
// row budget (htotal) and starves the output FIFO (drifting underrun band). This
// version stores the raw 64-bit DataMover beats at 1 BEAT/clk (~ceil(IN_W*3/8)
// cycles/line — for IN_W=1920 that's 720 « htotal=1650), and extracts the 24-bit
// pixel on the READ side by byte address. pg_unpack leaves the datapath.
//
// Storage: beats are split into EVEN/ODD banks (beat bi → bank[bi&1] at index
// bi>>1) so any two CONSECUTIVE beats live in different banks and can be read in
// the same cycle. A pixel's 3 bytes start at byte offset o=3*rd_col; they
// straddle beats b=o>>3 and b+1 when (o&7) > 5 (i.e. rd_col mod 8 ∈ {2,5}). The
// read forms the 128-bit {hi_beat, lo_beat} window, barrel-shifts right by
// (o&7)*8, and takes the low 24 bits — which by the [G,B,R] memory order is the
// {R,B,G} AXIS pixel (no swizzle; see schindler_pipeline_rbg_byte_order). NN
// pick, so no rounding. rd_data stays single-cycle (registered banks + a
// combinational shift), preserving the pg_compose consumer contract.
//
// LINE_W*3 must be <= BSTRIDE_BYTES (per-buffer byte stride, power-of-2). The DDA
// and residency/recycle logic are unchanged from the prior version.

`default_nettype none
`timescale 1ns / 1ps

module pg_linefetch #(
    parameter integer LINE_W = 1280,   // master line width (pixels)
    parameter integer STRIDE = 3840,   // master line stride (bytes) = LINE_W*3
    parameter integer NBUF   = 5        // resident line buffers (>=2)
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [31:0] frame_base_addr,

    // prefetch request (compositor -> engine): ensure src row pf_row is resident
    input  wire        pf_req,
    input  wire [11:0] pf_row,

    // pixel read (compositor -> engine)
    input  wire [11:0] rd_row,
    input  wire [11:0] rd_col,
    output reg  [23:0] rd_data,        // registered (valid 1 cycle after rd_col)
    output reg         rd_resident,    // combinational: rd_row present & valid

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
    // power-of-2 per-buffer index stride for each bank (clean {sel,idx} address)
    localparam integer BSTRIDE = (HALF_BEATS <= 256)  ? 256  :
                                 (HALF_BEATS <= 512)  ? 512  :
                                 (HALF_BEATS <= 1024) ? 1024 : 2048;
    localparam integer SELW    = (NBUF <= 2) ? 1 : $clog2(NBUF);
    localparam integer IXW     = $clog2(BSTRIDE);

    reg [63:0]     mem_e [0:NBUF*BSTRIDE-1];   // even beats (bi&1==0), idx bi>>1
    reg [63:0]     mem_o [0:NBUF*BSTRIDE-1];   // odd  beats (bi&1==1), idx bi>>1
    reg [11:0]     tag [0:NBUF-1];
    reg [NBUF-1:0] val;
    reg [SELW-1:0] fill_sel;

    localparam S_IDLE=1'b0, S_FILL=1'b1;
    reg            state;
    reg [SELW-1:0] fill_buf;
    reg [11:0]     beat_cnt;                   // beats written this line
    assign busy = (state == S_FILL);
    assign beat_ready = (state == S_FILL);     // accept beats only while filling

    integer i;

    // ---- residency ----
    reg have_row;
    always @* begin
        have_row = 1'b0;
        for (i=0;i<NBUF;i=i+1) if ((pf_row==tag[i]) && val[i]) have_row=1'b1;
    end

    // read-side buffer select (exclude the in-flight fill buffer — see prior fix)
    reg [SELW-1:0] rd_sel;
    reg            rd_hit;
    always @* begin
        rd_sel = {SELW{1'b0}}; rd_hit = 1'b0;
        for (i=0;i<NBUF;i=i+1)
            if ((rd_row==tag[i]) && val[i] &&
                !((state==S_FILL)&&(i[SELW-1:0]==fill_buf)) && !rd_hit) begin
                rd_sel=i[SELW-1:0]; rd_hit=1'b1;
            end
    end
    always @* rd_resident = rd_hit;

    // ---- byte-addressed read: two consecutive beats (b, b+1) → straddle window ----
    wire [23:0] o      = {12'd0, rd_col} * 24'd3;   // byte offset of pixel
    wire [20:0] beat_b = o[23:3];                    // = o>>3
    wire [2:0]  sub    = o[2:0];                      // byte within beat
    // even-bank index = (b>>1)+(b&1); odd-bank index = b>>1
    wire [IXW-1:0] idx_e = beat_b[IXW:1] + {{(IXW-1){1'b0}}, beat_b[0]};
    wire [IXW-1:0] idx_o = beat_b[IXW:1];

    reg [63:0] beat_e_q, beat_o_q;
    reg [2:0]  sub_q;
    reg        b_odd_q;
    always @(posedge clk) begin
        beat_e_q <= mem_e[{rd_sel, idx_e}];
        beat_o_q <= mem_o[{rd_sel, idx_o}];
        sub_q    <= sub;
        b_odd_q  <= beat_b[0];
    end
    // lo beat = the one at b; hi beat = the one at b+1
    wire [63:0]  lo_beat = b_odd_q ? beat_o_q : beat_e_q;
    wire [63:0]  hi_beat = b_odd_q ? beat_e_q : beat_o_q;
    wire [127:0] window  = {hi_beat, lo_beat};
    always @* rd_data = window[ {sub_q,3'b000} +: 24 ];   // (window >> sub*8)[23:0]

    // ---- fill FSM: accept 1 beat/clk, bank by parity ----
    always @(posedge clk) begin
        if (!rstn) begin
            state<=S_IDLE; fetch_req<=1'b0;
            fill_sel<={SELW{1'b0}}; fill_buf<={SELW{1'b0}}; beat_cnt<=12'd0;
            val<={NBUF{1'b0}};
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
                        fetch_addr    <= frame_base_addr + pf_row*STRIDE;
                        fetch_len     <= LINE_W[11:0];
                        fetch_req     <= 1'b1;
                        beat_cnt      <= 12'd0;
                        state         <= S_FILL;
                    end
                S_FILL:
                    if (beat_valid) begin       // beat_ready is high in S_FILL
                        if (beat_cnt[0]==1'b0) mem_e[{fill_buf, beat_cnt[IXW:1]}] <= beat_data;
                        else                   mem_o[{fill_buf, beat_cnt[IXW:1]}] <= beat_data;
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
