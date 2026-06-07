// pg_tile_dma.v — tile fetch + 2x2-block reorder, between the tile cache and the AXI DataMover.
//
// REWRITE (fill rework, 2026-06-07): the old gearbox capped at 2 px/clk and issued the 16 tile-row
// DataMover commands serially (each waiting for the prior row's last emit), so beats only flowed ~half
// the in-flight time and the prefetch starved. This version is GAP-FREE:
//   * Row commands are PIPELINED: fetch_req is held (AXIS-style, combinational; VALID independent of
//     READY) and one row is consumed per fetch_ready, so the DataMover command FIFO is kept full and the
//     beat stream never stalls between rows OR tiles. Tile requests are buffered (t_req/t_ready).
//   * The 64-bit beat is drained at up to 3 px/clk (the full ~2.67 px/clk beat bandwidth), gated so a
//     downstream stall never loses pixels.
//   * A 2-slot PAIR ping-pong (be/bo, independent producer/consumer pointers rx_pp/em_pp + full[] flags)
//     lets the emitter drain one row-pair as 8 2x2 blocks while the receiver fills the next — emit runs
//     at the beat rate (~96 clk/tile) with no even-row dead phase.
// The cache fill interface is unchanged: one 2x2 block {b11,b01,b10,b00}/clk, fill_last per tile, blocks
// emitted in row-pair-major / paircol order so the cache's fcw within-slot addressing stays bit-exact.

`default_nettype none
`timescale 1ns / 1ps

