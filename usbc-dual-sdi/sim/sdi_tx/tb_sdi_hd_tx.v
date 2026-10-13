// tb_sdi_hd_tx.v — self-checking testbench for sdi_hd_tx_top (HD-SDI datapath).
//
// The checker is written independently of the DUT. It undoes NRZI and the scrambler bit by bit, splits C/Y
// words, then parses the stream like a receiver and checks:
//   * TRS: 3FF 000 000 XYZ in both streams, identical XYZ, valid protection bits, F = 0
//   * EAV spacing = H_TOT words; active span between SAV and EAV = H_ACT words
//   * LN0/LN1 format; line numbers increment 1..V_TOT and wrap
//   * V bit: EAV and the SAV before a line's active video both match that line's blanking state
//   * CRC-18 per stream, computed with an MSB-first polynomial division (a different formulation from the
//     DUT's reflected LFSR), over active video + EAV + LN0 + LN1
//   * active video = 75% bars on active lines, 0x040/0x200 on blanking lines
// Define SMALL for a tiny raster (fast); default is full 1080p30. Define INJECT to flip one bit on the
// wire — the run script expects that run to FAIL, proving the checker can catch errors.

`timescale 1ns / 1ps

module tb_sdi_hd_tx;
`ifdef SMALL
    localparam integer H_ACT = 32, H_TOT = 48, V_TOT = 12, V_FIRST = 4, V_LAST = 9;
    localparam integer FRAMES = 3;
