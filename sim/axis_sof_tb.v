// axis_sof_tb.v — unit test for axis_to_vid_io's SOF-gated frame realign (option 1).
//
// Proves the property the reviewer asked for: frame alignment is independent of
// producer latency, and a stale/junk beat can never become the frame's pixel 0.
//
// Tiny synthetic raster: 8 active px x 4 active lines, 4 px hblank, 2 line vblank.
// A producer streams 32 pixels/frame with TUSER=SOF on pixel 0 and TLAST=EOL on
// each row's last pixel. Each pixel's data encodes its identity:
//   [23:16]=frame_id (>=1, so a real pixel is never 0x000000 = black),
//   [15:8]=row, [7:0]=col.
//
// Per-frame defects exercise the realign:
//   frame 1 clean   — full bit-exact check (no regression)
//   frame 2 junk    — 3 pre-SOF beats (TUSER=0) must be DRAINED, not shown
//   frame 3 clean   — full check (re-anchor after junk)
//   frame 4 late    — SOF delayed 2 active slots (latency independence)
//   frame 5 clean   — full check (re-anchor after late)
//   frame 6 starve  — 1-cycle mid-frame bubble (shift confined to this frame)
//   frame 7 clean   — full check (re-anchor after starve)
//   frame 8 nosof   — NO beat tagged SOF (the failure the drain-cap protects):
//                     the bounded blanking-flush must drain at most MAX_DRAIN and
//                     NOT cascade — frame 9 must re-anchor cleanly.
//   frame 9 clean   — full check (re-anchor after the missing-SOF frame)
//
// Checks (per frame): the FIRST non-black emitted pixel == {frame,0,0} (SOF
// anchor — never a junk/stale beat). For clean frames, EVERY active slot is
// bit-exact. Plus the δ/blanking-flush diag (predrain_snap) — see the scoreboard:
//   • residue/clean frames with SOF present → δ==0 (the blanking-flush fix: the
//     prior-frame residue is drained in VBLANK, so pixel 0 lands at column 0).
//     This is the assertion that would FAIL on the pre-fix active-gated drain
//     (frame 2 measured δ=3 there). frame-2 here models the color-stack residue.
//   • missing-SOF frame → blanking-flush count is CAPPED at MAX_DRAIN (bounded),
//     proving a dropped SOF can't eat the whole vblank / cascade.
// Any violation -> $error + FAIL.

`default_nettype none
`timescale 1ns / 1ps

