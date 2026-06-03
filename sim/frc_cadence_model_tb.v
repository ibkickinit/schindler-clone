// frc_cadence_model_tb.v — behavioral frame-level model of the FRC ring + cadence.
//
// GATE for the cadence-controller RTL (task #101). HARDENED 2026-06-02 after an
// independent review showed the first cut was a self-fulfilling gate: the safety
// clamp forces read into [newest-max_lag, newest], which is collision-free BY
// CONSTRUCTION at every N — so `collisions==0` could never fail and "N=5 collides /
// N=7 clean" was NOT reproducible from the committed file (N=4/5/7 all passed). The
// confound: clamp + N were changed together and the pass mis-attributed to N.
//
// This version gives the gate teeth:
//   - SAFETY_CLAMP_ON knob: with the clamp OFF, the hazard is REAL — N=5 collides at
//     60->24 (the writer laps the read slot mid-read). Proves the clamp is load-bearing.
//   - the PASS criterion is no longer collisions==0 (clamp-guaranteed). It is:
//       collisions==0  AND  occ_min >= MARGIN  AND  depth_suppress==0
//     where depth_suppress = frames where alpha is fractional and frame S+1 EXISTS
//     (completed) but lies OUTSIDE the safe window → the ring silently dropped a blend
//     (Mackin judder returns) with zero collisions reported. THIS is what distinguishes
//     a deep-enough ring from a too-shallow one. Under it, N=4/5 FAIL, N=7 PASSES.
//   - writer JITTER (±JIT ticks): perfectly-periodic writers make occ=0 look "safe";
//     real DDR-latency jitter makes a zero-margin config collide. Jitter exposes margin.
//
// Cadence = phase accumulator (acc+=inc; n_adv=floor; frac=Mackin alpha); inc servo'd
// by ring occupancy (PI). Two readers (A=HD blend, B=SD single-fetch) share one ring.
//
// Override N / SAFETY_CLAMP_ON via:  xelab -generic_top "N=5" -generic_top "SAFETY_CLAMP_ON=0"
// Abstract time: 1 tick = 1ns. Behavioral characterization, NOT pixel-accurate.

`default_nettype none
`timescale 1ns / 1ps

