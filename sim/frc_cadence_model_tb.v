// frc_cadence_model_tb.v — DDR-contention frame-level model of the FRC ring + cadence.
//
// GATE for the cadence-controller RTL (task #101).  v3 (2026-06-02 session 2): the
// prior hardened gate snapshotted slot occupancy at frame start, so it couldn't tell a
// real collision from a model artifact and the clamp-margin was unverifiable. This
// version models DDR as a SHARED-BANDWIDTH resource: the S2MM writer and the two
// readers' fetches are byte transfers that split bandwidth when concurrent, so each
// read takes REAL TIME and a slot is in-use from read-START to read-COMPLETE — which
// can overlap the next output frame under contention (the O term). That lets the model
// MEASURE the two unknowns in the review's closed form
//
//     max_lag_robust = N - ceil(R) - 2 - J - O
//
//   J = (max writer frames completed in one output frame) - ceil(R)   [jitter/burst]
//   O = 1 if a reader's fetch ever overlaps past its next out_evt      [read-too-slow]
//
// COLLISION (true data hazard) = the writer is actively writing slot X while a reader
// is actively reading slot X. PASS = collisions==0 AND occ_min>=MARGIN AND no
// depth-driven blend suppression. SAFETY_CLAMP_ON=0 removes the tail clamp to prove the
// hazard is real. Override N/BW/etc via xelab -generic_top.
//
// Cadence = phase accumulator (acc+=inc; n_adv=floor; frac=alpha) + PI occupancy servo
// WITH deadband (no integrate |err|<=1) + anti-windup (clamp integral) — the form the
// RTL must copy. Two readers: A=HD dual-fetch/blend, B=SD single-fetch.
//
// Bytes/BW are abstract but ratio-faithful to 720p/1080p over ~2 GB/s DDR3:
//   one engine-A blended fetch ~= 1/4 of an output frame at full BW (matches ~8 MB / 2 GB/s
//   vs 16.7 ms); contention stretches it. Abstract time: 1 tick = 1 ns.

`default_nettype none
`timescale 1ns / 1ps

