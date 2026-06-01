// pg_genlock_tb.v — self-checking TB for the read-engine frame-follow.
//
// Drives source-vsync and output-vsync at matched and FRC ratios and checks:
//   (1) write_slot mirrors the source-vsync count  (mod NUM_FRAMES)
//   (2) read_slot  == (write_slot - READ_DELAY) mod NUM_FRAMES   [latched @ out vsync]
//   (3) read_base_addr == FRAME_BUF_BASE + read_slot*SLOT_STRIDE
//   (4) safety: read_slot != write_slot  (never read the in-progress slot)
//
// Pass criterion: "Total errors = 0".  Run: make sim-pg.

`default_nettype none
`timescale 1ns / 1ps

module pg_genlock_tb;
    localparam [31:0]  FRAME_BUF_BASE = 32'h1000_0000;
    localparam integer NUM_FRAMES     = 5;
    localparam integer SLOT_STRIDE    = 2768640;
    localparam integer READ_DELAY     = 2;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rstn, src_vsync, out_vsync;
    wire [2:0]  read_slot, write_slot;
    wire [31:0] read_base_addr;

    pg_genlock #(.FRAME_BUF_BASE(FRAME_BUF_BASE), .NUM_FRAMES(NUM_FRAMES),
                 .SLOT_STRIDE(SLOT_STRIDE), .READ_DELAY(READ_DELAY)) dut (
        .clk(clk), .rstn(rstn), .src_vsync(src_vsync), .out_vsync(out_vsync),
        .read_slot(read_slot), .read_base_addr(read_base_addr), .write_slot(write_slot)
    );

    integer errors;
    integer src_count;          // source vsyncs issued so far

    // ---- vsync generators (free-running counters) ----
    integer p_src, p_out;       // periods in clk cycles (set per scenario)
    integer scnt, ocnt;
    reg     gen_en;
    always @(posedge clk) begin
        if (!rstn || !gen_en) begin scnt <= 0; ocnt <= 0; src_vsync <= 0; out_vsync <= 0; end
        else begin
            // source vsync: 2-cycle pulse every p_src
            if (scnt >= p_src-1) begin scnt <= 0; src_vsync <= 1'b1; src_count <= src_count + 1; end
            else begin scnt <= scnt + 1; if (scnt == 1) src_vsync <= 1'b0; end
            // output vsync: 2-cycle pulse every p_out
            if (ocnt >= p_out-1) begin ocnt <= 0; out_vsync <= 1'b1; end
            else begin ocnt <= ocnt + 1; if (ocnt == 1) out_vsync <= 1'b0; end
        end
    end

    // ---- checker on output-vsync latch ----
    // Capture write_slot on the SAME cycle the DUT latches (out_vsync rising,
    // matching the DUT's registered ov_q), then verify read_slot the next cycle.
    reg ov_q; reg check_now; reg [2:0] cap_write;
    integer exp_read;
    always @(posedge clk) begin
        ov_q <= out_vsync;
        check_now <= 1'b0;
        if (out_vsync && !ov_q) begin
            cap_write <= write_slot;   // the value the DUT uses this cycle
            check_now <= 1'b1;         // results valid next cycle
        end
        if (check_now) begin
            // (2) read == (write_at_latch - READ_DELAY) mod N
            exp_read = (cap_write >= READ_DELAY) ? (cap_write - READ_DELAY)
                                                 : (cap_write + NUM_FRAMES - READ_DELAY);
            if (read_slot !== exp_read[2:0]) begin
                if (errors < 20) $display("  ERR read_slot=%0d exp=%0d (write@latch=%0d)",
                                          read_slot, exp_read, cap_write);
                errors = errors + 1;
            end
            // (3) base address
            if (read_base_addr !== FRAME_BUF_BASE + read_slot*SLOT_STRIDE) begin
                if (errors < 20) $display("  ERR base=%h exp=%h (slot=%0d)",
                        read_base_addr, FRAME_BUF_BASE + read_slot*SLOT_STRIDE, read_slot);
                errors = errors + 1;
            end
            // (4) safety: never read the in-progress write slot
            if (read_slot === write_slot) begin
                if (errors < 20) $display("  ERR safety: read_slot==write_slot==%0d", read_slot);
                errors = errors + 1;
            end
        end
    end

    // ---- mirror check: sample write_slot just before each new src pulse ----
    integer exp_write;
    reg sv_q;
    always @(posedge clk) begin
        sv_q <= src_vsync;
        // just after a src pulse has been counted + propagated, write_slot
        // should equal src_count mod N. Sample on the falling edge of the
        // pulse + a couple cycles via scnt==4 (well clear of CDC latency).
        if (gen_en && scnt == 4) begin
            exp_write = src_count % NUM_FRAMES;
            if (write_slot !== exp_write[2:0]) begin
                if (errors < 20) $display("  ERR write_slot=%0d exp=%0d (src_count=%0d)",
                                          write_slot, exp_write, src_count);
                errors = errors + 1;
            end
        end
    end

    task run_scenario;
        input [127:0] name;
        input integer psrc, pout, frames;
        integer start_err;
        begin
            start_err = errors;
            // reset counters for a clean phase, keep ring pointer continuity
            gen_en = 1'b0; @(posedge clk); @(posedge clk);
            p_src = psrc; p_out = pout;
            gen_en = 1'b1;
            // run for `frames` output frames
            repeat (frames * pout) @(posedge clk);
            $display("SCENARIO %0s  p_src=%0d p_out=%0d frames=%0d : errors=%0d",
                     name, psrc, pout, frames, errors - start_err);
        end
    endtask

    initial begin
        errors = 0; src_count = 0;
        rstn = 0; src_vsync = 0; out_vsync = 0; gen_en = 0;
        p_src = 2000; p_out = 2000; scnt = 0; ocnt = 0;
        check_now = 0; cap_write = 0; ov_q = 0; sv_q = 0;
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (3) @(posedge clk);

        run_scenario("60to60_matched", 2000, 2000, 20);
        run_scenario("60to30_FRC",     1000, 2000, 20);
        run_scenario("60to24_FRC_2.5", 1000, 2500, 20);
        run_scenario("24to60_upcadence",2500, 1000, 20);

        $display("=================================");
        $display("Total errors = %0d", errors);
        $display("=================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("TIMEOUT — Total errors = %0d (incomplete)", errors);
        $finish;
    end
endmodule

`default_nettype wire
