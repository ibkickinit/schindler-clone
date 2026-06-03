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
