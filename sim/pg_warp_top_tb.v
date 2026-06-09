// pg_warp_top_tb.v — BD-wrapper glue: cmd-formatter path, sof-from-vsync, output TUSER/TLAST framing.
// Behavioral DataMover consumes m_axis_cmd (decodes SADDR/BTT) and serves beats. Checks bit-exact
// warp + that TUSER marks pixel 0 and TLAST marks every OUT_W-th pixel.
`default_nettype none
`timescale 1ns / 1ps

module pg_warp_top_tb;
    localparam OUT_W=256, OUT_H=144, IN_W=384, IN_H=216, TILE=16, STRIDE=IN_W*3;
    localparam CW=32, FB=12, NA=OUT_W*OUT_H;
    reg clk=0, rstn=0, out_vsync=0;
    reg signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f; reg [23:0] matte=24'h101010;
    wire [23:0] mt; wire mv, mtuser, mtlast; reg mready=1;
    wire [71:0] cmd_td; wire cmd_tv; reg cmd_tr=1;
    reg [63:0] dm_td=0; reg dm_tv=0; wire dm_tr; reg dm_tl=0;

    pg_warp_top #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),
                  .FRAME_BUF_BASE(32'd0),.NUM_FRAMES(7),.SLOT_STRIDE(0),
                  .NTILE(256),.LTILE(4),.LEAD(2048),.CW(CW),.FB(FB)) dut (
        .clk(clk),.rstn(rstn),.frame_ptr(6'd1),.out_vsync(out_vsync),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.matte_rgb(matte),.lead_cfg(32'd0),
        .m_axis_tdata(mt),.m_axis_tvalid(mv),.m_axis_tready(mready),.m_axis_tuser(mtuser),.m_axis_tlast(mtlast),
        .m_axis_cmd_tdata(cmd_td),.m_axis_cmd_tvalid(cmd_tv),.m_axis_cmd_tready(cmd_tr),
        .s_axis_dm_tdata(dm_td),.s_axis_dm_tvalid(dm_tv),.s_axis_dm_tready(dm_tr),.s_axis_dm_tlast(dm_tl),
        .s_axis_sts_tdata(8'd0),.s_axis_sts_tkeep(1'b0),.s_axis_sts_tlast(1'b0),.s_axis_sts_tvalid(1'b0),
        .s_axis_sts_tready());
    always #5 clk=~clk;

    reg [23:0] frame[0:IN_W*IN_H-1];
    function [23:0] pxf; input integer x,y; pxf=frame[y*IN_W+x]; endfunction

    // behavioral DataMover: consume cmd (SADDR=cmd[63:32], BTT=cmd[22:0]); serve beats from frame
    reg [383:0] packed; integer srcrow,srccol,k; reg [2:0] dst,bidx; reg [31:0] caddr; reg [22:0] cbtt;
    localparam NBEAT=(TILE*3)/8;
    always @* begin dm_tv=(dst==3'd2); dm_td=packed[bidx*64 +: 64]; dm_tl=(dst==3'd2)&&(bidx==NBEAT-1); end
    always @(posedge clk) begin
        if(!rstn) begin dst<=0; bidx<=0; end
        else case(dst)
            0: if(cmd_tv && cmd_tr) begin caddr<=cmd_td[63:32]; cbtt<=cmd_td[22:0]; dst<=1; end
            1: begin srcrow=caddr/STRIDE; srccol=(caddr-srcrow*STRIDE)/3;
                     for(k=0;k<TILE;k=k+1) packed[k*24 +: 24]=pxf(srccol+k,srcrow); bidx<=0; dst<=2; end
            2: if(dm_tv && dm_tr) begin if(bidx==NBEAT-1) dst<=0; else bidx<=bidx+1; end
            default: dst<=0;
        endcase
    end

    // golden (matches pg_warp_engine lerp)
    function [7:0] g8; input [7:0] a,b; input [7:0] w;
        reg signed [19:0] d,p,r; begin d=$signed({1'b0,b})-$signed({1'b0,a});
            p=d*$signed({1'b0,w}); r=$signed({1'b0,a})+((p+20'sd128)>>>8); g8=r[7:0]; end endfunction
    function [23:0] g24; input [23:0] a,b; input [7:0] w;
        g24={g8(a[23:16],b[23:16],w),g8(a[15:8],b[15:8],w),g8(a[7:0],b[7:0],w)}; endfunction
    function [23:0] golden; input integer idx; integer ox,oy,sxq,syq,col,row,cn1,rn1; reg[7:0] wx,wy;
        reg[23:0] p00,p10,p01,p11,tp,bt; begin
        ox=idx%OUT_W; oy=idx/OUT_W; sxq=m_c+ox*m_a+oy*m_b; syq=m_f+ox*m_d+oy*m_e;
        col=sxq>>>FB; row=syq>>>FB;
        if(col<0||row<0||col>=IN_W||row>=IN_H) golden=matte;
        else begin cn1=(col>=IN_W-1)?col:col+1; rn1=(row>=IN_H-1)?row:row+1;
            wx=(sxq>>4)&8'hFF; wy=(syq>>4)&8'hFF;
            p00=pxf(col,row);p10=pxf(cn1,row);p01=pxf(col,rn1);p11=pxf(cn1,rn1);
            tp=g24(p00,p10,wx); bt=g24(p01,p11,wx); golden=g24(tp,bt,wy); end end
    endfunction

    integer cn, errors, ferr, axx, ayy; real PI;
    always @(posedge clk) if(mv && mready) begin
        if(mt!==golden(cn)) begin errors<=errors+1; if(errors<6)$display("  ERR idx %0d got %h exp %h",cn,mt,golden(cn)); end
        // framing checks
        if((cn==0) != mtuser) begin ferr<=ferr+1; if(ferr<6)$display("  TUSER err idx %0d tuser=%b",cn,mtuser); end
        if(((cn%OUT_W)==OUT_W-1) != mtlast) begin ferr<=ferr+1; if(ferr<6)$display("  TLAST err idx %0d tlast=%b",cn,mtlast); end
        cn<=cn+1;
    end

    task setrot; input real deg; begin : s
        real th,co,si,cxo,cyo,cxs,cys; th=deg*PI/180.0;co=$cos(th);si=$sin(th);
        cxo=OUT_W/2.0;cyo=OUT_H/2.0;cxs=IN_W/2.0;cys=IN_H/2.0;
        m_a=$rtoi(co*4096);m_b=$rtoi(si*4096);m_c=$rtoi((cxs-co*cxo-si*cyo)*4096);
        m_d=$rtoi(-si*4096);m_e=$rtoi(co*4096);m_f=$rtoi((cys+si*cxo-co*cyo)*4096);
    end endtask

    initial begin
        PI=3.14159265358979;
        for(ayy=0;ayy<IN_H;ayy=ayy+1) for(axx=0;axx<IN_W;axx=axx+1)
            frame[ayy*IN_W+axx]={axx[7:0],ayy[7:0],(axx*3+ayy*5)+8'h07};
        setrot(20.0); cn=0;errors=0;ferr=0;
        rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        @(posedge clk); out_vsync<=1; repeat(2)@(posedge clk); out_vsync<=0;   // sof pulse
        while(cn<NA) @(posedge clk);
        $display("WARP_TOP rot20: %0d px | bit-err=%0d framing-err=%0d | %s",
                 cn, errors, ferr, (errors==0&&ferr==0)?"PASS":"FAIL");
        $finish;
    end
    initial begin #1_000_000_000; $display("WATCHDOG cn=%0d",cn); $finish; end
endmodule

`default_nettype wire
