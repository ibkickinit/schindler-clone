// pg_tile_dma.v — tile fetch + 2x2-block reorder, between the tile cache and the AXI DataMover.
//
// The cache asks for tile (tx,ty); DDR holds the frame raster (linear), so we issue 16 row-fetches
// (one DataMover command each: addr = base + (ty*TILE+r)*stride + tx*TILE*3, BTT = TILE*3 bytes),
// run the 64-bit beats through pg_unpack to recover TILE pixels/row, buffer the even row, then pair
// it with the odd row to emit TILE/2 * TILE/2 = 64 2x2-block fills {p11,p01,p10,p00} for the cache's
// 4-bank parallel write. Reuses the existing pg_read_engine_top fetch/beat interface (drop-in where
// pg_linefetch sat). One tile in flight (matches the cache's single-outstanding fetch).

`default_nettype none
`timescale 1ns / 1ps

module pg_tile_dma #(
    parameter integer IN_W  = 1920,
    parameter integer LTILE = 4
) (
    input  wire        clk, rstn,
    input  wire [31:0] frame_base,                 // genlock-selected source frame base (bytes)
    // request from the cache
    input  wire        t_req,
    input  wire [11:0] t_tx, t_ty,
    // 2x2-block fill to the cache
    output reg         fill_valid,
    output reg  [95:0] fill_blk,
    output reg         fill_last,
    // DataMover fetch (to pg_read_engine_top command formatter)
    output reg         fetch_req,
    output reg  [31:0] fetch_addr,
    output reg  [11:0] fetch_len,                  // pixels (formatter -> BTT = len*3)
    // DataMover MM2S beats (64-bit)
    input  wire [63:0] beat_data,
    input  wire        beat_valid,
    output wire        beat_ready,
    input  wire        beat_last
);
    localparam integer TILE=(1<<LTILE), STRIDE=IN_W*3;

    // beats -> pixels
    wire        p_valid; wire [23:0] p_data; wire p_last;
    pg_unpack u_unpack (.clk(clk),.rstn(rstn),.line_px(TILE[11:0]),
        .s_tdata(beat_data),.s_tvalid(beat_valid),.s_tready(beat_ready),
        .p_valid(p_valid),.p_data(p_data),.p_last(p_last));

    reg [23:0] even_buf[0:TILE-1];                 // the buffered even row
    reg [23:0] odd_prev;                           // previous pixel of the odd row (col 2bc)
    reg [11:0] tx_l, ty_l; reg [4:0] row;          // current tile + row (0..TILE)
    reg [4:0]  pcol;                               // pixel column within the row
    reg        busy;
    integer bi;

    wire [31:0] row_addr = frame_base + (ty_l*TILE + row)*STRIDE + (tx_l*TILE)*3;

    always @(posedge clk) begin
        if(!rstn) begin
            busy<=1'b0; fetch_req<=1'b0; fill_valid<=1'b0; fill_last<=1'b0; row<=5'd0; pcol<=5'd0;
        end else begin
            fetch_req<=1'b0; fill_valid<=1'b0; fill_last<=1'b0;
            if(!busy) begin
                if(t_req) begin                    // start a tile: issue row 0
                    tx_l<=t_tx; ty_l<=t_ty; row<=5'd0; pcol<=5'd0; busy<=1'b1;
                    fetch_addr<=frame_base + (t_ty*TILE)*STRIDE + (t_tx*TILE)*3;
                    fetch_len<=TILE[11:0]; fetch_req<=1'b1;
                end
            end else if(p_valid) begin
                // collect pixel pcol of the current row
                if(row[0]==1'b0) begin
                    even_buf[pcol]<=p_data;                 // even row -> buffer
                end else begin
                    odd_prev<=p_data;                       // odd row -> pair on odd columns
                    if(pcol[0]==1'b1) begin                 // pcol = 2bc+1 -> emit block bc
                        fill_valid<=1'b1;
                        fill_blk<={p_data, odd_prev, even_buf[pcol], even_buf[pcol-5'd1]};
                        fill_last<=(row==TILE-1) && (pcol==TILE-1);
                    end
                end
                if(p_last) begin                            // row done (TILE px)
                    pcol<=5'd0;
                    if(row==TILE-1) busy<=1'b0;             // tile done
                    else begin
                        row<=row+5'd1;
                        fetch_addr<=frame_base + (ty_l*TILE + (row+5'd1))*STRIDE + (tx_l*TILE)*3;
                        fetch_len<=TILE[11:0]; fetch_req<=1'b1;     // issue next row
                    end
                end else pcol<=pcol+5'd1;
            end
        end
    end
endmodule

`default_nettype wire
