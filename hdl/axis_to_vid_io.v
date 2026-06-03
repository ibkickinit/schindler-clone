// axis_to_vid_io.v — Schindler 2.0 Phase B adapter.
//
// Replaces Xilinx's v_axi4s_vid_out, which wouldn't lock in our pipeline
// configuration despite the AXIS data and VTC vtiming both being valid.
// This adapter outputs an AXIS pixel during VTC's active-video window and zero
// during blanking, passing VTC's sync signals through unchanged. Backpressure
// to AXIS via TREADY when VTC is in blanking; consume from AXIS when in active
// video. If AXIS is starved during an active pixel (TVALID=0), output 0 so sync
// stays valid — we lose one pixel but the monitor's lock survives.
//
// SOF-gated frame realign (option 1, 2026-06-02):
//   The stream carries TUSER=SOF on the frame's first pixel (VDMA MM2S asserts
//   it via fsync; the read-engine's pg_compose asserts it on pixel 0). At each
//   output frame we re-arm and emit black (draining any pre-SOF beat) until the
//   SOF beat is consumed, map that beat to the active slot it lands on, and then
//   free-run for the rest of the frame. This makes frame alignment INDEPENDENT of producer
//   latency (engine engage, geometry change, genlock slot change) and guarantees
//   we never latch a stale/partial beat as pixel 0. A mid-frame starve still
//   shifts the remainder of THAT frame, but every frame re-anchors to its own SOF
//   so a glitch can never desync subsequent frames. TLAST/EOL is carried through
//   but intentionally NOT required here (VDMA MM2S does not assert per-line TLAST).
//
// All signals run in a single PixelClk domain.

`default_nettype none
`timescale 1ns / 1ps

