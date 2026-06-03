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
WNS +0.235) on board.

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

**Our lead hypothesis:** `axis_to_vid_io` has `s_axis_tready = vtg_active_video && enable`, so it
consumes **only during active video**. The SOF-realign re-arms each frame (`started<=0` at vsync)
and discards non-SOF head beats until the SOF beat appears. Because tready is active-gated, δ
residual beats (frame N's tail still in the output FIFO at blanking start) can only be drained by
**burning the first δ active-pixel slots** → the SOF beat (pixel 0) lands at active column δ →
every line shifted +δ, last δ px wrap to next line. δ in 64-bit beats (~2.67 px) → "a few pixels."

**Proposed fix:** flush pre-SOF residue during **blanking** — assert tready while `!started` to
drain non-SOF head beats in blanking, then hold once the head IS the SOF beat so it becomes pixel
0 at active column 0. Gate to active-video thereafter as today.

**Questions for you:**
1. Does the residue-drain-in-active mechanism hold up, or is there a more fundamental reason pixel
   0 lands at column δ (e.g., producer leaving a deterministic FIFO residue across the frame
   boundary that we should fix producer-side in `pg_compose` instead)?
2. Is the proposed blanking-flush safe against (a) a SOF that never arrives / arrives mid-active,
   (b) over-draining into the next frame, (c) the `vtg_vsync` re-arm timing? Any edge cases?
3. Best ILA signal to confirm δ before we touch RTL — beats drained before SOF emit per frame, or
   output-FIFO occupancy latched at `vtg_vsync` rising?
