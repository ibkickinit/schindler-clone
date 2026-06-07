// pg_tilecache.v — Phase-2 fetch for the warp read engine, MILESTONE 1 (functional).
//
// Given a stream of integer source coords (top-left of the bilinear 2x2) + fractions from
// pg_affine, returns the 2x2 source pixels, fetching 32x32 tiles from the (genlock-selected)
// DDR frame through a small BRAM tile cache. Demand-fetch + round-robin victim — FUNCTIONALLY
// correct (bit-exact), proven in sim against a golden. NOT yet real-time-optimized (1 px/cycle
// gather + prefetch is Milestone 2); this milestone proves the cache LOGIC (tag/fill/gather/
// edge-clamp/straddle) is correct before the real-time refinement.
//
// Behavioral tile store + behavioral DMA interface (the TB models DDR). The 2x2 may straddle up
// to 4 tiles at tile/frame edges — each pixel is resolved independently (clamped at the frame
// edge, mirror-style, matching pg_linefetch's lastcol behaviour).

`default_nettype none
`timescale 1ns / 1ps

module pg_tilecache #(
    parameter integer IN_W   = 1920,
    parameter integer IN_H   = 1080,
    parameter integer LTILE  = 5,            // log2(tile dim) -> 32x32
    parameter integer NTILE  = 16,           // cache depth (tiles)
    parameter integer SB     = 4             // passthrough side-band width (new_row/tuser/tlast/inwin spare)
) (
    input  wire        clk,
    input  wire        rstn,

    // consumer (from pg_affine): integer src coord of the 2x2 top-left + Q0.12 fractions + side-band
    input  wire        in_valid,
    input  wire [11:0] in_x,
    input  wire [11:0] in_y,
    input  wire [11:0] in_fx,
    input  wire [11:0] in_fy,
    input  wire        in_inwin,
    input  wire [SB-1:0] in_sb,
    output wire        in_ready,

    // producer (to bilinear): the 2x2 + fractions + side-band
    output reg         out_valid,
    output reg  [23:0] out_p00, out_p10, out_p01, out_p11,
    output reg  [11:0] out_fx, out_fy,
    output reg         out_inwin,
    output reg  [SB-1:0] out_sb,
    input  wire        out_ready,

    // behavioral DMA: pulse fetch_req with the tile coords; receive the tile's pixels streamed
    output reg         fetch_req,
    output reg  [11:0] fetch_tx,
    output reg  [11:0] fetch_ty,
    input  wire        fill_valid,
    input  wire [23:0] fill_data,
    input  wire        fill_last
);
    localparam integer TILE  = (1 << LTILE);
    localparam integer TPX   = TILE * TILE;          // pixels per tile
    localparam integer TX    = (IN_W + TILE - 1) / TILE;
    localparam integer SLW   = $clog2(NTILE);
    localparam integer TIDW  = 24;

    // ---- storage ----
    (* ram_style="block" *) reg [23:0] tmem [0:NTILE*TPX-1];
    reg [TIDW-1:0] tag [0:NTILE-1];
    reg            vld [0:NTILE-1];
    reg [SLW-1:0]  rr;                                // round-robin victim

    // ---- latched request ----
    reg [11:0] lx, ly, lfx, lfy; reg linwin; reg [SB-1:0] lsb;
    reg [1:0]  pidx;                                  // which of the 4 neighbours (0..3)
    reg [23:0] p0, p1, p2, p3;

    // current neighbour pixel coord (edge-clamped)
    wire [11:0] lxr = (lx >= IN_W-1) ? lx : lx + 12'd1;
    wire [11:0] lyb = (ly >= IN_H-1) ? ly : ly + 12'd1;
    wire [11:0] cpx = (pidx==2'd0 || pidx==2'd2) ? lx : lxr;
    wire [11:0] cpy = (pidx==2'd0 || pidx==2'd1) ? ly : lyb;
    wire [11:0] ctx = cpx >> LTILE;
    wire [11:0] cty = cpy >> LTILE;
    wire [TIDW-1:0] ctid = cty * TX[11:0] + ctx;
    wire [2*LTILE-1:0] within = (cpy[LTILE-1:0] << LTILE) | cpx[LTILE-1:0];

    // combinational tag lookup
    integer i; reg hit; reg [SLW-1:0] slot;
    always @* begin
        hit = 1'b0; slot = {SLW{1'b0}};
        for (i=0;i<NTILE;i=i+1)
            if (vld[i] && tag[i]==ctid) begin hit = 1'b1; slot = i[SLW-1:0]; end
    end
    wire [SLW+2*LTILE-1:0] rd_addr = (slot << (2*LTILE)) | within;
    wire [23:0] rd_pix = tmem[rd_addr];

    // ---- FSM ----
    localparam S_IDLE=0, S_SERVE=1, S_FILL=2, S_EMIT=3;
    reg [1:0] st;
    reg [SLW+2*LTILE-1:0] fill_addr;                  // write pointer during fill

    assign in_ready = (st==S_IDLE);

    integer j;
    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE; out_valid <= 1'b0; fetch_req <= 1'b0; rr <= 0; pidx <= 0;
            for (j=0;j<NTILE;j=j+1) vld[j] <= 1'b0;
        end else begin
            fetch_req <= 1'b0;
            case (st)
            S_IDLE: begin
                if (in_valid) begin
                    lx<=in_x; ly<=in_y; lfx<=in_fx; lfy<=in_fy; linwin<=in_inwin; lsb<=in_sb;
                    pidx <= 2'd0;
                    st <= in_inwin ? S_SERVE : S_EMIT;
                end
            end
            S_SERVE: begin
                if (hit) begin
                    case (pidx)
                        2'd0: p0 <= rd_pix; 2'd1: p1 <= rd_pix;
                        2'd2: p2 <= rd_pix; default: p3 <= rd_pix;
                    endcase
                    if (pidx==2'd3) st <= S_EMIT;
                    else pidx <= pidx + 2'd1;
                end else begin
                    fetch_req <= 1'b1; fetch_tx <= ctx; fetch_ty <= cty;
                    fill_addr <= (rr << (2*LTILE));
                    st <= S_FILL;
                end
            end
            S_FILL: begin
                if (fill_valid) begin
                    tmem[fill_addr] <= fill_data;
                    fill_addr <= fill_addr + 1'b1;
                    if (fill_last) begin
                        tag[rr] <= ctid; vld[rr] <= 1'b1; rr <= rr + 1'b1;
                        st <= S_SERVE;            // retry the same neighbour — now a hit
                    end
                end
            end
            S_EMIT: begin
                if (!out_valid) begin
                    out_valid <= 1'b1;
                    out_p00<=p0; out_p10<=p1; out_p01<=p2; out_p11<=p3;
                    out_fx<=lfx; out_fy<=lfy; out_inwin<=linwin; out_sb<=lsb;
                end else if (out_ready) begin
                    out_valid <= 1'b0; st <= S_IDLE;
                end
            end
            endcase
        end
    end
endmodule

`default_nettype wire
