// pg_tilecache_rt.v — Phase-2 fetch, MILESTONE 3a: the 1-pixel/clock 4-bank 2x2 gather.
//
// Returns the bilinear 2x2 in ONE cycle even when it straddles up to four tiles, via a 4-BANK tile
// BRAM split by pixel parity: bank[bx][by] holds every cached pixel with (col&1,row&1)==(bx,by).
// The 2x2 hits all four parity combos once -> four parallel reads (each with its own tile slot) ->
// one cycle; a parity mux on (x&1,y&1) routes banks back to p00/p10/p01/p11. Frame-edge neighbours
// (clamp-to-self) break the parity invariant, so the outputs get an explicit edge-mux.
// 16x16 tiles. Demand-fetch on miss (M1 behaviour); the always-hit prefetch walker is M3b.

`default_nettype none
`timescale 1ns / 1ps

module pg_tilecache_rt #(
    parameter integer IN_W  = 1920,
    parameter integer IN_H  = 1080,
    parameter integer LTILE = 4,                  // 16x16 tiles
    parameter integer NTILE = 16,
    parameter integer SB    = 4
) (
    input  wire        clk, rstn,
    input  wire        in_valid,
    input  wire [11:0] in_x, in_y, in_fx, in_fy,
    input  wire        in_inwin,
    input  wire [SB-1:0] in_sb,
    output wire        in_ready,
    output reg         out_valid,
    output reg  [23:0] out_p00, out_p10, out_p01, out_p11,
    output reg  [11:0] out_fx, out_fy,
    output reg         out_inwin,
    output reg  [SB-1:0] out_sb,
    input  wire        out_ready,
    output reg         fetch_req,
    output reg  [11:0] fetch_tx, fetch_ty,
    input  wire        fill_valid,
    input  wire [23:0] fill_data,
    input  wire        fill_last
);
    localparam integer TILE = (1<<LTILE);
    localparam integer HT   = LTILE-1;
    localparam integer BPT  = (TILE*TILE)/4;
    localparam integer TX   = (IN_W + TILE - 1)/TILE;
    localparam integer SLW  = $clog2(NTILE);
    localparam integer BAW  = SLW + 2*HT;
    localparam integer TIDW = 24;

    (* ram_style="block" *) reg [23:0] b00 [0:NTILE*BPT-1];
    (* ram_style="block" *) reg [23:0] b10 [0:NTILE*BPT-1];
    (* ram_style="block" *) reg [23:0] b01 [0:NTILE*BPT-1];
    (* ram_style="block" *) reg [23:0] b11 [0:NTILE*BPT-1];
    reg [TIDW-1:0] tag [0:NTILE-1];
    reg            vld [0:NTILE-1];
    reg [SLW-1:0]  rr;

    reg [11:0] lx, ly, lfx, lfy; reg linwin; reg [SB-1:0] lsb;

    function [11:0] clampx; input [11:0] v; clampx = (v>=IN_W) ? (IN_W-1) : v; endfunction
    function [11:0] clampy; input [11:0] v; clampy = (v>=IN_H) ? (IN_H-1) : v; endfunction
    wire [11:0] xr = clampx(lx+12'd1);
    wire [11:0] yb = clampy(ly+12'd1);
    wire edge_x = (xr==lx);          // right frame edge: neighbour clamps to self
    wire edge_y = (yb==ly);
    // pixel coord feeding each parity bank
    wire [11:0] px_b0 = (lx[0]==1'b0) ? lx : xr;
    wire [11:0] px_b1 = (lx[0]==1'b1) ? lx : xr;
    wire [11:0] py_b0 = (ly[0]==1'b0) ? ly : yb;
    wire [11:0] py_b1 = (ly[0]==1'b1) ? ly : yb;

    function [TIDW-1:0] tidf; input [11:0] px,py; tidf = (py>>LTILE)*TX + (px>>LTILE); endfunction
    function [BAW-1:0] baddr; input [SLW-1:0] slot; input [11:0] px,py;
        baddr = (slot<<(2*HT)) | (((py[LTILE-1:0]>>1)<<HT) | (px[LTILE-1:0]>>1));
    endfunction

    // four banks' tiles + residency
    wire [TIDW-1:0] tid00=tidf(px_b0,py_b0), tid10=tidf(px_b1,py_b0),
                    tid01=tidf(px_b0,py_b1), tid11=tidf(px_b1,py_b1);
    // combinational 4-way tag lookup — MUST be always@* (sensitive to vld/tag), not a function in
    // a wire-assign (that would only re-eval on the tid argument, never on a fill updating the tags).
    reg hit00,hit10,hit01,hit11; reg [SLW-1:0] slot00,slot10,slot01,slot11;
    integer li;
    always @* begin
        hit00=0;slot00=0; hit10=0;slot10=0; hit01=0;slot01=0; hit11=0;slot11=0;
        for (li=0; li<NTILE; li=li+1) begin
            if (vld[li]&&tag[li]==tid00) begin hit00=1; slot00=li[SLW-1:0]; end
            if (vld[li]&&tag[li]==tid10) begin hit10=1; slot10=li[SLW-1:0]; end
            if (vld[li]&&tag[li]==tid01) begin hit01=1; slot01=li[SLW-1:0]; end
            if (vld[li]&&tag[li]==tid11) begin hit11=1; slot11=li[SLW-1:0]; end
        end
    end
    wire [BAW-1:0] a00=baddr(slot00,px_b0,py_b0), a10=baddr(slot10,px_b1,py_b0),
                   a01=baddr(slot01,px_b0,py_b1), a11=baddr(slot11,px_b1,py_b1);
    wire [23:0] r00=b00[a00], r10=b10[a10], r01=b01[a01], r11=b11[a11];

    // parity route to the geometric 2x2 (before edge handling)
    wire [23:0] g00 = lx[0]? (ly[0]? r11:r10) : (ly[0]? r01:r00);   // (x,y)
    wire [23:0] g10 = lx[0]? (ly[0]? r01:r00) : (ly[0]? r11:r10);   // (x+1,y)
    wire [23:0] g01 = lx[0]? (ly[0]? r10:r11) : (ly[0]? r00:r01);   // (x,y+1)
    wire [23:0] g11 = lx[0]? (ly[0]? r00:r01) : (ly[0]? r10:r11);   // (x+1,y+1)
    // edge mux: clamp-to-self neighbours mirror the in-frame pixel
    wire [23:0] pp00 = g00;
    wire [23:0] pp10 = edge_x ? pp00 : g10;
    wire [23:0] pp01 = edge_y ? pp00 : g01;
    wire [23:0] pp11 = edge_x ? pp01 : (edge_y ? pp10 : g11);

    // ---- FSM ----
    localparam S_IDLE=0, S_CHECK=1, S_FILL=2, S_EMIT=3;
    reg [1:0] st, midx;
    reg [SLW-1:0] fill_slot; reg [TIDW-1:0] miss_tid;
    reg [2*LTILE-1:0] fc;                                  // fill within-tile counter
    wire [BAW-1:0] fw_addr = (fill_slot<<(2*HT)) | (((fc[2*LTILE-1:LTILE]>>1)<<HT) | (fc[LTILE-1:0]>>1));
    assign in_ready = (st==S_IDLE);
    integer j;

    // current bank-under-check (midx): its tile coords + residency
    reg [11:0] cur_tx, cur_ty; reg cur_hit;
    always @* begin
        case (midx)
            2'd0: begin cur_tx=px_b0>>LTILE; cur_ty=py_b0>>LTILE; cur_hit=hit00; end
            2'd1: begin cur_tx=px_b1>>LTILE; cur_ty=py_b0>>LTILE; cur_hit=hit10; end
            2'd2: begin cur_tx=px_b0>>LTILE; cur_ty=py_b1>>LTILE; cur_hit=hit01; end
            default: begin cur_tx=px_b1>>LTILE; cur_ty=py_b1>>LTILE; cur_hit=hit11; end
        endcase
    end

    always @(posedge clk) begin
        if (!rstn) begin
            st<=S_IDLE; out_valid<=1'b0; fetch_req<=1'b0; rr<=0; midx<=0;
            for(j=0;j<NTILE;j=j+1) vld[j]<=1'b0;
        end else begin
            fetch_req<=1'b0;
            case (st)
            S_IDLE: if (in_valid) begin
                lx<=in_x; ly<=in_y; lfx<=in_fx; lfy<=in_fy; linwin<=in_inwin; lsb<=in_sb;
                midx<=2'd0; st<= in_inwin ? S_CHECK : S_EMIT;
            end
            S_CHECK: if (cur_hit) begin
                    if (midx==2'd3) st<=S_EMIT; else midx<=midx+2'd1;
                end else begin
                    fetch_req<=1'b1; fetch_tx<=cur_tx; fetch_ty<=cur_ty;
                    fill_slot<=rr; fc<=0; miss_tid<=cur_ty*TX+cur_tx; st<=S_FILL;
                end
            S_FILL: if (fill_valid) begin
                case ({fc[LTILE], fc[0]})              // (row&1, col&1) of the fill position
                    2'b00: b00[fw_addr]<=fill_data;
                    2'b01: b10[fw_addr]<=fill_data;
                    2'b10: b01[fw_addr]<=fill_data;
                    default: b11[fw_addr]<=fill_data;
                endcase
                fc<=fc+1'b1;
                if (fill_last) begin tag[rr]<=miss_tid; vld[rr]<=1'b1; rr<=rr+1'b1; st<=S_CHECK; end
            end
            S_EMIT: begin
                if (!out_valid) begin
                    out_valid<=1'b1; out_fx<=lfx; out_fy<=lfy; out_inwin<=linwin; out_sb<=lsb;
                    out_p00<=pp00; out_p10<=pp10; out_p01<=pp01; out_p11<=pp11;
                end else if (out_ready) begin out_valid<=1'b0; st<=S_IDLE; end
            end
            endcase
        end
    end
endmodule

`default_nettype wire
