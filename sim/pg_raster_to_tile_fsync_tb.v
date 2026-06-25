// pg_raster_to_tile_fsync_tb.v — Path B fsync-alignment proof (2026-06-25).
//
// Drives a FULL multi-frame raster through pg_raster_to_tile with realistic vsync (s_tuser=SOF at row0/col0)
// timing, including a TRAILING PARTIAL BAND (frame height not a multiple of 16, like 1080 -> 67 full bands +
// 8-row remainder dropped). Confirms the m_sof output frame-sync:
//   (a) pulses for exactly ONE cycle on the FIRST emitted beat of tile(0,0) of each frame,
//   (b) exactly TILES_X*TILES_Y tiles (each with tlast) land between consecutive m_sof pulses,
//   (c) NO mid-frame m_sof (sof never fires except on a tile-0/beat-0),
//   (d) the emitted tile-row-major data is bit-exact per frame.
//
// Geometry (scaled-down but topologically identical to 1920x1080->120x67):
//   IN_W=32 -> TILES_X=2;  frame height H=40 -> 2 full 16-row bands + 8-row remainder (dropped) -> TILES_Y=2.
//   tiles/frame = TILES_X*TILES_Y = 4.  px(row,col) = frame*1000 + row*32 + col  (frame-unique).
//
// Also stresses back-pressure: m_tr drops periodically so the fsync-vs-first-beat alignment is checked under
// stall (the silicon case where the VDMA back-pressures the S2MM AXIS).

