// pg_place_affine_tb.v — self-checking regression for the STAGE-2 placement affine.
// Guards the A1/A2 pipeline-split (2026-06-29 warp-margin recovery): drives random sheet
// coords through the engine and checks the LOD-coordinate outputs (o_lod_col/o_lod_row +
// the H/V fractions) against a computed golden of the affine math xl = (a*sx+b*sy)>>FB + c.
// Latency-agnostic: golden(input) is queued as each valid input is accepted, popped+compared
// on each o_valid. Prints "PG_PLACE: PASS"/"FAIL (n)".
`timescale 1ns/1ps
`default_nettype none
module pg_place_affine_tb;
  localparam CW=32, FB=20, AW=44, PW=AW+CW;
  reg clk=0,rstn=0,pen=1,i_valid=0,i_sheet_in=0,i_new_row=0;
  reg signed [AW-1:0] i_sx=0,i_sy=0;
  reg signed [CW-1:0] a2,b2,c2,d2,e2,f2;
  reg [11:0] inw,inh;
  wire ov,osi,oli,onr; wire [11:0] oc,orr,ofx,ofy; wire [7:0] oal;
  pg_place_affine #(.CW(CW),.FB(FB),.AW(AW)) dut(
    .clk(clk),.rstn(rstn),.pen(pen),.i_valid(i_valid),.i_sheet_x(i_sx),.i_sheet_y(i_sy),
    .i_sheet_in(i_sheet_in),.i_new_row(i_new_row),.a2(a2),.b2(b2),.c2(c2),.d2(d2),.e2(e2),.f2(f2),
    .in_w_rt(inw),.in_h_rt(inh),.o_valid(ov),.o_lod_col(oc),.o_lod_row(orr),.o_h_frac(ofx),.o_v_frac(ofy),
    .o_sheet_in(osi),.o_lod_in(oli),.o_alpha(oal),.o_new_row(onr));
  always #5 clk=~clk;

  // golden: xl = ((a*sx + b*sy) >>> FB) + c ; col = xl[FB+:12], frac = xl[FB-1-:12]
  function [11:0] gcol(input signed [AW-1:0] sx, input signed [AW-1:0] sy,
                       input signed [CW-1:0] a, input signed [CW-1:0] b, input signed [CW-1:0] c);
    reg signed [PW-1:0] s; reg signed [AW-1:0] xl;
    begin s = a*sx + b*sy; xl = (s >>> FB) + c; gcol = xl[FB +: 12]; end
  endfunction
  function [11:0] gfrac(input signed [AW-1:0] sx, input signed [AW-1:0] sy,
                        input signed [CW-1:0] a, input signed [CW-1:0] b, input signed [CW-1:0] c);
    reg signed [PW-1:0] s; reg signed [AW-1:0] xl;
    begin s = a*sx + b*sy; xl = (s >>> FB) + c; gfrac = xl[FB-1 -: 12]; end
  endfunction

  // expected-output queue (one entry per accepted valid input)
  reg [11:0] qc[0:65535],qr[0:65535],qfx[0:65535],qfy[0:65535]; reg qsi[0:65535];
  integer wr=0, rd=0, errors=0, i;
  always @(posedge clk) if(rstn && pen && i_valid) begin
    qc[wr]=gcol(i_sx,i_sy,a2,b2,c2); qr[wr]=gcol(i_sx,i_sy,d2,e2,f2);
    qfx[wr]=gfrac(i_sx,i_sy,a2,b2,c2); qfy[wr]=gfrac(i_sx,i_sy,d2,e2,f2);
    qsi[wr]=i_sheet_in; wr=wr+1;
  end
  always @(posedge clk) if(rstn && pen && ov) begin
    if(oc!==qc[rd] || orr!==qr[rd] || ofx!==qfx[rd] || ofy!==qfy[rd] || osi!==qsi[rd]) begin
      errors=errors+1;
      if(errors<=8) $display("  FAIL out %0d: col %h/%h row %h/%h fx %h/%h fy %h/%h si %b/%b",
        rd,oc,qc[rd],orr,qr[rd],ofx,qfx[rd],ofy,qfy[rd],osi,qsi[rd]);
    end
    rd=rd+1;
  end

  initial begin
    a2=32'sd1100000; b2=-32'sd45000; c2=32'sd33000; d2=32'sd52000; e2=32'sd1080000; f2=-32'sd21000;
    inw=12'd1280; inh=12'd720;
    rstn=0; repeat(4)@(posedge clk); rstn=1;
    for(i=0;i<8000;i=i+1) begin @(posedge clk);
      i_valid=$random; pen=(($random%4)!=0); i_sheet_in=$random; i_new_row=$random;
      i_sx={$random,$random}; i_sy={$random,$random};
    end
    i_valid=0; pen=1; repeat(20)@(posedge clk);
    $display("PG_PLACE: %s (%0d)  [%0d outputs checked]", (errors==0)?"PASS":"FAIL", errors, rd);
    $finish;
  end
endmodule
`default_nettype wire
