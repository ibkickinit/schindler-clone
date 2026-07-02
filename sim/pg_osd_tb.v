`timescale 1ns/1ps
`default_nettype none
module pg_osd_tb;  // OSD output-side compositor: passthrough / box-bg / glyph-render
  localparam H_TOT=200,H_ACT=160,V_TOT=120,V_ACT=100;
  reg clk=0,rstn=0,osd_en=0; reg [23:0] vin=24'h808080; reg [19:0] ld=0;
  wire [23:0] vout; wire ao,ho,vo;
  reg [11:0] h=0,v=0;
  always #5 clk=~clk;
  always @(posedge clk) begin if(h==H_TOT-1)begin h<=0; v<=(v==V_TOT-1)?0:v+1; end else h<=h+1; end
  wire active=(h<H_ACT)&&(v<V_ACT);
  wire hsync =(h>=H_ACT+4)&&(h<H_ACT+12);
  wire vsync =(v>=V_ACT+2)&&(v<V_ACT+4);
  // small OSD: 4 cols x 2 rows, box at (16,8), 16x32 cells -> hc[16,80) vc[8,72)
  pg_osd #(.COLS(4),.ROWS(2),.X0(16),.Y0(8),.CW(16),.CH(32)) dut(
    .clk(clk),.rstn(rstn),.osd_en(osd_en),.vid_in(vin),
    .vid_active(active),.vid_hsync(hsync),.vid_vsync(vsync),.osd_load(ld),
    .vid_out(vout),.vid_active_o(ao),.vid_hsync_o(ho),.vid_vsync_o(vo));
  integer gray,blk,wht,off_nongray,i,osd_fail; initial osd_fail=0;
  task scanframe(output integer g,output integer bk,output integer wh,output integer ong); begin
    g=0;bk=0;wh=0;ong=0;
    // scan ~1.2 frames to be safe
    for(i=0;i<H_TOT*V_TOT+H_TOT;i=i+1) begin @(posedge clk);
      if(ao) begin
        // in-box (using OUTPUT-aligned pos ~ dut.hc/vc delayed; classify by color)
        if(vout==24'h808080) g=g+1;
        else if(vout==24'h000000) bk=bk+1;
        else if(vout==24'hffffff) wh=wh+1;
      end
    end
  end endtask
  task setcell(input [9:0] a,input inv,input [7:0] c); begin
    @(posedge clk); ld[18]=inv; ld[17:8]=a; ld[7:0]=c; @(posedge clk); ld[19]=~ld[19]; repeat(3)@(posedge clk); end endtask
  initial begin
    rstn=0; repeat(4)@(posedge clk); rstn=1; repeat(V_TOT)@(posedge clk);
    // (1) osd_en=0 -> passthrough: all active pixels gray, no black/white
    osd_en=0; scanframe(gray,blk,wht,off_nongray);
    $display("EN=0: gray=%0d black=%0d white=%0d %s",gray,blk,wht,(blk==0&&wht==0&&gray>0)?"PASS":"FAIL"); if(!(blk==0&&wht==0&&gray>0)) osd_fail=osd_fail+1;
    // (2) osd_en=1, all spaces -> box shows black bg, outside gray
    osd_en=1; scanframe(gray,blk,wht,off_nongray);
    $display("EN=1 spaces: gray=%0d black=%0d white=%0d %s",gray,blk,wht,(blk>0&&gray>0)?"PASS(box=black bg)":"FAIL"); if(!(blk>0&&gray>0)) osd_fail=osd_fail+1;
    // (3) load 'A' into cell 0 -> white glyph pixels appear
    setcell(10'd0,1'b0,"A"); scanframe(gray,blk,wht,off_nongray);
    $display("EN=1 'A'@cell0: gray=%0d black=%0d white=%0d %s",gray,blk,wht,(wht>0)?"PASS(glyph rendered)":"FAIL"); if(!(wht>0)) osd_fail=osd_fail+1;
    $display("PG_OSD: %s", (osd_fail==0)?"PASS":"FAIL");
    $finish;
  end
endmodule
`default_nettype wire