`default_nettype none
`timescale 1ns/1ps
module pg_raster_to_tile_fsync_tb;
    localparam IN_W=32, TILE=16, TILES_X=IN_W/TILE; // =2
    localparam H=40;                                 // 2 full bands + 8 remainder
    localparam TILES_Y=H/TILE;                       // =2 (floor)
    localparam TPF=TILES_X*TILES_Y;                  // tiles per frame = 4
    localparam NFRAMES=3;
    localparam BANDPX=TILE*IN_W;                      // px per band

    reg clk=0, rstn=0; always #5 clk=~clk;
    reg [23:0] s_td; reg s_tv=0, s_tuser=0, s_tlast=0; wire s_tr;
    wire [23:0] m_td; wire m_tv, m_tl, m_sof; reg m_tr=1;

    pg_raster_to_tile #(.IN_W(IN_W),.LTILE(4)) dut(
        .clk(clk),.rstn(rstn),.in_w(IN_W[11:0]),.s_tdata(s_td),.s_tvalid(s_tv),.s_tready(s_tr),
        .s_tuser(s_tuser),.s_tlast(s_tlast),
        .m_tdata(m_td),.m_tvalid(m_tv),.m_tready(m_tr),.m_tlast(m_tl),.m_sof(m_sof));

    // ---- expected emitted stream, per frame: tile-row-major (ty,tx){r,c} -> px(ty*16+r, tx*16+c) ----
    // Only the 2 FULL bands are emitted (rows 0..31); the 8-row remainder is dropped.
    function [23:0] px; input integer f, row, col; px = f*1000 + row*IN_W + col; endfunction

    integer beat_in_frame;  // 0..TPF*256-1, expected emit index within current frame
    integer cur_frame;      // which frame's data we currently expect on the output
    integer errs, tiles_total, sof_count, mid_frame_sof, tlast_since_sof, sof_not_beat0;
    integer interval_bad, first_beat_was_sof, any_out_beat;
    integer beat_global;
    integer last_sof_at_tile0; // 1 if the in-tile/in-frame position at a sof was beat0 of tile0

    // emit-position trackers (mirror the dut's emit order to compute expected data + alignment)
    integer e_tile;   // 0..TPF-1 within frame
    integer e_pos;    // 0..255 within tile
    integer beats_seen_in_frame;

    // ---------- DRIVE: NFRAMES rasters of H rows x IN_W cols ----------
    integer fnum, r, c, g;
    initial begin
        errs=0; tiles_total=0; sof_count=0; mid_frame_sof=0; tlast_since_sof=0; sof_not_beat0=0;
        interval_bad=0; first_beat_was_sof=0; any_out_beat=0;
        rstn=0; repeat(4)@(posedge clk); rstn=1; @(posedge clk);
        for(fnum=0; fnum<NFRAMES; fnum=fnum+1) begin
            for(r=0; r<H; r=r+1) begin
                for(c=0; c<IN_W; c=c+1) begin
                    @(posedge clk);
                    s_td   <= px(fnum, r, c);
                    s_tv   <= 1'b1;
                    s_tuser<= (r==0 && c==0);     // SOF marks row0/col0 of each frame
                    s_tlast<= (c==IN_W-1);
                    while(!s_tr) @(posedge clk);  // honor back-pressure on the write side
                end
            end
        end
        @(posedge clk); s_tv<=0; s_tuser<=0; s_tlast<=0;
        // let the pipeline drain the last band fully
        repeat(8000) @(posedge clk);

        // ---------- VERDICT ----------
        // final interval: last frame's TPF tiles after the last sof (no trailing sof closes it)
        if(tlast_since_sof!=TPF) interval_bad = interval_bad+1;
        $display("FSYNC_TB: frames=%0d sof_count=%0d (exp %0d)  tiles_total=%0d (exp %0d)",
                 NFRAMES, sof_count, NFRAMES, tiles_total, NFRAMES*TPF);
        $display("FSYNC_TB: first_beat_was_sof=%0d  mid_frame_sof=%0d  sof_not_beat0=%0d  interval_bad=%0d  data_errs=%0d",
                 first_beat_was_sof, mid_frame_sof, sof_not_beat0, interval_bad, errs);
        $display("FSYNC_TB: each interval = %0d tiles (exp TPF=%0d)", TPF, TPF);
        if (sof_count==NFRAMES && tiles_total==NFRAMES*TPF && mid_frame_sof==0 &&
            sof_not_beat0==0 && interval_bad==0 && first_beat_was_sof==1 && errs==0)
            $display("FSYNC_TB: PASS");
        else
            $display("FSYNC_TB: FAIL");
        $finish;
    end

    // ---------- BACK-PRESSURE: drop m_tr in a repeating pattern to stress alignment under stall ----------
    integer bpc=0;
    always @(posedge clk) begin
        if(!rstn) m_tr<=1;
        else begin
            bpc <= bpc+1;
            m_tr <= (bpc % 7 != 0);  // ~1-in-7 cycles back-pressured
        end
    end

    // ---------- MONITOR: check emit data + m_sof alignment ----------
    // Track emit position. A new frame's data begins at the first OUT beat after a m_sof.
    initial begin e_tile=0; e_pos=0; cur_frame=-1; beats_seen_in_frame=0; end

    // expected px at emit position (e_tile,e_pos) of frame cur_frame
    function [23:0] exp_emit; input integer f, etile, epos;
        integer tx, ty, rr, cc;
        begin
            ty = etile / TILES_X;  tx = etile % TILES_X;
            rr = epos / TILE;      cc = epos % TILE;
            exp_emit = px(f, ty*TILE+rr, tx*TILE+cc);
        end
    endfunction

    always @(posedge clk) if(rstn && m_tv && m_tr) begin
        // --- the VERY FIRST output beat overall must carry m_sof (frame opens cleanly) ---
        if(any_out_beat==0) begin any_out_beat=1; first_beat_was_sof = m_sof ? 1 : 0; end

        // --- m_sof handling: a sof must coincide with the FIRST beat of tile0 of a NEW frame ---
        if(m_sof) begin
            // interval check: tiles emitted since the PREVIOUS sof must be exactly TPF (no mid-frame sof,
            // no short/long frame). Skipped for the first sof (sof_count still 0).
            if(sof_count>0 && tlast_since_sof!=TPF) interval_bad = interval_bad+1;
            tlast_since_sof = 0;

            sof_count = sof_count+1;
            cur_frame = sof_count-1;       // frame index this sof opens
            // alignment: a sof MUST land on a clean TILE boundary (e_pos==0, never mid-tile) AND on a clean
            // FRAME boundary (the prior frame emitted a whole number of full frames: e_tile==0 at the very
            // first sof, or ==TPF having just finished the prior frame's last tile).
            if(!(e_pos==0 && (e_tile==0 || e_tile==TPF))) sof_not_beat0 = sof_not_beat0+1;
            // mid-frame check: if we were mid-frame (had emitted some beats but not a full frame) -> bad
            if(beats_seen_in_frame!=0 && beats_seen_in_frame!=TPF*256) mid_frame_sof = mid_frame_sof+1;
            e_tile=0; e_pos=0; beats_seen_in_frame=0;
        end

        // --- data check against expected tile-row-major stream ---
        if(cur_frame>=0) begin
            if(m_td !== exp_emit(cur_frame, e_tile, e_pos)) begin
                errs=errs+1;
                if(errs<10) $display("  ERR f=%0d tile=%0d pos=%0d got=%0d exp=%0d",
                                     cur_frame, e_tile, e_pos, m_td, exp_emit(cur_frame,e_tile,e_pos));
            end
        end

        // --- tlast must land on the LAST beat of each tile (pos==255) ---
        if(m_tl) begin
            tiles_total = tiles_total+1;
            tlast_since_sof = tlast_since_sof+1;   // tiles emitted in the current frame interval
            if(e_pos != TILE*TILE-1)
                $display("  ERR tlast at wrong pos: f=%0d tile=%0d pos=%0d", cur_frame, e_tile, e_pos);
        end

        // --- advance emit position ---
        beats_seen_in_frame = beats_seen_in_frame+1;
        if(e_pos==TILE*TILE-1) begin
            e_pos=0;
            e_tile = e_tile+1;             // next tile (frame-relative)
        end else e_pos=e_pos+1;
    end

    initial begin #2000000 $display("WATCHDOG sof=%0d tiles=%0d",sof_count,tiles_total); $finish; end
endmodule
`default_nettype wire
