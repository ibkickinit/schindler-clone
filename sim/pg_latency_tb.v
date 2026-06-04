// pg_latency_tb.v — STEP-1 GATE (reviewer-mandated): reproduce the output-FIFO
// underrun in simulation BEFORE any RTL change, so the packed-beat fix can be
// proven to remove it.
//
// Root cause (ILA build #14, confirmed two review rounds): the line fill is
// pixel-limited at 1 px/clk through pg_unpack (~IN_W cycles per master line),
// while one output row's budget is OUT_W + HBLANK cycles, and fetches are
// serialized. When per-line-fill (IN_W) > per-row-budget (OUT_W+HBLANK) the
// prefetch loses ground every row; the NBUF ring only delays the catch-up, then
// the consumer stalls mid-row waiting for an in-flight fetch and the output FIFO
// underruns (m_tvalid=0 while m_tready=1 during active video).
//
// The stock pg_read_engine_top_tb uses IN_W=64, OUT_W=64, HBLANK=150 → fill(64)
// « budget(214) → big surplus → never underruns (that's why every prior sim was
// clean while hardware stalled). Here we deliberately set IN_W >> OUT_W+HBLANK
// to recreate the real 1920-vs-1650 deficit at small scale.
//
// EXPECTED ON CURRENT RTL: starv > 0 / seen < OUT_W*OUT_H  → "UNDERRUN REPRODUCED".
// AFTER packed-beat fill: starv == 0, seen == OUT_W*OUT_H, golden-clean.
//
// Run: see Makefile sim-pg-latency (or xvlog/xelab/xsim by hand).

`default_nettype none
`timescale 1ns / 1ps