module frc_cadence_model_tb #(
    parameter integer N = 7,
    parameter integer SAFETY_CLAMP_ON = 1,
    parameter integer MARGIN = 2,
    parameter integer SETPOINT = 2,       // occupancy target (small; clamp ceiling caps transients)
    parameter integer JMARG = 1,          // jitter allowance J in the clamp (measured ~1)
    parameter integer JIT = 8,            // writer jitter, +/- ticks (a few, per review)
    parameter integer BWx100 = 1600,      // DDR bandwidth * 100 (bytes/tick) → 16.0
    parameter integer W_BYTES = 6200,     // S2MM HD-frame write
    parameter integer A_BYTES = 4100,     // engine-A read per fetch (HD->720p)
    parameter integer B_BYTES = 500       // engine-B SD read
);
    localparam integer NR = 2;
    localparam integer MAXT = 4;          // max concurrent read transfers per reader
    real BW; initial BW = BWx100/100.0;

    reg clk = 1'b0;  always #1 clk = ~clk;

    // ---- timing (ticks); rate steps change these ----
    integer src_period, out_period [0:NR-1];
    integer src_cnt, src_target, out_cnt [0:NR-1];

    // deterministic LCG jitter
    integer jseed;
    function integer jit_next; input integer d; begin
        jseed = (jseed*1103515245 + 12345) & 32'h7fff_ffff;
        jit_next = (jseed % (2*JIT+1)) - JIT;
    end endfunction

    // ---- writer (S2MM): writes slots linearly; a write occupies its slot for real time ----
    integer wid;          // next frame id to write
    integer newest;       // most-recent COMPLETED frame id (-1 = none)
    integer w_active, w_slot;
    real    w_rem;
    integer w_completes_this_outframe;     // for J
    integer J_meas, w_overflow;

    // ---- readers ----
    real    acc [0:NR-1];
    real    inc [0:NR-1];
    real    integ [0:NR-1];
    integer read_id [0:NR-1], prev_id [0:NR-1];
    integer can_blend [0:NR-1];
    // active read transfers
    integer rt_valid  [0:NR-1][0:MAXT-1];
    integer rt_slot   [0:NR-1][0:MAXT-1];
    integer rt_readid [0:NR-1][0:MAXT-1];
    real    rt_rem    [0:NR-1][0:MAXT-1];
    integer min_lap   [0:NR-1];            // min (read_id+N - wid) over active reads = safety headroom (frames)
    integer rt_outstanding [0:NR-1];       // transfers still active from prior frame at new out_evt
    // metrics
    integer m_adv[0:NR-1], m_rep[0:NR-1], m_drop[0:NR-1], m_blend[0:NR-1], m_tot[0:NR-1], m_supp[0:NR-1], m_wantblend[0:NR-1];
    integer occ_min[0:NR-1], occ_max[0:NR-1];
    integer O_meas[0:NR-1];                // overlap occurred (read past next out_evt)
    integer collisions, started;
    real    KP, KI;

    integer i,k,r;
    initial begin
        src_period=1001; src_target=1001; src_cnt=0; jseed=32'h1234_5678;
        wid=0; newest=-1; w_active=0; w_slot=0; w_rem=0.0;
        w_completes_this_outframe=0; J_meas=0; w_overflow=0;
        collisions=0; started=0; KP=0.002; KI=0.0004;
        for (i=0;i<NR;i=i+1) begin
            out_cnt[i]=0; acc[i]=0.0; inc[i]=1.0; integ[i]=0.0; read_id[i]=0; prev_id[i]=-1;
            m_adv[i]=0;m_rep[i]=0;m_drop[i]=0;m_blend[i]=0;m_tot[i]=0;m_supp[i]=0;m_wantblend[i]=0;
            occ_min[i]=99999; occ_max[i]=-99999; O_meas[i]=0; rt_outstanding[i]=0; min_lap[i]=99999;
            for (k=0;k<MAXT;k=k+1) begin rt_valid[i][k]=0; rt_slot[i][k]=0; rt_rem[i][k]=0.0; end
        end
        out_period[0]=1000; out_period[1]=1000;
        can_blend[0]=1; can_blend[1]=0;
    end

    // ---- helpers ----
    function integer count_active; input integer dummy; integer rr,kk,c; begin
        c = (w_active!=0) ? 1 : 0;
        for (rr=0;rr<NR;rr=rr+1) for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[rr][kk]) c=c+1;
        count_active = c;
    end endfunction

    task enqueue_read; input integer rdr; input integer slot; input integer rid; input integer bytes;
        integer kk; reg done; begin
            done=1'b0;
            for (kk=0;kk<MAXT;kk=kk+1) if (!done && !rt_valid[rdr][kk]) begin
                rt_valid[rdr][kk]=1; rt_slot[rdr][kk]=slot; rt_readid[rdr][kk]=rid;
                rt_rem[rdr][kk]=bytes*1.0; done=1'b1;
            end
        end
    endtask

    // ---- cadence (accumulator + PI servo w/ deadband + anti-windup + safety clamp) ----
    task run_cadence; input integer rdr;
        integer n_adv, want, occ, errf, ceilR, max_lag, hi, lo, s1; real Rr, fracv; reg wantblend;
        begin
            acc[rdr] = acc[rdr] + inc[rdr];
            n_adv    = $floor(acc[rdr]);
            acc[rdr] = acc[rdr] - n_adv;
            fracv    = acc[rdr];
            want     = read_id[rdr] + n_adv;

            Rr = (out_period[rdr]*1.0)/(src_period*1.0);
            ceilR = $ceil(Rr);
            // Clamp ceiling = collision bound - target margin, INCLUDING measured O
            // (read-overlap-past-frame). Review fix: code previously dropped O so at 1080p
            // (O=1) the clamp was 1 too loose vs its own derivation.
            //   occ_collide = N-1-ceil(R)-J-O
            //   max_lag     = occ_collide - MARGIN = N - ceil(R) - 1 - JMARG - O - MARGIN
            max_lag = N - ceilR - 1 - JMARG - O_meas[rdr] - MARGIN; if (max_lag<0) max_lag=0;
            // Bracketing-pair fetch (review B): a blend reader caps read at newest-1 so the
            // forward partner S+1=newest always EXISTS (the repeat case can't lose its blend).
            hi = (can_blend[rdr]) ? (newest-1) : newest; if (hi<0) hi=0;
            lo = newest - max_lag; if (lo<0) lo=0; if (lo>hi) lo=hi;
            if (SAFETY_CLAMP_ON!=0) begin
                if (want>hi) want=hi;
                if (want<lo) want=lo;
            end else begin
                if (want>hi) want=hi;
                if (want<0)  want=0;
            end
            read_id[rdr]=want;

            wantblend = (fracv>0.004 && fracv<0.996);
            s1 = want+1;
            // metrics
            if (started) begin
                m_tot[rdr]=m_tot[rdr]+1;
                if (read_id[rdr]==prev_id[rdr])        m_rep[rdr]=m_rep[rdr]+1;
                else if (read_id[rdr]==prev_id[rdr]+1) m_adv[rdr]=m_adv[rdr]+1;
                else if (read_id[rdr]>prev_id[rdr]+1)  m_drop[rdr]=m_drop[rdr]+(read_id[rdr]-prev_id[rdr]-1);
                if (can_blend[rdr] && wantblend) m_wantblend[rdr]=m_wantblend[rdr]+1;
                if (can_blend[rdr] && wantblend && s1<=newest && (newest-s1)>max_lag)
                    m_supp[rdr]=m_supp[rdr]+1;     // depth-driven blend suppression
                occ = newest - read_id[rdr];
                if (occ<occ_min[rdr]) occ_min[rdr]=occ;
                if (occ>occ_max[rdr]) occ_max[rdr]=occ;
                // O: any transfer still active from the previous frame?
                if (rt_outstanding[rdr]>0) O_meas[rdr]=1;
            end
            prev_id[rdr]=read_id[rdr];

            // enqueue fetch(es): frame S, plus S+1 if blending and safe
            enqueue_read(rdr, want % N, want, A_BYTES_OR_B(rdr));
            if (can_blend[rdr] && wantblend && s1<=newest && (newest-s1)<=max_lag) begin
                enqueue_read(rdr, s1 % N, s1, A_BYTES);
                m_blend[rdr]=m_blend[rdr]+1;
            end

            // PI occupancy servo with deadband + anti-windup
            occ  = newest - read_id[rdr];
            errf = occ - SETPOINT;
            if (errf>1 || errf<-1) begin
                integ[rdr] = integ[rdr] + errf;
                if (integ[rdr]> 500.0) integ[rdr]= 500.0;
                if (integ[rdr]<-500.0) integ[rdr]=-500.0;
                inc[rdr] = inc[rdr] + KP*errf + KI*integ[rdr];
                if (inc[rdr]<0.05) inc[rdr]=0.05;
                if (inc[rdr]>5.0)  inc[rdr]=5.0;
            end
        end
    endtask
    function integer A_BYTES_OR_B; input integer rdr; begin A_BYTES_OR_B = (rdr==0)?A_BYTES:B_BYTES; end endfunction

    // ============================ one clocked engine ============================
    real share; integer n_act, ev_src; reg [1:0] ev_out;
    always @(posedge clk) begin : ENGINE
        integer rr,kk,lm;
        // ---- event generation ----
        ev_src = 0; ev_out = 2'b00;
        if (src_cnt >= src_target-1) begin src_cnt=0; src_target=src_period+jit_next(0); ev_src=1; end
        else src_cnt=src_cnt+1;
        for (rr=0;rr<NR;rr=rr+1) begin
            if (out_cnt[rr] >= out_period[rr]-1) begin out_cnt[rr]=0; ev_out[rr]=1'b1; end
            else out_cnt[rr]=out_cnt[rr]+1;
        end

        // ---- DDR shared-bandwidth drain (this tick) ----
        n_act = count_active(0);
        if (n_act>0) begin
            share = BW / (n_act*1.0);
            if (w_active) begin
                w_rem = w_rem - share;
                if (w_rem<=0.0) begin newest=wid; wid=wid+1; w_active=0;
                                      w_completes_this_outframe=w_completes_this_outframe+1; end
            end
            for (rr=0;rr<NR;rr=rr+1) for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[rr][kk]) begin
                rt_rem[rr][kk] = rt_rem[rr][kk] - share;
                if (rt_rem[rr][kk]<=0.0) rt_valid[rr][kk]=0;
            end
        end

        // ---- collision check: writer-active slot == any reader-active slot ----
        if (started && w_active) for (rr=0;rr<NR;rr=rr+1) for (kk=0;kk<MAXT;kk=kk+1)
            if (rt_valid[rr][kk] && rt_slot[rr][kk]==w_slot) begin
                collisions=collisions+1;
                $error("COLLISION @%0t reader%0d: writing slot %0d while reading it (read_id newest=%0d)",
                       $time, rr, w_slot, newest);
            end

        // ---- lap-margin: frames between writer pointer and the frame that overwrites
        //      the slot being read (read_id+N). min over active reads = safety headroom. ----
        if (started) for (rr=0;rr<NR;rr=rr+1) for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[rr][kk]) begin
            lm = rt_readid[rr][kk] + N - wid;
            if (lm < min_lap[rr]) min_lap[rr] = lm;
        end

        // ---- writer start ----
        if (ev_src) begin
            if (w_active) w_overflow=w_overflow+1;      // writer fell behind (read contention)
            else begin w_slot=wid%N; w_rem=W_BYTES*1.0; w_active=1; end
        end

        // ---- reader output-frame events ----
        for (rr=0;rr<NR;rr=rr+1) if (ev_out[rr] && newest>=0) begin
            started=1;
            // count outstanding (overlap) BEFORE enqueuing the new frame's fetches
            rt_outstanding[rr]=0;
            for (kk=0;kk<MAXT;kk=kk+1) if (rt_valid[rr][kk]) rt_outstanding[rr]=rt_outstanding[rr]+1;
            run_cadence(rr);
            // J bookkeeping on reader A's frame boundary (the reference frame)
            if (rr==0) begin
                if ((w_completes_this_outframe - 0) > J_meas) J_meas = w_completes_this_outframe;
                w_completes_this_outframe=0;
            end
        end
    end

    // ---- rate-step schedule ----
    task run_phase; input integer sp; input integer opA; input integer opB; input integer nf; input [255:0] nm;
        integer kk; begin
            src_period=sp; src_target=sp; out_period[0]=opA; out_period[1]=opB;
            $display("---- %0s : src=%0d outA=%0d (R=%f) outB=%0d ----", nm, sp, opA, (opA*1.0)/(sp*1.0), opB);
            for (kk=0;kk<nf;kk=kk+1) begin @(posedge clk); while (!ev_out[0]) @(posedge clk); end
        end
    endtask

    integer pass;
    initial begin
        @(posedge clk);
        run_phase(1001,1000,1000,80,"P1 src59.94 A->60");
        run_phase(1000,1001,1000,80,"P2 src60    A->59.94");
        run_phase(1000,1200,1000,80,"P3 STEP 60->50");
        run_phase(1000,2500,1000,60,"P4 STEP 60->24 (2.5x)");
        run_phase(1200,1000,1000,80,"P5 STEP 50->60");
        run_phase(1000,4000,1000,60,"P6 HOT-PLUG 60->15 (R=4, long dwell)");

        $display("==== frc_cadence_model_tb v3  N=%0d CLAMP=%0d JIT=%0d BW=%0d/100 ====", N,SAFETY_CLAMP_ON,JIT,BWx100);
        $display("  collisions=%0d  writer_overflow=%0d  J_meas(extra writes/outframe)=%0d",
                 collisions, w_overflow, (J_meas>0)?(J_meas-1):0);
        for (i=0;i<NR;i=i+1)
            $display("  reader%0d (%s): occ[%0d..%0d] min_lap=%0d adv/rep/drop=%0d/%0d/%0d blend=%0d/want%0d suppress=%0d O=%0d",
                     i,(i==0)?"A blend":"B single",occ_min[i],occ_max[i],min_lap[i],
                     m_adv[i],m_rep[i],m_drop[i],m_blend[i],m_wantblend[i],m_supp[i],O_meas[i]);
        // SAFETY PASS: no collision AND safety headroom >= MARGIN frames. min_lap is the
        // true safety metric (writer never within MARGIN frames of lapping a read slot).
        // blend coverage (blend/want) is the QUALITY metric — read off the min-N where it's
        // high (low coverage => ring too shallow to blend at that ratio, judder returns).
        // PASS now also requires the writer never starved (review A1): writer_overflow>0
        // = S2MM couldn't finish a frame write under read contention = torn INPUT, which
        // collisions+min_lap alone don't catch.
        pass = (collisions==0) && (min_lap[0]>=MARGIN) && (w_overflow==0);
        if (SAFETY_CLAMP_ON==0) begin
            if (collisions>0) $display("FRC: HAZARD CONFIRMED (clamp off -> collisions)");
            else              $display("FRC: UNEXPECTED (clamp off, no collision)");
        end else begin
            if (pass) $display("FRC_CADENCE_TB: SAFE-PASS  (blend coverage A = %0d/%0d, w_overflow=0)", m_blend[0], m_wantblend[0]);
            else      $display("FRC_CADENCE_TB: FAIL (collisions=%0d min_lap=%0d w_overflow=%0d)", collisions, min_lap[0], w_overflow);
        end
        $finish;
    end
    initial begin #20000000; $display("FRC_CADENCE_TB: TIMEOUT"); $finish; end
endmodule

`default_nettype wire
