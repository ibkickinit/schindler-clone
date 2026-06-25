// pg_tile_pack64_tb.v — prove pg_tile_pack64 produces the IDENTICAL contiguous LE byte stream as the
// reference "every 24-bit beat -> 3 LE bytes" model the tiled roundtrip TB uses. Feeds a 24-bit pixel
// stream with backpressure on both sides; compares the byte sequence reconstructed from the 64-bit packed
// beats against the reference byte sequence.
`default_nettype none
`timescale 1ns/1ps
module pg_tile_pack64_tb;
    localparam integer NPIX=3072;                 // multiple of 8 px -> whole 64-bit beats (3072*3/8=1152)
    reg clk=0,rstn=0; always #5 clk=~clk;

    reg [23:0] s_td; reg s_tv=0; wire s_tr;
    wire [63:0] m_td; wire m_tv; reg m_tr=1;
    pg_tile_pack64 dut(.clk(clk),.rstn(rstn),
        .s_tdata(s_td),.s_tvalid(s_tv),.s_tready(s_tr),
        .m_tdata(m_td),.m_tvalid(m_tv),.m_tready(m_tr));

    // reference contiguous LE byte stream
    reg [7:0] ref_bytes[0:NPIX*3-1];
    reg [7:0] got_bytes[0:NPIX*3-1];
    integer gbi;

    function [23:0] pv; input integer i; pv = (i*7+3) ^ (i<<5); endfunction

    // capture 8 bytes per accepted 64-bit beat
    integer kk;
    always @(posedge clk) if(rstn && m_tv && m_tr) begin
        for(kk=0;kk<8;kk=kk+1) begin got_bytes[gbi]=m_td[8*kk +: 8]; gbi=gbi+1; end
    end

    // backpressure on the master side
    integer bp=0;
    always @(posedge clk) begin bp<=bp+1; m_tr <= (bp%5!=0); end

    integer i, errs;
    initial begin
        gbi=0; errs=0;
        for(i=0;i<NPIX;i=i+1) begin
            ref_bytes[i*3+0]=pv(i)[7:0]; ref_bytes[i*3+1]=pv(i)[15:8]; ref_bytes[i*3+2]=pv(i)[23:16];
        end
        rstn=0; repeat(4)@(posedge clk); rstn=1; @(posedge clk);
        for(i=0;i<NPIX;i=i+1) begin
            @(posedge clk); s_td<=pv(i); s_tv<=1;
            while(!s_tr) @(posedge clk);
        end
        @(posedge clk); s_tv<=0;
        repeat(100)@(posedge clk);
        if(gbi !== NPIX*3) begin errs=errs+1; $display("  ERR byte count got=%0d exp=%0d",gbi,NPIX*3); end
        for(i=0;i<NPIX*3;i=i+1) if(got_bytes[i]!==ref_bytes[i]) begin
            errs=errs+1; if(errs<10) $display("  ERR byte %0d got=%02x exp=%02x",i,got_bytes[i],ref_bytes[i]); end
        $display("PACK64_TB: bytes=%0d errs=%0d -> %s", gbi, errs, (errs==0)?"PASS":"FAIL");
        $finish;
    end
    initial begin #2000000 $display("WATCHDOG gbi=%0d",gbi); $finish; end
endmodule
`default_nettype wire