module frc_cadence_model_tb #(
    parameter integer N = 7,                 // ring slots (override per run)
    parameter integer SAFETY_CLAMP_ON = 1,   // 0 = disable clamp → prove the hazard is real
    parameter integer MARGIN = 2,            // required occupancy floor for a PASS
    parameter integer JIT = 30               // writer jitter, +/- ticks on src interval
);
    localparam integer NR = 2;
    localparam integer SETPOINT = N/2;

    reg clk = 1'b0;  always #1 clk = ~clk;

    // ---- writer with jitter: source frame interval = src_period +/- JIT ticks ----
    integer src_period;
    integer src_cnt = 0;
    integer src_target;
    reg src_evt;
    integer jseed = 32'h1234_5678;
    function integer jitter; input integer dummy; begin
        jseed  = (jseed*1103515245 + 12345) & 32'h7fff_ffff;   // LCG (deterministic)
        jitter = (jseed % (2*JIT+1)) - JIT;
    end endfunction
    always @(posedge clk) begin
        src_evt <= 1'b0;
        if (src_cnt >= src_target-1) begin
            src_cnt <= 0; src_evt <= 1'b1; src_target <= src_period + jitter(0);
        end else src_cnt <= src_cnt + 1;
    end

    integer newest = -1;
    always @(posedge clk) if (src_evt) newest <= newest + 1;
    wire [31:0] inprog_slot = (newest + 1) % N;

    // ---- per-reader state ----
    integer out_period [0:NR-1];
    integer out_cnt    [0:NR-1];
    reg     out_evt    [0:NR-1];
    real    acc        [0:NR-1];
    real    inc        [0:NR-1];
    real    integ      [0:NR-1];
    integer read_id    [0:NR-1];
    integer prev_id    [0:NR-1];
    integer read_slot  [0:NR-1];
    reg     read_active[0:NR-1];
    reg     blend      [0:NR-1];
    integer can_blend  [0:NR-1];
    integer m_adv[0:NR-1], m_rep[0:NR-1], m_drop[0:NR-1], m_blend[0:NR-1], m_tot[0:NR-1];
    integer m_supp[0:NR-1];                  // depth-driven blend suppression (the real failure)
    integer occ_min[0:NR-1], occ_max[0:NR-1];

    integer collisions = 0;
    integer started = 0;
    real KP; real KI;

    integer i;
    initial begin
        for (i=0;i<NR;i=i+1) begin
            out_cnt[i]=0; out_evt[i]=1'b0; acc[i]=0.0; integ[i]=0.0;
            read_id[i]=0; prev_id[i]=-1; read_slot[i]=0; read_active[i]=1'b0; blend[i]=1'b0;
            m_adv[i]=0; m_rep[i]=0; m_drop[i]=0; m_blend[i]=0; m_tot[i]=0; m_supp[i]=0;
            occ_min[i]=999; occ_max[i]=-999;
        end
        can_blend[0]=1; can_blend[1]=0;
        KP = 0.002; KI = 0.0004;
    end

    genvar g;
    generate for (g=0; g<NR; g=g+1) begin: oevt
        always @(posedge clk) begin
            out_evt[g] <= 1'b0;
            if (out_cnt[g] >= out_period[g]-1) begin out_cnt[g] <= 0; out_evt[g] <= 1'b1; end
            else                                     out_cnt[g] <= out_cnt[g] + 1;
        end
    end endgenerate

    integer r, n_adv, want, occ, errf, max_lag, ceilR, hi, lo, s1;
    real    Rr, fracv;
    reg     want_blend;
    always @(posedge clk) begin
        for (r=0; r<NR; r=r+1) begin
            if (out_evt[r] && newest >= 0) begin
                started <= 1;
                acc[r] = acc[r] + inc[r];
                n_adv  = $floor(acc[r]);
                acc[r] = acc[r] - n_adv;
                fracv  = acc[r];                 // residual = alpha
                want   = read_id[r] + n_adv;

                Rr      = (out_period[r]*1.0)/(src_period*1.0);
                ceilR   = $ceil(Rr);
                max_lag = N - ceilR - 2; if (max_lag < 0) max_lag = 0;
                hi = newest;
                lo = newest - max_lag; if (lo < 0) lo = 0;

                if (SAFETY_CLAMP_ON != 0) begin
                    if (want > hi) want = hi;        // repeat (output ahead)
                    if (want < lo) want = lo;        // force-advance (drop) — collision-free
                end else begin
                    // clamp OFF: only the physical "can't read uncompleted" head clamp.
                    // Tail is UNGUARDED → the writer can lap a too-old read slot → collision.
                    if (want > hi) want = hi;
                    if (want < 0)  want = 0;
                end
                read_id[r]   = want;
                read_slot[r] = want % N;

                // blend intent vs ability (depth)
                want_blend = (fracv > 0.004 && fracv < 0.996);
                s1 = want + 1;
                blend[r] = (can_blend[r] && want_blend && s1 <= newest
                            && (newest - s1) <= max_lag);

                if (started) begin
                    m_tot[r] = m_tot[r] + 1;
                    if (read_id[r] == prev_id[r])          m_rep[r]  = m_rep[r] + 1;
                    else if (read_id[r] == prev_id[r]+1)   m_adv[r]  = m_adv[r] + 1;
                    else if (read_id[r] >  prev_id[r]+1)   m_drop[r] = m_drop[r] + (read_id[r]-prev_id[r]-1);
                    if (blend[r]) m_blend[r] = m_blend[r] + 1;
                    // DEPTH suppression: wanted to blend, S+1 EXISTS (completed), but it's
                    // outside the safe window → ring too shallow → silent single-fetch.
                    if (can_blend[r] && want_blend && s1 <= newest && (newest - s1) > max_lag)
                        m_supp[r] = m_supp[r] + 1;
                    occ = newest - read_id[r];
                    if (occ < occ_min[r]) occ_min[r] <= occ;
                    if (occ > occ_max[r]) occ_max[r] <= occ;
                end
                prev_id[r] = read_id[r];
                read_active[r] <= 1'b1;

                // PI occupancy servo with deadband (|err|<=1 → no integrate) + anti-windup
                occ  = newest - read_id[r];
                errf = occ - SETPOINT;
                if (errf > 1 || errf < -1) begin
                    integ[r] = integ[r] + errf;
                    if (integ[r] >  500.0) integ[r] =  500.0;   // anti-windup clamp
                    if (integ[r] < -500.0) integ[r] = -500.0;
                    inc[r]   = inc[r] + KP*errf + KI*integ[r];
                    if (inc[r] < 0.05) inc[r] = 0.05;
                    if (inc[r] > 5.0)  inc[r] = 5.0;
                end
            end
        end
    end

    integer c;
    always @(posedge clk) begin
        if (started) for (c=0; c<NR; c=c+1) begin
            if (read_active[c] &&
                ( inprog_slot == read_slot[c][31:0] ||
                  (blend[c] && inprog_slot == ((read_slot[c]+1)%N)) )) begin
                collisions <= collisions + 1;
                $error("COLLISION @%0t reader%0d: inprog %0d == read_slot %0d (read_id=%0d newest=%0d)",
                       $time, c, inprog_slot, read_slot[c], read_id[c], newest);
            end
        end
    end

    task run_phase(input integer sp, input integer opA, input integer opB,
                   input integer nframes, input [255:0] name);
        integer k;
        begin
            src_period = sp; src_target = sp; out_period[0]=opA; out_period[1]=opB;
            $display("---- %0s : src=%0d outA=%0d (R=%f) outB=%0d ----",
                     name, sp, opA, (opA*1.0)/(sp*1.0), opB);
            for (k=0; k<nframes; k=k+1) begin
                @(posedge clk); while (!out_evt[0]) @(posedge clk);
            end
        end
    endtask

    integer pass;
    initial begin
        src_period=1001; src_target=1001; out_period[0]=1000; out_period[1]=1000;
        inc[0]=1.0; inc[1]=1.0;
        @(posedge clk);
        run_phase(1001, 1000, 1000, 80, "P1 src59.94 A->60");
        run_phase(1000, 1001, 1000, 80, "P2 src60    A->59.94");
        run_phase(1000, 1200, 1000, 80, "P3 STEP 60->50");
        run_phase(1000, 2500, 1000, 60, "P4 STEP 60->24 (2.5x)");
        run_phase(1200, 1000, 1000, 80, "P5 STEP 50->60");

        $display("==== frc_cadence_model_tb  N=%0d  CLAMP=%0d  JIT=%0d ====", N, SAFETY_CLAMP_ON, JIT);
        $display("  collisions = %0d", collisions);
        for (i=0;i<NR;i=i+1)
            $display("  reader%0d (%s): occ[%0d..%0d] adv/rep/drop=%0d/%0d/%0d blendfire=%0d/%0d depth_suppress=%0d",
                     i, (i==0)?"A blend":"B single", occ_min[i], occ_max[i],
                     m_adv[i], m_rep[i], m_drop[i], m_blend[i], m_tot[i], m_supp[i]);
        // PASS (clamp-on gate): no collisions AND reader A holds margin AND no silent
        // depth-driven blend suppression. (When CLAMP=0 we EXPECT collisions>0.)
        pass = (collisions==0) && (occ_min[0] >= MARGIN) && (m_supp[0]==0);
        if (SAFETY_CLAMP_ON == 0)
            $display((collisions>0) ? "FRC_CADENCE_TB: HAZARD CONFIRMED (clamp off -> collisions, as intended)"
                                    : "FRC_CADENCE_TB: UNEXPECTED (clamp off but no collision)");
        else
            $display(pass ? "FRC_CADENCE_TB: PASS (no collision, occ>=MARGIN, no blend suppression)"
                          : "FRC_CADENCE_TB: FAIL (margin/suppression — ring too shallow for this config)");
        $finish;
    end

    initial begin #12000000; $display("FRC_CADENCE_TB: TIMEOUT"); $finish; end
endmodule

`default_nettype wire