module pg_tile_dma #(
    parameter integer IN_W  = 1920,
    parameter integer LTILE = 4,
    parameter integer DREQ  = 16                     // outstanding tile requests buffered (covers the
                                                     // prefetch's in-flight burst; see pg_tilecache_rt2)
) (
    input  wire        clk, rstn,
    input  wire [31:0] frame_base,
    // tile request in (handshake; t_req may assert while busy -> queued)
    input  wire        t_req,
    input  wire [11:0] t_tx, t_ty,
    output wire        t_ready,
    // 2x2-block fill out to the cache
    output reg         fill_valid,
    output reg  [95:0] fill_blk,
    output reg         fill_last,
    // DataMover command out (one per tile row); held while a row is pending, consumed on fetch_ready
    output wire        fetch_req,
    output wire [31:0] fetch_addr,
    output wire [11:0] fetch_len,
    input  wire        fetch_ready,
    // DataMover beat in
    input  wire [63:0] beat_data,
    input  wire        beat_valid,
    output wire        beat_ready,
    input  wire        beat_last
);
    localparam integer TILE=(1<<LTILE), STRIDE=IN_W*3, DW=$clog2(DREQ);

    // ---------------- input tile request FIFO ----------------
    reg [23:0] rq[0:DREQ-1];                          // {ty,tx}
    reg [DW:0] rq_cnt; reg [DW-1:0] rq_wr, rq_rd;
    wire rq_full  = (rq_cnt==DREQ[DW:0]);
    wire rq_empty = (rq_cnt==0);
    assign t_ready = !rq_full;
    wire rq_push = t_req && t_ready;

    // ---------------- command issuer (pipelined rows; gap-free across rows AND tiles) ----------
    reg        iss_act;                               // a tile is being issued (rows 0..TILE-1)
    reg [11:0] iss_tx, iss_ty; reg [LTILE-1:0] iss_row;
    wire       iss_load = !iss_act && !rq_empty;       // latch+pop the next tile to issue
    assign     fetch_req  = iss_act;                   // hold a row command while a tile is active
    assign     fetch_addr = frame_base + (iss_ty*TILE + iss_row)*STRIDE + (iss_tx*TILE)*3;
    assign     fetch_len  = TILE[11:0];
    wire       iss_emit = iss_act && fetch_ready;      // a row command is consumed this cycle

    // ---------------- receive: 64b beats -> px, into a 2-slot pair ping-pong ----------
    reg        rx_act;                                // receiving a tile's pixels
    reg [11:0] rx_left;                               // tiles issued but not yet fully received
    reg        rx_pp;                                 // pair buffer the receiver fills (toggles per pair)
    reg        rx_sub;                                // 0 = even row of the pair, 1 = odd row
    reg [2:0]  rx_pr;                                 // pair index within the current tile (0..7)
    reg [3:0]  rcol;                                  // column 0..TILE-1 within the current row
    reg [199:0] acc; reg [7:0] nbits;                 // wide accumulator: holds enough that >=3 whole px
                                                      // are usually available, so the drain sustains 2.67px/clk
    reg [23:0] be[0:1][0:TILE-1];                     // even-row pixels  [slot][col]
    reg [23:0] bo[0:1][0:TILE-1];                     // odd-row  pixels  [slot][col]
    reg        full[0:1];                             // pair slot filled, waiting to emit
    wire       can_rx = rx_act && !full[rx_pp];       // receiving AND target slot free
    // drain up to 4 px/clk: must beat the 2.67 px/clk (64b) beat rate so the gearbox never backs up and
    // stalls the DataMover (a 3px/clk cap + the row-boundary trim averages below 2.67 -> nbits overflow).
    wire [3:0] navail = (nbits>=8'd96)?4'd4:(nbits>=8'd72)?4'd3:(nbits>=8'd48)?4'd2:(nbits>=8'd24)?4'd1:4'd0;
    wire [4:0] room   = TILE[4:0]-{1'b0,rcol};        // px left in this row
    wire [3:0] ndrain = !can_rx ? 4'd0 : (navail>room[3:0] && room<4) ? room[3:0] : navail;
    assign beat_ready = (nbits <= 8'd96) && rx_act;   // hold up to ~96b so navail stays 3-4 (sustains rate)
    wire       acc_beat = beat_valid && beat_ready;
    wire [7:0] drbits = {1'b0,ndrain,4'b0000} + {1'b0,ndrain,3'b000};      // 24*ndrain (max 96)
    wire [7:0] nbits_a = nbits - drbits;
    wire [199:0] acc_a = acc >> drbits;
    wire [23:0] px0 = acc[23:0], px1 = acc[47:24], px2 = acc[71:48], px3 = acc[95:72];
    wire       row_done = (ndrain!=0) && (rcol + ndrain >= TILE);
    wire       rx_done  = row_done && rx_sub && (rx_pr==3'd7);   // tile fully received this cycle

    // ---------------- emit: drain a full pair slot as 8 2x2 blocks ----------
    reg        em_pp; reg [2:0] ecol, epr; reg emit_act;

    always @(posedge clk) begin
        if(!rstn) begin
            rq_cnt<=0; rq_wr<=0; rq_rd<=0;
            iss_act<=0; iss_row<=0;
            acc<=0; nbits<=0; rcol<=0; rx_act<=0; rx_left<=0; rx_pp<=0; rx_sub<=0; rx_pr<=0;
            full[0]<=0; full[1]<=0;
            em_pp<=0; ecol<=0; epr<=0; emit_act<=0;
            fill_valid<=0; fill_last<=0;
        end else begin
            fill_valid<=0; fill_last<=0;

            // ----- request FIFO push + issuer pop -----
            if(rq_push) begin rq[rq_wr]<={t_ty,t_tx}; rq_wr<=rq_wr+1'b1; end
            if(iss_load) begin
                iss_tx<=rq[rq_rd][11:0]; iss_ty<=rq[rq_rd][23:12]; iss_row<=0; iss_act<=1;
                rq_rd<=rq_rd+1'b1;
            end else if(iss_emit) begin
                if(iss_row==TILE-1) iss_act<=0; else iss_row<=iss_row+1'b1;
            end
            rq_cnt  <= rq_cnt  + (rq_push?1:0) - (iss_load?1:0);
            rx_left <= rx_left + (iss_load?1:0) - ((rx_act && rx_done)?1:0);

            // ----- receive: gearbox drain into the pair ping-pong -----
            if(acc_beat) begin acc <= acc_a | ({136'd0, beat_data} << nbits_a); nbits <= nbits_a + 8'd64; end
            else         begin acc <= acc_a;                                    nbits <= nbits_a; end
            if(!rx_act) begin
                if(rx_left!=0) begin rx_act<=1; rcol<=0; rx_sub<=0; rx_pr<=0; end
            end else if(ndrain!=0) begin
                if(rx_sub) begin                          // odd row -> bo
                    if(ndrain>=1) bo[rx_pp][rcol]   <= px0;
                    if(ndrain>=2) bo[rx_pp][rcol+1] <= px1;
                    if(ndrain>=3) bo[rx_pp][rcol+2] <= px2;
                    if(ndrain>=4) bo[rx_pp][rcol+3] <= px3;
                end else begin                            // even row -> be
                    if(ndrain>=1) be[rx_pp][rcol]   <= px0;
                    if(ndrain>=2) be[rx_pp][rcol+1] <= px1;
                    if(ndrain>=3) be[rx_pp][rcol+2] <= px2;
                    if(ndrain>=4) be[rx_pp][rcol+3] <= px3;
                end
                if(row_done) begin
                    rcol<=0;
                    if(!rx_sub) rx_sub<=1'b1;             // even done -> do odd row, same slot
                    else begin                            // pair complete
                        full[rx_pp]<=1'b1; rx_pp<=~rx_pp; rx_sub<=1'b0;
                        if(rx_pr==3'd7) begin rx_pr<=0; rx_act<=0; end  // tile done
                        else rx_pr<=rx_pr+1'b1;
                    end
                end else rcol<=rcol+ndrain;
            end

            // ----- emit: drain a full pair slot as 8 blocks (paircol 0..7) -----
            if(!emit_act) begin
                if(full[em_pp]) begin emit_act<=1; ecol<=0; end
            end else begin
                fill_valid<=1;
                fill_blk<={ bo[em_pp][{ecol,1'b1}], bo[em_pp][{ecol,1'b0}],
                            be[em_pp][{ecol,1'b1}], be[em_pp][{ecol,1'b0}] };  // {b11,b01,b10,b00}
                fill_last<=(epr==3'd7) && (ecol==3'd7);
                if(ecol==3'd7) begin
                    emit_act<=0; full[em_pp]<=1'b0; em_pp<=~em_pp;
                    epr<=(epr==3'd7)?3'd0:epr+1'b1;
                end else ecol<=ecol+1'b1;
            end
        end
    end
endmodule

`default_nettype wire
