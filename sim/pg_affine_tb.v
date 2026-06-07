// pg_affine_tb.v — proves the incremental affine DDA == a direct affine eval, bit-exact.
// Coeffs quantized to Q.FB first; HW DDA and golden accumulate the same integer Q.FB values
// -> exact match. Outputs are CAPTURED into arrays keyed on o_valid (no manual cycle alignment),
// then compared. Cases: identity, zoom, shrink, rotation, shift.
`default_nettype none
`timescale 1ns / 1ps

module pg_affine_tb;
    localparam OUT_W=64, OUT_H=48, IN_W=96, IN_H=72, CW=32, FB=12, N=OUT_W*OUT_H;
    reg clk=0, rstn=0, sof=0, px_valid=0;
    reg signed [CW-1:0] m_a,m_b,m_c,m_d,m_e,m_f;
    wire        o_valid, o_in_window, o_new_row;
    wire [11:0] o_src_col, o_src_row, o_h_frac, o_v_frac;

    pg_affine #(.OUT_W(OUT_W),.OUT_H(OUT_H),.IN_W(IN_W),.IN_H(IN_H),.CW(CW),.FB(FB)) dut (
        .clk(clk),.rstn(rstn),.sof(sof),.px_valid(px_valid),
        .m_a(m_a),.m_b(m_b),.m_c(m_c),.m_d(m_d),.m_e(m_e),.m_f(m_f),
        .o_valid(o_valid),.o_in_window(o_in_window),.o_src_col(o_src_col),.o_src_row(o_src_row),
        .o_h_frac(o_h_frac),.o_v_frac(o_v_frac),.o_new_row(o_new_row));

    always #5 clk = ~clk;

    // capture arrays (keyed on o_valid -> automatic raster-order alignment)
    reg [11:0] cc[0:N-1], cr[0:N-1], chf[0:N-1], cvf[0:N-1];
    reg        cin[0:N-1];
    integer cap_idx; reg capturing;
    always @(posedge clk) if (capturing && o_valid && cap_idx<N) begin
        cc[cap_idx]=o_src_col; cr[cap_idx]=o_src_row;
        chf[cap_idx]=o_h_frac; cvf[cap_idx]=o_v_frac; cin[cap_idx]=o_in_window;
        cap_idx = cap_idx + 1;
    end

    integer errors=0, total=0;
    real PI;
    function signed [CW-1:0] q; input real v; begin q = $rtoi(v*(1<<FB)); end endfunction

    task check_frame; input [127:0] name; begin : ck
        integer k, ox, oy, sxq, syq, sxi, syi, exin, ecol, erow, ehf, evf, e0, wait_c;
        e0 = errors; cap_idx = 0; capturing = 1;
        @(posedge clk); sof <= 1'b1; @(posedge clk); sof <= 1'b0;
        repeat (N) begin px_valid <= 1'b1; @(posedge clk); end
        px_valid <= 1'b0;
        wait_c = 0;
        while (cap_idx < N && wait_c < 16) begin @(posedge clk); wait_c = wait_c + 1; end
        capturing = 0;
        if (cap_idx != N) begin errors=errors+1; $display("  ERR captured %0d/%0d", cap_idx, N); end
        for (k=0; k<cap_idx; k=k+1) begin
            ox = k % OUT_W; oy = k / OUT_W;
            sxq = m_c + ox*m_a + oy*m_b; syq = m_f + ox*m_d + oy*m_e;
            sxi = sxq >>> FB; syi = syq >>> FB;
            exin = (sxi>=0 && sxi<IN_W && syi>=0 && syi<IN_H) ? 1 : 0;
            if (cin[k] !== exin[0]) begin
                errors=errors+1; if(errors-e0<8) $display("  ERR inwin @(%0d,%0d) got=%b exp=%0d",ox,oy,cin[k],exin);
            end else if (exin) begin
                ecol=sxi&12'hFFF; erow=syi&12'hFFF; ehf=sxq&12'hFFF; evf=syq&12'hFFF;
                if (cc[k]!==ecol[11:0]||cr[k]!==erow[11:0]||chf[k]!==ehf[11:0]||cvf[k]!==evf[11:0]) begin
                    errors=errors+1;
                    if(errors-e0<8) $display("  ERR @(%0d,%0d) got col=%0d row=%0d hf=%0d vf=%0d | exp %0d %0d %0d %0d",
                        ox,oy,cc[k],cr[k],chf[k],cvf[k],ecol,erow,ehf,evf);
                end
            end
            total=total+1;
        end
        $display("CASE %0s : errors=%0d", name, errors-e0);
    end endtask

    task set_rot; input real deg; input real s; begin : sr
        real th, cxo, cyo, cxs, cys, co, si, aa, bb, dd, ee;
        th=deg*PI/180.0; co=$cos(th); si=$sin(th);
        cxo=OUT_W/2.0; cyo=OUT_H/2.0; cxs=IN_W/2.0; cys=IN_H/2.0;
        aa=co/s; bb=si/s; dd=-si/s; ee=co/s;
        m_a=q(aa); m_b=q(bb); m_c=q(cxs-aa*cxo-bb*cyo);
        m_d=q(dd); m_e=q(ee); m_f=q(cys-dd*cxo-ee*cyo);
    end endtask

    initial begin
        PI = 3.14159265358979;
        rstn=0; repeat(4) @(posedge clk); rstn=1; repeat(2) @(posedge clk);
        set_rot(0.0,1.0);  check_frame("identity");
        set_rot(0.0,2.0);  check_frame("zoom 2x");
        set_rot(0.0,0.5);  check_frame("shrink 0.5");
        set_rot(30.0,1.0); check_frame("rotate 30");
        set_rot(90.0,1.0); check_frame("rotate 90");
        m_a=q(1.0);m_b=0;m_c=q(8.0); m_d=0;m_e=q(1.0);m_f=q(-5.0); check_frame("shift (+8,-5)");
        $display("Total errors = %0d (checked %0d px)", errors, total);
        $finish;
    end
endmodule

`default_nettype wire
