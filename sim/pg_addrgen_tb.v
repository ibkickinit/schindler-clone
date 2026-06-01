// pg_addrgen_tb.v — self-checking TB for the present-geometry address generator.
//
// Sweeps the full OUT_W×OUT_H raster for several geometry cases and checks
// every emitted pixel against a floor() golden:
//   in_window  == (ox in [pos_x,pos_x+out_w)) && (oy in [pos_y,pos_y+out_h))
//   src_col    == floor((ox-pos_x) * IN_W / out_w)   [when in_window]
//   src_row    == floor((oy-pos_y) * IN_H / out_h)   [when in_window]
//
// Pass criterion: "Total errors = 0".  Run with: make sim-pg  (or xsim).

`default_nettype none
`timescale 1ns / 1ps

module pg_addrgen_tb;
    localparam integer OUT_W = 1280;
    localparam integer OUT_H = 720;
    localparam integer IN_W  = 1280;
    localparam integer IN_H  = 720;

    reg clk = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    reg         rstn;
    reg         sof, px_valid;
    reg  [11:0] out_w_win, out_h_win, pos_x, pos_y;
    reg  [11:0] h_step_int, h_step_frac, v_step_int, v_step_frac;

    wire        o_valid, o_in_window, o_new_row;
    wire [11:0] o_src_col, o_src_row;

    pg_addrgen #(.OUT_W(OUT_W), .OUT_H(OUT_H), .IN_W(IN_W), .IN_H(IN_H)) dut (
        .clk(clk), .rstn(rstn), .sof(sof), .px_valid(px_valid),
        .out_w_win(out_w_win), .out_h_win(out_h_win), .pos_x(pos_x), .pos_y(pos_y),
        .h_step_int(h_step_int), .h_step_frac(h_step_frac),
        .v_step_int(v_step_int), .v_step_frac(v_step_frac),
        .o_valid(o_valid), .o_in_window(o_in_window),
        .o_src_col(o_src_col), .o_src_row(o_src_row), .o_new_row(o_new_row)
    );

    integer errors;
    integer total_errors;
    integer seen;                // count of o_valid pulses this case

    // case params captured for the golden check
    integer c_ow, c_oh, c_px, c_py;
    // output-side walk: which (ox,oy) the current o_valid corresponds to.
    // Advances on every o_valid, so it is immune to pipeline latency and to
    // blanking gaps in px_valid (which we add in later modules).
    integer vox, voy;
    reg     checking;            // 1 while we should be scoring o_valid pulses

    // golden helpers
    function integer gold_inwin;
        input integer ox, oy;
        begin
            gold_inwin = ((ox >= c_px) && (ox < c_px + c_ow) &&
                          (oy >= c_py) && (oy < c_py + c_oh)) ? 1 : 0;
        end
    endfunction
    function integer gold_col; input integer ox; gold_col = ((ox - c_px) * IN_W) / c_ow; endfunction
    function integer gold_row; input integer oy; gold_row = ((oy - c_py) * IN_H) / c_oh; endfunction

    // checker: each o_valid corresponds to the next raster position in order.
    integer g_inwin, g_col, g_row;
    always @(posedge clk) begin
        if (checking && o_valid) begin
            g_inwin = gold_inwin(vox, voy);
            g_col   = gold_col(vox);
            g_row   = gold_row(voy);
            if (o_in_window !== (g_inwin != 0)) begin
                if (errors < 20)
                  $display("  MISMATCH inwin @ (%0d,%0d): dut=%b gold=%0d",
                           vox, voy, o_in_window, g_inwin);
                errors = errors + 1;
            end else if (o_in_window) begin
                if (o_src_col !== g_col[11:0] || o_src_row !== g_row[11:0]) begin
                    if (errors < 20)
                      $display("  MISMATCH src @ (%0d,%0d): dut=(%0d,%0d) gold=(%0d,%0d)",
                               vox, voy, o_src_col, o_src_row, g_col, g_row);
                    errors = errors + 1;
                end
            end
            seen = seen + 1;
            if (vox == OUT_W-1) begin vox = 0; voy = voy + 1; end
            else vox = vox + 1;
        end
    end

    task run_case;
        input [11:0] ow, oh, ppx, ppy;
        integer i;
        begin
            c_ow = ow; c_oh = oh; c_px = ppx; c_py = ppy;
            out_w_win = ow; out_h_win = oh; pos_x = ppx; pos_y = ppy;
            h_step_int  = IN_W / ow;  h_step_frac = IN_W % ow;
            v_step_int  = IN_H / oh;  v_step_frac = IN_H % oh;
            errors = 0; seen = 0;

            // reset the walk via sof (no px_valid → no o_valid during this)
            checking = 0;
            @(posedge clk); sof <= 1'b1; px_valid <= 1'b0;
            @(posedge clk); sof <= 1'b0;
            vox = 0; voy = 0; checking = 1;

            // stream the full raster, back-to-back active pixels
            for (i = 0; i < OUT_W*OUT_H; i = i + 1) begin
                px_valid <= 1'b1;
                @(posedge clk);
            end
            px_valid <= 1'b0;
            // drain the pipeline so the final o_valid pulses are scored
            repeat (8) @(posedge clk);
            checking = 0;

            $display("CASE %0dx%0d @ (%0d,%0d)  [hstep %0d+%0d/%0d, vstep %0d+%0d/%0d] : seen=%0d errors = %0d",
                     ow, oh, ppx, ppy, h_step_int, h_step_frac, ow,
                     v_step_int, v_step_frac, oh, seen, errors);
            if (seen != OUT_W*OUT_H)
                $display("  WARN: expected %0d o_valid pulses, saw %0d", OUT_W*OUT_H, seen);
            total_errors = total_errors + errors;
        end
    endtask

    initial begin
        total_errors = 0;
        rstn = 1'b0; sof = 1'b0; px_valid = 1'b0;
        out_w_win = OUT_W; out_h_win = OUT_H; pos_x = 0; pos_y = 0;
        h_step_int = 1; h_step_frac = 0; v_step_int = 1; v_step_frac = 0;
        repeat (4) @(posedge clk);
        rstn = 1'b1;
        repeat (2) @(posedge clk);

        run_case(1280, 720,   0,   0);   // full size, no scale, no offset
        run_case( 960, 540, 160,  90);   // 0.75x, centered
        run_case( 640, 360, 320, 180);   // 0.5x, centered
        run_case( 854, 480, 213, 120);   // ugly ratio (1280/854, 720/480)
        run_case( 320, 240, 480, 240);   // strong shrink, off-center

        $display("=================================");
        $display("Total errors = %0d", total_errors);
        $display("=================================");
        $finish;
    end

    // safety timeout
    initial begin
        #2_000_000_000;
        $display("TIMEOUT — Total errors = %0d (incomplete)", total_errors);
        $finish;
    end
endmodule

`default_nettype wire
