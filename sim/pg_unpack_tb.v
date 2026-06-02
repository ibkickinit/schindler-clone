// pg_unpack_tb.v — self-checking TB for the 64b→24b pixel gearbox.
//
// Packs pixels as DDR bytes [G,B,R] (ascending address) into 64-bit little-endian
// beats, streams them (with backpressure + gaps), and checks the reconstructed
// 24-bit pixels equal the originals and p_last fires on the line_px-th pixel.
//
// Pass criterion: "Total errors = 0".  Run: make sim-pg.

`default_nettype none
`timescale 1ns / 1ps

module pg_unpack_tb;
    localparam integer LINE_PX = 20;
    localparam integer NLINES  = 2;
    localparam integer NBYTES  = 3*LINE_PX*NLINES;     // 120, multiple of 8
    localparam integer NBEATS  = NBYTES/8;             // 15

    reg clk = 1'b0; always #5 clk = ~clk;
    reg rstn;

    reg  [11:0] line_px;
    reg  [63:0] s_tdata; reg s_tvalid; wire s_tready;
    wire        p_valid; wire [23:0] p_data; wire p_last;

    pg_unpack dut (.clk(clk), .rstn(rstn), .line_px(line_px),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready),
        .p_valid(p_valid), .p_data(p_data), .p_last(p_last));

    function [23:0] gpix; input integer line, col; gpix = (line*100000 + col*37 + 9) & 24'hFFFFFF; endfunction

    // byte memory: byte[3*(line*LINE_PX+col)+0]=G, +1=B, +2=R
    reg [7:0] bytes [0:NBYTES-1];
    integer L, C, base, errors;
    reg [23:0] pv;
    initial begin
        for (L=0; L<NLINES; L=L+1)
            for (C=0; C<LINE_PX; C=C+1) begin
                pv = gpix(L,C);
                base = 3*(L*LINE_PX + C);
                bytes[base+0] = pv[7:0];    // G
                bytes[base+1] = pv[15:8];   // B
                bytes[base+2] = pv[23:16];  // R
            end
    end

    // checker
    integer oline, ocol;
    always @(posedge clk) begin
        if (rstn && p_valid) begin
            if (p_data !== gpix(oline, ocol)) begin
                if (errors<25) $display("  ERR pixel (line %0d col %0d): dut=%h gold=%h",
                                        oline, ocol, p_data, gpix(oline,ocol));
                errors = errors + 1;
            end
            if ((ocol==LINE_PX-1) !== p_last) begin
                if (errors<25) $display("  ERR p_last @ (line %0d col %0d): dut=%b",
                                        oline, ocol, p_last);
                errors = errors + 1;
            end
            if (ocol==LINE_PX-1) begin ocol=0; oline=oline+1; end else ocol=ocol+1;
        end
    end

    integer b, k; reg [63:0] beat;
    function [63:0] mkbeat; input integer idx; integer bb; begin
        mkbeat = 64'd0;
        for (bb=0; bb<8; bb=bb+1) mkbeat[bb*8 +: 8] = bytes[idx*8 + bb];
    end endfunction

    initial begin
        errors=0; oline=0; ocol=0;
        rstn=0; s_tvalid=0; s_tdata=0; line_px=LINE_PX;
        repeat(5) @(posedge clk); rstn=1; repeat(2) @(posedge clk);

        // standard AXIS master: hold valid, advance data only on accepted transfer
        k = 0; s_tdata <= mkbeat(0); s_tvalid <= 1'b1;
        while (k < NBEATS) begin
            @(posedge clk);
            if (s_tvalid && s_tready) begin     // transfer accepted this edge
                k = k + 1;
                if (k < NBEATS) s_tdata <= mkbeat(k);
                else            s_tvalid <= 1'b0;
            end
        end
        repeat(20) @(posedge clk);   // drain

        $display("=================================");
        $display("Total errors = %0d", errors);
        $display("seen lines=%0d (expect %0d)", oline, NLINES);
        $display("=================================");
        if (oline != NLINES) errors = errors + 1;
        $finish;
    end

    initial begin #5_000_000; $display("TIMEOUT Total errors=%0d", errors); $finish; end
endmodule

`default_nettype wire
