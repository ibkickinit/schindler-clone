// pg_read_engine_top_tb.v — capstone TB for the whole route-B read-engine.
//
// Exercises the engine through the real AXI-DataMover interface: a behavioral
// DataMover parses the 72-bit command (addr/BTT), decodes the master row, and
// streams 64-bit little-endian beats of [G,B,R] bytes from a behavioral DDR.
// Genlock (src/out vsync) + VTC timing (active/hblank/vblank) are modeled.
// Checks the output AXIS frame vs golden (downscale+position+matte), full
// delivery, and zero starvation.  Small dims for an exhaustive, fast check.
//
// Pass criterion: "Total errors = 0".  Run: make sim-pg-top.

`default_nettype none
`timescale 1ns / 1ps

module pg_read_engine_top_tb;
    localparam integer OUT_W=64, OUT_H=48, IN_W=64, IN_H=48;
    localparam integer STRIDE = IN_W*3;                 // 192
    localparam [31:0]  BASE = 32'h1000_0000;
    localparam integer SLOT_STRIDE = STRIDE*IN_H + STRIDE;   // 9408
    localparam integer NUMF = 5, RDLY = 2;
    localparam integer HBLANK = 150, VBLANK = 1400;

    reg clk = 1'b0; always #5 clk = ~clk;
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

    // ---- behavioral AXI DataMover ----
    localparam DM_IDLE=0, DM_STREAM=1;
    integer dm_state, dm_row, dm_byte, dm_btt;
    integer bb;
    always @(posedge clk) begin
        if (!rstn) begin dm_state<=DM_IDLE; dm_tvalid<=0; dm_tlast<=0; cmd_tready<=1; end
        else begin
            case (dm_state)
                DM_IDLE: begin
                    cmd_tready <= 1'b1; dm_tvalid <= 1'b0; dm_tlast <= 1'b0;
                    if (cmd_tvalid && cmd_tready) begin
                        dm_row  = ((cmd_tdata[63:32]-BASE) % SLOT_STRIDE) / STRIDE;
                        dm_btt  = cmd_tdata[22:0];
                        dm_byte = 0; cmd_tready <= 1'b0; dm_state <= DM_STREAM;
                    end
                end
                DM_STREAM: begin
                    // present a beat; advance only when accepted (dm_tready)
                    if (dm_tvalid && dm_tready) begin
                        dm_byte = dm_byte + 8;
                        if (dm_byte >= dm_btt) begin dm_tvalid<=0; dm_tlast<=0; dm_state<=DM_IDLE; cmd_tready<=1; end
                    end
                    if (dm_state==DM_STREAM && (!dm_tvalid || dm_tready)) begin
                        for (bb=0; bb<8; bb=bb+1)
                            dm_tdata[bb*8 +: 8] <= (dm_byte+bb < dm_btt) ? lbyte(dm_row, dm_byte+bb) : 8'd0;
                        dm_tvalid <= 1'b1;
                        dm_tlast  <= (dm_byte+8 >= dm_btt);
                    end
                end
            endcase
        end
    end

    // ---- output checker ----
    integer vox,voy,seen,starv; reg checking,in_active;
    always @(posedge clk) begin
        if (checking) begin
            if (in_active && !m_tvalid) starv=starv+1;
            if (m_tvalid && m_tready) begin
                if (m_tdata !== golden(vox,voy)) begin
                    if (errors<25) $display("  ERR @ (%0d,%0d): dut=%h gold=%h", vox,voy,m_tdata,golden(vox,voy));
                    errors=errors+1;
                end
                seen=seen+1;
                if (vox==OUT_W-1) begin vox=0; voy=voy+1; end else vox=vox+1;
            end
        end
    end

    task run_frame; integer line; begin
        // advance S2MM framestore pointer (mimic the master), settle CDC/debounce,
        // then SOF latches read_slot = frame_ptr-READ_DELAY. DDR pattern is
        // slot-independent in this TB, so any settled frame_ptr yields golden.
        frame_ptr <= (frame_ptr + 1) % 5; repeat(8)@(posedge clk);
        out_vsync<=1; repeat(3)@(posedge clk); out_vsync<=0;
        vox=0; voy=0; seen=0; starv=0; checking=1; in_active=0;
        repeat(VBLANK)@(posedge clk);
        for (line=0; line<OUT_H; line=line+1) begin
            in_active<=1; m_tready<=1; repeat(OUT_W)@(posedge clk);
            in_active<=0; m_tready<=0; repeat(HBLANK)@(posedge clk);
        end
        repeat(60)@(posedge clk); checking=0;
        if (seen!=OUT_W*OUT_H) begin $display("  ERR delivered %0d/%0d",seen,OUT_W*OUT_H); errors=errors+1; end
        if (starv!=0) begin $display("  ERR starvation %0d",starv); errors=errors+1; end
    end endtask

    task set_geom; input [11:0] ow,oh,ppx,ppy; begin
        c_ow=ow;c_oh=oh;c_px=ppx;c_py=ppy;c_matte=24'h101010;
        out_w_win=ow;out_h_win=oh;pos_x=ppx;pos_y=ppy;matte=24'h101010;
        hsi=IN_W/ow;hsf=IN_W%ow;vsi=IN_H/oh;vsf=IN_H%oh;
    end endtask

    task run_case; input [11:0] ow,oh,ppx,ppy; input integer fr; integer f,e0; begin
        e0=errors; set_geom(ow,oh,ppx,ppy);
        repeat(6) @(posedge clk);   // let the geometry CDC settle (firmware writes then waits)
        for (f=0;f<fr;f=f+1) run_frame;
        $display("CASE %0dx%0d @ (%0d,%0d) x%0d : errors=%0d", ow,oh,ppx,ppy,fr,errors-e0);
    end endtask

    initial begin
        errors=0; rstn=0; frame_ptr=0; out_vsync=0; m_tready=0; checking=0; in_active=0;
        out_w_win=OUT_W;out_h_win=OUT_H;pos_x=0;pos_y=0;hsi=1;hsf=0;vsi=1;vsf=0;matte=0;
        repeat(6)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        // advance the ring a few frames so read_slot is well-defined
        repeat(20) @(posedge clk);   // let things settle after reset

        run_case(64,48, 0, 0, 2);
        run_case(32,24,16,12, 2);
        run_case(40,30,12, 9, 1);

        $display("================================="); $display("Total errors = %0d", errors);
        $display("================================="); $finish;
    end
    initial begin #300_000_000; $display("TIMEOUT errors=%0d",errors); $finish; end
endmodule

`default_nettype wire
