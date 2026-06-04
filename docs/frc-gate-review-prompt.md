# Review request — sanity-check the FRC cadence gate BEFORE the RTL is built on it

**You caught the last confound (the self-fulfilling gate). Please try to break this one
before I write the cadence-controller RTL against it.** I'd rather you find a hole now than
have the RTL inherit it.

**Artifact:** `sim/frc_cadence_model_tb.v` @ commit `167f741` (branch `readengine-b-integration`).
Findings written up in `docs/dual-engine-frc-plan.md` §12.

## What the gate is now

A DDR shared-bandwidth model with real slot lifetimes. The S2MM writer and both readers'
fetches are byte transfers; when concurrent they split a fixed bandwidth `BW`, so a read
takes real time and a slot is in-use from read-START to read-COMPLETE (can overlap the next
output frame = the **O** term). **Collision = the writer is actively writing slot X while a
reader is actively reading slot X.** Cadence = phase accumulator (`acc+=inc; n_adv=floor;
frac=α`) + PI occupancy servo (deadband + anti-windup) + a safety clamp.

Reproduce (you ran it last time):
```
xvlog frc_cadence_model_tb.v
# sweep N, MARGIN=2:
xelab -top frc_cadence_model_tb -snapshot s -generic_top N=8 -generic_top MARGIN=2 && xsim s -runall
# controls:
xelab ... -generic_top BWx100=100000   # hi-BW: reads ~instant
xelab ... -generic_top BWx100=500       # lo-BW: contention
xelab ... -generic_top N=8 -generic_top SAFETY_CLAMP_ON=0   # clamp off
```

## Claims I'm making (please attack each)

1. **O=0 — "one full-raster read fits in one output frame at realistic BW."** Control:
   hi-BW (`BWx100=100000`) and default (`BWx100=1600` = 16.0) give identical results, both O=0.
2. **The clamp is load-bearing, not the depth.** Control: `SAFETY_CLAMP_ON=0` collides at
   **both** N=5 and N=8.
3. **Validated clamp ceiling** `max_lag = N − ⌈R⌉ − 1 − J − MARGIN` (= `occ_collide − MARGIN`,
   with `occ_collide = N − 1 − ⌈R⌉ − J`) → `min_lap ≥ MARGIN` by construction (measured 3–4 @ M=2).
4. **Setpoint must be small** (read near head); depth = margin + blend coverage, not lag.
5. **Min-N (R=2.5 / 60→24, MARGIN=2, B single-fetch):** N=6 safe-min for drop/repeat; **N=8 =
   knee for full Mackin blend** (coverage 42/84/94/95% at N=6/7/8/9).

## Where I'm LEAST confident — please prioritize these

- **(A) Byte/BW calibration is abstract and 720p-flavored.** `W_BYTES=6200, A_BYTES=4100,
  B_BYTES=500, BW=16` are hand-scaled to "engine-A blended fetch ≈ ¼ frame at 2 GB/s / 720p."
  **At 1080p engine A reads ~1.8–2× more bytes/frame and the master write is bigger** — does O
  stay 0, or does 1080p contention push reads past the frame boundary (O→1), which would move
  the min-N up by 1 per the closed form? I have NOT run a 1080p byte profile. This is my #1
  worry. Are my ratios even right?
- **(B) Blend-pair direction.** The model fetches S and **S+1 (forward)**. For the repeat case
  (R<1, output faster) real Mackin blends the **bracketing** pair (S−1, S) — the future frame
  S+1 doesn't exist yet. Does fetching forward bias the blend-coverage numbers (especially the
  ~6% "misses" at N=8, and the P1/P5 repeat-dominant phases)? Should the coverage table be
  re-measured with bracketing-pair logic before I trust the 94% knee?
