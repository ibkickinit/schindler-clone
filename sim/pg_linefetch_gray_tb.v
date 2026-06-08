// pg_linefetch_gray_tb.v — gray-gradient chroma probe for the packed-beat line fetch.
//
// Drives the CURRENT pg_linefetch (64-bit beat fill interface) at production
// geometry (IN_W=1920 master). DDR holds a pure-GRAY horizontal gradient:
// every pixel has R==B==G==grad(col). The read side is then swept across ALL
// source columns 0..LINE_W-1 and we flag any column whose extracted pixel is
// NOT gray (R!=B!=G) — that is a byte-misalignment / window defect, since a
// gray input can ONLY come out chromatic if the fetch reads bytes from the
// wrong place.
//
// Byte order: pipeline tdata[23:16]=R, [15:8]=B, [7:0]=G. In DDR the pixel's
// 3 bytes at offset o are {byte o = G, o+1 = B, o+2 = R}. For a gray pixel all
// three are equal, so a correct fetch is always gray out.

`default_nettype none
`timescale 1ns / 1ps

module pg_linefetch_gray_tb;
    localparam integer LINE_W = 1920;          // master width (1920->1280 downscale source)
    localparam integer STRIDE = LINE_W*3;      // 5760
    localparam integer NBUF   = 5;
    localparam [31:0]  FRAME_BASE = 32'h1000_0000;

    reg clk = 1'b0; always #5 clk = ~clk;
    reg rstn;

    reg         pf_req, blend_en, flush;
    reg  [11:0] pf_row, rd_row, rd_col;
    reg  [31:0] base2;
    wire [23:0] rd_data, rd_data2, rd_data_h1, rd_data2_h1;
    wire        rd_resident;
    wire        fetch_req;
    wire [31:0] fetch_addr;
    wire [11:0] fetch_len;
    reg  [63:0] beat_data;
    reg         beat_valid, beat_last;
    wire        beat_ready, busy;
    wire [3:0]  dbg_fill_sel, dbg_rd_sel; wire dbg_have_row;

    pg_linefetch #(.LINE_W(LINE_W), .STRIDE(STRIDE), .NBUF(NBUF)) dut (
        .clk(clk), .rstn(rstn),
        .frame_base_addr(FRAME_BASE), .frame_base_addr2(base2), .blend_en(blend_en),
        .pf_req(pf_req), .pf_row(pf_row), .flush(flush),
        .rd_row(rd_row), .rd_col(rd_col),
        .rd_data(rd_data), .rd_data2(rd_data2),
        .rd_data_h1(rd_data_h1), .rd_data2_h1(rd_data2_h1), .rd_resident(rd_resident),
        .fetch_req(fetch_req), .fetch_addr(fetch_addr), .fetch_len(fetch_len),
        .beat_data(beat_data), .beat_valid(beat_valid), .beat_ready(beat_ready), .beat_last(beat_last),
        .busy(busy),
        .dbg_fill_sel(dbg_fill_sel), .dbg_rd_sel(dbg_rd_sel), .dbg_have_row(dbg_have_row)
    );

    // ---- pure-gray gradient: every pixel R==B==G==grad(col) ----
    function [7:0] grad; input integer c; grad = (c * 131 + 7) & 8'hFF; endfunction
    // DDR byte at line-relative offset off: pixel = off/3, channel byte = off%3.
    // All three channel bytes equal grad(pixel) (gray), so byte value depends ONLY
    // on the pixel index — any cross-pixel bleed shows as R!=B!=G.
    function [7:0] dbyte; input integer off; integer p; begin
        p = off/3; dbyte = grad(p);
    end endfunction

    integer errors, chroma_cols;
    integer last_bad;

    // ---- behavioral DataMover: on fetch cmd, stream ceil(len*3/8) 64-bit beats ----
    // Clean AXI-master model: tracks dm_byte = byte offset of the beat CURRENTLY
    // presented. On accept, advance to next beat. To model a stall, deassert
    // tvalid for one cycle WITHOUT advancing (data held stable, AXI-legal). No
    // beat is ever repeated or skipped.
    integer dm_state, dm_byte, dm_btt, bb, dm_bcnt; reg dm_stall;
    integer GAPN = 64;
    localparam DM_IDLE=0, DM_STREAM=1;
    task present_cur; begin
        for (bb=0; bb<8; bb=bb+1)
            beat_data[bb*8 +: 8] <= (dm_byte+bb < dm_btt) ? dbyte(dm_byte+bb) : 8'd0;
        beat_valid <= 1'b1;
        beat_last  <= (dm_byte+8 >= dm_btt);
    end endtask
    always @(posedge clk) begin
        if (!rstn) begin dm_state<=DM_IDLE; beat_valid<=0; beat_last<=0; dm_stall<=0; end
        else begin
            case (dm_state)
                DM_IDLE: begin
                    beat_valid<=0; beat_last<=0; dm_stall<=0;
                    if (fetch_req) begin
                        dm_btt = fetch_len*3; dm_byte = 0; dm_bcnt=0; dm_state<=DM_STREAM;
                        present_cur;   // present beat 0 next cycle
                    end
                end
                DM_STREAM: begin
                    if (dm_stall) begin
                        dm_stall <= 1'b0; present_cur;       // resume: re-present the SAME (unaccepted) beat
                    end else if (beat_valid && beat_ready) begin
                        dm_byte  = dm_byte + 8; dm_bcnt = dm_bcnt + 1;
                        if (dm_byte >= dm_btt) begin
                            beat_valid<=0; beat_last<=0; dm_state<=DM_IDLE;
                        end else if ((dm_bcnt % GAPN)==0) begin
                            beat_valid<=0; dm_stall<=1;      // stall: drop tvalid, hold next beat back 1 cyc
                        end else begin
                            present_cur;
                        end
                    end
                end
            endcase
        end
    end

    task fetch_row; input [11:0] r; begin
        @(posedge clk); pf_req<=1; pf_row<=r;
        @(posedge clk); pf_req<=0;
        wait (busy); wait (!busy); @(posedge clk);
    end endtask

    // sweep every source column, check grayness (R==B==G). rd_data valid 1 cyc after rd_col.
    task sweep_check; input [11:0] r; integer c; reg [11:0] pcol; reg first; reg [7:0] R,B,G; begin
        rd_row = r; first = 1; #1;
        if (!rd_resident) begin $display("  ERR row %0d not resident", r); errors=errors+1; end
        for (c=0; c<LINE_W; c=c+1) begin
            rd_col <= c[11:0];
            @(posedge clk);
            if (!first) begin
                R = rd_data[23:16]; B = rd_data[15:8]; G = rd_data[7:0];
                if (!((R==B) && (B==G))) begin
                    chroma_cols = chroma_cols + 1;
                    last_bad = pcol;
                    if (chroma_cols <= 40)
                        $display("  CHROMA col %0d: R=%0d B=%0d G=%0d  (gray expected %0d)",
                                 pcol, R, B, G, grad(pcol));
                    errors = errors + 1;
                end else if (G !== grad(pcol)) begin
                    // gray but wrong value = a different (value) defect; report separately
                    if (errors < 60) $display("  VALERR col %0d: got %0d expected %0d", pcol, G, grad(pcol));
                    errors = errors + 1;
                end
            end
            pcol = c[11:0]; first = 0;
        end
        @(posedge clk);
        R = rd_data[23:16]; B = rd_data[15:8]; G = rd_data[7:0];
        if (!((R==B)&&(B==G))) begin chroma_cols=chroma_cols+1; last_bad=pcol; errors=errors+1;
            if (chroma_cols<=40) $display("  CHROMA col %0d (last): R=%0d B=%0d G=%0d", pcol,R,B,G); end
    end endtask

    initial begin
        errors=0; chroma_cols=0; last_bad=-1;
        rstn=0; pf_req=0; pf_row=0; rd_row=12'hFFF; rd_col=0;
        blend_en=0; flush=0; base2=32'h2000_0000;
        repeat(5)@(posedge clk); rstn=1; repeat(3)@(posedge clk);

        fetch_row(0);
        fetch_row(1);
        fetch_row(2);
        sweep_check(0);
        // interleave rows to force rd_sel to switch buffers between consecutive reads
        rd_row=1; rd_col<=10; @(posedge clk);
        rd_row=2; rd_col<=11; @(posedge clk);
        rd_row=0; rd_col<=12; @(posedge clk);
        sweep_check(1);
        sweep_check(2);

        $display("=================================");
        $display("chroma columns (R!=B!=G) = %0d", chroma_cols);
        $display("Total errors = %0d", errors);
        $display("=================================");
        $finish;
    end
    initial begin #50_000_000; $display("TIMEOUT errors=%0d chroma=%0d",errors,chroma_cols); $finish; end
endmodule

`default_nettype wire