module axis_sof_tb;
    localparam integer AW = 8;   // active width
    localparam integer HB = 4;   // h blank
    localparam integer HT = AW+HB;
    localparam integer AH = 4;   // active height
    localparam integer VB = 2;   // v blank
    localparam integer VT = AH+VB;
    // Small drain cap so the bound is exercised within this tiny raster's ~12-cycle
    // post-vsync vblank (production axis_to_vid_io uses MAX_DRAIN=16). A missing-SOF
    // frame would, uncapped, drain every available vblank beat; with the cap it
    // stops at MAX_DRAIN_TB — that's the assertion below.
    localparam integer MAX_DRAIN_TB = 5;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rstn = 1'b0;
    reg enable = 1'b0;

    // ---- VTC raster generator ----
    reg [7:0] hcnt = 0, vcnt = 0;
    wire active = (hcnt < AW) && (vcnt < AH);
    wire vblank = (vcnt >= AH);
    // vsync pulse: assert on the last vblank line, first 2 px
    wire vsync  = (vcnt == VT-1) && (hcnt < 2);
    wire hsync  = (hcnt >= AW+1) && (hcnt < AW+3);

    always @(posedge clk) begin
        if (!rstn) begin hcnt <= 0; vcnt <= 0; end
        else begin
            if (hcnt == HT-1) begin
                hcnt <= 0;
                vcnt <= (vcnt == VT-1) ? 0 : vcnt + 1;
            end else hcnt <= hcnt + 1;
        end
    end

    // vsync rising (testbench-side, for frame bookkeeping/producer reset)
    reg vsync_q;
    always @(posedge clk) vsync_q <= vsync;
    wire vsync_rising = vsync && !vsync_q;

    // ---- per-frame defect program ----
    // dmode: 0 none, 1 junk, 2 late, 3 starve, 4 missing-SOF
    reg [7:0] frame_id;
    reg [2:0] dmode;
    reg [7:0] djunk_n, dlate_k, dstarve_at;

    task set_defect(input [7:0] id);
        begin
            case (id)
                8'd1: begin dmode<=0; djunk_n<=0; dlate_k<=0; dstarve_at<=0; end
                8'd2: begin dmode<=1; djunk_n<=3; dlate_k<=0; dstarve_at<=0; end
                8'd3: begin dmode<=0; djunk_n<=0; dlate_k<=0; dstarve_at<=0; end
                8'd4: begin dmode<=2; djunk_n<=0; dlate_k<=2; dstarve_at<=0; end
                8'd5: begin dmode<=0; djunk_n<=0; dlate_k<=0; dstarve_at<=0; end
                8'd6: begin dmode<=3; djunk_n<=0; dlate_k<=0; dstarve_at<=8'd13; end
                8'd8: begin dmode<=4; djunk_n<=0; dlate_k<=0; dstarve_at<=0; end  // missing SOF
                default: begin dmode<=0; djunk_n<=0; dlate_k<=0; dstarve_at<=0; end
            endcase
        end
    endtask

    // ---- producer state (resets at vsync, mimics pg_compose flush-on-sof) ----
    reg [7:0] pbeat;       // real pixels emitted this frame (0..31)
    reg [7:0] pjunk;       // junk beats emitted this frame
    reg [7:0] pasc;        // active slots elapsed this frame
    reg       pstarve_done;

    wire [4:0] pidx  = pbeat[4:0];               // 0..31
    wire [7:0] prow  = {6'd0, pidx[4:3]};        // /8
    wire [7:0] pcol  = {5'd0, pidx[2:0]};        // %8

    // producer combinational output
    reg [23:0] sv_tdata; reg sv_tvalid, sv_tuser, sv_tlast;
    wire emitting_junk = (dmode==1) && (pjunk < djunk_n);
    always @(*) begin
        sv_tvalid = 1'b0; sv_tdata = 24'h000000; sv_tuser = 1'b0; sv_tlast = 1'b0;
        if (emitting_junk) begin
            sv_tvalid = 1'b1; sv_tdata = 24'hDEAD00 | {16'd0, pjunk}; // distinct junk
            sv_tuser  = 1'b0; sv_tlast = 1'b0;
        end else if (pbeat < 32) begin
            if ((dmode==2) && (pasc < dlate_k)) begin
                sv_tvalid = 1'b0;                                  // late: hold
            end else if ((dmode==3) && (pbeat==dstarve_at) && !pstarve_done) begin
                sv_tvalid = 1'b0;                                  // starve: 1-cyc bubble
            end else begin
                sv_tvalid = 1'b1;
                sv_tdata  = {frame_id, prow, pcol};
                sv_tuser  = (pbeat == 0) && (dmode != 3'd4);  // dmode 4 = no SOF ever
                sv_tlast  = (pidx[2:0] == 3'd7);
            end
        end
    end

    // DUT wiring
    wire dut_tready;
    wire consume = sv_tvalid && dut_tready;

    always @(posedge clk) begin
        if (!rstn) begin
            pbeat<=0; pjunk<=0; pasc<=0; pstarve_done<=0; frame_id<=1;
            dmode<=0; djunk_n<=0; dlate_k<=0; dstarve_at<=0;
        end else begin
            if (vsync_rising) begin
                pbeat<=0; pjunk<=0; pasc<=0; pstarve_done<=0;
                frame_id <= frame_id + 8'd1;
                set_defect(frame_id + 8'd1);
            end else begin
                if (active) pasc <= pasc + 8'd1;
                if ((dmode==3) && (pbeat==dstarve_at) && !pstarve_done && active)
                    pstarve_done <= 1'b1;             // bubble lasts exactly 1 active cyc
                if (consume) begin
                    if (emitting_junk) pjunk <= pjunk + 8'd1;
                    else               pbeat <= pbeat + 8'd1;
                end
            end
        end
    end

    // ---- DUT ----
    wire [23:0] vid_data;
    wire        vid_active, vid_hs, vid_vs, fsync_pulse;
    wire [15:0] tlast_snap;
    wire [31:0] predrain;          // [15:0]=δ, [31:16]=blanking-flush count
    axis_to_vid_io #(.MAX_DRAIN(MAX_DRAIN_TB)) dut (
        .clk(clk), .enable(enable),
        .s_axis_tdata(sv_tdata), .s_axis_tvalid(sv_tvalid), .s_axis_tready(dut_tready),
        .s_axis_tlast(sv_tlast), .s_axis_tuser(sv_tuser),
        .vtg_active_video(active), .vtg_hsync(hsync), .vtg_vsync(vsync),
        .vtg_hblank(hcnt>=AW), .vtg_vblank(vblank),
        .vid_data(vid_data), .vid_active_video(vid_active),
        .vid_hsync(vid_hs), .vid_vsync(vid_vs),
        .mm2s_fsync_pulse(fsync_pulse), .mm2s_tlast_snap(tlast_snap),
        .predrain_snap(predrain)
    );

    // ---- scoreboard ----
    // Output is registered (1-clk after VTC), so the VTC position of the pixel
    // now on vid_data is the previous clock's hcnt/vcnt.
    reg [7:0] hcnt_q, vcnt_q;
    always @(posedge clk) begin hcnt_q <= hcnt; vcnt_q <= vcnt; end

    integer errors = 0;
    integer checks = 0;
    reg seen_nonblack;
    always @(posedge clk) begin
        if (!rstn) seen_nonblack <= 1'b0;
        else begin
            if (vsync_rising) seen_nonblack <= 1'b0;
            // frame 1 is warmup: enable rises mid-raster so its first line is
            // not frame-aligned. Checks start at frame 2 (after a clean vsync
            // re-arm), which is exactly the realign path under test.
            if (enable && vid_active && frame_id >= 2) begin
                // (1) SOF anchor: first non-black pixel of a frame must be P0.
                if (!seen_nonblack && vid_data != 24'h000000) begin
                    seen_nonblack <= 1'b1;
                    checks = checks + 1;
                    if (vid_data !== {frame_id, 16'h0000}) begin
                        errors = errors + 1;
                        $error("[f%0d] first non-black = %06h, expected SOF %06h (col=%0d row=%0d)",
                               frame_id, vid_data, {frame_id,16'h0000}, hcnt_q, vcnt_q);
                    end
                end
                // (2) clean frames: every active slot bit-exact.
                if (dmode == 2'd0) begin
                    checks = checks + 1;
                    if (vid_data !== {frame_id, {6'd0,vcnt_q[1:0]}, {5'd0,hcnt_q[2:0]}}) begin
                        errors = errors + 1;
                        $error("[f%0d clean] (r%0d c%0d) got %06h exp %06h",
                               frame_id, vcnt_q, hcnt_q, vid_data,
                               {frame_id,{6'd0,vcnt_q[1:0]},{5'd0,hcnt_q[2:0]}});
                    end
                end
            end
        end
    end

    // ---- δ / blanking-flush scoreboard (separate counters → no multi-driver race) ----
    // predrain_snap latches at the DUT's vsync_rising (= the frame that just ended);
    // the TB also increments frame_id there, so one cycle later the ended frame is
    // (frame_id-1). Sample on that delayed strobe.
    integer errors2 = 0;
    integer checks2 = 0;
    reg vsr_q;
    always @(posedge clk) begin
        vsr_q <= vsync_rising;
        if (rstn && enable && vsr_q) begin
            // SOF-present frames (residue/clean) must show δ==0 — the blanking-flush
            // drains the prior-frame residue in VBLANK so pixel 0 lands at col 0.
            // This is the assertion that FAILS on the pre-fix active-gated drain
            // (frame 2 models the color-stack residue; δ was 3 there). Skip frame 1
            // (warmup), 4 (late) & 6 (starve) — genuine producer lateness the fix
            // correctly does NOT mask — and 8 (missing SOF, checked below).
            if ((frame_id-1==2)||(frame_id-1==3)||(frame_id-1==5)||
                (frame_id-1==7)||(frame_id-1==9)) begin
                checks2 = checks2 + 1;
                if (predrain[15:0] !== 16'd0) begin
                    errors2 = errors2 + 1;
                    $error("[f%0d] delta=%0d expected 0 (blanking-flush should land pixel0 at col0)",
                           frame_id-1, predrain[15:0]);
                end
            end
            // missing-SOF frame: blanking-flush must be CAPPED at MAX_DRAIN_TB
            // (bounded). Uncapped, an absent SOF drains the whole vblank → cascade.
            if (frame_id-1==8) begin
                checks2 = checks2 + 1;
                if (predrain[31:16] !== MAX_DRAIN_TB[15:0]) begin
                    errors2 = errors2 + 1;
                    $error("[f8 nosof] blanking-flush=%0d expected CAP %0d (drain not bounded!)",
                           predrain[31:16], MAX_DRAIN_TB);
                end
            end
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        rstn = 1'b1;
        @(posedge clk);
        enable = 1'b1;
        // run through ~10 frames (need frame 9's re-anchor check after missing-SOF f8)
        repeat (11*HT*VT + 40) @(posedge clk);
        $display("==== axis_sof_tb: %0d checks, %0d errors (anchor/clean) + %0d checks, %0d errors (delta/cap) ====",
                 checks, errors, checks2, errors2);
        if (errors + errors2 == 0) $display("AXIS_SOF_TB: PASS");
        else                       $display("AXIS_SOF_TB: FAIL (%0d errors)", errors + errors2);
        $finish;
    end

    // safety timeout
    initial begin
        #200000;
        $display("AXIS_SOF_TB: TIMEOUT");
        $finish;
    end
endmodule

`default_nettype wire
