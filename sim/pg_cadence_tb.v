// pg_cadence_tb.v — RTL gate for hdl/pg_cadence.v.
//
// Wraps the ACTUAL pg_cadence DUT in the same DDR-contention writer + ring + safety
// harness the behavioral model (sim/frc_cadence_model_tb.v §13) was validated with, and
// holds the RTL to the same PASS bar: ZERO writer↔reader slot collisions, lap margin
// >= MARGIN, writer never starves (overflow=0). The DUT only exposes SLOTS, so all checks
// are slot-based: the writer's in-progress slot = frame_ptr = wid % N; a read slot is the
// DUT's read_slot/read2_slot. collision = writer writing a slot a reader is reading;
// lap = (read_slot - frame_ptr) mod N = writes until the writer overwrites the read slot.
//
// Override N/MARGIN/O/BW/A_BYTES/blend_mode via xelab -generic_top.

`default_nettype none
`timescale 1ns / 1ps

module pg_cadence_tb #(
    parameter integer N        = 6,
    parameter integer MARGIN   = 2,
    parameter integer O_MARG   = 0,
    parameter integer BLEND    = 1,        // drive DUT blend_mode
    parameter integer JIT      = 8,
    parameter integer BWx100   = 1600,
    parameter integer W_BYTES  = 6200,
    parameter integer A_BYTES  = 4100,
    parameter integer FP_CHAOS = 0         // 1 = non-monotonic writer pointer (skip/back/repeat)
);
    localparam integer MAXT = 4;
    real BW; initial BW = BWx100/100.0;

    reg clk = 1'b0; always #1 clk = ~clk;
    reg rstn = 1'b0;

    // ---- timing ----
    integer src_period, out_period, src_cnt, src_target, out_cnt;
    integer jseed;
    function integer jit_next; input integer d; begin
        jseed = (jseed*1103515245 + 12345) & 32'h7fff_ffff;
        jit_next = (jseed % (2*JIT+1)) - JIT;
    end endfunction

    // ---- writer (DDR-contention) ----
    integer wid, w_active, w_slot; real w_rem;
    integer w_completes_this_outframe, w_overflow;
    // eslot = the writer's EXPOSED current slot. Normally (eslot+1)%N each write, but with
    // FP_CHAOS it goes non-monotonic (skip +2 / backward -1 / repeat +0) — the exact behavior
    // pg_genlock-v1 was bench-disproven on. Both the DUT (via dut_fp) and the collision/lap
    // checks use eslot, so the gate sees whatever the real pointer might do.
    integer eslot, cseed, n_dec;   // n_dec = # of pointer-DECREASES injected (the dividing line)
    // Chaos taxonomy, made EXPLICIT (per review): the ONLY unhandled hazard is a pointer
    // DECREASE (the writer moving to an older framestore). FP_CHAOS=1 advances eslot by
    // {0,+1,+2,+3} — strictly NON-DECREASING in ring order (repeat / +1 / skip / bigger-skip);
    // it injects ZERO decreases (asserted via n_dec below). This is the physically-real
    // "non-linear but forward-writing" behavior (the v1 bench finding). FP_CHAOS=2 additionally
    // injects a step of N-1 == −1 (mod N) = a true ring-decrease, to confirm a decrease is the
    // hard hazard (expected FAIL) — it would corrupt ANY reader incl. pg_genlock v2. So
    // "decrease = the one unhandled case" is the TESTED dividing line, not a sampling artifact.
    function integer chaos_step; input integer d; integer r; begin
        cseed = (cseed*1103515245 + 12345) & 32'h7fff_ffff; r = cseed % 16;
        if      (r==0) chaos_step = 2;                                  // skip a framestore (fwd)
        else if (r==1) chaos_step = 3;                                  // bigger skip (fwd)
        else if (r==2) chaos_step = 0;                                  // repeat (no advance)
        else if (r==3 && FP_CHAOS==2) begin chaos_step = N-1; n_dec = n_dec + 1; end // DECREASE
        else           chaos_step = 1;                                  // normal +1 (fwd)
    end endfunction

    // ---- DUT inputs: registered (nonblocking) so the real RTL sees clean signals,
    //      not a posedge race against the model's blocking-assigned regs ----
    reg [5:0] dut_fp; reg dut_ov;

    // ---- DUT ----
    wire [2:0]  d_read_slot, d_read2_slot, d_write_slot;
    wire [31:0] d_read_base, d_read2_base;
    wire [7:0]  d_alpha; wire d_blend_en;
    wire [15:0] d_inc; wire [7:0] d_dnew; wire [3:0] d_lag;
    pg_cadence #(.NUM_FRAMES(N), .MARGIN(MARGIN), .O_MARG(O_MARG)) dut (
        .clk(clk), .rstn(rstn), .frame_ptr(dut_fp), .out_vsync(dut_ov),
        .blend_mode(BLEND[0]),
        .read_slot(d_read_slot), .read_base_addr(d_read_base), .write_slot(d_write_slot),
        .read2_slot(d_read2_slot), .read2_base_addr(d_read2_base),
        .alpha(d_alpha), .blend_en(d_blend_en),
        .dbg_inc(d_inc), .dbg_dnew(d_dnew), .dbg_lag(d_lag)
    );

    // ---- read transfers (slot, remaining bytes) ----
    integer rt_valid [0:MAXT-1];
    integer rt_slot  [0:MAXT-1];
    real    rt_rem   [0:MAXT-1];

    // ---- metrics ----
    integer collisions, started, min_lap, m_blend, m_tot, outstanding;
    integer k;

    function integer count_active; input integer d; integer kk,c; begin
        c = (w_active!=0)?1:0;
        for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[kk]) c=c+1;
        count_active=c;
    end endfunction
    task enq; input integer slot; input integer bytes; integer kk; reg done; begin
        done=0;
        for (kk=0;kk<MAXT;kk=kk+1) if (!done && !rt_valid[kk]) begin
            rt_valid[kk]=1; rt_slot[kk]=slot; rt_rem[kk]=bytes*1.0; done=1; end
    end endtask

    // ---- enqueue pulse: a few cycles after dut_ov rising so the DUT's registered
    //      read_slot/blend outputs have settled before we sample them. ----
    reg dov_q; reg [3:0] ov_pipe; reg enq_pulse;
    always @(posedge clk) begin
        if (!rstn) begin dov_q<=0; ov_pipe<=0; enq_pulse<=0; end
        else begin
            dov_q     <= dut_ov;
            ov_pipe   <= {ov_pipe[2:0], (dut_ov & ~dov_q)};
            enq_pulse <= ov_pipe[2];
        end
    end

    real share; integer n_act, dist, lm;
    initial begin
        src_period=1001; src_target=1001; src_cnt=0; out_period=1000; out_cnt=0; jseed=32'h1234_5678;
        wid=0; w_active=0; w_slot=0; w_rem=0.0; w_completes_this_outframe=0; w_overflow=0;
        dut_ov=0; dut_fp=0; eslot=0; cseed=32'h00C0FFEE; n_dec=0; collisions=0; started=0; min_lap=99999; m_blend=0; m_tot=0; outstanding=0;
        for (k=0;k<MAXT;k=k+1) begin rt_valid[k]=0; rt_slot[k]=0; rt_rem[k]=0.0; end
    end

    // ---- engine ----
    always @(posedge clk) begin : ENG
        integer kk;
        if (!rstn) begin
            // hold
        end else begin
            // src + out events
            if (src_cnt >= src_target-1) begin
                src_cnt=0; src_target=src_period+jit_next(0);
                if (w_active) w_overflow=w_overflow+1;
                else begin
                    eslot = (eslot + (FP_CHAOS ? chaos_step(0) : 1)) % N;  // advance writer slot
                    w_rem=W_BYTES*1.0; w_active=1;
                end
            end else src_cnt=src_cnt+1;
            if (out_cnt >= out_period-1) out_cnt=0; else out_cnt=out_cnt+1;
            dut_ov <= (out_cnt < 4);       // registered DUT inputs (nonblocking, no race)
            dut_fp <= eslot[5:0];

            // DDR drain
            n_act = count_active(0);
            if (n_act>0) begin
                share = BW/(n_act*1.0);
                if (w_active) begin
                    w_rem=w_rem-share;
                    if (w_rem<=0.0) begin wid=wid+1; w_active=0; w_completes_this_outframe=w_completes_this_outframe+1; end
                end
                for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[kk]) begin
                    rt_rem[kk]=rt_rem[kk]-share; if (rt_rem[kk]<=0.0) rt_valid[kk]=0;
                end
            end

            // collision + lap (slot-based) against the writer's in-progress slot
            if (started && w_active) for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[kk] && rt_slot[kk]==eslot) begin
                collisions=collisions+1;
                $error("COLLISION @%0t: writer slot %0d == read slot %0d", $time, eslot, rt_slot[kk]);
            end
            // lap margin only meaningful while the writer is actively writing a slot
            // (when idle, read_slot==last-written-slot is harmless, not a hazard).
            if (started && w_active) for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[kk]) begin
                dist = (rt_slot[kk] - eslot + N) % N;        // writes until writer overwrites this slot
                if (dist < min_lap) min_lap = dist;
            end

            // enqueue the DUT's chosen reads (one cycle after it latched)
            if (enq_pulse && wid>=1) begin
                started=1;
                outstanding=0; for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[kk]) outstanding=outstanding+1;
                m_tot=m_tot+1;
                enq(d_read_slot, A_BYTES);
                if (d_blend_en) begin enq(d_read2_slot, A_BYTES); m_blend=m_blend+1; end
                if (wid%N==w_completes_this_outframe) ; // (no-op; keep J bookkeeping simple)
                w_completes_this_outframe=0;
            end
        end
    end

    task run_phase; input integer sp; input integer op; input integer nf; input [255:0] nm;
        integer kk; begin
            src_period=sp; src_target=sp; out_period=op;
            $display("---- %0s : src=%0d out=%0d (R=%f) ----", nm, sp, op, (op*1.0)/(sp*1.0));
            for (kk=0;kk<nf;kk=kk+1) begin @(posedge clk); while (!enq_pulse) @(posedge clk); end
        end
    endtask

    integer pass;
    initial begin
        repeat(4) @(posedge clk); rstn=1; @(posedge clk);
        run_phase(1001,1000,80,"P1 src59.94 -> 60");
        run_phase(1000,1001,80,"P2 60 -> 59.94");
        run_phase(1000,1200,80,"P3 60 -> 50");
        run_phase(1000,2500,60,"P4 60 -> 24 (2.5x)");
        run_phase(1200,1000,80,"P5 50 -> 60");
        run_phase(1000,4000,60,"P6 HOT-PLUG 60 -> 15");

        $display("==== pg_cadence_tb  N=%0d MARGIN=%0d O=%0d BLEND=%0d BW=%0d/100 A=%0d ====",
                 N,MARGIN,O_MARG,BLEND,BWx100,A_BYTES);
        $display("  collisions=%0d  min_lap=%0d  writer_overflow=%0d  blend=%0d/%0d  pointer_decreases_injected=%0d",
                 collisions, (min_lap==99999)?-1:min_lap, w_overflow, m_blend, m_tot, n_dec);
        // sanity: FP_CHAOS=1 must inject ZERO decreases (so a PASS can't be hiding one)
        if (FP_CHAOS==1 && n_dec != 0)
            $display("PG_CADENCE_TB: TAXONOMY-ERROR (FP_CHAOS=1 injected %0d decreases — boundary not clean)", n_dec);
        pass = (collisions==0) && (min_lap>=MARGIN) && (w_overflow==0);
        if (pass) $display("PG_CADENCE_TB: PASS (RTL meets the gate)");
        else      $display("PG_CADENCE_TB: FAIL (collisions=%0d min_lap=%0d overflow=%0d)", collisions, min_lap, w_overflow);
        $finish;
    end
    initial begin #20000000; $display("PG_CADENCE_TB: TIMEOUT"); $finish; end
endmodule

`default_nettype wire
