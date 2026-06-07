// pg_warp_dma_tb.v — M4 integration: warp engine + pg_tile_dma + behavioral AXI DataMover.
// Proves the real fill path (cache fetch_req -> tile_dma 16 row-fetches -> unpack -> 2x2 reorder ->
// cache fill) keeps the warp output bit-exact vs the golden affine-bilinear.
`default_nettype none
`timescale 1ns / 1ps

module pg_warp_dma_tb;
    localparam OUT_W=256, OUT_H=144, IN_W=384, IN_H=216;
    localparam LTILE=4, TILE=16, NTILE=256, CW=32, FB=12, NA=OUT_W*OUT_H, LEAD=512;
    localparam STRIDE=IN_W*3, FRAME_PERIOD=330*170;
    reg clk=0, rstn=0, sof=0;
    reg signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f; reg [23:0] matte=24'h101010;
    wire o_valid; wire [23:0] o_pix; reg o_ready=1;
    // warp engine <-> tile_dma
    wire wreq; wire [11:0] wtx,wty;
    wire fv; wire [95:0] fblk; wire fl;
    // tile_dma <-> DataMover
    wire dm_req; wire [31:0] dm_addr; wire [11:0] dm_len;
    reg  [63:0] beat_data=0; reg beat_valid=0; wire beat_ready; reg beat_last=0;

    pg_warp_engine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.CW(CW),.FB(FB),.LEAD(LEAD)) dut (
        .clk(clk),.rstn(rstn),.sof(sof),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.matte(matte),
        .o_valid(o_valid),.o_pix(o_pix),.o_ready(o_ready),
        .fetch_req(wreq),.fetch_tx(wtx),.fetch_ty(wty),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl));

    pg_tile_dma #(.IN_W(IN_W),.LTILE(LTILE)) u_dma (
        .clk(clk),.rstn(rstn),.frame_base(32'd0),
        .t_req(wreq),.t_tx(wtx),.t_ty(wty),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),
        .beat_data(beat_data),.beat_valid(beat_valid),.beat_ready(beat_ready),.beat_last(beat_last));
    always #5 clk=~clk;

    reg [23:0] frame[0:IN_W*IN_H-1];
    function [23:0] pxf; input integer x,y; pxf=frame[y*IN_W+x]; endfunction

    // behavioral DataMover: on a row-fetch, pack TILE pixels into 64-bit beats (little-endian 24b)
    reg [383:0] packed; integer srcrow, srccol, bidx, k; reg [2:0] dstate;
    localparam NBEAT=(TILE*3)/8;   // 16*3/8 = 6
    always @(posedge clk) begin
        if(!rstn) begin dstate<=0; beat_valid<=0; beat_last<=0; end
        else case(dstate)
            0: begin beat_valid<=0; beat_last<=0;
                if(dm_req) begin
                    srcrow=dm_addr/STRIDE; srccol=(dm_addr-srcrow*STRIDE)/3;
                    for(k=0;k<TILE;k=k+1) packed[k*24 +: 24] = pxf(srccol+k, srcrow);
                    bidx=0; dstate<=1;
                end end
            1: begin beat_valid<=1; beat_data<=packed[bidx*64 +: 64]; beat_last<=(bidx==NBEAT-1);
                if(beat_valid && beat_ready) begin
                    if(bidx==NBEAT-1) begin dstate<=0; beat_valid<=0; beat_last<=0; end
                    else bidx=bidx+1;
                end end
            default: dstate<=0;
        endcase
    end

    // golden (identical lerp to pg_warp_engine)
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

    integer cn, errors, total, cyc, t0, axx, ayy; real PI;
    always @(posedge clk) cyc<=cyc+1;
    always @(posedge clk) if(o_valid && o_ready) begin
        if(o_pix!==golden(cn)) begin errors<=errors+1; if(errors<8)$display("  ERR idx %0d got %h exp %h",cn,o_pix,golden(cn)); end
        cn<=cn+1; total<=total+1;
    end

    task setrot; input real deg; input real sc; begin : s
        real th,co,si,inv,cxo,cyo,cxs,cys,aa,bb,dd,ee;
        th=deg*PI/180.0;co=$cos(th);si=$sin(th);inv=1.0/sc;
        cxo=OUT_W/2.0;cyo=OUT_H/2.0;cxs=IN_W/2.0;cys=IN_H/2.0;
        aa=co*inv;bb=si*inv;dd=-si*inv;ee=co*inv;
        m_a=$rtoi(aa*4096);m_b=$rtoi(bb*4096);m_c=$rtoi((cxs-aa*cxo-bb*cyo)*4096);
        m_d=$rtoi(dd*4096);m_e=$rtoi(ee*4096);m_f=$rtoi((cys-dd*cxo-ee*cyo)*4096);
    end endtask

    initial begin
        PI=3.14159265358979;
        for(ayy=0;ayy<IN_H;ayy=ayy+1) for(axx=0;axx<IN_W;axx=axx+1)
            frame[ayy*IN_W+axx]={axx[7:0],ayy[7:0],(axx*3+ayy*5)+8'h07};
        setrot(20.0,1.0);
        cn=0;errors=0;total=0;cyc=0;
        rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        @(posedge clk); sof<=1; @(posedge clk); sof<=0;
        t0=cyc;
        while(cn<NA) @(posedge clk);
        $display("M4 warp+dma rot20: %0d px in %0d cyc (period %0d) | bit-err=%0d | %s",
                 total, cyc-t0, FRAME_PERIOD, errors, (errors==0)?"OK":"FAIL");
        $finish;
    end
    initial begin #2_000_000_000; $display("WATCHDOG cn=%0d err=%0d",cn,errors); $finish; end
endmodule

`default_nettype wire
