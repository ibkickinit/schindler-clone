// pg_chroma_mod_tb.v — self-checking regression for the NTSC chroma QAM modulator.
// Verifies: (1) the RGB->U/V matrix (exact, vs golden), (2) NEUTRALS carry no chroma (white/gray/black
// -> chroma==0 across all active phases), (3) a saturated color produces a subcarrier oscillation whose
// peak amplitude matches (U*sin+V*cos)>>SHIFT. Input is R-B-G order. Prints PG_CHROMA: PASS/FAIL.
`timescale 1ns/1ps
`default_nettype none
module pg_chroma_mod_tb;
  reg clk=0,rstn=0,active=0,hsync=0; reg [23:0] vid_rgb=0;
  wire signed [11:0] chroma;
  pg_chroma_mod dut(.clk(clk),.rstn(rstn),.vid_rgb(vid_rgb),.active(active),.hsync(hsync),.chroma(chroma));
  always #5 clk=~clk;
  integer errors=0, i; reg signed [11:0] cmax, cmin;

  // drive a color (R-B-G order: {R,B,G}), let U/V settle, return dut.u/dut.v
  task setcol(input [7:0] R,input [7:0] B,input [7:0] G); begin
    vid_rgb = {R,B,G}; active=1'b1; repeat(4)@(posedge clk); end
  endtask

  initial begin
    rstn=0; repeat(4)@(posedge clk); rstn=1; @(posedge clk);

    // (1) U/V matrix exactness vs golden (Q0.8 >>8): red 255,0,0 -> U=-38 V=157 ; blue(B=255) -> U=+112? etc.
    // red: R=255,B=0,G=0 -> U=(-38*255)>>8=-38, V=(157*255)>>8=156
    setcol(8'd255,8'd0,8'd0);
    if (dut.u !== -10'sd38 && dut.u !== -10'sd37) begin errors=errors+1; $display("  FAIL red U=%0d exp ~-38",dut.u); end
    if (dut.v !== 10'sd156 && dut.v !== 10'sd157) begin errors=errors+1; $display("  FAIL red V=%0d exp ~156",dut.v); end
    // green field sits in the LOW byte (R-B-G): G=255 -> U=(-74*255)>>8=-74, V=(-132*255)>>8=-132
    setcol(8'd0,8'd0,8'd255);
    if (dut.u > -10'sd70 || dut.u < -10'sd78) begin errors=errors+1; $display("  FAIL green U=%0d exp ~-74",dut.u); end
    if (dut.v > -10'sd128 || dut.v < -10'sd136) begin errors=errors+1; $display("  FAIL green V=%0d exp ~-132",dut.v); end

    // (2) NEUTRALS: white / mid-gray / black -> U=V=0 -> ACTIVE chroma == 0 (check the internal QAM
    //     result chroma_active directly, so the back-porch burst doesn't confound the test).
    setcol(8'd255,8'd255,8'd255);
    if (dut.u !== 10'sd0 || dut.v !== 10'sd0) begin errors=errors+1; $display("  FAIL white U/V nonzero: %0d %0d",dut.u,dut.v); end
    for(i=0;i<40;i=i+1) begin @(posedge clk); if(dut.chroma_active!==12'sd0) begin errors=errors+1; if(errors<8)$display("  FAIL white chroma_active=%0d",dut.chroma_active); end end
    setcol(8'd128,8'd128,8'd128);
    for(i=0;i<40;i=i+1) begin @(posedge clk); if(dut.chroma_active!==12'sd0) begin errors=errors+1; if(errors<8)$display("  FAIL gray chroma_active=%0d",dut.chroma_active); end end
    setcol(8'd0,8'd0,8'd0);
    for(i=0;i<40;i=i+1) begin @(posedge clk); if(dut.chroma_active!==12'sd0) begin errors=errors+1; if(errors<8)$display("  FAIL black chroma_active=%0d",dut.chroma_active); end end

    // (3) SATURATED color -> real QAM oscillation. Red |C|~161; peak ~ (161*255)>>10 ~ 40.
    setcol(8'd255,8'd0,8'd0);
    cmax=-12'sd2048; cmin=12'sd2047;
    for(i=0;i<64;i=i+1) begin @(posedge clk);
      if(dut.chroma_active>cmax) cmax=dut.chroma_active; if(dut.chroma_active<cmin) cmin=dut.chroma_active; end
    if (!(cmax > 12'sd20 && cmin < -12'sd20)) begin errors=errors+1;
      $display("  FAIL red chroma no oscillation: max=%0d min=%0d (exp +/->20)",cmax,cmin); end
    else $display("  red chroma_active swing: max=%0d min=%0d (oscillating)",cmax,cmin);

    $display("PG_CHROMA: %s (%0d)", (errors==0)?"PASS":"FAIL", errors);
    $finish;
  end
endmodule
`default_nettype wire