- **(C) Two-reader adversarial phasing.** Reader B is fixed at `out=1000` while A sweeps. Are
  their phases ever genuinely worst-case-aligned against the writer simultaneously, or does the
  fixed-B choice accidentally avoid the stacked-occupancy case the depth math (sum=4) is meant
  to cover? Should B's phase be swept/offset to force the bad alignment?
- **(D) Off-by-one in `occ_collide`.** I have `occ_collide = N−1−⌈R⌉−J`; your earlier
  derivation gave safe lag `d ≤ N−⌈R⌉−2`. Reconcile: is my `−1−J` vs your `−2` consistent
  (J folds the +1), or have I lost/gained a frame somewhere?
- **(E) Transient coverage.** Only 5 rate-step phases, `JIT=8` ticks (~0.8% of a 1000-tick src
  period). Is that a strong enough transient/jitter stress to trust min_lap, or should JIT and
  the step set be harsher (hot-plug = instantaneous large R change, longer dwell)?

## Known gaps I'm already treating as non-blocking (flag if you disagree)

- The `suppress` metric was superseded by the blend-coverage report.
- The repeat-case blend-pair (B above) — I planned to fix when wiring real Mackin; tell me if
  it invalidates the min-N conclusion *now* instead.

## The decision this gates

If the gate holds, I apply the validated clamp `N−⌈R⌉−1−J−MARGIN` + small setpoint + the owed
PI fixes (deadband/anti-windup) + a blend-disable/α-snap mode to `hdl/pg_cadence.v`, then a
companion `sim/pg_cadence_tb.v` gates the RTL against this model, then you get the adversarial
Q7 pass on the actual controller. **So: is the gate sound enough to pin the clamp formula and
N=8, or does (A)/(B)/(C) move the answer?**

---

## ROUND 2 — adversarial Q7 review of the actual RTL (2026-06-03)

The gate held under your last review (fixes applied: writer_overflow in PASS, O in clamp,
bracketing pair, 1080p profile → §13). The cadence RTL is now written and gated:

**Artifacts @ commit `5da13c0`:** `hdl/pg_cadence.v` + `sim/pg_cadence_tb.v` (gates the RTL
against the §13 DDR-contention harness). Result: PASS at N≥6 (720p + 1080p-scaled-BW, blend &
disable); FAILs the 1080p-starvation case on `writer_overflow`. §14 has the summary.

**Please try to break the actual controller against the Q7 safety invariant — on real slot
lifetimes.** Specifically:
1. **The one model→RTL departure:** the RTL can't use true R, so `inc` is a FEEDFORWARD IIR of
   `Δnewest`/output-frame + a gentle occupancy trim (pure occupancy servo deadlocked — the
   clamp's `⌈inc⌉` pinned occupancy in the deadband). **Does the IIR lag at a rate STEP make
   `⌈inc⌉` transiently wrong → clamp transiently too loose → a collision the steady-state gate
   misses?** This is the highest-risk seam.
2. **`fp_delta` reconstruction** of the absolute write index from a mod-N pointer — safe if
   VDMA advances `frame_ptr` by <N between samples. Is that assumption sound for real S2MM
   Dynamic-Genlock (can it jump >1, repeat, or briefly glitch the pointer)?
3. **Blend coverage 63% vs the model's 99%** — is the gap purely benign (feedforward lag in
   near-1:1 phases where α≈0 anyway), or is the controller silently dropping blends it should do?
4. The TB registers DUT inputs (nonblocking) to kill a posedge race — does that hide any real
   1-cycle timing hazard the integrated design would have against live VTC vsync / VDMA frame_ptr?

If it survives this, the plan is: integrate `pg_cadence` into `pg_read_engine_top` (replace
`pg_genlock`) + BD + firmware `blend_mode` GPIO, then Vivado build + bench.

---

## ROUND 3 — integrated gen-lock cadence + the Gray-code discovery (2026-06-03)

Since round 2, the bench monotonicity check (autonomous builds #17–#20 with a sticky
fp_mon_detector) produced a **surprise that changes the picture**, and pg_cadence is now
integrated into the read engine. Please probe the new seams.

