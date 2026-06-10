// pg_affine_tile_tb.v — verify the tile-order walk + DDA matches the direct affine, in tile order,
// with correct tlast (per 256-px tile) + tuser (first px). Tests identity-scale and a 90deg transpose.
`default_nettype none
`timescale 1ns/1ps
module pg_affine_tile_tb;
    localparam OUT_W=32, OUT_H=32, IN_W=64, IN_H=64, CW=32, FB=12, TILE=16, OTX=2, OTY=2;
    localparam NPX=OUT_W*OUT_H;
    reg clk=0, rstn=0, sof=0; always #5 clk=~clk;
    reg signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f;
    wire o_valid, o_inwin, o_tlast, o_tuser; wire [11:0] o_col,o_row,o_hf,o_vf;
    reg o_ready=1;

    pg_affine_tile #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.CW(CW),.FB(FB),.LTILE(4)) dut(
        .clk(clk),.rstn(rstn),.sof(sof),.m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),
        .o_valid(o_valid),.o_ready(o_ready),.o_in_window(o_inwin),
        .o_src_col(o_col),.o_src_row(o_row),.o_h_frac(o_hf),.o_v_frac(o_vf),
        .o_tlast(o_tlast),.o_tuser(o_tuser));

    integer eoty,eotx,eor,eoc, n, errs, tiles, sofs;
    // expected src col/row at output (ox,oy) for the current coeffs
    function signed [31:0] esx; input integer ox,oy; esx=(m_a*ox + m_b*oy + m_c)>>>FB; endfunction
    function signed [31:0] esy; input integer ox,oy; esy=(m_d*ox + m_e*oy + m_f)>>>FB; endfunction

    task run; input [127:0] nm; begin
        eoty=0;eotx=0;eor=0;eoc=0; n=0; errs=0; tiles=0; sofs=0;
        @(posedge clk); sof<=1; @(posedge clk); sof<=0;
        while(n<NPX) begin
            @(posedge clk);
            if(o_valid && o_ready) begin
                : chk
                integer ox,oy; ox=eotx*16+eoc; oy=eoty*16+eor;
                if(o_col!==esx(ox,oy)[11:0] || o_row!==esy(ox,oy)[11:0]) begin
                    errs=errs+1; if(errs<6)$display("  ERR n%0d (ox%0d oy%0d) got(%0d,%0d) exp(%0d,%0d)",
                        n,ox,oy,o_col,o_row,esx(ox,oy)[11:0],esy(ox,oy)[11:0]); end
                if(o_tuser) begin sofs=sofs+1; if(n!=0)errs=errs+1; end
                if(o_tlast) begin tiles=tiles+1; if(eoc!=15||eor!=15)errs=errs+1; end
                // advance tile-order counters
                if(eoc<15) eoc=eoc+1;
                else if(eor<15) begin eoc=0; eor=eor+1; end
                else if(eotx<OTX-1) begin eoc=0;eor=0; eotx=eotx+1; end
                else begin eoc=0;eor=0;eotx=0; eoty=eoty+1; end
                n=n+1;
            end
        end
        $display("AFFINE_TILE %0s: n=%0d tiles=%0d(exp %0d) sof=%0d errs=%0d | %s",
            nm, n, tiles, OTX*OTY, sofs, errs, (n==NPX&&errs==0&&tiles==OTX*OTY&&sofs==1)?"PASS":"FAIL");
        repeat(4)@(posedge clk);
    end endtask

    initial begin
        rstn=0; repeat(4)@(posedge clk); rstn=1; repeat(2)@(posedge clk);
        // identity scale (src=out, centered crop)
        m_a=4096;m_b=0;m_c=8*4096; m_d=0;m_e=4096;m_f=8*4096; run("ident");
        // 90deg: sx=oy+off, sy=-ox+off
        m_a=0;m_b=4096;m_c=4*4096; m_d=-4096;m_e=0;m_f=40*4096; run("rot90");
        $finish;
    end
    initial begin #500000 $display("WATCHDOG"); $finish; end
endmodule
`default_nettype wire
