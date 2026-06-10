// pg_tile_to_raster.v — production orient engine, output-side reorder: 16x16 OUTPUT tiles -> RASTER.
// Mirror of pg_raster_to_tile. The output-tile engine produces output in 16x16 tiles (tile-row-major:
// for each output tile-row, otx=0..OTX-1, each tile 256 px r0c0..r15c15); this buffers a 16-row band of
// them and streams it out as raster lines for the VTC. Two band BRAMs ping-pong (fill one while emitting
// the other). 1 px/clk both ways; SOF on the first raster pixel of each frame; tlast per output line.
`default_nettype none
`timescale 1ns / 1ps

module pg_tile_to_raster #(
    parameter integer OUT_W = 1280,
    parameter integer LTILE = 4                       // TILE = 16
) (
    input  wire        clk, rstn,
    input  wire [23:0] s_axis_tdata, input wire s_axis_tvalid, output wire s_axis_tready,
    input  wire        s_axis_tuser,                  // SOF (first beat of the frame's first output tile)
    input  wire        s_axis_tlast,                  // per-tile (unused; counted)
    output reg  [23:0] m_axis_tdata, output reg m_axis_tvalid, input wire m_axis_tready,
    output reg         m_axis_tuser,                  // SOF — first raster pixel of the frame
    output reg         m_axis_tlast                   // per-line EOL
);
    localparam integer TILE=(1<<LTILE), BAND=TILE*OUT_W, OTX=OUT_W/TILE, AW=$clog2(BAND);
    (* ram_style="block" *) reg [23:0] band0[0:BAND-1];
    (* ram_style="block" *) reg [23:0] band1[0:BAND-1];
    reg full0, full1;
    reg first0, first1, wfirst;

    // ---- WRITE: output tiles (otx,r,c) -> band[r*OUT_W + otx*16 + c] ----
    reg        wsel; reg [11:0] wotx; reg [3:0] wr, wc;
    wire wfree = wsel ? !full1 : !full0;
    assign s_axis_tready = wfree;
    wire wbeat = s_axis_tvalid && s_axis_tready;
    wire        sof_beat = wbeat && s_axis_tuser;     // SOF -> this beat is tile 0, (r,c)=(0,0)
    wire [11:0] eotx = sof_beat ? 12'd0 : wotx;
    wire [3:0]  erw  = sof_beat ? 4'd0  : wr;
    wire [3:0]  ecw  = sof_beat ? 4'd0  : wc;
    wire [AW-1:0] waddr = erw*OUT_W + (eotx*TILE + ecw);

    // ---- EMIT: band -> raster (er row, ec col), 1-cycle BRAM read pipeline ----
    reg        esel; reg e_act; reg [3:0] eer; reg [11:0] eec; reg eo_armed;
    wire efull = esel ? full1 : full0;
    wire [AW-1:0] eaddr = eer*OUT_W + eec;
    reg  s1_v, s1_last, s1_sel; reg [23:0] eq0, eq1;
    wire out_ready = !m_axis_tvalid || m_axis_tready;
    wire emit_go = out_ready && (e_act || s1_v);

    always @(posedge clk) begin
        if(!rstn) begin
            wsel<=0; wotx<=0; wr<=0; wc<=0; full0<=0; full1<=0; wfirst<=0; first0<=0; first1<=0;
            esel<=0; e_act<=0; eer<=0; eec<=0; s1_v<=0; m_axis_tvalid<=0; m_axis_tlast<=0; m_axis_tuser<=0; eo_armed<=0;
        end else begin
            // ---------- WRITE ----------
            if(sof_beat) wfirst<=1'b1;
            if(wbeat) begin
                if(wsel==0) band0[waddr]<=s_axis_tdata; else band1[waddr]<=s_axis_tdata;
                if(ecw==TILE-1) begin wc<=0;            // end of a tile row of 16 px
                    if(erw==TILE-1) begin wr<=0;        // end of a tile (16x16)
                        if(eotx==OTX-1) begin           // band done (OTX tiles)
                            if(wsel==0) begin full0<=1'b1; first0<=wfirst||sof_beat; end
                            else        begin full1<=1'b1; first1<=wfirst||sof_beat; end
                            wfirst<=1'b0; wsel<=~wsel; wotx<=0;
                        end else wotx<=eotx+1'b1;
                    end else wr<=erw+1'b1;
                end else begin wc<=ecw+1'b1; wr<=erw; wotx<=eotx; end
            end

            // ---------- EMIT ----------
            if(m_axis_tvalid && m_axis_tready) m_axis_tvalid<=0;
            if(!e_act && !s1_v && efull) begin e_act<=1'b1; eer<=0; eec<=0;
                eo_armed <= (esel ? first1 : first0); end
            if(emit_go) begin
                m_axis_tdata  <= s1_sel ? eq1 : eq0;
                m_axis_tvalid <= s1_v;
                m_axis_tuser  <= s1_v && eo_armed;
                if(s1_v && eo_armed) eo_armed <= 1'b0;
                m_axis_tlast  <= s1_last;
                if(e_act) begin
                    eq0 <= band0[eaddr]; eq1 <= band1[eaddr];
                    s1_v <= 1'b1; s1_sel <= esel; s1_last <= (eec==OUT_W-1);  // EOL
                    if(eec==OUT_W-1) begin eec<=0;
                        if(eer==TILE-1) e_act<=1'b0; else eer<=eer+1'b1;
                    end else eec<=eec+1'b1;
                end else begin
                    s1_v <= 1'b0;
                    if(esel==0) full0<=1'b0; else full1<=1'b0; esel<=~esel;
                end
            end
        end
    end
endmodule

`default_nettype wire
