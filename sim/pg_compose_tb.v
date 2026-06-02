// pg_compose_tb.v — end-to-end self-checking TB for the read-engine core.
//
// Small dims (64x48) so the full-frame golden check is exhaustive AND fast,
// while still exercising downscale + position + matte + prefetch + ping-pong +
// output FIFO. Models VTC timing (active/hblank/vblank → m_tready), a
// behavioral DDR + DataMover, and a pg_genlock-style fixed frame base.
//
// Checks per frame:
//   (1) each consumed AXIS pixel == golden(ox,oy)  [in-window ? pix(src) : matte]
//   (2) exactly OUT_W*OUT_H pixels delivered
//   (3) zero starvation: m_tvalid never low during active video
//
// Pass criterion: "Total errors = 0".  Run: make sim-pg.

`default_nettype none
`timescale 1ns / 1ps

module pg_compose_tb;
    localparam integer OUT_W = 64, OUT_H = 48, IN_W = 64, IN_H = 48;
    localparam integer STRIDE = IN_W*3;             // bytes/line
    localparam [31:0]  FRAME_BASE = 32'h1000_0000;
    localparam integer HBLANK = 150, VBLANK = 1200;  // cycles (hblank >= line-fetch time)

    reg clk = 1'b0; always #5 clk = ~clk;
    reg rstn;

    reg         vtg_vsync, m_tready;
    reg  [11:0] out_w_win, out_h_win, pos_x, pos_y;
    reg  [11:0] h_step_int, h_step_frac, v_step_int, v_step_frac;
    reg  [23:0] matte_rgb;

    wire [23:0] m_tdata; wire m_tvalid;
    wire        fetch_req; wire [31:0] fetch_addr; wire [11:0] fetch_len;
    reg         fetch_pvalid, fetch_last; reg [23:0] fetch_pdata;

    pg_compose #(.OUT_W(OUT_W), .OUT_H(OUT_H), .IN_W(IN_W), .IN_H(IN_H),
                 .STRIDE(STRIDE), .FIFO_DEPTH(16)) dut (
        .clk(clk), .rstn(rstn), .vtg_vsync(vtg_vsync), .frame_base_addr(FRAME_BASE),
        .out_w_win(out_w_win), .out_h_win(out_h_win), .pos_x(pos_x), .pos_y(pos_y),
        .h_step_int(h_step_int), .h_step_frac(h_step_frac),
        .v_step_int(v_step_int), .v_step_frac(v_step_frac), .matte_rgb(matte_rgb),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr), .fetch_len(fetch_len),
        .fetch_pvalid(fetch_pvalid), .fetch_pdata(fetch_pdata), .fetch_last(fetch_last)
    );

    function [23:0] pix; input integer r, c; pix = (r*7919 + c*31 + 12345) & 24'hFFFFFF; endfunction

    integer errors;
    integer c_ow, c_oh, c_px, c_py; reg [23:0] c_matte;
    function integer g_inwin; input integer ox, oy;
        g_inwin = ((ox>=c_px)&&(ox<c_px+c_ow)&&(oy>=c_py)&&(oy<c_py+c_oh)) ? 1 : 0; endfunction
    function [23:0] golden; input integer ox, oy; integer sc, sr;
        begin
            if (g_inwin(ox,oy)) begin
                sc = ((ox-c_px)*IN_W)/c_ow; sr = ((oy-c_py)*IN_H)/c_oh;
                golden = pix(sr, sc);
            end else golden = c_matte;
        end
    endfunction

    // ---- behavioral DataMover (with bus gaps) ----
    integer dm_row, dm_i, dm_len; reg dm_busy, dm_gap;
    always @(posedge clk) begin
        if (!rstn) begin dm_busy<=0; dm_gap<=0; fetch_pvalid<=0; fetch_last<=0; end
        else begin
            fetch_pvalid<=0; fetch_last<=0;
            if (fetch_req && !dm_busy) begin
                dm_row=(fetch_addr-FRAME_BASE)/STRIDE; dm_len=fetch_len; dm_i=0; dm_busy<=1; dm_gap<=0;
            end else if (dm_busy) begin
                if (dm_gap) dm_gap<=0;
                else begin
                    fetch_pvalid<=1; fetch_pdata<=pix(dm_row,dm_i); fetch_last<=(dm_i==dm_len-1);
                    if ((dm_i%17)==16 && dm_i!=dm_len-1) dm_gap<=1;
                    dm_i=dm_i+1; if (dm_i==dm_len) dm_busy<=0;
                end
            end
        end
    end

    // ---- output checker (output-side walk, advances on each consumed pixel) ----
    integer vox, voy, seen, starv; reg checking; reg in_active;
    always @(posedge clk) begin
        if (checking) begin
            if (in_active && !m_tvalid) starv = starv + 1;     // starvation during active video
            if (m_tvalid && m_tready) begin
                if (m_tdata !== golden(vox,voy)) begin
                    if (errors<25) $display("  ERR @ (%0d,%0d): dut=%h gold=%h",
                                            vox, voy, m_tdata, golden(vox,voy));
                    errors = errors + 1;
                end
                seen = seen + 1;
                if (vox==OUT_W-1) begin vox=0; voy=voy+1; end else vox=vox+1;
            end
        end
    end

    // ---- VTC + frame driver ----
    task run_frame; integer line;
        begin
            // SOF
            vtg_vsync <= 1; repeat(3) @(posedge clk); vtg_vsync <= 0;
            // reset checker walk for this frame
            vox=0; voy=0; seen=0; starv=0; checking=1; in_active=0;
            // vblank (prefetch of rows 0,1 happens here)
            repeat(VBLANK) @(posedge clk);
            // active lines
            for (line=0; line<OUT_H; line=line+1) begin
                in_active<=1; m_tready<=1;
                repeat(OUT_W) @(posedge clk);
                in_active<=0; m_tready<=0;
                repeat(HBLANK) @(posedge clk);
            end
            // tail drain
            repeat(50) @(posedge clk);
            checking=0;
            if (seen != OUT_W*OUT_H) begin
                $display("  ERR frame delivered %0d px, expected %0d", seen, OUT_W*OUT_H);
                errors = errors + 1;
            end
            if (starv != 0) begin
                $display("  ERR starvation: %0d active cycles with no valid pixel", starv);
                errors = errors + 1;
            end
        end
    endtask

    task set_geom; input [11:0] ow, oh, ppx, ppy;
        begin
            c_ow=ow; c_oh=oh; c_px=ppx; c_py=ppy; c_matte=24'h101010;
            out_w_win=ow; out_h_win=oh; pos_x=ppx; pos_y=ppy; matte_rgb=24'h101010;
            h_step_int=IN_W/ow; h_step_frac=IN_W%ow;
            v_step_int=IN_H/oh; v_step_frac=IN_H%oh;
        end
    endtask

    task run_case; input [11:0] ow, oh, ppx, ppy; input integer frames; integer f; integer e0;
        begin
            e0 = errors; set_geom(ow,oh,ppx,ppy);
            for (f=0; f<frames; f=f+1) run_frame;
            $display("CASE %0dx%0d @ (%0d,%0d) x%0d frames : errors=%0d",
                     ow, oh, ppx, ppy, frames, errors - e0);
        end
    endtask

    initial begin
        errors=0; rstn=0; vtg_vsync=0; m_tready=0; checking=0; in_active=0;
        out_w_win=OUT_W; out_h_win=OUT_H; pos_x=0; pos_y=0;
        h_step_int=1; h_step_frac=0; v_step_int=1; v_step_frac=0; matte_rgb=0;
        repeat(5) @(posedge clk); rstn=1; repeat(3) @(posedge clk);

        run_case(64, 48,  0,  0, 2);   // full, no scale
        run_case(32, 24, 16, 12, 2);   // 0.5x centered
        run_case(40, 30, 12,  9, 2);   // ugly ratio (64/40, 48/30)
        run_case(24, 18, 20, 15, 2);   // strong shrink off-center
        run_case(64, 48,  0,  0, 1);   // back to full (geometry change)

        $display("=================================");
        $display("Total errors = %0d", errors);
        $display("=================================");
        $finish;
    end

    initial begin
        #200_000_000; $display("TIMEOUT — Total errors = %0d", errors); $finish;
    end
endmodule

`default_nettype wire
