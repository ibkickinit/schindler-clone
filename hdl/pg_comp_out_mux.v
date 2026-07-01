// pg_comp_out_mux.v — runtime-selectable composite-encode / raw-bypass output stage.
//
// Per the dual-engine requirement: pg_composite_out is a per-engine OUTPUT OPTION,
// not hard-wired. This thin wrapper instantiates the clean pg_composite_out encoder
// AND a raw bypass path, and a runtime GPIO bit (comp_enable) selects which one
// drives the 8-bit R-2R ladder pins:
//   comp_enable = 1  -> composite-encoded luma+sync (analog/scope target)
//   comp_enable = 0  -> raw 8-bit channel (RGB/HDMI-style target takes it straight)
// Drop this block on ANY engine's raster output to make the composite encode optional.
//
// brightness + comp_enable are quasi-static AXI-GPIO controls in the FCLK_CLK0 domain;
// they are 2-FF synchronized into this pixel-clock domain here (false-paths in XDC).
// The raw bypass uses the pipeline's G byte (pipeline carries pixels as
// tdata[23:16]=R,[15:8]=B,[7:0]=G — see schindler_pipeline_rbg_byte_order), gated to
// the active window so blanking reads 0.

`default_nettype none
`timescale 1ns / 1ps

module pg_comp_out_mux #(
    parameter [7:0] BLANK_LVL = 8'd72
) (
    input  wire        clk, rstn,
    // raster from axis_to_vid_io (this pixel-clock domain)
    input  wire [23:0] vid_rgb,
    input  wire        vid_active,
    input  wire        vid_hsync,
    input  wire        vid_vsync,
    // runtime control (AXI GPIO, FCLK_CLK0 — async, quasi-static)
    input  wire [15:0] brightness_async,    // Q8.8 luma gain, 0x0100 = 1.0
    input  wire        comp_enable_async,   // 1 = composite-encoded, 0 = raw bypass
    input  wire        chroma_en_async,     // 1 = add NTSC color (stage 2); 0 = mono luma (stage 1)
    // sample to the external R-2R ladder pins
    output reg  [7:0]  comp,
    output wire        comp_blank,
    output wire        burst_window
);
    // ---- 2-FF CDC of the quasi-static controls into this clock domain ----
    (* ASYNC_REG = "TRUE" *) reg [15:0] br_q1, br_q2;
    (* ASYNC_REG = "TRUE" *) reg        ce_q1, ce_q2;
    (* ASYNC_REG = "TRUE" *) reg        ck_q1, ck_q2;
    always @(posedge clk) begin
        if (!rstn) begin
            br_q1 <= 16'h0100; br_q2 <= 16'h0100; ce_q1 <= 1'b1; ce_q2 <= 1'b1; ck_q1 <= 1'b0; ck_q2 <= 1'b0;
        end else begin
            br_q1 <= brightness_async; br_q2 <= br_q1;
            ce_q1 <= comp_enable_async; ce_q2 <= ce_q1;
            ck_q1 <= chroma_en_async;   ck_q2 <= ck_q1;
        end
    end

    // ---- composite encoder (clean reusable module) ----
    wire [7:0] comp_enc;
    pg_composite_out #(.BLANK_LVL(BLANK_LVL)) u_enc (
        .clk(clk), .rstn(rstn),
        .vid_rgb(vid_rgb),
        .vid_active(vid_active), .vid_hsync(vid_hsync), .vid_vsync(vid_vsync),
        .brightness(br_q2), .chroma_en(ck_q2),
        .comp(comp_enc), .comp_blank(comp_blank), .burst_window(burst_window)
    );

    // ---- raw bypass = G channel ([7:0]), active-gated ----
    wire [7:0] raw = vid_active ? vid_rgb[7:0] : 8'd0;

    always @(posedge clk) begin
        if (!rstn) comp <= 8'd0;
        else       comp <= ce_q2 ? comp_enc : raw;
    end
endmodule

`default_nettype wire