module pg_latency_tb;
    // Deficit geometry: per-line fill = IN_W (=256) cycles >> per-row budget
    // = OUT_W+HBLANK (=64+8=72). 4x downscale H, 1:1 V (the deficit is the
    // per-line FILL time, independent of the downscale ratio).
    // Realistic ratio mirroring HW (1920 fill / 720 packed-beat / 1650 budget):
    //   current 1px/clk fill = IN_W = 256 cyc/line  > row budget (OUT_W+HBLANK=168) → UNDERRUN
    //   packed-beat fill = ceil(IN_W*3/8) = 96 cyc/line       < 168               → FIXED
    localparam integer OUT_W=128, OUT_H=24, IN_W=256, IN_H=24;
    localparam integer STRIDE = IN_W*3;                     // 768 bytes/line
    localparam [31:0]  BASE = 32'h1000_0000;
    localparam integer SLOT_STRIDE = STRIDE*IN_H + STRIDE;
    localparam integer NUMF=5, RDLY=2;
    localparam integer HBLANK=40, VBLANK=400;

    reg clk=1'b0; always #5 clk=~clk;
    reg rstn;

    reg         out_vsync, m_tready;
    reg  [5:0]  frame_ptr;
    reg  [11:0] out_w_win,out_h_win,pos_x,pos_y,hsi,hsf,vsi,vsf;
    reg  [23:0] matte;

    wire [23:0] m_tdata; wire m_tvalid;
    wire [71:0] cmd_tdata; wire cmd_tvalid; reg cmd_tready;
    reg  [63:0] dm_tdata; reg dm_tvalid, dm_tlast; wire dm_tready;
    wire [2:0]  rslot, wslot;

    pg_read_engine_top #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),
        .STRIDE(STRIDE),.FRAME_BUF_BASE(BASE),.NUM_FRAMES(NUMF),
        .SLOT_STRIDE(SLOT_STRIDE),.READ_DELAY(RDLY)) dut (
        .clk(clk),.rstn(rstn),.frame_ptr(frame_ptr),.out_vsync(out_vsync),
        .out_w_win(out_w_win),.out_h_win(out_h_win),.pos_x(pos_x),.pos_y(pos_y),
        .h_step_int(hsi),.h_step_frac(hsf),.v_step_int(vsi),.v_step_frac(vsf),.matte_rgb(matte),.blend_mode(1'b0),
        .m_axis_tdata(m_tdata),.m_axis_tvalid(m_tvalid),.m_axis_tready(m_tready),
        .m_axis_cmd_tdata(cmd_tdata),.m_axis_cmd_tvalid(cmd_tvalid),.m_axis_cmd_tready(cmd_tready),
        .s_axis_dm_tdata(dm_tdata),.s_axis_dm_tvalid(dm_tvalid),.s_axis_dm_tready(dm_tready),
        .s_axis_dm_tlast(dm_tlast),
        .dbg_read_slot(rslot),.dbg_write_slot(wslot));

    function [23:0] gpix; input integer r,c; gpix=(r*7919 + c*31 + 12345)&24'hFFFFFF; endfunction
    function [7:0] lbyte; input integer r,off; integer p,ch; reg [23:0] pv; begin
        p=off/3; ch=off%3; pv=gpix(r,p);
        lbyte = (ch==0)?pv[7:0] : (ch==1)?pv[15:8] : pv[23:16];
    end endfunction

    integer errors;
    integer c_ow,c_oh,c_px,c_py; reg [23:0] c_matte;
    function integer ginwin; input integer ox,oy;
        ginwin=((ox>=c_px)&&(ox<c_px+c_ow)&&(oy>=c_py)&&(oy<c_py+c_oh))?1:0; endfunction
    function [23:0] golden; input integer ox,oy; integer sc,sr; begin
        if (ginwin(ox,oy)) begin sc=((ox-c_px)*IN_W)/c_ow; sr=((oy-c_py)*IN_H)/c_oh; golden=gpix(sr,sc); end
        else golden=c_matte; end
    endfunction

    // ---- behavioral AXI DataMover: 1 beat/clk gated by dm_tready (= unpack) ----
    // (unpack-limited fill, matching the confirmed real bottleneck; no extra DDR
    //  latency added — reviewer found DDR is not the limiter, up_pvalid=87%.)
    localparam DM_IDLE=0, DM_STREAM=1;
    integer dm_state, dm_row, dm_byte, dm_btt, bb;
    always @(posedge clk) begin
        if (!rstn) begin dm_state<=DM_IDLE; dm_tvalid<=0; dm_tlast<=0; cmd_tready<=1; end
        else case (dm_state)
            DM_IDLE: begin
                cmd_tready<=1'b1; dm_tvalid<=1'b0; dm_tlast<=1'b0;
                if (cmd_tvalid && cmd_tready) begin
                    dm_row=((cmd_tdata[63:32]-BASE)%SLOT_STRIDE)/STRIDE;
                    dm_btt=cmd_tdata[22:0]; dm_byte=0; cmd_tready<=1'b0; dm_state<=DM_STREAM;
                end
            end
            DM_STREAM: begin
                if (dm_tvalid && dm_tready) begin
                    dm_byte=dm_byte+8;
                    if (dm_byte>=dm_btt) begin dm_tvalid<=0; dm_tlast<=0; dm_state<=DM_IDLE; cmd_tready<=1; end
                end
                if (dm_state==DM_STREAM && (!dm_tvalid || dm_tready)) begin
                    for (bb=0; bb<8; bb=bb+1)
                        dm_tdata[bb*8 +: 8] <= (dm_byte+bb<dm_btt) ? lbyte(dm_row,dm_byte+bb) : 8'd0;
                    dm_tvalid<=1'b1; dm_tlast<=(dm_byte+8>=dm_btt);
                end
            end
        endcase
    end

    // ---- output checker: count starvation (the underrun) + golden + delivery ----
    integer vox,voy,seen,starv; reg checking,in_active;
    always @(posedge clk) begin
        if (checking) begin
            if (in_active && !m_tvalid) starv=starv+1;        // m_tready high (active) & m_tvalid low = UNDERRUN
            if (m_tvalid && m_tready) begin
                if (m_tdata!==golden(vox,voy)) begin
                    if (errors<10) $display("  ERR @ (%0d,%0d): dut=%h gold=%h",vox,voy,m_tdata,golden(vox,voy));
                    errors=errors+1;
                end
                seen=seen+1;
                if (vox==OUT_W-1) begin vox=0; voy=voy+1; end else vox=vox+1;
            end
        end
    end

    integer f;
    task run_frame; integer line; begin
        frame_ptr<=(frame_ptr+1)%5; repeat(8)@(posedge clk);
        out_vsync<=1; repeat(3)@(posedge clk); out_vsync<=0;
        vox=0; voy=0; seen=0; starv=0; checking=1; in_active=0;
        repeat(VBLANK)@(posedge clk);
        for (line=0; line<OUT_H; line=line+1) begin
            in_active<=1; m_tready<=1; repeat(OUT_W)@(posedge clk);
            in_active<=0; m_tready<=0; repeat(HBLANK)@(posedge clk);
        end
        repeat(60)@(posedge clk); checking=0;
        $display("  frame: seen=%0d/%0d  starvation(underrun cyc)=%0d", seen, OUT_W*OUT_H, starv);
    end endtask

    initial begin
        errors=0; rstn=0; frame_ptr=0; out_vsync=0; m_tready=0; checking=0; in_active=0;
        c_ow=OUT_W;c_oh=OUT_H;c_px=0;c_py=0;c_matte=24'h101010;
        out_w_win=OUT_W;out_h_win=OUT_H;pos_x=0;pos_y=0;matte=24'h101010;
        hsi=IN_W/OUT_W;hsf=IN_W%OUT_W;vsi=IN_H/OUT_H;vsf=IN_H%OUT_H;
        repeat(6)@(posedge clk); rstn=1; repeat(20)@(posedge clk);
        for (f=0; f<3; f=f+1) run_frame;
        $display("=================================");
        if (starv>0 || seen!=OUT_W*OUT_H)
            $display("UNDERRUN REPRODUCED (starv=%0d seen=%0d/%0d) — STEP-1 gate OK on current RTL",
                     starv, seen, OUT_W*OUT_H);
        else
            $display("NO UNDERRUN (starv=0, full delivery) — fix verified / or deficit not provoked");
        $display("Total errors (golden mismatches) = %0d", errors);
        $display("================================="); $finish;
    end
    initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
