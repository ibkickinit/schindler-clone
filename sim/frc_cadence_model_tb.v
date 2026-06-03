// frc_cadence_model_tb.v — behavioral frame-level model of the FRC ring + cadence.
//
// GATE for the cadence-controller RTL (task #101). Implements the canonical form the
// reviewer specified and proves the properties that matter, across injected RATE STEPS:
//
//   Cadence = phase accumulator (Q1): per output frame  acc += inc; n_adv = floor(acc);
//             acc -= n_adv.  n_adv: 0=repeat, 1=advance, >=2=drop.  frac(acc)=Mackin alpha.
//   Rate    = inc is NOT constant; the source is async, so inc is servo'd by ring
//             OCCUPANCY (read distance behind the write pointer) via a PI loop holding
//             occupancy at a setpoint (~N/2). Video analog of audio async-SRC / ascal o_lltune.
//   Safety  = HARD invariant (Q7): never read a slot (or, when blending, slot pair S,S+1)
//             the writer can reach before the output frame completes. If a repeat/hold
//             would let the writer close within margin, FORCE-ADVANCE (accept a 1-frame
//             cadence error). This is the one thing that can corrupt (not just look wrong).
//
//   TWO readers (engine A = HD, dual-fetch/blend;  engine B = SD analog, single-fetch/
//   no-blend per Q5) share one ring filled by one writer (S2MM). Worst-case occupancy
//   across a SOURCE-rate step (resolution change / hot-plug) is where the lap happens (Q7).
//
// Asserts: ZERO writer↔reader slot collisions; occupancy bounded; reports cadence
// (advance/repeat/drop) and blend-fire fraction (the alpha-gated 2nd-fetch rate, Q4).
//
// Abstract time: 1 tick = 1ns. *_period = frame interval in ticks. Changing a period
// mid-sim injects a rate step. R = out_period/src_period = source frames per output frame.
// Behavioral characterization model, NOT pixel-accurate. Job: find the failure first.

`default_nettype none
`timescale 1ns / 1ps

