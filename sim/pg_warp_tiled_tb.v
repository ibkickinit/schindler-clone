// pg_warp_tiled_tb.v — full engine (pg_warp_engine + pg_tile_dma TILED=1) against a TILED source.
// Proves the tiled backend composes: the DataMover returns one contiguous 768B tile per command (from a
// tiled layout of the raster frame), the cache/gather produce the SAME bit-exact output as the raster
// golden. If this passes, the integration is functionally correct (only BD wiring + the real tiled-S2MM
// remain). Geometries: identity + rot20 + 90 (the orientations we care about).
`default_nettype none
`timescale 1ns / 1ps
module pg_warp_tiled_tb;
    localparam OUT_W=256, OUT_H=144, IN_W=384, IN_H=216, LTILE=4, TILE=16, CW=32, FB=12, NA=OUT_W*OUT_H;
    localparam TILES_X=IN_W/TILE;
    reg clk=0, rstn=0, sof=0; always #5 clk=~clk;
    reg signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f; reg [23:0] matte=24'h101010;
    wire o_valid; wire [23:0] o_pix; reg o_ready=1;
    wire wreq; wire [11:0] wtx,wty; wire fv; wire [95:0] fblk; wire fl; wire t_ready;
    reg busy=0;                                                  // DataMover streaming a tile
    wire dm_req; wire [31:0] dm_addr; wire [11:0] dm_len; wire dm_ready = !busy;  // ready only when not streaming
    reg [63:0] beat=0; reg bvalid=0; wire bready; reg blast=0;

    pg_warp_engine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.LTILE(LTILE),
                     .NTILE(512),.WAY(4),.PD(64),.CW(CW),.FB(FB),.LEAD(8192)) dut(
        .clk(clk),.rstn(rstn),.sof(sof),.lead_rt(20'd0),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),.matte(matte),
        .o_valid(o_valid),.o_pix(o_pix),.o_ready(o_ready),
        .fetch_req(wreq),.fetch_tx(wtx),.fetch_ty(wty),.fetch_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl));
    pg_tile_dma #(.IN_W(IN_W),.LTILE(LTILE),.TILED(1),.DREQ(64)) u_dma(
        .clk(clk),.rstn(rstn),.srst(1'b0),.frame_base(32'd0),
        .t_req(wreq),.t_tx(wtx),.t_ty(wty),.t_ready(t_ready),
        .fill_valid(fv),.fill_blk(fblk),.fill_last(fl),
        .fetch_req(dm_req),.fetch_addr(dm_addr),.fetch_len(dm_len),.fetch_ready(dm_ready),
        .beat_data(beat),.beat_valid(bvalid),.beat_ready(bready),.beat_last(blast));

    reg [23:0] frame[0:IN_W*IN_H-1];
    function [23:0] pxf; input integer x,y; pxf=frame[y*IN_W+x]; endfunction

    // ---- behavioral TILED DataMover: cmd -> stream the tile's 768 bytes (row-major px) as 64b beats ----
    reg [7:0] tilebuf[0:767]; integer cidx,ctx,cty,r,c,kk,bb; reg [11:0] nbeat;
    wire cgo = dm_req && dm_ready && !busy;
    always @(posedge clk) begin
        if(!rstn) begin busy<=0; bvalid<=0; bb<=0; end
        else begin
            if(cgo) begin
                cidx=dm_addr/768; cty=cidx/TILES_X; ctx=cidx%TILES_X;
                for(r=0;r<16;r=r+1) for(c=0;c<16;c=c+1) begin
                    kk=(r*16+c)*3; {tilebuf[kk+2],tilebuf[kk+1],tilebuf[kk]} = pxf(ctx*16+c, cty*16+r); end
                bb<=0; nbeat<=(dm_len*3+7)/8; busy<=1;
            end
            if(busy && (!bvalid || bready)) begin
                for(kk=0;kk<8;kk=kk+1) beat[kk*8 +: 8] <= (bb*8+kk<768) ? tilebuf[bb*8+kk] : 8'h0;
                bvalid<=1; blast<=(bb+1>=nbeat);
                if(bb+1>=nbeat) busy<=0; bb<=bb+1;
            end else if(bvalid && bready) bvalid<=0;
        end
    end

    // golden (matches pg_warp_engine lerp)
    function [7:0] g8; input [7:0] a,b; input [7:0] w; reg signed [19:0] d,p,rr; begin
        d=$signed({1'b0,b})-$signed({1'b0,a}); p=d*$signed({1'b0,w}); rr=$signed({1'b0,a})+((p+20'sd128)>>>8); g8=rr[7:0]; end endfunction
    function [23:0] g24; input [23:0] a,b; input [7:0] w;
        g24={g8(a[23:16],b[23:16],w),g8(a[15:8],b[15:8],w),g8(a[7:0],b[7:0],w)}; endfunction
    function [23:0] golden; input integer idx; integer ox,oy,sxq,syq,col,row,cn1,rn1; reg[7:0] wx,wy; reg[23:0] p00,p10,p01,p11,tp,bt; begin
        ox=idx%OUT_W; oy=idx/OUT_W; sxq=m_c+ox*m_a+oy*m_b; syq=m_f+ox*m_d+oy*m_e; col=sxq>>>FB; row=syq>>>FB;
        if(col<0||row<0||col>=IN_W||row>=IN_H) golden=matte;
        else begin cn1=(col>=IN_W-1)?col:col+1; rn1=(row>=IN_H-1)?row:row+1; wx=(sxq>>4)&8'hFF; wy=(syq>>4)&8'hFF;
            p00=pxf(col,row);p10=pxf(cn1,row);p01=pxf(col,rn1);p11=pxf(cn1,rn1);
            tp=g24(p00,p10,wx); bt=g24(p01,p11,wx); golden=g24(tp,bt,wy); end end endfunction

    integer cn,errors,axx,ayy; real PI;
    always @(posedge clk) if(rstn && o_valid && o_ready) begin
        if(o_pix!==golden(cn)) begin errors=errors+1; if(errors<6)$display("  ERR idx %0d got %h exp %h",cn,o_pix,golden(cn)); end
        cn=cn+1; end
    task setrot; input real deg; begin : s real th,co,si,cxo,cyo,cxs,cys; th=deg*PI/180.0;co=$cos(th);si=$sin(th);
        cxo=OUT_W/2.0;cyo=OUT_H/2.0;cxs=IN_W/2.0;cys=IN_H/2.0;
        m_a=$rtoi(co*4096);m_b=$rtoi(si*4096);m_c=$rtoi((cxs-co*cxo-si*cyo)*4096);
        m_d=$rtoi(-si*4096);m_e=$rtoi(co*4096);m_f=$rtoi((cys+si*cxo-co*cyo)*4096); end endtask
    task run; input real deg; input [63:0] nm; begin
        setrot(deg); cn=0; errors=0;
        rstn=0; repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);
        @(posedge clk); sof<=1; @(posedge clk); sof<=0;        // single-cycle SOF (real engine gets one pulse)
        while(cn<NA) @(posedge clk);
        $display("WARP_TILED %0s: %0d px bit-err=%0d | %s", nm, cn, errors, (errors==0)?"PASS":"FAIL"); repeat(40)@(posedge clk); end endtask
    initial begin PI=3.14159265358979;
        for(ayy=0;ayy<IN_H;ayy=ayy+1) for(axx=0;axx<IN_W;axx=axx+1) frame[ayy*IN_W+axx]={axx[7:0],ayy[7:0],(axx*3+ayy*5)+8'h07};
        run(0.0,"ident"); run(20.0,"rot20"); run(90.0,"rot90"); $finish; end
    initial begin #80_000_000 $display("WATCHDOG cn=%0d",cn); $finish; end
endmodule
`default_nettype wire
