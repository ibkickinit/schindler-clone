// gamma_lut_tb.v — gate for the DOUBLE-BUFFERED per-channel gamma/tone LUT (#114).
// Proves: identity passthrough; loads land in the INACTIVE bank and do NOT change the
// display; the bank swap commits ONLY at SOF after `swap` flips (atomic, no mid-load
// chroma); ping-pong across two loads. PASS = errors 0.
`default_nettype none
`timescale 1ns / 1ps

module gamma_lut_tb;
    reg clk = 1'b0; always #5 clk = ~clk;
    reg rstn;
    reg [23:0] s_tdata; reg s_tvalid, s_tuser, s_tlast; wire s_tready;
    wire [23:0] m_tdata; wire m_tvalid, m_tuser, m_tlast; reg m_tready;
    reg lut_tog, swap; reg [1:0] lut_ch; reg [7:0] lut_addr, lut_data; reg bypass;

    gamma_lut dut(.clk(clk), .rstn(rstn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast),
        .lut_tog(lut_tog), .lut_ch(lut_ch), .lut_addr(lut_addr), .lut_data(lut_data),
        .bypass(bypass), .swap(swap));

    integer errors = 0, i;
    reg [7:0] curveA[0:255], curveB[0:255];   // golden banks
    integer act;                              // 0=A active, 1=B active (mirrors rd_bank)

    // load one (addr,data) to ALL 3 channels of the INACTIVE bank
    task gload; input [7:0] a, d; integer ch; begin
        if (act==0) curveB[a]=d; else curveA[a]=d;   // golden: inactive bank
        for (ch=0; ch<3; ch=ch+1) begin
            lut_ch=ch[1:0]; lut_addr=a; lut_data=d; @(posedge clk);
            lut_tog = ~lut_tog; repeat(6) @(posedge clk);
        end
    end endtask

    task do_swap; begin swap = ~swap; repeat(6) @(posedge clk); end endtask  // request swap
    task sof_beat; begin                                                     // one SOF beat → commits swap
        s_tdata=24'h000000; s_tuser=1'b1; s_tvalid=1'b1; @(posedge clk); #1;
        s_tuser=1'b0;
        if (act==0) act=1; else act=0;   // golden: rd_bank toggles at this SOF if a swap was pending
    end endtask

    task drive_check; input [7:0] v; reg [7:0] e; reg [23:0] exp; begin
        s_tdata={v,v,v}; s_tuser=1'b0; s_tvalid=1'b1; @(posedge clk); #1;
        e = bypass ? v : (act==0 ? curveA[v] : curveB[v]);
        exp = {e,e,e};
        if (m_tdata !== exp) begin
            $display("  ERR v=%02x out=%06x exp=%06x byp=%b act=%0d", v, m_tdata, exp, bypass, act);
            errors = errors + 1;
        end
    end endtask

    initial begin
        for (i=0;i<256;i=i+1) begin curveA[i]=i[7:0]; curveB[i]=i[7:0]; end  // both identity
        act=0; rstn=0; lut_tog=0; swap=0; bypass=1; s_tvalid=0; m_tready=1;
        lut_ch=0; lut_addr=0; lut_data=0; s_tuser=0; s_tlast=0; s_tdata=0;
        repeat(4) @(posedge clk); rstn=1; repeat(4) @(posedge clk);

        drive_check(8'h40);                       // bypass → passthrough
        bypass=0; repeat(3) @(posedge clk);
        drive_check(8'h40);                       // both banks identity → 0x40

        // load 0x40->0xC0 into the INACTIVE bank; display must NOT change yet
        gload(8'h40, 8'hC0);
        drive_check(8'h40);                       // still 0x40 (active bank untouched)  <-- the key proof
        // request swap but NO sof yet → still old
        do_swap;
        drive_check(8'h40);                       // still 0x40 (swap pending, not committed)
        // SOF commits the swap
        sof_beat;
        drive_check(8'h40);                       // now 0xC0 (atomic swap at SOF)
        drive_check(8'h7F);                       // unloaded entry → identity in the new bank

        // ping-pong: load 0x40->0x20 into the (now) inactive bank
        gload(8'h40, 8'h20);
        drive_check(8'h40);                       // still 0xC0 (no swap yet)
        do_swap; sof_beat;
        drive_check(8'h40);                       // now 0x20

        $display("================================="); $display("Total errors = %0d", errors);
        $display("================================="); $finish;
    end
    initial begin #3_000_000; $display("TIMEOUT errors=%0d", errors); $finish; end
endmodule

`default_nettype wire
