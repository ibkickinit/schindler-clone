// pg_raster_to_tile.v — production orient engine, P2: RASTER -> TILED conversion (DDR-efficiency foundation).
// Buffers a 16-row band of the source raster in BRAM, then emits it as 16x16 tiles in tile-row-major order,
// so the downstream S2MM writes a TILED frame. A tiled frame lets the orient reader fetch ANY tile (any
// orientation) as ONE contiguous 768B burst (the 1080p60 proof) instead of 16 strided 48B reads.
//
// Two band buffers ping-pong (full[0]/full[1]): fill one while emitting the other -> 1 px/clk both ways.
// Emit order per band: tx=0..TILES_X-1 { r=0..15 { c=0..15 { px(r, tx*16+c) } } } -> each 16x16 tile
// contiguous, tlast on the last beat of each tile.
`default_nettype none
`timescale 1ns / 1ps

module pg_raster_to_tile #(
    parameter integer IN_W  = 1920,
    parameter integer LTILE = 4                       // TILE = 16
) (
    input  wire        clk, rstn,
    input  wire [23:0] s_tdata, input wire s_tvalid, output wire s_tready,
    input  wire        s_tuser,                        // SOF
    input  wire        s_tlast,                        // EOL (unused; row width is counted)
    output reg  [23:0] m_tdata, output reg m_tvalid, input wire m_tready,
    output reg         m_tuser,                        // SOF — first beat of the frame's first tile
    output reg         m_tlast                         // last beat of a 16x16 tile
);
    localparam integer TILE=(1<<LTILE), BAND=TILE*IN_W, TILES_X=IN_W/TILE, AW=$clog2(BAND);
    (* ram_style="block" *) reg [23:0] band0[0:BAND-1];
    (* ram_style="block" *) reg [23:0] band1[0:BAND-1];
    reg full0, full1;                                  // per-buffer: filled, waiting to emit
    reg first0, first1, wfirst;                        // per-buffer "this band is the frame's FIRST band"

    // ---- WRITE: raster -> the buffer wsel ----
    reg        wsel; reg [11:0] wrow, wcol;
    wire wfree = wsel ? !full1 : !full0;
    assign s_tready = wfree;
    wire wbeat = s_tvalid && s_tready;
    wire        sof_beat = wbeat && s_tuser;            // SOF -> this beat is (row 0, col 0)
    wire [11:0] erow = sof_beat ? 12'd0 : wrow;
    wire [11:0] ecol = sof_beat ? 12'd0 : wcol;
    wire [AW-1:0] waddr = erow*IN_W + ecol;

    // ---- EMIT: the buffer esel -> tiled stream (1-cycle BRAM read pipeline) ----
    reg        esel; reg e_act; reg [11:0] etx; reg [3:0] er, ec; reg eo_armed;  // arm SOF on band's 1st out beat
    wire efull = esel ? full1 : full0;
    wire [AW-1:0] eaddr = er*IN_W + (etx*TILE + ec);
    reg  s1_v, s1_last, s1_sel; reg [23:0] eq0, eq1;    // S1: registered read + carried meta
    wire out_ready = !m_tvalid || m_tready;
    wire emit_go = out_ready && (e_act || s1_v);        // run while emitting OR flushing the last S1 beat

    always @(posedge clk) begin
        if(!rstn) begin
            wsel<=0; wrow<=0; wcol<=0; full0<=0; full1<=0; wfirst<=0; first0<=0; first1<=0;
            esel<=0; e_act<=0; etx<=0; er<=0; ec<=0; s1_v<=0; m_tvalid<=0; m_tlast<=0; m_tuser<=0; eo_armed<=0;
        end else begin
            // ---------- WRITE (SOF beat = (0,0), then advance) ----------
            if(sof_beat) wfirst<=1'b1;                          // the band starting now is the frame's first
            if(wbeat) begin
                if(wsel==0) band0[waddr]<=s_tdata; else band1[waddr]<=s_tdata;
                if(ecol==IN_W-1) begin wcol<=0;
                    if(erow==TILE-1) begin wrow<=0;
                        if(wsel==0) begin full0<=1'b1; first0<=wfirst||sof_beat; end
                        else        begin full1<=1'b1; first1<=wfirst||sof_beat; end
                        wfirst<=1'b0; wsel<=~wsel;              // band done -> hand off + swap; next band not first
                    end else wrow<=erow+1'b1;
                end else begin wcol<=ecol+1'b1; wrow<=erow; end
            end

            // ---------- EMIT (S1 read -> OUT, 1-cycle BRAM-read pipeline) ----------
            if(m_tvalid && m_tready) m_tvalid<=0;
            if(!e_act && !s1_v && efull) begin e_act<=1'b1; etx<=0; er<=0; ec<=0;
                eo_armed <= (esel ? first1 : first0); end           // arm SOF if this band is the frame's first
            if(emit_go) begin
                // OUT: push the read of the addr presented LAST cycle
                m_tdata  <= s1_sel ? eq1 : eq0;
                m_tvalid <= s1_v;
                m_tuser  <= s1_v && eo_armed;                       // SOF on the band's FIRST output beat
                if(s1_v && eo_armed) eo_armed <= 1'b0;
                m_tlast  <= s1_last;
                if(e_act) begin                                    // S1: present this addr + advance
                    eq0 <= band0[eaddr]; eq1 <= band1[eaddr];
                    s1_v <= 1'b1; s1_sel <= esel; s1_last <= (er==TILE-1) && (ec==TILE-1);  // last beat of tile
                    if(ec==TILE-1) begin ec<=0;
                        if(er==TILE-1) begin er<=0;
                            if(etx==TILES_X-1) e_act<=1'b0; else etx<=etx+1'b1;
                        end else er<=er+1'b1;
                    end else ec<=ec+1'b1;
                end else begin                                     // FLUSH last beat -> free buffer + swap
                    s1_v <= 1'b0;
                    if(esel==0) full0<=1'b0; else full1<=1'b0; esel<=~esel;
                end
            end
        end
    end
endmodule

`default_nettype wire
