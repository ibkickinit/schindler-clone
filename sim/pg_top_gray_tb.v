// pg_top_gray_tb.v — full read-engine gray-gradient chroma probe at 1920->1280.
//
// DDR holds a PURE GRAY horizontal gradient (R==B==G==grad(col)). The engine
// downscales 1920->1280 (1.5:1) via the DDA and emits 1280 output px/line.
// We flag any OUTPUT pixel that is not gray (R!=B!=G) and report its output
// column, so we can see the periodic chroma bands and correlate the period to
// a structural boundary. Few short rows for speed.

`default_nettype none
`timescale 1ns / 1ps

module pg_top_gray_tb;
    localparam integer OUT_W=1280, OUT_H=24, IN_W=1920, IN_H=36;
    localparam integer STRIDE = IN_W*3;                 // 5760
    localparam [31:0]  BASE = 32'h1000_0000;
    localparam integer SLOT_STRIDE = STRIDE*IN_H + STRIDE;
    localparam integer NUMF = 5, RDLY = 2;
    localparam integer HBLANK = 200, VBLANK = 6000;
    // DataMover realism: insert a 1-cycle beat-stream gap every GAPN beats.
    integer GAPN = 64;

    reg clk = 1'b0; always #5 clk = ~clk;
    reg rstn;

    reg         out_vsync, m_tready;
    reg  [5:0]  frame_ptr;
    reg  [11:0] out_w_win,out_h_win,pos_x,pos_y,src_col0,src_row0,hsi,hsf,vsi,vsf;
    reg  [23:0] matte;
    reg         filt_h, h_dir, v_dir;

    wire [23:0] m_tdata; wire m_tvalid;
    wire [71:0] cmd_tdata; wire cmd_tvalid; reg cmd_tready;
    reg  [63:0] dm_tdata; reg dm_tvalid, dm_tlast; wire dm_tready;

    pg_read_engine_top #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),
        .STRIDE(STRIDE),.FRAME_BUF_BASE(BASE),.NUM_FRAMES(NUMF),
        .SLOT_STRIDE(SLOT_STRIDE),.READ_DELAY(RDLY)) dut (
        .clk(clk),.rstn(rstn),.frame_ptr(frame_ptr),.out_vsync(out_vsync),
        .out_w_win(out_w_win),.out_h_win(out_h_win),.pos_x(pos_x),.pos_y(pos_y),
        .src_col0(src_col0),.src_row0(src_row0),
        .h_step_int(hsi),.h_step_frac(hsf),.v_step_int(vsi),.v_step_frac(vsf),.matte_rgb(matte),.filt_h(filt_h),
        .h_dir(h_dir),.v_dir(v_dir),.blend_mode(2'b00),
        .m_axis_tdata(m_tdata),.m_axis_tvalid(m_tvalid),.m_axis_tready(m_tready),
        .m_axis_cmd_tdata(cmd_tdata),.m_axis_cmd_tvalid(cmd_tvalid),.m_axis_cmd_tready(cmd_tready),
        .s_axis_dm_tdata(dm_tdata),.s_axis_dm_tvalid(dm_tvalid),.s_axis_dm_tready(dm_tready),
        .s_axis_dm_tlast(dm_tlast));

    // pure-gray gradient pixel
    function [7:0] grad; input integer c; grad = (c*131 + 7) & 8'hFF; endfunction
    function [7:0] lbyte; input integer r,off; integer p; begin p=off/3; lbyte = grad(p); end endfunction

    integer errors, chroma_cols, c_ow, c_oh, c_px, c_py, c_sc, c_sr;

    // golden source-col map (floor DDA) for value-check (not chroma)
    function integer gsrc; input integer ox; gsrc = (ox*IN_W)/c_ow; endfunction

    // ---- behavioral AXI DataMover ----
    localparam DM_IDLE=0, DM_STREAM=1;
    integer dm_state, dm_row, dm_byte, dm_btt, bb, dm_bcnt; reg dm_stall;
    task present_cur; begin
        for (bb=0; bb<8; bb=bb+1)
            dm_tdata[bb*8 +: 8] <= (dm_byte+bb < dm_btt) ? lbyte(dm_row, dm_byte+bb) : 8'd0;
        dm_tvalid <= 1'b1;
        dm_tlast  <= (dm_byte+8 >= dm_btt);
    end endtask
    always @(posedge clk) begin
        if (!rstn) begin dm_state<=DM_IDLE; dm_tvalid<=0; dm_tlast<=0; cmd_tready<=1; dm_stall<=0; end
        else begin
            case (dm_state)
                DM_IDLE: begin
                    cmd_tready <= 1'b1; dm_tvalid <= 1'b0; dm_tlast <= 1'b0; dm_stall<=0;
                    if (cmd_tvalid && cmd_tready) begin
                        dm_row  = ((cmd_tdata[63:32]-BASE) % SLOT_STRIDE) / STRIDE;
                        dm_btt  = cmd_tdata[22:0];
                        dm_byte = 0; dm_bcnt = 0; cmd_tready <= 1'b0; dm_state <= DM_STREAM;
                        present_cur;
                    end
                end
                DM_STREAM: begin
                    if (dm_stall) begin
                        dm_stall <= 1'b0; present_cur;             // resume: re-present SAME held beat
                    end else if (dm_tvalid && dm_tready) begin
                        dm_byte = dm_byte + 8; dm_bcnt = dm_bcnt + 1;
                        if (dm_byte >= dm_btt) begin
                            dm_tvalid<=0; dm_tlast<=0; dm_state<=DM_IDLE; cmd_tready<=1;
                        end else if ((dm_bcnt % GAPN)==0) begin
                            dm_tvalid<=0; dm_stall<=1;             // AXI-legal stall: hold next beat 1 cyc
                        end else begin
                            present_cur;
                        end
                    end
                end
            endcase
        end
    end

    // ---- output checker: flag non-gray pixels ----
    integer vox,voy,seen; reg checking,in_active;
    reg [7:0] R,B,G;
    always @(posedge clk) begin
        if (checking && m_tvalid && m_tready) begin
            R=m_tdata[23:16]; B=m_tdata[15:8]; G=m_tdata[7:0];
            if (!((R==B)&&(B==G))) begin
                chroma_cols=chroma_cols+1;
                if (chroma_cols<=60)
                    $display("  CHROMA out(%0d,%0d): R=%0d B=%0d G=%0d  src=%0d",
                             vox,voy,R,B,G,gsrc(vox));
                errors=errors+1;
            end
            seen=seen+1;
            if (vox==OUT_W-1) begin vox=0; voy=voy+1; end else vox=vox+1;
        end
    end

    task run_frame; integer line; begin
        frame_ptr <= (frame_ptr + 1) % 5; repeat(8)@(posedge clk);
        out_vsync<=1; repeat(3)@(posedge clk); out_vsync<=0;
        vox=0; voy=0; seen=0; checking=1; in_active=0;
        repeat(VBLANK)@(posedge clk);
        for (line=0; line<OUT_H; line=line+1) begin
            in_active<=1; m_tready<=1; repeat(OUT_W)@(posedge clk);
            in_active<=0; m_tready<=0; repeat(HBLANK)@(posedge clk);
        end
        repeat(200)@(posedge clk); checking=0;
        if (seen!=OUT_W*OUT_H) begin $display("  NOTE delivered %0d/%0d",seen,OUT_W*OUT_H); end
    end endtask

    task set_geom; input integer ow,oh,ppx,ppy; begin
        c_ow=ow;c_oh=oh;c_px=ppx;c_py=ppy;
        c_sc=0; c_sr=0;
        out_w_win=ow[11:0];out_h_win=oh[11:0];
        pos_x=ppx[11:0];pos_y=ppy[11:0];
        src_col0=0;src_row0=0;
        matte=24'h101010;
        hsi=IN_W/ow;hsf=IN_W%ow;vsi=IN_H/oh;vsf=IN_H%oh;
    end endtask

    initial begin
        errors=0; chroma_cols=0; rstn=0; frame_ptr=0; out_vsync=0; m_tready=0; checking=0; in_active=0;
        out_w_win=OUT_W;out_h_win=OUT_H;pos_x=0;pos_y=0;src_col0=0;src_row0=0;
        hsi=1;hsf=0;vsi=1;vsf=0;matte=0;filt_h=0;h_dir=0;v_dir=0;
        repeat(6)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        repeat(20)@(posedge clk);

        set_geom(OUT_W,OUT_H,0,0);     // full-window 1920->1280 downscale
        repeat(6)@(posedge clk);
        run_frame; run_frame; run_frame;

        $display("=================================");
        $display("chroma columns = %0d / %0d", chroma_cols, OUT_W*OUT_H);
        $display("Total errors = %0d", errors);
        $display("=================================");
        $finish;
    end
    initial begin #800_000_000; $display("TIMEOUT errors=%0d chroma=%0d",errors,chroma_cols); $finish; end
endmodule

`default_nettype wire
