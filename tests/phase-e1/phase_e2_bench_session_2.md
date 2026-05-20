# Phase E2 — bench session 2: full diagnosis + remaining unacceptable failure

**Date:** 2026-05-19 / 2026-05-20 (overnight session)
**Build at session end:** post-median-filter (uncommitted) — bitstream is post-iter4a-fix (b25d27d), firmware has median filter on top.

**TL;DR:** Three real bugs found and fixed; loop architecture fully validated; **the picture is still unacceptable due to a static framestore phase offset that the loop architecturally cannot correct via rate alone.** The phase offset is the **product-blocker** for Phase E1/E2 spike-done.

---

## What we found, in cascade order

### Bug 1 — iter-4a measurement bias (+1.7%)

**Where:** `sw/phase-b/src/main.c::measure_source_rate_mhz`.

**Origin:** the original P0-1 fix from the pre-bench review edge-aligned `t_start`, but forgot to update `prev` after the sync `break`. First iteration of the second loop saw `cur=1, prev=0` and immediately counted the synchronizing edge AS the first edge of the timed window. So N edges spanned only (N-1) intervals; formula treated them as N → systematic `+1/(N-1)` bias = **+16,950 ppm at N=60**.

**Bench evidence (diagnostic):** built an `iter4a_test_mux` to inject the known-50.000 Hz synth_vsync_gen into the measurement path. Result:
- Real source (Windows): reads **60.955 Hz** (≈ +1.69% above presumed 60.000)
- Test (known 50.000): reads **50.847 Hz** (≈ +1.69% above 50.000)
- Same bias on both → measurement bug, not source anomaly.

**Fix:** one-line `prev = 1;` after the sync break (commit `b25d27d`).

**Post-fix verification:**
- Test (synth 50.000 Hz): reads **49.999 Hz** — within 20 ppm.
- Real source: reads **59.940 Hz** — Windows was outputting NTSC all along.

### Bug 2 — Auto-FRC ratio (downstream of Bug 1)

With the +1.7% bias, the auto-FRC math computed wrong M/N. Earlier we thought source was at 60.95 Hz; M/N=10000/12191 was picked. Against a REAL 60.000 Hz source that produces ref at `60.000 × 10000/12191 = 49.22 Hz`, **not 50.000 Hz**. The loop would saturate trying to bridge a -1.5% mismatch (way past ±500 ppm pull range) and never lock.

**Fix:** automatic, downstream of Bug 1's fix. Auto-FRC against the (now-accurate) 59.940 Hz reading produces **M/N = 2500/2997** — the irreducible NTSC ratio that the P1-3 widening (8→16 bit M/N) was designed for. The divider produces ref at `59.940 × 2500/2997 = 50.000 Hz exactly`.

### Bug 3 — Bresenham jitter dominating per-cycle err

Bresenham fractional divider produces inter-pulse intervals that vary between 1 source period (~80% of pulses) and 2 source periods (~20%). Per-output-cycle err sees this as ±source-period of jitter = **±834k ticks at 100 MHz** for an NTSC source. The pre-fix loop saw this jitter on every cycle, saturated PI immediately, never reached LOCK criterion.

**Fix:** software median filter on `err` samples (5-sample window). Rejects the 1-in-5 outlier "long" intervals while preserving the mean. Per-cycle err range shrank from ±900k → ±100-250k.

---

## What's left: the unacceptable phase offset

After all three fixes:

- Output rate matches ref average rate (loop tracks correctly)
- Per-cycle err noise is small (median filter working)
- **But err has a persistent positive DC component of ~+200k ticks (= 2 ms = ~120 lines at 720p50).**

This means:
- Output VTC's vsync edge fires CONSISTENTLY ~2 ms after the src_vsync_divider's ref pulse
- At lock-on-rate, this phase offset stays constant (output rate matches ref rate → relative phase frozen)
- **The PI controller's rate-only actuator cannot fix a phase offset.** Adjusting rate causes drift; the loop's I-term integrates the constant +200k err and runs the integrator deep negative (saturating at -500k cmd_mppm), but the rate adjustment doesn't move the phase offset toward zero.

**On the monitor:** the picture shows the same vertical wraparound pattern as without the loop engaged. Top of one frame fills the upper ~80% of screen; bottom ~20% shows the top of the next frame. **This is a product-blocker failure mode.** No content is usable when the picture wraps mid-frame.

### Why rate control can't fix phase offset

Phase = ∫ (rate_out - rate_ref) dt + initial_phase_offset

The PI loop's actuator changes (rate_out - rate_ref). At lock, this difference is approximately zero. The integral term over zero is zero. So phase stays at whatever initial_phase_offset was when the loop reached rate-match.