**What we found (the big one): `s2mm_frame_ptr_out` is GRAY-CODED.** Raw capture showed it
taking values {2,4,5,6,7,10,12,13,14,15}; every consecutive value differs by exactly 1 bit;
Gray→binary decode = a clean monotonic +1 counter (steps {+1:79, wrap:8, other:0}). So:
- The pointer **never decreases** — the monotonicity assumption HOLDS on silicon. (The
  detector's repeated `decreased=1` was it reading Gray as binary; same bug I had in my model.)
- **Latent bug fixed:** `pg_cadence` AND `pg_genlock` had been treating `frame_ptr` as binary
  (clamp/`-READ_DELAY`/`mod`). Now both do `fp_use = gray2bin(fp_stable) % NUM_FRAMES`. All three
  TBs green (pg_cadence_tb PASS, pg_genlock_tb + capstone golden Total errors=0). Commits
  800d6d1 / aa58b89 / d44f132.
- `pg_genlock` v2 only *looked* clean before because the bench source is a STATIC grid (every
  framestore holds the same image) — so a mis-decoded slot showed the identical picture. This
  invalidates "read-engine clean ⟹ pointer fine" for anything tested on static content.

**Integration (commit 8a4849d):** `pg_read_engine_top` now instantiates `pg_cadence` in gen-lock
mode (`blend_mode=0`, drop/repeat, single fetch) in place of `pg_genlock`. Capstone golden green
(slot-independent pattern, so it confirms the swap doesn't break the pixel path but does NOT
exercise cadence/decode timing). Building + programming now; bench wrap-kill is a visual check.

**Please attack these — the new seams:**
1. **Decode→slot mapping (the #1 open risk).** We proved the pointer is monotonic Gray, but we
   have NOT confirmed `framestore = gray2bin(fp) % NUM_FRAMES` points at the slot actually holding
   the freshest frame. The decoded cycle is **10 states (binary 3..12) for c_num_fstores=5** — odd
   (2× the store count; offset 3). On a static grid we can't tell if the offset/period is right
   (all slots identical). A wrong decode→slot offset would read a valid-but-wrong-timed frame →
   invisible on static, a temporal offset on MOTION. How would you pin the exact mapping —
   correlate decoded fp against which slot S2MM just wrote (needs a per-slot marker / motion)?
2. **The 10-state period.** Why 10 for 5 framestores? Genlock frame-counter vs store-index? Does
   `mod 5` correctly fold it, or is the true store = decoded `mod` something else?
3. **Slot-switch atomicity vs SOF-realign (your round-2 Q8).** The cadence picks read_slot at
   `out_vsync`; the read engine must have the first line of the new slot primed before active
   video, composing with the SOF-realign layer (build #16). Is the per-frame slot-switch
   frame-atomic + pre-primed here, or can a cadence slot-change throw a one-frame alignment glitch?
4. **Gray CDC.** Gray coding means 1 bit changes per step → the 8-cycle-stable debounce is now
   belt-and-suspenders. But skips (multi-bit Gray) and the genlock's actual transitions — any CDC
   hazard on the decoded value at a skip?
5. **gen-lock-mode sufficiency.** blend_mode=0 = drop/repeat (no blend). Does that kill the wrap
   cleanly on its own (the goal), or is there residual judder that only the Mackin blend (step 3,
   dual-fetch) resolves?

We'll bring the bench result (does the wrap die? motion behaviour?) to this. fp_mon_detector
stays as a permanent Gray-aware health bit.

---

## Round 4 — bench result + the residual pixel-shift (2026-06-03)

Full record: `docs/readengine-b-cadence-bench-result.md`. Build #21b (pg_cadence gen-lock mode,
WNS +0.235) validated motion; build #22 (WNS +0.153, +δ-measurement diag) measured the residual
offset. Both on board, both clean on motion.

**Result — the round-3 open risks closed favourably on MOTION:**
- Motion (Osee input 2) and 1080p60 laptop (input 3) are **clean on the monitor** — no judder,
  roll, tear, or periodic hitch. Telemetry tracked (`in=1920x1080 src=60 out=60`).
- This validates the **gen-lock cadence**, the **Gray decode**, and crucially the
  **decode→slot mapping** (round-3 risk #1): a wrong `gray2bin(fp) % 5` offset/period would have
  surfaced as a constant temporal offset or hitch on motion — it did not. The static grid could
  not disambiguate this; live motion does. So `framestore = gray2bin(fp) % NUM_FRAMES` is
  empirically pointing at the freshest frame, and gen-lock-mode (drop/repeat, no blend) kills the
  wrap cleanly on its own (round-3 Q5: yes, for this 60→60 case).
- Color pipeline confirmed at identity (UART `i`) — not a factor.

**New question for you — the residual offset is a per-line WRAP (symptom refined at bench).**
Closer look: source pixel 0 lands a few pixels IN from the left, and **each line's last few
pixels wrap into the START of the next line**, constant and **non-accumulating** (vertical grid
lines stay straight — no shear). Same on every source. This is a **horizontal phase offset in the
AXIS→video stream, not a rigid raster shift** — a VTC porch shift can't wrap end-of-line content
into the next line, so we are *withdrawing the VTC-porch hypothesis*.

Resample/address math is clean (output(0,0)→source(0,0); addrgen DDA no init phase; linefetch
`rd_col=0`=src px0; compose SOF on genuine first pixel). The content is right; only its horizontal
**anchor** is off by δ.

**Mechanism (hypothesised, then MEASURED).** `axis_to_vid_io` has
`s_axis_tready = vtg_active_video && enable` → it consumes **only during active video**. The
SOF-realign re-arms each frame (`started<=0` at the `vtg_vsync` rising edge) and discards non-SOF
head beats until the SOF beat appears (then SOF=pixel 0). Because tready is active-gated, the δ
residual beats (the prior frame's tail still queued when blanking began) can only be drained by
**burning the first δ active-pixel slots** → the SOF beat lands at active column δ → every line is
shifted +δ and the last δ px wrap to the next line. (At this interface the stream is 24-bit, one
pixel per beat, so δ is directly in pixels.)

**MEASUREMENT (build #22, 2026-06-03).** We added `axis_to_vid_io.predrain_snap[31:0]`
(`[15:0]`=δ = active cycles before the SOF beat emits; `[31:16]`=of those, stale beats discarded
vs the rest being starves), routed onto the dead-in-route-B scaler diag ch1, firmware `DRAIN:`
line. Result, **constant every frame**:

    DRAIN: delta_px=6 (stale=6 starve=0)

δ = **6 px constant, 100% stale, 0 starve.** Confirms the mechanism: six residual beats discarded
in active video; producer is never late (starve=0 ⇒ NOT a `pg_compose` priming issue).

**PROPOSED FIX (for your review — not yet committed).** Flush the residue during **blanking** so
the SOF beat is at the FIFO head exactly when active video begins. In `hdl/axis_to_vid_io.v`:

```verilog
// today:
assign s_axis_tready = vtg_active_video && enable;

// proposed:
wire in_blank     = !vtg_active_video;
// While not yet started, drain non-SOF head beats during blanking; once the SOF
// beat reaches the head, drain_presof deasserts so SOF waits and becomes pixel 0
// at active column 0. SOF beat is never consumed in blanking (excluded via !tuser).
wire drain_presof = enable && !started && in_blank && s_axis_tvalid && !s_axis_tuser;
assign s_axis_tready = enable && (vtg_active_video || drain_presof);
```

`consume`/`emit_pix`/`started` logic is unchanged: drained beats fall in blanking
(`vtg_active_video=0` → emit black, not shown), `started` stays 0 (drain excludes `tuser`), and on
the SOF beat at active col 0 `started` latches as today. Built-in check: after the fix
`DRAIN: delta_px` should read **0**.

**BLAST RADIUS.** `axis_to_vid_io` is **shared** by the read-engine path AND the proven VDMA
passthrough/scaler path (route-B was deliberately additive-with-a-mux to protect passthrough; this
fix is NOT additive). The wrap is "as before" (common to all builds), so fixing it on both is
correct — but passthrough regression is the risk to vet.

**Verification plan (before bench):** extend `sim/axis_sof_tb.v` with a case that injects δ pre-SOF
residue and asserts pixel 0 lands at column 0 (and `predrain_snap`→0); then build #23 → confirm
`DRAIN: delta_px=0` on the read engine AND a passthrough (mux sel=0) sanity pass.

**Questions for you:**
1. Mechanism + fix sound? Anything that makes the blanking-flush wrong or incomplete?
2. **Shared-path safety (the real risk):** on the VDMA MM2S path, does asserting tready during our
   blanking to drain residue risk desyncing VDMA's frame/genlock accounting, or is draining the
   prior frame's tail beats benign there as it is for the `pg_compose` FIFO?
3. Edge cases: (a) SOF never arrives / arrives mid-active (we measured starve=0, but is the
   degrade-to-today's-behaviour path correct?); (b) any way to over-drain past the SOF beat;
   (c) `vtg_vsync` re-arm vs the start of blanking — timing hazard?
4. Is `in_blank = !vtg_active_video` the right blanking signal, or should it be
   `vtg_hblank || vtg_vblank` (the dedicated VTC blank outputs we already bring in)?

### Round 4 — OUTCOME (2026-06-03)

Agent endorsed the diagnosis + fix and added the **drain-cap** requirement (unbounded blanking-
drain would turn a dropped SOF into a multi-frame desync). Incorporated: `MAX_DRAIN=16`,
`vtg_vblank`-scoped, plus a missing-SOF sim case proving the bound. Root cause refined to the
**shared color-stack pipeline depth** (not `pg_compose`). Shipped as commit `78ce592` (build #23).
**Silicon-confirmed:** `DRAIN: delta_px=0` across static / 2× zoom / full / passthrough; wrap gone,
motion clean, position perfect. Sim PASS 230+6. See `docs/readengine-b-cadence-bench-result.md` and
`docs/build-manifest.md` (2026-06-03 section). ⚠️ 3-cold-boot verify owed before ✅ CLEAN promotion.

---

## Round 5 — Mackin blend on silicon: framestore-depth blocker + latency proposal (2026-06-04)

**State.** Builds #24→#27 wired the Mackin blend end-to-end. #27 on board (timing MET, WNS +0.248):
3-way `blend_mode` (0=off, 1=intelligent, 2=force), per-frame blend telemetry (`BLEND: n/60`),
200% scale, web UI (blend select + scale/shift sliders). Blend **datapath** sim-proven
(`pg_blend_tb`: dual-fetch fed `starv=0`, lerp bit-exact). Conditional dual-fetch (2nd line only
when `blend_en`), 3-stage pipelined lerp, `bm_q1[*]` CDC false-pathed.

**Bench finding — blend NEVER engages (the blocker).** With Osee feeding 1080p24 → 720p60, the
telemetry reads `BLEND: 0/60` in **all three modes incl. Force**. Root cause is **framestore depth**,
not wiring:
```
lag = clamp( NUM_FRAMES − eff − J_MARG(1) − O_MARG(0) − MARGIN(2) − 1 , LAG_MIN(1) , NUM_FRAMES−2 )
```
At `NUM_FRAMES=5` (VDMA c_num_fstores=5) and `eff=1` (output-faster cases, 24/30/50/59.94→60):
`lag = clamp(5−1−1−0−2−1, 1, 3) = clamp(0,1,3) = 1`. But `do_blend` requires **lag ≥ 2** (S+1 must
be a *completed* frame to interpolate toward). So at N=5 the read sits 1 behind the writer, has no
completed "next" frame, and blend can never fire — confirmed by `BLEND=0` even in force. The blend
is correct; it has nothing to blend *with* at 5 stores.

**Proposal (#28).**
1. **VDMA ring 5→7** (`c_num_fstores 7`, `NUM_FRAMES=7`, +DDR alloc). At N=7, eff=1:
   `lag = clamp(7−1−1−0−2−1,1,5) = 2` → blend engages. (Gate §13/§14 validated N≥6–7 for blend.)
2. **Mode-dependent lag** — keep `lag=1` when blend is off (minimum latency), bump to ≥2 only when
   actually blending → the +1 frame of latency is **opt-in** (Intelligent/Force only); drop/repeat
   stays minimum-latency even on the N=7 ring.
3. (separate track) signed-position pan / 200% zoom-pan in `pg_addrgen`.

**Latency analysis (Justin's concern).** `lag` *is* the input→output latency in frames:
`delay ≈ lag × input_frame_period + ~1 frame fixed pipeline`.
- N=5, lag=1 → ~1 input-frame buffering (+~1 fixed) ≈ ~2 frames end-to-end.
- N=7, lag=2 (blend) → **+1 input-frame** (60Hz +16.7ms, 30Hz +33ms, 24Hz +42ms) ≈ ~3 frames.
The +1 frame is **inherent to temporal interpolation** (must buffer S+1 to blend toward it — every
motion-interpolating display does this). **The extra framestores add ZERO latency** — latency = lag,
not N; the 2 added slots are headroom/jitter margin sitting in DRAM. So N=7 ≠ "7 frames of delay";
it's lag(2) of delay + 5 slots of headroom.

**Questions for you:**
1. **N=7 vs N=8.** Is 7 the right floor, or do we want 8 (the §14 "knee" for full blend coverage)?
   Tradeoff: N=8 = more DDR (8×6.2 MB ≈ 50 MB) and possibly lag=3 (more latency) unless the
   mode-dependent lag caps it at 2. Does coverage at N=7 leave gaps across 24/30/50/59.94→60?
2. **Mode-dependent lag safety.** Switching `lag` per-frame (1↔2 as blend toggles, or as the cadence
   enters/leaves blend) shifts the read slot by one → at the transition frame the read pointer jumps
   back/forward a slot, which could re-show or skip a frame (1-frame hitch). Is that acceptable, or
   should lag only change at a safe boundary / ramp? Any collision risk vs the writer at the change?
3. **DDR bandwidth at N=7 + dual-fetch.** `pg_blend_tb` proved 2× line-fetch fits the per-row budget
   in isolation (~0.87 fill/budget). On real shared DDR (S2MM write @ source + the dual read), does
   7-store blending hold, or do we risk underrun when blend engages? (Conditional fetch limits it to
   blending frames.)
4. **eff at the high end.** At 24→60 eff=1 (lag=2 at N=7) so blend should engage — but confirm: are
   there input rates in scope where eff>1 pushes lag<2 even at N=7, leaving blend off?
5. **Output-format runtime.** The box does multi-rate INPUT → fixed 720p60 OUTPUT (build-time MMCM
   clock + VTC). Runtime *output* rate/res = MMCM dynamic reconfig (clk_wiz DRP) + VTC reprogram +
   rgb2dvi relock, **or** the external Si5351 per-output clock (the dual-engine architecture). For v1,
   is the Si5351 the right path, or is on-chip MMCM-DRP worth doing first? (1080p60 out stays blocked
   on Zybo -1 regardless; 720p60 + 1080p30 are the in-spec on-chip modes.)

Artifacts: `#27` commit `22d5759` (branch `readengine-b-integration`); `docs/mackin-blend-integration.md`;
`docs/build-manifest.md`. Bench: `BLEND:`/`DRAIN:` over UART; web UI at :8080.
