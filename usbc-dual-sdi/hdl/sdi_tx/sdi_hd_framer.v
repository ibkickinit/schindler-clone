// sdi_hd_framer.v — HD-SDI (SMPTE 292-1) word framer: TRS (EAV/SAV), line numbers, line CRC, blanking.
//
// Two 10-bit data streams per clock: Y (luma) and C (Cb/Cr interleaved, Cb on even h). Output order on
// the wire is C then Y per sample (see sdi_hd_tx_top). Registered outputs, 1 clock after h/ln.
//
// Per line (h from sdi_hd_timing, 0 = first active sample):
//   [0, H_ACT)          active video (clipped to 0x004..0x3FB) or blanking (Y 0x040 / C 0x200) in V blank
//   H_ACT .. +3         EAV  3FF 000 000 XYZ(H=1)      — F/V of THIS line (ln)
//   H_ACT+4, +5         LN0, LN1                       — line number ln (both streams)
//   H_ACT+6, +7         CR0, CR1                       — CRC-18 per stream over [0 .. H_ACT+5]
//   H_TOT-4 .. -1       SAV  3FF 000 000 XYZ(H=0)      — F/V of the NEXT line (ln+1, wraps)
//   elsewhere           horizontal blanking (no ancillary data yet; ST 352 / ST 299 come later)
//
// Line convention (to confirm on an analyzer — docs/12): line N = SAV, active(N), EAV(N), LN=N, CRC(N);
// i.e. LN after an EAV labels the active video that preceded it, and the CRC covers that active video
// plus the EAV and LN words.

`default_nettype none
`timescale 1ns / 1ps

module sdi_hd_framer #(
    parameter integer H_ACT       = 1920,
    parameter integer H_TOT       = 2200,
    parameter integer V_TOT       = 1125,
    parameter integer V_ACT_FIRST = 42,     // 1080p: active lines 42..1121; 720p: 26..745
    parameter integer V_ACT_LAST  = 1121
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [11:0] h,
    input  wire [10:0] ln,
    input  wire [9:0]  y_in,               // active video, valid for h < H_ACT in active lines
    input  wire [9:0]  c_in,
    output reg  [9:0]  y_out,
    output reg  [9:0]  c_out
);
    localparam [9:0] Y_BLANK = 10'h040;
    localparam [9:0] C_BLANK = 10'h200;
    localparam       F       = 1'b0;       // progressive

    // ---- helpers ----
    function vblank;                                    // 1 = vertical blanking line
        input [10:0] line;
        vblank = (line < V_ACT_FIRST) || (line > V_ACT_LAST);
    endfunction

    function [9:0] xyz;                                 // TRS status word with protection bits
        input f, v, hb;
        xyz = {1'b1, f, v, hb, v ^ hb, f ^ hb, f ^ v, f ^ v ^ hb, 2'b00};
    endfunction

    function [9:0] clip;                                // keep 0x000-0x003 / 0x3FC-0x3FF for TRS only
        input [9:0] x;
        clip = (x < 10'h004) ? 10'h004 : (x > 10'h3FB) ? 10'h3FB : x;
    endfunction

    wire [10:0] ln_next = (ln == V_TOT) ? 11'd1 : ln + 11'd1;
    wire        vb      = vblank(ln);
    wire        vb_next = vblank(ln_next);

    wire [9:0] ln0 = {~ln[6], ln[6:0], 2'b00};
    wire [9:0] ln1 = {1'b1, 3'b000, ln[10:7], 2'b00};

    reg  [17:0] crc_y, crc_c;
    wire [17:0] crc_y_nx, crc_c_nx;
    reg  [9:0]  y_w, c_w;

    // ---- word select (combinational) ----
    always @* begin
        if (h < H_ACT) begin
            y_w = vb ? Y_BLANK : clip(y_in);
            c_w = vb ? C_BLANK : clip(c_in);
        end else if (h == H_ACT)                       begin y_w = 10'h3FF;  c_w = 10'h3FF;  end
        else if (h == H_ACT + 1 || h == H_ACT + 2)     begin y_w = 10'h000;  c_w = 10'h000;  end
        else if (h == H_ACT + 3)                       begin y_w = xyz(F, vb, 1'b1); c_w = y_w; end
        else if (h == H_ACT + 4)                       begin y_w = ln0;      c_w = ln0;      end
        else if (h == H_ACT + 5)                       begin y_w = ln1;      c_w = ln1;      end
        else if (h == H_ACT + 6) begin
            y_w = {~crc_y[8],  crc_y[8:0]};
            c_w = {~crc_c[8],  crc_c[8:0]};
        end else if (h == H_ACT + 7) begin
            y_w = {~crc_y[17], crc_y[17:9]};
            c_w = {~crc_c[17], crc_c[17:9]};
        end
        else if (h == H_TOT - 4)                       begin y_w = 10'h3FF;  c_w = 10'h3FF;  end
        else if (h == H_TOT - 3 || h == H_TOT - 2)     begin y_w = 10'h000;  c_w = 10'h000;  end
        else if (h == H_TOT - 1)                       begin y_w = xyz(F, vb_next, 1'b0); c_w = y_w; end
        else                                           begin y_w = Y_BLANK;  c_w = C_BLANK;  end
    end

    // ---- line CRC: restart at h = 0, accumulate through LN1 (h = H_ACT+5), hold for CR0/CR1 ----
    sdi_crc18 u_crc_y (.crc_in(h == 0 ? 18'd0 : crc_y), .d(y_w), .crc_out(crc_y_nx));
    sdi_crc18 u_crc_c (.crc_in(h == 0 ? 18'd0 : crc_c), .d(c_w), .crc_out(crc_c_nx));

    always @(posedge clk) begin
        if (rst) begin
            y_out <= Y_BLANK;
            c_out <= C_BLANK;
            crc_y <= 18'd0;
            crc_c <= 18'd0;
        end else begin
            y_out <= y_w;
            c_out <= c_w;
            if (h <= H_ACT + 5) begin
                crc_y <= crc_y_nx;
                crc_c <= crc_c_nx;
            end
        end
    end
endmodule

`default_nettype wire
