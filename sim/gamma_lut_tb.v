// gamma_lut_tb.v — gate for the per-channel gamma/tone LUT stage.
// Proves: identity-init + bypass passthrough; toggle-strobed per-entry load (with
// CDC settle); R-B-G lane mapping; unloaded entries stay identity. PASS = errors 0.
`default_nettype none
`timescale 1ns / 1ps

module gamma_lut_tb;
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rstn;
    reg [23:0] s_tdata; reg s_tvalid, s_tuser, s_tlast; wire s_tready;
    wire [23:0] m_tdata; wire m_tvalid, m_tuser, m_tlast; reg m_tready;
    reg lut_tog; reg [1:0] lut_ch; reg [7:0] lut_addr, lut_data; reg bypass;

    gamma_lut dut(.clk(clk), .rstn(rstn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast),
        .lut_tog(lut_tog), .lut_ch(lut_ch), .lut_addr(lut_addr), .lut_data(lut_data), .bypass(bypass));

    integer errors = 0, i;
    reg [7:0] gr[0:255], gb[0:255], gg[0:255];   // golden LUTs

    task load; input [1:0] ch; input [7:0] a, d; begin
        lut_ch=ch; lut_addr=a; lut_data=d; @(posedge clk);
        lut_tog = ~lut_tog; repeat(6) @(posedge clk);   // flip toggle + let CDC (3FF) settle + write
    end endtask

    task drive_check; input [7:0] r, b, g; reg [23:0] exp; begin
        s_tdata = {r,b,g}; s_tvalid = 1'b1; @(posedge clk); #1;
        exp = bypass ? {r,b,g} : {gr[r], gb[b], gg[g]};
        if (m_tdata !== exp) begin
            $display("  ERR in=%02x%02x%02x out=%06x exp=%06x byp=%b", r,b,g, m_tdata, exp, bypass);
            errors = errors + 1;
        end
    end endtask

    initial begin
        for (i=0;i<256;i=i+1) begin gr[i]=i[7:0]; gb[i]=i[7:0]; gg[i]=i[7:0]; end
        rstn=0; lut_tog=0; bypass=1; s_tvalid=0; m_tready=1; lut_ch=0; lut_addr=0; lut_data=0; s_tuser=0; s_tlast=0;
        repeat(4) @(posedge clk); rstn=1; repeat(4) @(posedge clk);

        drive_check(8'h12,8'h34,8'h56);             // bypass=1 -> identity passthrough

        bypass=0;
        load(2'd0, 8'h12, 8'hED); gr[8'h12]=8'hED;  // R lane: 0x12 -> 0xED (invert-ish)
        load(2'd1, 8'h34, 8'h1A); gb[8'h34]=8'h1A;  // B lane: 0x34 -> 0x1A
        load(2'd2, 8'h56, 8'h80); gg[8'h56]=8'h80;  // G lane: 0x56 -> 0x80
        drive_check(8'h12,8'h34,8'h56);             // expect {ED,1A,80}
        drive_check(8'h00,8'hFF,8'h7F);             // unloaded -> identity
        // load a full gamma-ish ramp on G and spot-check
        for (i=0;i<256;i=i+1) begin gg[i]=(i*i)/255; load(2'd2, i[7:0], gg[i]); end
        drive_check(8'h80,8'h80,8'h80);             // G: 128 -> 64ish, R/B identity-default for 0x80
        bypass=1; repeat(3) @(posedge clk);          // let the bypass CDC settle
        drive_check(8'h12,8'h34,8'h56);              // bypass overrides loaded LUTs

        $display("================================="); $display("Total errors = %0d", errors);
        $display("================================="); $finish;
    end
    initial begin #2_000_000; $display("TIMEOUT errors=%0d", errors); $finish; end
endmodule

`default_nettype wire