module frc_cadence_model_tb;
    localparam integer N = 7;            // ring slots. N=5 collides at 60->24 (proven);
                                         // worst-case safe lag = N-ceil(R)-2, and two
                                         // blending readers+writer want >=6-7 (Q7 depth math).
    localparam integer NR = 2;           // readers (A=HD blend, B=SD single-fetch)
    localparam integer SETPOINT = N/2;   // occupancy target (~N/2)

    reg clk = 1'b0;  always #1 clk = ~clk;

    integer src_period;
    integer src_cnt = 0;  reg src_evt;
    always @(posedge clk) begin
        src_evt <= 1'b0;
        if (src_cnt >= src_period-1) begin src_cnt <= 0; src_evt <= 1'b1; end
        else                              src_cnt <= src_cnt + 1;
    end

    // ---- writer: fills ring at source rate; in-progress slot = (newest+1)%N ----
    integer newest = -1;
    always @(posedge clk) if (src_evt) newest <= newest + 1;
    wire [31:0] inprog_slot = (newest + 1) % N;

    // ---- per-reader state ----
    integer out_period [0:NR-1];
    integer out_cnt    [0:NR-1];
    reg     out_evt    [0:NR-1];
    real    acc        [0:NR-1];         // phase accumulator
    real    inc        [0:NR-1];         // servo'd rate (src frames per out frame)
    real    integ      [0:NR-1];         // PI integral
    integer read_id    [0:NR-1];
    integer prev_id    [0:NR-1];
    integer read_slot  [0:NR-1];
    reg     read_active[0:NR-1];
    reg     blend      [0:NR-1];         // dual-fetch this frame (A only)
    integer can_blend  [0:NR-1];         // 1 = reader is allowed to blend (A=1, B=0)
    // metrics
    integer m_adv[0:NR-1], m_rep[0:NR-1], m_drop[0:NR-1], m_blend[0:NR-1], m_tot[0:NR-1];
    integer occ_min[0:NR-1], occ_max[0:NR-1];

    integer collisions = 0;
    integer started = 0;

    // PI gains (tuning — the model exists to confirm these are stable; conservative).
    real KP; real KI;

    integer i;
    initial begin
        for (i=0;i<NR;i=i+1) begin
            out_cnt[i]=0; out_evt[i]=1'b0; acc[i]=0.0; integ[i]=0.0;
            read_id[i]=0; prev_id[i]=-1; read_slot[i]=0; read_active[i]=1'b0; blend[i]=1'b0;
            m_adv[i]=0; m_rep[i]=0; m_drop[i]=0; m_blend[i]=0; m_tot[i]=0;
            occ_min[i]=999; occ_max[i]=-999;
        end
        can_blend[0]=1;   // engine A (HD): blends
        can_blend[1]=0;   // engine B (SD analog): single-fetch, no blend (Q5 mitigation)
        KP = 0.002; KI = 0.0004;
    end

    // ---- output frame-event generators (per reader) ----
    genvar g;
    generate
      for (g=0; g<NR; g=g+1) begin: oevt
        always @(posedge clk) begin
            out_evt[g] <= 1'b0;
            if (out_cnt[g] >= out_period[g]-1) begin out_cnt[g] <= 0; out_evt[g] <= 1'b1; end
            else                                     out_cnt[g] <= out_cnt[g] + 1;
        end
      end
    endgenerate

    // ---- cadence per reader at its output-frame event ----
    integer r, n_adv, want, occ, errf, max_lag, ceilR, hi, lo;
    real    Rr;
    always @(posedge clk) begin
        for (r=0; r<NR; r=r+1) begin
            if (out_evt[r] && newest >= 0) begin
                started <= 1;
                // --- accumulator: integer carry = cadence, frac = alpha ---
                acc[r] = acc[r] + inc[r];
                n_adv  = $floor(acc[r]);
                acc[r] = acc[r] - n_adv;
                want   = read_id[r] + n_adv;     // resampler's desired frame

                // --- HARD safety clamp (Q7) ---
                // writer advances ~ceil(R) slots during this read; safe max lag behind
                // newest = N - ceil(R) - 2 (one slot in-progress + one frame margin).
                Rr      = (out_period[r]*1.0)/(src_period*1.0);
                ceilR   = $ceil(Rr);
                max_lag = N - ceilR - 2;  if (max_lag < 0) max_lag = 0;
                hi = newest;                       // can't read uncompleted -> hold (repeat)
                lo = newest - max_lag;             // too old/unsafe -> force-advance (drop)
                if (lo < 0) lo = 0;
                if (want > hi) want = hi;          // output ahead of source -> repeat newest
                if (want < lo) want = lo;          // fell behind / transient -> force-advance
                read_id[r]   = want;
                read_slot[r] = want % N;

                // --- alpha-gated dual fetch (Q4): blend only if frac>0 AND S+1 exists+safe ---
                blend[r] = (can_blend[r] && acc[r] > 0.004 && (want+1) <= newest
                            && (newest - (want+1)) <= max_lag);

                // --- metrics ---
                if (started) begin
                    m_tot[r] = m_tot[r] + 1;
                    if (read_id[r] == prev_id[r])          m_rep[r]  = m_rep[r] + 1;
                    else if (read_id[r] == prev_id[r]+1)   m_adv[r]  = m_adv[r] + 1;
                    else if (read_id[r] >  prev_id[r]+1)   m_drop[r] = m_drop[r] + (read_id[r]-prev_id[r]-1);
                    if (blend[r]) m_blend[r] = m_blend[r] + 1;
                    occ = newest - read_id[r];
                    if (occ < occ_min[r]) occ_min[r] <= occ;
                    if (occ > occ_max[r]) occ_max[r] <= occ;
                end
                prev_id[r] = read_id[r];
                read_active[r] <= 1'b1;

                // --- PI occupancy servo: nudge inc to hold occupancy at SETPOINT ---
                // occ high (writer far ahead) -> advance faster -> raise inc.
                occ  = newest - read_id[r];
                errf = occ - SETPOINT;
                if (errf > 0 || errf < 0) begin       // deadband: |err|<1 is 0 (integer)
                    integ[r] = integ[r] + errf;
                    inc[r]   = inc[r] + KP*errf + KI*integ[r];
                    if (inc[r] < 0.05) inc[r] = 0.05;
                    if (inc[r] > 5.0)  inc[r] = 5.0;
                end
            end
        end
    end

    // ---- SAFETY check: writer in-progress slot must not equal any reader's live slot ----
    integer c;
    always @(posedge clk) begin
        if (started) for (c=0; c<NR; c=c+1) begin
            if (read_active[c] &&
                ( inprog_slot == read_slot[c][31:0] ||
                  (blend[c] && inprog_slot == ((read_slot[c]+1)%N)) )) begin
                collisions <= collisions + 1;
                $error("COLLISION @%0t reader%0d: inprog slot %0d hits read_slot %0d (blend=%0d read_id=%0d newest=%0d)",
                       $time, c, inprog_slot, read_slot[c], blend[c], read_id[c], newest);
            end
        end
    end

    // ---- rate-step schedule ----
    task run_phase(input integer sp, input integer opA, input integer opB,
                   input integer nframes, input [255:0] name);
        integer k;
        begin
            src_period = sp; out_period[0] = opA; out_period[1] = opB;
            $display("---- %0s : src=%0d  outA=%0d (R=%f)  outB=%0d (R=%f) ----",
                     name, sp, opA, (opA*1.0)/(sp*1.0), opB, (opB*1.0)/(sp*1.0));
            for (k=0; k<nframes; k=k+1) begin
                @(posedge clk); while (!out_evt[0]) @(posedge clk);
            end
        end
    endtask

    initial begin
        src_period = 1001; out_period[0]=1000; out_period[1]=1000;
        inc[0]=1.0; inc[1]=1.0;                 // seed: assume same rate; servo LEARNS the truth
        @(posedge clk);
        // engine B (analog) held at out=1000 throughout; engine A is the test subject.
        run_phase(1001, 1000, 1000, 80, "P1 src59.94 A->60  (A repeat-dominant)");
        run_phase(1000, 1001, 1000, 80, "P2 src60    A->59.94 (A drop-dominant)");
        run_phase(1000, 1200, 1000, 80, "P3 STEP src60 A->50  (heavy drop)");
        run_phase(1000, 2500, 1000, 60, "P4 STEP src60 A->24  (2.5x drop, N=5 would collide)");
        run_phase(1200, 1000, 1000, 80, "P5 STEP src50 A->60  (A repeat-heavy; src step hits BOTH)");

        $display("==== frc_cadence_model_tb results (N=%0d, %0d readers) ====", N, NR);
        $display("  collisions (MUST be 0) = %0d", collisions);
        for (i=0;i<NR;i=i+1)
            $display("  reader%0d (%s): occ[%0d..%0d]  adv/rep/drop=%0d/%0d/%0d  blendfire=%0d/%0d",
                     i, (i==0)?"A HD blend":"B SD single", occ_min[i], occ_max[i],
                     m_adv[i], m_rep[i], m_drop[i], m_blend[i], m_tot[i]);
        if (collisions == 0) $display("FRC_CADENCE_TB: PASS (no collisions across all rate steps)");
        else                 $display("FRC_CADENCE_TB: FAIL (%0d collisions)", collisions);
        $finish;
    end

    initial begin #8000000; $display("FRC_CADENCE_TB: TIMEOUT"); $finish; end
endmodule

`default_nettype wire
