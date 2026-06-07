// pg_tile_dma.v — tile fetch + 2x2-block reorder, between the tile cache and the AXI DataMover.
//
// The cache asks for tile (tx,ty); DDR holds the frame raster (linear), so we issue TILE row-fetches
// (one DataMover command each: addr = base + (ty*TILE+r)*stride + tx*TILE*3, BTT = TILE*3 bytes).
// 64-bit beats are gearboxed to TWO pixels/clock (uses the beat's ~2.67px bandwidth — a 1px/clk
// gearbox starves the cache), the even row is buffered, then paired with the odd row to emit one
// 2x2-block fill/clock {p11,p01,p10,p00} for the cache's 4-bank parallel write. ~128 clk/tile.
// Reuses the pg_read_engine_top fetch/beat interface (drop-in where pg_linefetch sat). One tile in
// flight (matches the cache's single-outstanding fetch).

`default_nettype none
`timescale 1ns / 1ps

module pg_tile_dma #(
    parameter integer IN_W  = 1920,
    parameter integer LTILE = 4
) (
    input  wire        clk, rstn,
    input  wire [31:0] frame_base,
    input  wire        t_req,
    input  wire [11:0] t_tx, t_ty,
    output reg         fill_valid,
    output reg  [95:0] fill_blk,
    output reg         fill_last,
    output reg         fetch_req,
    output reg  [31:0] fetch_addr,
    output reg  [11:0] fetch_len,
    input  wire [63:0] beat_data,
    input  wire        beat_valid,
    output wire        beat_ready,
    input  wire        beat_last
);
    localparam integer TILE=(1<<LTILE), STRIDE=IN_W*3;

    // ---- 64b beat -> 2 px/clk gearbox ----
    reg  [135:0] acc; reg [7:0] nbits;
    assign beat_ready = (nbits <= 8'd64);                 // room for one more 64b beat
    wire        acc_beat = beat_valid && beat_ready;
    wire        emit2    = (nbits >= 8'd48);              // two pixels available
    wire [23:0] g_p0 = acc[23:0], g_p1 = acc[47:24];
    wire [7:0]  nbits_ae = emit2 ? (nbits - 8'd48) : nbits;
    wire [135:0] acc_ae  = emit2 ? (acc >> 48) : acc;

    reg [23:0] even_buf[0:TILE-1];
    reg [11:0] tx_l, ty_l; reg [4:0] row, pcol; reg busy;

    always @(posedge clk) begin
        if(!rstn) begin
            busy<=1'b0; fetch_req<=1'b0; fill_valid<=1'b0; fill_last<=1'b0;
            row<=5'd0; pcol<=5'd0; acc<=136'd0; nbits<=8'd0;
        end else begin
            fetch_req<=1'b0; fill_valid<=1'b0; fill_last<=1'b0;
            if(!busy) begin
                if(t_req) begin
                    tx_l<=t_tx; ty_l<=t_ty; row<=5'd0; pcol<=5'd0; nbits<=8'd0; acc<=136'd0; busy<=1'b1;
                    fetch_addr<=frame_base + (t_ty*TILE)*STRIDE + (t_tx*TILE)*3;
                    fetch_len<=TILE[11:0]; fetch_req<=1'b1;
                end
            end else begin
                // gearbox accumulator update (pop 48 on emit, append 64 on beat)
                if(acc_beat) begin acc <= acc_ae | ({72'd0, beat_data} << nbits_ae); nbits <= nbits_ae + 8'd64; end
                else         begin acc <= acc_ae; nbits <= nbits_ae; end
                // consume the two emitted pixels
                if(emit2) begin
                    if(row[0]==1'b0) begin
                        even_buf[pcol]<=g_p0; even_buf[pcol+5'd1]<=g_p1;     // even row -> buffer
                    end else begin
                        fill_valid<=1'b1;                                    // odd row -> emit block
                        fill_blk<={g_p1, g_p0, even_buf[pcol+5'd1], even_buf[pcol]};
                        fill_last<=(row==TILE-1) && (pcol==TILE-2);
                    end
                    if(pcol==TILE-2) begin                                   // row complete (TILE px)
                        pcol<=5'd0;
                        if(row==TILE-1) busy<=1'b0;
                        else begin
                            row<=row+5'd1;
                            fetch_addr<=frame_base + (ty_l*TILE + (row+5'd1))*STRIDE + (tx_l*TILE)*3;
                            fetch_len<=TILE[11:0]; fetch_req<=1'b1;
                        end
                    end else pcol<=pcol+5'd2;
                end
            end
        end
    end
endmodule

`default_nettype wire