module axis_to_vid_io #(
    // Upper bound on beats flushed during blanking while waiting for the SOF beat
    // (the blanking-flush fix below). Sized a few× the measured residue (δ=6, the
    // shared color-stack pipeline depth) so a MISSING/late SOF can drain at most
    // MAX_DRAIN beats and then falls back to the old bounded 1-frame-black-flash
    // behaviour instead of eating the whole ~49.5k-cycle vblank and cascading.
    parameter integer MAX_DRAIN = 16
) (
    input  wire        clk,
    input  wire        enable,          // active-high; tie to dvi2rgb pLocked

    // AXIS input from VDMA MM2S
    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,    // ignored — VTC drives EOL (VDMA omits it)
    input  wire        s_axis_tuser,    // SOF — anchors each frame's pixel 0

    // VTC timing signals (individual outputs from v_tc)
    input  wire        vtg_active_video,
    input  wire        vtg_hsync,
    input  wire        vtg_vsync,
    input  wire        vtg_hblank,
    input  wire        vtg_vblank,

    // Pixel-parallel output to rgb2dvi
    output wire [23:0] vid_data,
    output wire        vid_active_video,
    output wire        vid_hsync,
    output wire        vid_vsync,

    // VDMA MM2S frame-sync: 1-cycle pulse on rising edge of vtg_vsync.
    // Wire to axi_vdma_0/mm2s_fsync so MM2S starts each frame transfer at
    // source's vsync — locks the output frame to source's frame, eliminating
    // the random vertical phase seam that you get when fsync comes from a
    // VTC running independent of source.
    output wire        mm2s_fsync_pulse,

    /* iter4g DIAG: count s_axis_tlast events per OUTPUT frame (between
     * vtg_vsync rising edges = VTC output frame boundary). Tells us how
     * many rows MM2S actually delivered per output frame. Latched snapshot
     * for firmware read via AXI GPIO 2. */
    output reg  [15:0] mm2s_tlast_snap,

    /* δ + blanking-flush diag (2026-06-03), snapshotted at vtg_vsync rising:
     *   [15:0]  = δ = active-video pixel slots elapsed BEFORE the SOF beat emits as
     *            pixel 0 (= the output column pixel 0 lands at = the per-line wrap
     *            offset). With the blanking-flush below working, δ → 0.
     *   [31:16] = beats flushed during blanking this frame (the new fix). Expected
     *            ≈ residue depth (~6), capped at MAX_DRAIN. A missing SOF shows up
     *            as this field pinned at MAX_DRAIN AND δ large (the bounded fall-
     *            back, not a cascade). */
    output reg  [31:0] predrain_snap
);

    // ---- SOF-gated frame start ----
    // started: have we locked onto this frame's SOF beat yet? Re-armed each frame
    // at the vtg_vsync rising edge (deep in vblank, well clear of the prior active
    // region). We consume during active video as before; the SOF tag only controls
    // what we EMIT. Until SOF is seen we emit black, and any pre-SOF beat at the
    // head is drained (consumed + discarded) rather than shown as pixel 0 — so a
    // stale/partial beat can never become the frame's pixel 0, and we never
    // deadlock waiting on a SOF stuck behind junk. Once the SOF beat is consumed,
    // it becomes pixel 0 and we free-run for the rest of the frame.
    reg  started;
    wire consume  = s_axis_tvalid && s_axis_tready;
    wire emit_pix = consume && (started || s_axis_tuser);   // emit from SOF onward

    // vtg_vsync rising-edge detector (re-arms the frame; also feeds fsync + diag).
    reg  vtg_vsync_q;
    always @(posedge clk) vtg_vsync_q <= vtg_vsync;
    wire vsync_rising = vtg_vsync && !vtg_vsync_q && enable;

    // ---- bounded pre-SOF blanking flush (2026-06-03 fix) ----
    // Root cause of the +6px per-line wrap: the shared color stack (saturation→
    // correct→matrix, downstream of the mux) holds the prior frame's last ~6 pixels
    // in its pipeline at the frame boundary; they emerge AHEAD of the new frame's
    // SOF-tagged pixel 0. With tready gated to active-video only, those residual
    // beats were drained by burning the first 6 ACTIVE pixels → pixel 0 landed at
    // column 6 → every line shifted, tail wrapping to the next line. (Measured:
    // DRAIN delta_px=6, 100% stale, 0 starve.)
    //
    // Fix: drain the residue during VBLANK instead. While not yet started, accept
    // non-SOF head beats during vblank (emitted as black, not shown) so that when
    // active video begins the SOF beat is at the head and becomes pixel 0 at column
    // 0. The drain STOPS the instant the SOF beat reaches the head (!s_axis_tuser,
    // combinational) and is BOUNDED to MAX_DRAIN beats/frame: a missing/late SOF
    // therefore drains at most MAX_DRAIN and then reverts to the old active-gated
    // behaviour (bounded 1-frame black flash) rather than eating the whole vblank
    // and desyncing into following frames. vblank-scoped (not !active_video) so the
    // drain window is exactly the frame boundary.
    reg [15:0] bflush_cnt;   // beats flushed in blanking this frame (0..MAX_DRAIN)
    wire drain_presof = enable && !started && vtg_vblank && s_axis_tvalid
                        && !s_axis_tuser && (bflush_cnt < MAX_DRAIN[15:0]);
    // Consume during active video, plus the bounded blanking flush.
    assign s_axis_tready = enable && (vtg_active_video || drain_presof);

    // Register all outputs so data and sync transition on the same clock
    // edge. Avoids combinational glitches on sync edges that would otherwise
    // upset the monitor.
    reg [23:0] vid_data_r;
    reg        vid_active_r;
    reg        vid_hsync_r;
    reg        vid_vsync_r;

    always @(posedge clk) begin
        if (!enable) begin
            vid_data_r   <= 24'h000000;
            vid_active_r <= 1'b0;
            vid_hsync_r  <= 1'b0;
            vid_vsync_r  <= 1'b0;
        end else begin
            // Emit the consumed pixel only once SOF has locked (emit_pix). Before
            // SOF, during a starve, or in blanking → black, so sync stays valid.
            if (vtg_active_video && emit_pix) begin
                vid_data_r <= s_axis_tdata;
            end else begin
                vid_data_r <= 24'h000000;
            end
            vid_active_r <= vtg_active_video;
            vid_hsync_r  <= vtg_hsync;
            vid_vsync_r  <= vtg_vsync;
        end
    end

    // started: latched once we consume the SOF beat; re-armed each frame at the
    // vtg_vsync rising edge. emit_pix asserts on the SOF beat itself (started||tuser),
    // so the SOF beat is emitted as pixel 0 the same cycle it sets started.
    always @(posedge clk) begin
        if (!enable)                              started <= 1'b0;
        else if (vsync_rising)                    started <= 1'b0;
        else if (consume && s_axis_tuser)         started <= 1'b1;
    end

    assign vid_data         = vid_data_r;
    assign vid_active_video = vid_active_r;
    assign vid_hsync        = vid_hsync_r;
    assign vid_vsync        = vid_vsync_r;

    // Rising-edge pulse generator on vtg_vsync for VDMA MM2S fsync.
    assign mm2s_fsync_pulse = vsync_rising;

    /* iter4g DIAG: count s_axis_tlast events per output frame.
     * mm2s_tlast_count increments on each TLAST handshake; snapshotted
     * into mm2s_tlast_snap at vtg_vsync rising edge (= start of new
     * output frame), then count resets. Reads after vsync return the
     * just-completed frame's row count.
     *
     * Expected: 720 (one TLAST per active row of the 720p output).
     * If <720, MM2S starved during active video.
     * If >720, MM2S delivered extra rows (which axis_to_vid_io would
     * still gate via vtg_active_video, so extras only "land" if VTC
     * drives active for >720 lines — important corroborating signal). */
    reg [15:0] mm2s_tlast_count;
    wire tlast_handshake = s_axis_tvalid && s_axis_tready && s_axis_tlast;
    always @(posedge clk) begin
        if (!enable) begin
            mm2s_tlast_count <= 16'd0;
            mm2s_tlast_snap  <= 16'd0;
        end else if (vsync_rising) begin
            mm2s_tlast_snap  <= mm2s_tlast_count;
            mm2s_tlast_count <= tlast_handshake ? 16'd1 : 16'd0;
        end else if (tlast_handshake) begin
            mm2s_tlast_count <= mm2s_tlast_count + 16'd1;
        end
    end

    /* ---- δ + blanking-flush measurement ----
     * presof: an active-video cycle that elapses before pixel 0 emits. The SOF
     * cycle itself (consume && s_axis_tuser) emits pixel 0, so it is EXCLUDED —
     * presof_cnt is the column index at which pixel 0 lands (= δ). With the
     * blanking flush working, the SOF beat is already at the head when active
     * begins, so δ → 0. bflush_cnt (declared above, used by drain_presof's cap)
     * counts the beats flushed in blanking — expected ≈ residue depth, ≤ MAX_DRAIN. */
    wire presof = vtg_active_video && enable && !started
                  && !(consume && s_axis_tuser);
    reg [15:0] presof_cnt;
    always @(posedge clk) begin
        if (!enable) begin
            presof_cnt <= 16'd0; bflush_cnt <= 16'd0; predrain_snap <= 32'd0;
        end else if (vsync_rising) begin
            predrain_snap <= {bflush_cnt, presof_cnt};  // {[31:16]=bflush, [15:0]=δ}
            presof_cnt <= 16'd0; bflush_cnt <= 16'd0;
        end else begin
            if (presof)       presof_cnt <= presof_cnt + 16'd1;
            if (drain_presof) bflush_cnt <= bflush_cnt + 16'd1;  // bounded by the cap
        end
    end

endmodule

`default_nettype wire