`else
    localparam integer H_ACT = 1920, H_TOT = 2200, V_TOT = 1125, V_FIRST = 42, V_LAST = 1121;
    localparam integer FRAMES = 1;
`endif

    reg clk = 1'b0, rst = 1'b1;
    always #6.734 clk = ~clk;              // ~74.25 MHz

    wire [19:0] txdata;
    wire [9:0]  dbg_y, dbg_c;
    wire [11:0] dbg_h;
    wire [10:0] dbg_ln;

    sdi_hd_tx_top #(.H_ACT(H_ACT), .H_TOT(H_TOT), .V_TOT(V_TOT),
                    .V_ACT_FIRST(V_FIRST), .V_ACT_LAST(V_LAST)) dut (
        .clk(clk), .rst(rst), .txdata(txdata),
        .dbg_y(dbg_y), .dbg_c(dbg_c), .dbg_h(dbg_h), .dbg_ln(dbg_ln));

    // ---------------- independent reference functions ----------------
    function exp_vblank;
        input integer line;
        exp_vblank = (line < V_FIRST) || (line > V_LAST);
    endfunction

    // 75% bars, written as a table lookup by bar edge (independent of the DUT's divide)
    function [9:0] exp_y;
        input integer s;
        integer b;
        begin
            b = 0;
            while (b < 7 && s >= ((b + 1) * H_ACT) / 8) b = b + 1;
            case (b)
                0: exp_y = 721; 1: exp_y = 674; 2: exp_y = 581; 3: exp_y = 534;
                4: exp_y = 251; 5: exp_y = 204; 6: exp_y = 111; default: exp_y = 64;
            endcase
        end
    endfunction

    function [9:0] exp_c;
        input integer s;
        integer b;
        reg [9:0] cb, cr;
        begin
            b = 0;
            while (b < 7 && s >= ((b + 1) * H_ACT) / 8) b = b + 1;
            case (b)
                0: begin cb = 512; cr = 512; end  1: begin cb = 176; cr = 543; end
                2: begin cb = 589; cr = 176; end  3: begin cb = 253; cr = 207; end
                4: begin cb = 771; cr = 817; end  5: begin cb = 435; cr = 848; end
                6: begin cb = 848; cr = 481; end  default: begin cb = 512; cr = 512; end
            endcase
            exp_c = (s % 2) ? cr : cb;
        end
    endfunction

    // MSB-first CRC-18 division: r[17] = coefficient of x^17 = first CRC bit on the wire (C0)
    function [17:0] crc_feed;
        input [17:0] r_in;
        input [9:0]  w;
        integer i;
        reg [17:0] r;
        reg fb;
        begin
            r = r_in;
            for (i = 0; i < 10; i = i + 1) begin
                fb = w[i] ^ r[17];
                r  = {r[16:0], 1'b0};
                if (fb) r = r ^ 18'h00031;   // x^5 + x^4 + 1
            end
            crc_feed = r;
        end
    endfunction

    function [9:0] crc_word;                 // CR0 (hi = 0) or CR1 (hi = 1) from an MSB-first remainder
        input [17:0] r;
        input        hi;
        integer k;
        reg [8:0] cbits;
        begin
            for (k = 0; k < 9; k = k + 1) cbits[k] = r[17 - (hi ? k + 9 : k)];
            crc_word = {~cbits[8], cbits};
        end
    endfunction

    function xyz_ok;
        input [9:0] x;
        reg f, v, hh;
        begin
            f = x[8]; v = x[7]; hh = x[6];
            xyz_ok = x[9] && (x[1:0] == 2'b00) &&
                     (x[5] == (v ^ hh)) && (x[4] == (f ^ hh)) &&
                     (x[3] == (f ^ v))  && (x[2] == (f ^ v ^ hh));
        end
    endfunction

    // ---------------- descrambler (bit-serial, LSB first) ----------------
    reg       q_prev;
    reg [8:0] s_hist;          // s_hist[k] = s[n-1-k]

    task descramble;
        input  [19:0] tx;
        output [19:0] d;
        integer i;
        reg s;
        begin
            for (i = 0; i < 20; i = i + 1) begin
                s      = tx[i] ^ q_prev;
                q_prev = tx[i];
                d[i]   = s ^ s_hist[3] ^ s_hist[8];
                s_hist = {s_hist[7:0], s};
            end
        end
    endtask

    // ---------------- receiver-style parser ----------------
    integer errors = 0, lines_checked = 0, frames_done = 0, words = 0;
    reg [9:0] y3, y2, y1, c3, c2, c1;      // previous words (y1 = most recent)
    integer   since_eav;                   // words since the last EAV's XYZ
    integer   act_idx;                     // index within the active span (-1 = not in active)
    integer   post_eav;                    // 0 = idle, 1 = expect LN0, 2 = LN1, 3 = CR0, 4 = CR1
    reg       have_eav, have_sav, eav_v, sav_v;
    integer   prev_ln, cur_ln;
    reg [9:0] ln0_w;
    reg [17:0] ry, rc;
    reg [9:0] act_y [0:H_ACT-1];
    reg [9:0] act_c [0:H_ACT-1];
    integer   k, act_count, line_bad;

    task err;
        input [8*64-1:0] msg;
        begin
            errors = errors + 1;
            if (errors <= 20) $display("ERROR @word %0d: %0s", words, msg);
        end
    endtask

    task check_line_video;
        input integer line;
        begin
            line_bad = 0;
            for (k = 0; k < H_ACT; k = k + 1) begin
                if (exp_vblank(line)) begin
                    if (act_y[k] !== 10'h040 || act_c[k] !== 10'h200) line_bad = line_bad + 1;
                end else begin
                    if (act_y[k] !== exp_y(k) || act_c[k] !== exp_c(k)) line_bad = line_bad + 1;
                end
            end
            if (line_bad) err("active video mismatch");
        end
    endtask

    task parse_word;
        input [9:0] y, c;
        begin
            words = words + 1;
            since_eav = since_eav + 1;

            // CRC accumulation runs from the first active word through LN1
            if (act_idx >= 0 || post_eav == 1 || post_eav == 2) begin
                ry = crc_feed(ry, y);
                rc = crc_feed(rc, c);
            end

            if (post_eav == 1) begin                        // LN0
                if (y !== c) err("LN0 differs between streams");
                if (y[9] !== ~y[8] || y[1:0] !== 2'b00) err("LN0 format");
                ln0_w = y;
                post_eav = 2;
            end else if (post_eav == 2) begin               // LN1
                if (y !== c) err("LN1 differs between streams");
                if (y[9] !== 1'b1 || y[8:6] !== 3'b000 || y[1:0] !== 2'b00) err("LN1 format");
                cur_ln = {y[5:2], ln0_w[8:2]};
                if (prev_ln > 0 && cur_ln !== ((prev_ln == V_TOT) ? 1 : prev_ln + 1)) err("line number sequence");
                if (eav_v !== exp_vblank(cur_ln)) err("EAV V bit");
                if (have_sav && sav_v !== exp_vblank(cur_ln)) err("SAV V bit");
                if (have_sav) begin
                    if (act_count != H_ACT) err("active span length");
                    check_line_video(cur_ln);
                    lines_checked = lines_checked + 1;
                end
                if (prev_ln == V_TOT && cur_ln == 1) frames_done = frames_done + 1;
                prev_ln = cur_ln;
                post_eav = 3;
            end else if (post_eav == 3) begin               // CR0
                if (have_sav) begin
                    if (y !== crc_word(ry, 1'b0)) err("Y CR0");
                    if (c !== crc_word(rc, 1'b0)) err("C CR0");
                end
                post_eav = 4;
            end else if (post_eav == 4) begin               // CR1
                if (have_sav) begin
                    if (y !== crc_word(ry, 1'b1)) err("Y CR1");
                    if (c !== crc_word(rc, 1'b1)) err("C CR1");
                end
                post_eav = 0;
            end

            // TRS detection: 3FF 000 000 then XYZ (this word)
            if (y3 == 10'h3FF && y2 == 10'h000 && y1 == 10'h000) begin
                if (!(c3 == 10'h3FF && c2 == 10'h000 && c1 == 10'h000)) err("C stream TRS missing");
                if (c !== y) err("XYZ differs between streams");
                if (!xyz_ok(y)) err("XYZ protection bits");
                if (y[8] !== 1'b0) err("F bit set (progressive)");
                if (y[6]) begin                              // EAV
                    if (have_eav && since_eav != H_TOT) err("EAV spacing != H_TOT");
                    // EAV's 000 000 were captured as active words (its 3FF was not): subtract 2
                    act_count = (act_idx >= 0) ? act_idx - 2 : 0;
                    act_idx   = -1;
                    have_eav  = 1'b1;
                    eav_v     = y[7];
                    since_eav = 0;
                    post_eav  = 1;
                end else begin                               // SAV
                    have_sav = 1'b1;
                    sav_v    = y[7];
                    act_idx  = 0;
                    ry = 18'd0;
                    rc = 18'd0;
                end
            end else if (act_idx >= 0 && !(y == 10'h3FF)) begin
                if (act_idx < H_ACT) begin
                    act_y[act_idx] = y;
                    act_c[act_idx] = c;
                end
                act_idx = act_idx + 1;
            end
            y3 = y2; y2 = y1; y1 = y;
            c3 = c2; c2 = c1; c1 = c;
        end
    endtask

    // ---------------- drive + check ----------------
    reg [19:0] d, tx;
    integer cyc = 0;
    initial begin
        q_prev = 1'b0; s_hist = 9'd0;
        y1 = 0; y2 = 0; y3 = 0; c1 = 0; c2 = 0; c3 = 0;
        since_eav = 0; act_idx = -1; post_eav = 0; act_count = 0;
        have_eav = 1'b0; have_sav = 1'b0; eav_v = 1'b0; sav_v = 1'b0;
        prev_ln = 0; cur_ln = 0; ry = 0; rc = 0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            cyc = cyc + 1;
            tx  = txdata;
`ifdef INJECT
            if (cyc == (H_TOT * (V_FIRST + 1)) + 10) tx[3] = ~tx[3];   // one wire-bit error in an active line
`endif
            descramble(tx, d);
            if (cyc > 3) parse_word(d[19:10], d[9:0]);   // skip pipeline fill + descrambler sync
            if (frames_done >= FRAMES) begin
                $display("lines_checked=%0d frames=%0d words=%0d errors=%0d", lines_checked, frames_done, words, errors);
                if (errors == 0 && lines_checked >= FRAMES * V_TOT) $display("PASS");
                else                                                 $display("FAIL");
                $finish;
            end
        end
    end
endmodule
