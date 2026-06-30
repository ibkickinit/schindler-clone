// pg_pincushion_tb.v — self-checking regression for the radial (pincushion/barrel) warp stage.
// The load-bearing invariant: kx==ky==0 is a TRANSPARENT passthrough (o_sheet == i_sheet, just
// pipeline-delayed) -- "pincushion off must not disturb identity/corner-pin geometry". Also checks
// that a nonzero kx actually MOVES the coord (non-degenerate) and sheet_in/new_row are carried.
// Latency-agnostic queue compare. Prints "PG_PINCUSHION: PASS"/"FAIL (n)".
`timescale 1ns/1ps
`default_nettype none
module pg_pincushion_tb;
  localparam FB=20, AW=44, KPW=32;
  reg clk=0,rstn=0,pen=1,i_valid=0,i_sheet_in=0,i_new_row=0;
  reg signed [AW-1:0] i_sx=0,i_sy=0; reg signed [KPW-1:0] kx=0,ky=0;
  reg [11:0] cx=12'd960, cy=12'd540;
  wire ov,osi,onr; wire signed [AW-1:0] osx,osy;
  pg_pincushion #(.FB(FB),.AW(AW)) dut(
    .clk(clk),.rstn(rstn),.pen(pen),.i_valid(i_valid),.i_sheet_x(i_sx),.i_sheet_y(i_sy),
    .i_sheet_in(i_sheet_in),.i_new_row(i_new_row),.kx(kx),.ky(ky),.cx(cx),.cy(cy),
    .o_valid(ov),.o_sheet_x(osx),.o_sheet_y(osy),.o_sheet_in(osi),.o_new_row(onr));
  always #5 clk=~clk;

  // expected-output queue for the TRANSPARENT case (kx=ky=0 -> out==in)
  reg signed [AW-1:0] qx[0:65535],qy[0:65535]; reg qsi[0:65535],qnr[0:65535];
  integer wr=0,rd=0,errors=0,moved=0,i;
  reg checking_passthrough;
  always @(posedge clk) if(rstn && pen && i_valid && checking_passthrough) begin
    qx[wr]=i_sx; qy[wr]=i_sy; qsi[wr]=i_sheet_in; qnr[wr]=i_new_row; wr=wr+1;
  end
  always @(posedge clk) if(rstn && pen && ov && checking_passthrough) begin
    if(osx!==qx[rd] || osy!==qy[rd] || osi!==qsi[rd] || onr!==qnr[rd]) begin
      errors=errors+1;
      if(errors<=8) $display("  FAIL passthrough %0d: x %h/%h y %h/%h si %b/%b",rd,osx,qx[rd],osy,qy[rd],osi,qsi[rd]);
    end
    rd=rd+1;
  end

  initial begin
    // ---- phase 1: TRANSPARENT (kx=ky=0) -> out must equal in ----
    checking_passthrough=1; kx=0; ky=0;
    rstn=0; repeat(4)@(posedge clk); rstn=1;
    for(i=0;i<6000;i=i+1) begin @(posedge clk);
      i_valid=$random; pen=(($random%4)!=0); i_sheet_in=$random; i_new_row=$random;
      i_sx={$random,$random}; i_sy={$random,$random};
    end
    i_valid=0; pen=1; repeat(20)@(posedge clk);

    // ---- phase 2: NONZERO kx -> the coord must actually change at a MID-frame point ----
    // (displacement vanishes at centre AND at the corner radius r2max; pick (480,270)px = a
    // genuine interior point where gx/gy are non-zero.)
    checking_passthrough=0; kx=32'sd5000000; ky=32'sd5000000;
    rstn=0; repeat(4)@(posedge clk); rstn=1;
    i_sx=44'sd480 <<< FB; i_sy=44'sd270 <<< FB; i_sheet_in=1'b1;
    for(i=0;i<40;i=i+1) begin @(posedge clk); i_valid=1'b1;
      if(ov && (osx!==(44'sd480<<<FB) || osy!==(44'sd270<<<FB))) moved=1; end
    i_valid=0; repeat(10)@(posedge clk);

    $display("PG_PINCUSHION: %s  (passthrough-err=%0d, warp-moved=%0d)",
             (errors==0 && moved==1)?"PASS":"FAIL", errors, moved);
    $finish;
  end
endmodule
`default_nettype wire