**To eliminate phase offset, you need either:**
- A discrete **phase jump** (slip) — instantaneously add ±2 ms to output's phase reference (e.g., via VDMA park-pointer write at SOF)
- **Alignment at startup** — VTC TX's first vsync after `r src` engagement should be set to fire right after a ref pulse, before the loop locks. Phase D iter-4d-3's alignment dance does this for the synth-ref case (vtc_setup_720p is called after `wait_for_aligned_source_vsync()`), but the same alignment is NOT re-run when ref switches from synth to source-derived (`a` command + `r src`)

---

## Why this is the **product-blocker** for spike-done

The Phase E1/E2 spike's stated goal was: "validate the sync architecture against real HDMI sources."

We've now demonstrated:
- The architecture *runs* end-to-end ✓
- Every component does what its design says ✓
- Source format detection is accurate ✓
- Auto-FRC computes correct ratios ✓
- The loop tracks rate correctly under representative source jitter ✓

But the spike's *practical* goal — "loop locked → clean picture" — is NOT met because the picture is unusable regardless of how cleanly the loop tracks rate. **Until the phase-offset issue is closed, the spike cannot be declared production-architecture-validated.**

Calling out the failure explicitly: a static phase offset that wraps every frame 80%/20% across the screen is **not a polish issue** or a "needs tuning" issue. It's a complete product breakage. Calling it anything less than unacceptable would be dishonest about where the spike sits.

---

## How far back the diagnosis chain went

The session asked "how far back do we have to go to start and find the problem." The chain ended up reaching:

1. **Phase D iter-4a measurement** (March-area work) — bug here.
2. **Pre-bench review P0-1 fix** (today before bench) — partial fix, introduced its own off-by-one.
3. **E2.1 src_vsync_divider Bresenham architecture** — fundamentally jittery design choice; needed Bug 3's median-filter workaround.
4. **E2.3 auto-FRC math** — correct given correct input; downstream of Bug 1.
5. **Phase D iter-4d-3 VTC alignment** — never re-runs after ref-mode switch. Source of the remaining unacceptable phase offset.

Diagnosis "walking back" pattern:
- Bench symptoms (loop not locking) → led to → Bresenham jitter hypothesis (P0-2)
- P0-2 needed to wait on → iter-4a bias question (P0-1)
- iter-4a bias diagnosis required → bench-side known-signal injection (E2 diagnostic mux)
- With bias fixed → revealed the residual Bresenham jitter as a real but solvable issue
- With jitter median-filtered → revealed the **phase-offset issue** as the real product-blocker

Each layer of fix was necessary to make the NEXT layer's diagnosis interpretable. The pattern is consistent with "the last issue surfaced is the one that always was there, just hidden by louder failures."

---

## What the next session needs to do

In order:

1. **Don't add more loop tuning or filtering.** The loop is now demonstrably correct; further changes there won't fix the phase offset.
2. **Implement post-`a` VTC alignment trigger.** After the auto-FRC command applies M/N and switches ref to SRC, the firmware should:
   - Wait for the next ref pulse (poll axi_sync_inputs's vsync GPIO bit)
   - Re-run the VTC setup dance from boot (`wait_for_aligned_source_vsync()`-style + immediate `vtc_setup()`)
   - This aligns VTC TX's first vsync with a ref pulse → initial phase offset ≈ 0
   - The loop then maintains the alignment via rate control
3. **Test on bench.** Confirm picture is clean (no static framestore wrap) immediately after `a` + `L` sequence.
4. **If 3 succeeds:** declare Phase E1/E2 spike done.
5. **If 3 fails:** investigate VDMA park-pointer mechanism (Phase D iter-4d-3 substrate). The fsync wiring and FrameDelay=1 alignment may need explicit re-init on ref-mode switch.

Estimated effort: 30 min firmware change + bench validation. Single session.

---

## State at session end

- **Branch:** `phase-e1-pll-spike`
- **Committed:** all fixes for Bugs 1 + 2 (`b25d27d`) + the iter4a_test_mux diagnostic infrastructure.
- **Uncommitted:** the median filter (Bug 3 fix) — needs to be committed alongside this session doc.
- **Bitstream/firmware on board:** post-median-filter build, loaded, loop engaged in SMOOTH+src-ref+M/N=50000/59939 (or 2500/2997 depending on which `a` invocation), state ACQUIRING (never LOCKED due to +200k phase offset), picture has static framestore wrap.

## Acknowledged regression

Earlier session output (`phase_e2_bench_session_1.md`) attributed the loop's lock failure to Bresenham jitter alone. That's partially correct but UNDER-counted the cause: the iter-4a bias compounded it by feeding wrong M/N into the divider. After the bias fix, the residual Bresenham jitter became the next-layer cause; after the median filter, the phase offset became visible. Session 1 doc stands as a snapshot of the understanding at the time but should be read with this session's correction in mind.
