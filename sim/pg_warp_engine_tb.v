// pg_warp_engine_tb.v — M3c datapath: full engine (affine+prefetch+cache+bilinear) end-to-end.
// Drives the output-raster walk; behavioral 2x2-block DMA; checks o_pix bit-exact vs a golden
// affine-bilinear warp of the frame, and counts cycles (throughput) vs a frame period.
`default_nettype none
`timescale 1ns / 1ps

module pg_warp_engine_tb;
    localparam OUT_W=256, OUT_H=144, IN_W=384, IN_H=216;
    localparam LTILE=4, TILE=16, NTILE=128, CW=32, FB=12, NA=OUT_W*OUT_H, LEAD=512;
    localparam FRAME_PERIOD=330*170;
    reg clk=0, rstn=0, sof=0;
    reg signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f; reg [23:0] matte=24'h101010;
    wire o_valid; wire [23:0] o_pix; reg o_ready=1;
    wire fetch_req; wire [11:0] ftx,fty;
    reg fill_valid=0; reg [95:0] fill_blk=0; reg fill_last=0;

    pg_warp_engine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),.NTILE(NTILE),.CW(CW),.FB(FB),.LEAD(LEAD)) dut (
        .clk(clk),.rstn(rstn),.sof(sof),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.matte(matte),
        .o_valid(o_valid),.o_pix(o_pix),.o_ready(o_ready),
        .fetch_req(fetch_req),.fetch_tx(ftx),.fetch_ty(fty),
        .fill_valid(fill_valid),.fill_blk(fill_blk),.fill_last(fill_last));
    always #5 clk=~clk;

    reg [23:0] frame[0:IN_W*IN_H-1];
    function [23:0] pxf; input integer x,y; pxf=frame[y*IN_W+x]; endfunction
    reg [1:0] dst=0; integer fc; reg [11:0] dtx,dty;
    always @(posedge clk) begin
        if(!rstn) begin dst<=0;fill_valid<=0;fill_last<=0; end
        else case(dst)
            0:begin fill_valid<=0;fill_last<=0; if(fetch_req)begin dtx<=ftx;dty<=fty;fc<=0;dst<=2;end end
            2:begin fill_valid<=1;
                fill_blk<={ frame[(dty*TILE+2*(fc>>3)+1)*IN_W+dtx*TILE+2*(fc&7)+1],
                            frame[(dty*TILE+2*(fc>>3)+1)*IN_W+dtx*TILE+2*(fc&7)],
                            frame[(dty*TILE+2*(fc>>3))*IN_W+dtx*TILE+2*(fc&7)+1],
                            frame[(dty*TILE+2*(fc>>3))*IN_W+dtx*TILE+2*(fc&7)] };
                fill_last<=(fc==63); fc<=fc+1; if(fc==63)dst<=3; end
            3:begin fill_valid<=0;fill_last<=0;dst<=0; end
            default:dst<=0;
        endcase
    end

    // golden lerp (matches pg_warp_engine)
    function [7:0] g8; input [7:0] a,b; input [7:0] w;   // identical to pg_warp_engine lerp8
        reg signed [19:0] d,p,r; begin d=$signed({1'b0,b})-$signed({1'b0,a});
            p=d*$signed({1'b0,w}); r=$signed({1'b0,a})+((p+20'sd128)>>>8); g8=r[7:0]; end endfunction
    function [23:0] g24; input [23:0] a,b; input [7:0] w;
        g24={g8(a[23:16],b[23:16],w),g8(a[15:8],b[15:8],w),g8(a[7:0],b[7:0],w)}; endfunction
    function [23:0] golden; input integer idx; integer ox,oy,sxq,syq,col,row,cn1,rn1,fxv,fyv; reg[7:0] wx,wy;
        reg[23:0] p00,p10,p01,p11,tp,bt; begin
        ox=idx%OUT_W; oy=idx/OUT_W;
        sxq=m_c+ox*m_a+oy*m_b; syq=m_f+ox*m_d+oy*m_e; col=sxq>>>FB; row=syq>>>FB;
        if(col<0||row<0||col>=IN_W||row>=IN_H) golden=matte;   // affine in-window = col<IN_W (edge-clamped bilinear)
        else begin
            cn1=(col>=IN_W-1)?col:col+1; rn1=(row>=IN_H-1)?row:row+1;
            wx=(sxq>>4)&8'hFF; wy=(syq>>4)&8'hFF;   // frac[11:4]
            p00=pxf(col,row);p10=pxf(cn1,row);p01=pxf(col,rn1);p11=pxf(cn1,rn1);
            tp=g24(p00,p10,wx); bt=g24(p01,p11,wx); golden=g24(tp,bt,wy);
        end end
    endfunction

    integer cn, errors, total, cyc, t0, axx, ayy; real PI;
    // cache-out trace (aligned to output index) vs golden breakdown
    integer tci;
    always @(posedge clk) if(rstn && dut.tc_v && dut.b_ready) begin : tr
        integer ox,oy,sxq,syq,col,row,cn1,rn1; reg[7:0] wx,wy;
        if(tci>=174 && tci<181) begin
            ox=tci%OUT_W; oy=tci/OUT_W; sxq=m_c+ox*m_a+oy*m_b; syq=m_f+ox*m_d+oy*m_e;
            col=sxq>>>FB; row=syq>>>FB; cn1=(col>=IN_W-1)?col:col+1; rn1=(row>=IN_H-1)?row:row+1;
            wx=(sxq>>4)&8'hFF; wy=(syq>>4)&8'hFF;
            $display("CACHE idx%0d tp00=%h tp10=%h tp01=%h tp11=%h tfx=%h tfy=%h | gold col=%0d row=%0d p00=%h p10=%h p01=%h p11=%h wx=%h wy=%h",
                     tci, dut.tp00,dut.tp10,dut.tp01,dut.tp11,dut.tfx,dut.tfy,
                     col,row,pxf(col,row),pxf(cn1,row),pxf(col,rn1),pxf(cn1,rn1),wx,wy);
        end
        tci=tci+1;
    end
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
        cn=0;errors=0;total=0;cyc=0;tci=0;
        rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        @(posedge clk); sof<=1; @(posedge clk); sof<=0;
        t0=cyc;
        while(cn<NA) @(posedge clk);
        $display("M3c warp-engine rot20: %0d px in %0d cyc (period %0d) | bit-err=%0d | %s",
                 total, cyc-t0, FRAME_PERIOD, errors,
                 ((cyc-t0)<=FRAME_PERIOD*2 && errors==0)?"OK":"FAIL");   // *2: datapath has no output FIFO yet
        $finish;
    end
    initial begin #1_000_000_000; $display("WATCHDOG cn=%0d err=%0d",cn,errors); $finish; end
endmodule

`default_nettype wire
