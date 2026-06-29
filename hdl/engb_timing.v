// engb_timing.v — Engine-B free-running raster timing generator (dual-engine validation).
//
// Engine B has no VTC of its own (axi_ic_lite is full; a 2nd v_tc would need an
// AXI-Lite master port). This is a tiny self-contained progressive raster
// generator on Engine B's independent ~27 MHz PLL clock. It produces the strobes
// axis_to_vid_io expects (active_video / hsync / vsync / hblank / vblank, all
// active-HIGH) plus a frame_vsync level for pg_read_engine_top's out_vsync.
//
// Geometry defaults to a 1920x1080 active region inside a 2200x1125 frame so the
// active window EXACTLY matches Engine B's identity OUT_W x OUT_H — every emitted
// pixel lands in an active slot (clean 1:1 passthrough to the DAC). At ~27 MHz the
// frame rate is ~10.9 Hz; "wrong" NTSC timing is fine — this is a scope/bring-up aid.

`default_nettype none
`timescale 1ns / 1ps

module engb_timing #(
    parameter integer H_ACTIVE = 1920,
    parameter integer H_FP     = 88,
    parameter integer H_SYNC   = 44,
    parameter integer H_BP     = 148,   // H_TOTAL = 2200
    parameter integer V_ACTIVE = 1080,
    parameter integer V_FP     = 4,
    parameter integer V_SYNC   = 5,
    parameter integer V_BP     = 36     // V_TOTAL = 1125
) (
    input  wire        clk,
    input  wire        rstn,
    output reg         active_video,
    output reg         hsync,
    output reg         vsync,
    output reg         hblank,
    output reg         vblank,
    output reg         frame_vsync   // = vsync level, for pg_read_engine_top out_vsync
);
    localparam integer H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
    localparam integer V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

    reg [11:0] hc;   // 0..H_TOTAL-1 (<=4095)
    reg [11:0] vc;   // 0..V_TOTAL-1 (<=4095)
    always @(posedge clk) begin
        if (!rstn) begin
            hc <= 12'd0; vc <= 12'd0;
        end else if (hc == H_TOTAL-1) begin
            hc <= 12'd0;
            vc <= (vc == V_TOTAL-1) ? 12'd0 : (vc + 12'd1);
        end else begin
            hc <= hc + 12'd1;
        end
    end

    wire h_act    = (hc < H_ACTIVE);
    wire v_act    = (vc < V_ACTIVE);
    wire h_sync_w = (hc >= H_ACTIVE + H_FP) && (hc < H_ACTIVE + H_FP + H_SYNC);
    wire v_sync_w = (vc >= V_ACTIVE + V_FP) && (vc < V_ACTIVE + V_FP + V_SYNC);

    // Register all outputs (uniform 1-cycle latency, glitch-free edges).
    always @(posedge clk) begin
        if (!rstn) begin
            active_video <= 1'b0; hsync <= 1'b0; vsync <= 1'b0;
            hblank <= 1'b0; vblank <= 1'b0; frame_vsync <= 1'b0;
        end else begin
            active_video <= h_act && v_act;
            hsync        <= h_sync_w;
            vsync        <= v_sync_w;
            hblank       <= !h_act;
            vblank       <= !v_act;
            frame_vsync  <= v_sync_w;
        end
    end
endmodule

`default_nettype wire
