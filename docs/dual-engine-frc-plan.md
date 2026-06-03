# Dual-Engine Mackin-FRC Architecture — Plan & Review Request

**Status:** design, pre-implementation (2026-06-02)
**Audience:** an independent reviewer with no prior context on this codebase.
**Ask:** sanity-check the architecture, the cadence-controller approach, the clocking
plan, and the DDR budget. Specific questions in §9.

---

## 1. What this box is (the thesis that constrains everything)

Schindler 2.0 is a **genlock / frame-rate converter**, not a passthrough. A single
asynchronous content source comes in; the box produces output(s) at a rate/phase set
by a **house/target reference that is NOT the source**. Locking output to source would
make it a repeater — the one thing it must not be. This is a hard architectural law:
**the source is never the output reference.**

Consequence: when source rate ≈ output rate but they're not locked (e.g. 59.94 vs
60.00), the frame buffers drift and the picture slowly rolls ("the wrap"). That roll
is **not a bug to paper over — it is the frame-rate-conversion (FRC) problem the box
exists to solve.** The fix is a proper FRC cadence, not a clock trick.

## 2. The target

**Two independent read engines**, each reading the same HD master from DDR, each with:
- independent **geometry** (zoom/shift, including zoom *past* native res),
- per-engine **Mackin-capable FRC** (drop/repeat that degrades to smooth virtual-shutter
  blend at ugly near-1:1 ratios),
- an **independent output sync source** (its own programmable clock/reference).

Output forms (decided):
- **Output A = HDMI** — Si5351 #1 → pixel clock → `rgb2dvi` (TMDS).
- **Output B = analog NTSC 60i** — Si5351 #2 → 27 MHz → ADV7393 (DAC/encoder, **no FPGA
  serializer**).

```
 async content source (HDMI in)
        │
 dvi2rgb → scaler → VDMA S2MM ─► DDR 5-slot ring  (ONE writer, source rate, HD master)
                                      │
        ┌─────────────────────────────┴─────────────────────────────┐
        ▼                                                             ▼
  READ ENGINE A (HD/HDMI)                                      READ ENGINE B (SD/analog)
  cadence ctrl A (src-vsync ↔ OUT-A vsync)                     cadence ctrl B (↔ OUT-B vsync)
  dual-frame fetch (N, N+1) → Mackin blend A (alpha_A)         dual-fetch → Mackin blend B (alpha_B)
  zoom / shift A                                               zoom / shift B
        │                                                             │
  color A → VTC-A → rgb2dvi → HDMI OUT A                  color B → SD raster → ADV7393 → ANALOG OUT B
        ▲                                                             ▲
  Si5351 #1 (independent ref A)                            Si5351 #2 (independent ref B)
```

Because each output runs on its own clock locked to its own reference, the src↔output
phase **differs per output**, so **cadence control and Mackin are per-engine**. The two
engines are otherwise identical instances differing only in geometry, clock, and
reference.

## 3. Substrate that already exists (so the reviewer knows what's real)

- **Route-B read engine** (`hdl/pg_read_engine_top.v` + `pg_compose.v` + `pg_addrgen.v` +
  `pg_linefetch.v` + `pg_genlock.v`): random-access DDR reader via an AXI DataMover.
  Reads the full **1920×1080 master**, applies runtime geometry, emits an AXIS pixel
  stream. **Pixel path proven on silicon.** Line fill is "packed-beat" (stores raw 64-bit
  DataMover beats at 1 beat/clk, extracts pixels read-side) — this fixed an earlier
  per-row-fetch-latency underrun; sim-proven (latency TB starv=0) + golden bit-exact.
- **Mackin virtual-shutter blender**: HDL + Python golden + 3360-vector sim, **bit-exact**.
  Production wiring is still a **placeholder** (`axis_clone` + a manual blend-alpha set
  over UART `a`). The blender works; the thing that *drives* its alpha does not exist yet.
- **VDMA 5-slot genlock ring**: S2MM writes the HD master into DDR at the source rate
  (Dynamic Master genlock, 5 framestores). `s2mm_frame_ptr` (write pointer) and
  `out_vsync` (read frame boundary) are exposed.
- **SOF realign** (`hdl/axis_to_vid_io.v`): being built now. The output adapter now
  honors a TUSER=SOF tag so each output frame anchors pixel-0 to the stream's SOF beat
  regardless of producer latency (latency-independent alignment, never latches a stale
  beat as pixel 0). This sits **below** the FRC layer and is needed in every FRC mode.

## 4. The core gap: there is no cadence controller

`pg_genlock` today is a **fixed-offset follower**: `read_slot = frame_ptr − READ_DELAY`
(delay = 2), every output frame, forever. With an async source the actual src↔output
phase drifts, the read pointer eventually laps the write pointer, and the picture rolls.
**It has no mechanism to repeat or drop a frame — so it cannot hold phase.** That's the
wrap.

The engines are **independent DataMover readers** of a ring that S2MM fills continuously.
So FRC is purely a **read-side decision**: each output frame, the cadence controller
picks which completed slot to read —
- **repeat** = read the same slot again (output faster than source),
- **advance** = step to a newer slot (normal),
- **drop** = skip a slot (output slower than source),
- and for **blend** mode, fetch the two bracketing slots and emit Mackin's α-weighted mix.

**What's missing = the cadence controller**: a phase accumulator tracking source-frame
arrival (via `s2mm_frame_ptr` advancing) against the output frame clock (`out_vsync`),
that emits per-frame {slot select, repeat/drop, blend α} with hysteresis so it doesn't
thrash and keeps a safe buffer margin. One instance per engine.

## 5. Clocking — the hard constraint, and why the chosen outputs fit

Target dev silicon is the **Zynq-7020** (Zybo Z7-20, -1 speed); production carrier is the
**TE0720** (-2). The 7020 has **4 clock-management tiles** (4 MMCM + 4 PLL), already
heavily used (input `dvi2rgb` MMCM, output pixel `clk_wiz`, ref PLL, etc.). Two HDMI
outputs would need **two TMDS serializers** (each `rgb2dvi` consumes an MMCM for its 5×
serial clock) plus two steerable pixel clocks — that does not fit, and the -1 part can't
even serialize one 1080p60 HDMI (BUFIO 600 MHz limit).

**The analog choice removes the second serializer entirely** — ADV7393 takes 27 MHz and
does encoding + DACs internally. So the whole design has **one** serializer (HDMI). That
collapses the MMCM problem to something that fits the 7020.

```
Si5351 #1 → 74.25 MHz (HDMI pixel, steerable) → rgb2dvi (internal MMCM → 5× TMDS) → HDMI OUT A
Si5351 #2 → 27 MHz   (analog, steerable)      → ADV7393 CLKIN + SD raster logic     → ANALOG OUT B
```

Two **Si5351** programmable clocks are the two independent references: each output's
rate/phase is set over I²C; the per-engine cadence controller converts the one async
source to that output's rate.

**Both chips are currently hardware-blocked but NOT on the critical path:**
- ADV7393 — the bench chip died; replacement on order.
- Si5351 — breakout signal-integrity issues (I²C NAK/RESTART); needs 1 kΩ pull-ups +
  decoupling before multi-byte writes are reliable.

The **entire digital FRC stack (two engines, cadence, Mackin, dual-fetch) is
chip-independent** and bench-proves on the existing HDMI output (engine A) now. Engine
B's analog path + the two Si5351 references integrate when the hardware unblocks.

## 6. DDR bandwidth budget

7020 DDR3 (32-bit) gives roughly **~2 GB/s** usable. Worst case is 1 writer (S2MM) plus
2 engines × Mackin dual-fetch (2 reads each) = up to 5 concurrent streams. Rough numbers
(HD line = 1920×3 = 5760 B):

- **S2MM write** (1080p in): ~373 MB/s.
- **Engine A** (HD out, Mackin dual-fetch): ~500 MB/s (720p out) to ~750 MB/s (1080p out).
- **Engine B** (SD 60i): see below — the small term.

**Engine B and the interlace levers** (the SD/analog leg):
A field is half the lines (NTSC 60i = 60 fields × 240 active lines). source-lines/sec ≈
(lines/sample) × (samples/sec), and the interlacing strategies conserve that product:

| Engine-B strategy | samples/s | src-lines/sample | src-lines/s |
|---|---|---|---|
| 480p60 progressive (worst case) | 60 | ~480 | ~28,800 |
| true 60-field (240 lines, distinct moments) | 60 | ~240 | ~14,400 |
| 30-moment woven (read frame, emit both fields) | 30 | ~480 | ~14,400 |

So choosing 60i already buys ~2× over progressive. **Reading each source moment once and
emitting both fields from buffered lines (the "30 frames" path) halves it again**
(~14,400 → ~7,200) at the cost of on-chip buffer + 30 unique motion moments (PsF-style,
fine for SD). **Mackin's dual-fetch is a flat ×2** on top — and for SD analog, clean
cadence drop/repeat (no blend) may be acceptable, halving engine B once more. Stack:

```
480p60 + Mackin   ~57,600 src-lines/s  → ~330 MB/s   (worst case)
→ 60i field reads ~28,800              → ~165 MB/s
→ 30-moment cache ~14,400              → ~ 83 MB/s
→ cadence-only (no blend) ~7,200       → ~ 40 MB/s
```

**Conclusion:** engine B is the small term regardless; DDR pressure is dominated by
**engine A (HD Mackin dual-fetch) + S2MM** (~0.9–1.1 GB/s of the ~2 GB/s). Engine-B
interlace levers are correct and free up headroom but are not where the margin fight is.
The high-value bandwidth question is **engine A**: does the HD leg need full 60-moment
Mackin blend, or can it drop/repeat at the cadence edges and reserve blend for the worst
ratios? Also: Mackin dual-fetch could be **one DDR fetch + keep the previous frame in
BRAM** instead of two DDR fetches — trading BRAM for ~half of engine A's read bandwidth.

## 7. Build order (incremental; de-risk clocking + dead chips last)

1. **SOF realign** (in flight) — alignment robustness, below the FRC layer.
2. **Cadence controller → engine A** (phase-tracking drop/repeat, gen-lock mode, no blend)
   → **kills the wrap on HDMI.** Fully unblocked, bench now.
3. **Dual-fetch + Mackin → engine A** → smooth blended FRC. Unblocked, bench now.
4. **Instantiate engine B + ADV7393 SD raster/timing path** — HDL + sim now; bench when
   the replacement chip lands.
5. **Two Si5351 references** as the independent output clocks — integrate when the I²C SI
   fix is in. Engine A uses the existing pixel clock as a stand-in until then.

Critical path to the visible win (wrap gone, smooth FRC) = **steps 2–3 on engine A**,
which depend on no blocked hardware.

## 8. Reasoning recap (why these choices)

- **Source never lockable** → the wrap is genuine FRC → needs a cadence engine, not a
  clock-lock. (We explicitly rejected source-locking the output clock.)
- **1×HDMI + 1×analog** (not 2×HDMI) → only one TMDS serializer → fits the 7020's clock
  budget, and SD analog is cheap on DDR.
- **Two Si5351 clocks** → true independent rate/phase per output, set over I²C.
- **Per-engine cadence + Mackin** → each output converts the async source to its own rate
  independently; Mackin gives judder-free results at near-1:1 ratios.
- **Engines are read-side; S2MM owns the ring** → FRC is a clean per-engine read decision;
  no contention on the writer.

## 9. Questions for the reviewer

1. **Cadence controller algorithm.** Best structure for the phase accumulator tracking
   `s2mm_frame_ptr` advance vs `out_vsync`? How to choose drop vs repeat vs blend region,
   with hysteresis that avoids per-frame thrash, for both near-1:1 ratios and clean
   integer ratios (e.g. 60→30, 60→24)? Fixed-point fractional phase width?
2. **Buffer depth.** Is a 5-slot ring enough margin for the cadence to repeat/drop without
   the read lapping the write under realistic drift (±100s of ppm)? When does it need more
   framestores vs tighter hysteresis?
3. **Mackin fetch strategy for engine A.** Two DDR fetches per output frame vs one fetch +
   previous frame held in BRAM? BRAM cost of holding a 1080p (or downscaled) frame vs the
   ~half DDR bandwidth saving.
4. **Does engine A need full blend?** Is per-frame Mackin blend warranted for the HD/HDMI
   leg, or is drop/repeat (blend only near the worst ratios) sufficient and much cheaper?
5. **Interlace strategy for engine B.** True 60-field (60 distinct moments) vs 30-moment
   woven (PsF). Motion quality vs fetch/cadence implications for SD analog. Does the
   cadence controller for B operate on fields or frames?
6. **Independent sync semantics.** v1 = Si5351 free-running at a programmed rate per
   output (cadence absorbs the async source), or v1 = Si5351 steered in a loop to lock to
   an external house reference? Which is the right first target?
7. **Ring interaction with two independent readers.** S2MM writes; both engines read via
   independent DataMovers and pick slots via their own cadence controllers. Any hazard in
   two readers + drop/repeat on a 5-slot ring (e.g. one engine repeating an old slot while
   S2MM wants to recycle it)? Does the ring need per-reader "in-use" protection, or is
   read-behind-write-by-N sufficient?
8. **Anything structurally wrong** with treating FRC as a pure read-side cadence decision
   on a continuously-written ring?

---

## 10. Review resolved (2026-06-02) + behavioral-model gate result

Independent review answered all of §9 and the behavioral model (`sim/frc_cadence_model_tb.v`)
confirmed it. **Locked design:**

- **Q1 cadence = phase accumulator + occupancy PI servo.** Per output frame (frame-atomic,
  at vblank): `acc += inc; n_adv = floor(acc); acc -= n_adv` → `n_adv` 0=repeat / 1=advance /
  ≥2=drop; `frac(acc)` = Mackin α. `inc` is the *measured* source rate — the source is async,
  so a PI loop servos `inc` to hold ring occupancy at ~N/2 (video async-SRC, ascal `o_lltune`).
  Hysteresis is inherent in the integer carry; add a ±0.5-frame deadband on occupancy error.
  Widths: ~24-bit acc/inc (~20 bits tracks ±100 ppm), α = top 8 frac bits.
- **Q3 BRAM-hold is IMPOSSIBLE — deleted.** XC7Z020 = 140×36 Kb ≈ **0.63 MB** BRAM, no UltraRAM
  on 7-series; a 1080p frame is 6.2 MB (even 480p = 0.92 MB). The "previous frame" can only live
  in DDR — which is what dual-fetch already is. There is no BRAM-vs-DDR tradeoff for HD blend.
- **Q4 = α-gated conditional dual-fetch (the key bandwidth decision).** Single DDR fetch when
  α∈{0,1} (locked 60→60, 60→30 never blend), dual fetch only when α∈(ε,1−ε). The 2× read is a
  *peak* (59.94→60 hits it rarely), not a floor. α is known per-frame before the frame.
- **Q7 = hard safety invariant + ring depth.** Never pick a slot (or pair S,S+1 when blending)
  the write pointer can reach before the output frame completes; if a repeat would let the
  writer close within margin, force-advance and eat a 1-frame cadence error. Depth math: two
  readers at different phases × 2 slots (blend) + writer = up to 5 occupied on a 5-slot ring →
  zero headroom → **provisionally bump framestores to 7** and constrain engine B (SD analog) to
  single-fetch/no-blend. Danger is the rate-step *transient* (res change/hot-plug), not steady
  ppm (Q2).
  **⚠️ RETRACTION (2026-06-02 eve):** an earlier note here claimed the model *proved* "N=5
  collides / N=7 clean." That was **confounded** — the safety clamp + N were changed in one
  edit, so `collisions==0` was true *by construction of the clamp at any N* (an independent run
  reproduced N=4/5/7 all passing). The hardened gate (`sim/frc_cadence_model_tb.v`: writer
  jitter + clamp-on/off knob + a real PASS criterion of occ_min≥MARGIN and no depth-driven
  blend suppression) now has teeth, but its current results are **not yet trustworthy** (a
  `read_active`/stale-`read_slot` lifetime modeling issue produces collisions even at N=7 that
  may be artifacts). **The true minimum N and the exact clamp safety-margin (it must account
  for in-frame writer advance + jitter, so max_lag is likely TIGHTER than N−ceil(R)−2) are
  OPEN, to be pinned by the hardened gate next session before the RTL is gated.** The depth
  *direction* (≥6–7, B single-fetch) stands on the prose depth-math; it is not yet sim-proven.
- **Q5 interlace:** true 60-field (cadence-on-fields) for engine B — but raw alternate-line
  decimation twitters on HD verticals; **add a vertical lowpass / interlace filter before field
  decimation** in the B path.
- **Q6 sync:** free-running Si5351 at a programmed rate first (cadence absorbs the async
  source); house-reference steering is a later loop. Controller is identical either way.
- **Q8 structural check:** sound, with one addition — the per-frame slot-switch (and dual-fetch
  pair) **must be frame-atomic and pre-primed at vblank**, composing with the SOF-realign
  alignment layer. If slot-switch isn't atomic+primed, every cadence event throws a one-frame
  alignment transient. **Build the cadence controller ON TOP of the proven alignment layer
  (build #16), not in parallel** — which is exactly the current ordering.

**Model gate:** `sim/frc_cadence_model_tb.v` — S2MM writer + N-slot ring + 2 cadence readers
(accumulator + PI servo + safety clamp), rate steps {59.94↔60, 60→50, 60→24, 50→60}. Result at
N=7: **0 collisions, occupancy bounded [0..4], cadence tracks ratio.** This is the gate the
cadence-controller RTL must keep passing.

## 11. Next session — clamp-margin closed form + ordering (start here)

Independent review worked the clamp margin through analytically so next session validates a
closed form instead of re-deriving it.

**Derivation.** At output-frame start `newest = W`, in-progress slot `= W+1`. The reader holds
`want = W − d` (lag `d`) for the whole frame; during the frame the writer sweeps in-progress
slots `W+1 … W+⌈R⌉+1`. No wrap-collision requires:

```
    N − d > ⌈R⌉ + 1     →     d ≤ N − ⌈R⌉ − 2          (idealized: max_lag = N−⌈R⌉−2)
```

Exact only when (a) the writer completes ≤⌈R⌉ slots/frame and (b) the reader holds exactly one
slot for exactly one frame. Both break in the directions we suspected:
- **Jitter J:** a source frame landing ~1 src-period early lets the writer complete `⌈R⌉+1` in a
  frame → subtract `J` (≈1).
- **Slot-lifetime overlap O:** a reader's DataMover for frame K can still be draining when frame
  K+1's read starts → it transiently holds *two* consecutive frames' slots → subtract `O` (≈0–1,
  and `>0` exactly when DDR contention stretches a read past the frame boundary — when you most
  need margin). **This is the `read_active`/stale-`read_slot` modeling bug**: the model must mark
  a slot in-use from read-START to read-COMPLETE (which may overlap the next `out_evt`), not
  snapshot only the latest pick.

```
    max_lag_robust = N − ⌈R⌉ − 2 − J − O
```

For `R=2.5` (60→24), keeping a real margin ≥2 lands at **N≈8–9 worst-case-stacked**, **~6 if reads
never overlap** — so the exact minimum N hinges on whether *one full-raster read provably fits
inside one output frame with slack* (it should — prove it) and on the real jitter bound. ⇒ the
collisions-at-N=7 seen after hardening are **plausibly REAL** (exactly what `−J−O` predicts), not
pure artifact — but the slot-lifetime bug must be fixed first to tell signal from artifact.

**Depth math with two readers (load-bearing):** the writer must dodge both readers, so
simultaneously-held slots = A(2 when blending) + B(1) + in-progress(1) = **4**; `N−4` absorbs
jitter + overlap + phase-spread. **Keeping engine B single-fetch holds that sum at 4 instead of 5
— so B-single-fetch buys ring margin, not just bandwidth.** Likewise the **blend-disable fallback
for A drops A to 1 slot**, making it a lever on depth as well as DDR.

**Next-session ordering:**
1. **Fix the gate's slot-lifetime model** — mark a slot in-use from read-start to read-complete
   (allow overlap past `out_evt`); have the model **measure J and O** rather than assume them.
2. **Pin true minimum N + clamp margin** against the closed form `N−⌈R⌉−2−J−O`; prove one
   full-raster read fits inside one output frame with slack.
3. **Write the RTL correctly** (`hdl/pg_cadence.v` WIP): real deadband (no integrate at |err|≤1),
   anti-windup integral clamp, power-of-two KP/KI, the validated clamp margin, blend-disable /
   α-snap mode (default-on-blend@720p, off-available@1080p).
4. **Companion `sim/pg_cadence_tb.v`** wrapping the RTL in the (now-honest) writer+ring+safety
   harness; gate the RTL against it.
5. **Independent adversarial Q7 review** — hand over the controller + hardened model; break the
   invariant against real slot lifetimes.

## 12. Gate hardened + min-N (session 2, 2026-06-02) — ⚠️ knee SUPERSEDED by §13

`sim/frc_cadence_model_tb.v` rebuilt as a **DDR shared-bandwidth model with real slot
lifetimes**: the writer and both readers' fetches are byte transfers that split bandwidth
when concurrent, so a read takes real time and a slot is in-use read-START→read-COMPLETE
(can overlap the next frame = the O term). Collision = writer actively writing slot X
while a reader actively reads X. This replaces the toothless snapshot gate.

**Controls (guard against the self-fulfilling trap):**
- **hi-BW vs default-BW (16) → identical, O=0** ⇒ one full-raster read **fits inside one
  output frame** at realistic bandwidth (~1/4 frame); reads don't overlap. lo-BW(5) stress
  correctly shows writer overflow + O=1 (contention regime).
- **clamp-OFF → real collisions at BOTH N=5 AND N=8.** So the **safety clamp is the
  load-bearing mechanism, not the depth** — without it even a deep ring collides.

**Measured:** O = 0 (reads fit), J ≈ 1 (max writes/output-frame at 2.5× ≈ ⌈R⌉, +1 on jitter).

**Validated clamp formula** (the review's closed form, now grounded):
```
    max_lag (clamp ceiling) = N − ⌈R⌉ − 1 − J − MARGIN          (occ_collide − MARGIN)
    occ_collide = N − 1 − ⌈R⌉ − J     (writer laps a read slot when occupancy reaches this)
```
Operating at/below this ceiling gives `min_lap ≥ MARGIN` by construction (measured min_lap
= 3–4 for MARGIN=2). **Key design correction: the occupancy SETPOINT must be SMALL (read
near the head); depth becomes margin + blend-coverage, NOT lag.** Targeting N/2 (mid-ring)
was the bug — it spent all the depth on lag and pinned margin at ~1 regardless of N.

**Ring-depth result (R=2.5 / 60→24, the worst blend ratio; MARGIN=2, J=1, B single-fetch):**

| N | safety (min_lap≥2) | blend coverage (engine A) |
|---|---|---|
| 6 | SAFE-PASS | 158/378 = **42%** (can't blend at 2.5×) |
| 7 | SAFE-PASS | 316/376 = **84%** |
| **8** | **SAFE-PASS** | **353/376 = 94%  ← knee (full Mackin blend)** |
| 9 | SAFE-PASS | 359/376 = 95% (saturated) |

So: **N=6 is the safe minimum for drop/repeat; N=8 is the knee for full Mackin blend at
the worst ratio** (N=7 loses ~16% of blends → judder on those frames). Engine B single-fetch
keeps the two-reader occupied-slot sum at 4, so N=8 fits with headroom; A blend-disable
(α-snap) at extreme ratios drops A to 1 slot — a depth lever for 1080p.

**Remaining gate-polish (non-blocking):** the model fetches S,S+1 forward; for the repeat
case (R<1) real Mackin blends the *bracketing* pair (S−1,S) — refine when wiring Mackin.
The `suppress` metric is superseded by the blend-coverage report.

**→ Next (task #101): apply this to `hdl/pg_cadence.v`** — validated clamp `N−⌈R⌉−1−J−MARGIN`,
small setpoint, real deadband + anti-windup, blend-disable/α-snap mode; then `sim/pg_cadence_tb.v`
gates the RTL against this model; then the adversarial Q7 review.

## 13. Gate review fixes applied → CORRECTED min-N (session 2, 2026-06-03) ✅

Independent review reproduced §12 and found two 1080p failure modes the gate missed, plus a
blend-coverage artifact. All four fixes applied to `sim/frc_cadence_model_tb.v` and re-run:

1. **`writer_overflow==0` added to PASS** — at 1080p bytes with 720p-calibrated BW, the S2MM
   writer can't finish a frame write (torn INPUT); the old gate printed SAFE-PASS anyway.
2. **Measured O fed into the clamp**: `max_lag = N − ⌈R⌉ − 1 − J − O − MARGIN` (code had
   dropped O; harmless at 720p where O=0, but 1 too loose at 1080p where O=1).
3. **1080p byte profile** run (A 4100→6200, W→9300) — see bandwidth finding below.
4. **Bracketing-pair fetch**: a blend reader caps read at `newest−1` so the partner `S+1=newest`
   always exists (the repeat case can no longer lose its blend).

**Corrected results (MARGIN=2, J=1, engine B single-fetch; clamp-off still collides → teeth intact):**

| profile | N=6 | N=7 | N=8 |
|---|---|---|---|
| 720p (A=4100, BW=16) | SAFE-PASS, **blend 100%** | 100% | 100% |
| 1080p, BW scaled to keep A≈¼-frame (BW=24) | SAFE-PASS, **100%** | 100% | 100% |
| 1080p, **720p-calibrated BW=16** | **FAIL — writer_overflow=166, O=1** | FAIL | FAIL |

**The §12 "N=8 blend knee" was a forward-fetch ARTIFACT.** With bracketing, **blend coverage is
100% at the safety floor N=6** — there is no knee. So:

- **Ring depth: N=6** for full blended FRC at 720p AND 1080p (MARGIN=2, J=1, O accounted). The
  clamp using ⌈R⌉ (full-frame writer advance) is conservatively safe — the real read takes ~¼
  frame, so the writer advances far less during it, keeping min_lap ≥ 3 even at the R=4 hot-plug.
- **The binding 1080p constraint is DDR BANDWIDTH, not ring depth.** Engine A's 1080p read is
  ~1.5× the 720p bytes; with the same BW the writer starves (overflow=166, gate now FAILs).
  Needs ~1.5× more usable bandwidth for A, OR S2MM AXI write-QoS priority (the model's
  equal-share arbitration is pessimistic for the writer — real S2MM with write priority starves
  less, but the gate must still surface the pressure). **#3's true calibration — usable DDR3 BW
  under contention + S2MM QoS — is a bench/datasheet item, not pure sim; the gate now FLAGS
  insufficiency rather than hiding it.**

**Status: gate is sharp and green for the RTL.** 720p blended FRC at N=6 is fully validated;
1080p is depth-OK at N=6 but **gated on confirming real usable DDR3 bandwidth (+QoS) for engine
A's larger reads**. Net design constants for `pg_cadence.v`: clamp `N−⌈R⌉−1−J−O−MARGIN`, small
setpoint, bracketing pair, deadband + anti-windup, blend-disable/α-snap (which also halves A's
1080p read demand — directly relieving the bandwidth constraint).

## 14. Cadence RTL written + gated (session 2, 2026-06-03) ✅

`hdl/pg_cadence.v` (commit `5da13c0`) — fixed-point cadence controller, drop-in superset of
`pg_genlock`, implementing the §13 validated design (clamp `N−⌈R⌉−1−J−O−MARGIN`, small
setpoint, bracketing pair, blend-disable/α-snap). Gated by `sim/pg_cadence_tb.v` against the
DDR-contention harness: **PASS at N≥6 (720p + 1080p-scaled-BW, blend & disable); correctly
FAILs the 1080p-starvation case on `writer_overflow`.** Matches the model exactly.

**Two bugs the RTL gate caught (build-then-verify value):**
1. `fp_delta` wrap — `(fp_use−fp_prev)%N` wrapped mod 64 on a slot wrap (N−1→0 gave +N−1, not
   +1); fixed to `(fp_use+N−fp_prev)%N`.
2. **Rate-learning deadlock** — the behavioral model computed `⌈R⌉` from the true period ratio,
   masking that the RTL must *estimate* the async rate. A pure occupancy servo deadlocks (the
   clamp's `⌈inc⌉` pins occupancy in the deadband, so `inc` never learns R). **Fix: feedforward
   — `inc` tracks measured `R = Δnewest`/output-frame (IIR) + a gentle occupancy phase-trim.**
   This is the one place the RTL genuinely departs from the model.

**Open (non-blocking for safety):** blend coverage 275/437 (63%) vs the model's ~99% — the
feedforward IIR lags at rate steps, so some transient frames don't blend. A filter-tuning
(FILT_SH) refinement, not a safety issue.

**Next:** (a) independent adversarial **Q7 review on the actual RTL** + the harness; (b)
integrate into `pg_read_engine_top` (replace `pg_genlock`) + BD + firmware `blend_mode` GPIO;
(c) Vivado build + bench. Not yet integrated.

## 15. Q7 review of the RTL → integration BLOCKED on frame_ptr (session 2, 2026-06-03)

Independent adversarial review of `pg_cadence.v` + the harness. Reprioritized the risk:

- **Feedforward seam (the #1 worry) — GREEN.** The TB already drives the real estimating DUT
  through R-up steps (P4 60→24, P6 hot-plug 60→15, R:1→4) and `min_lap` (global min, incl.
  transients) holds at 3 (N=6) / 4 (N=7) — the IIR lag never eroded margin. Why: the clamp
  reserves a full-frame `⌈inc⌉` of writer advance but a read finishes in ~¼ frame → ~4× over-
  reservation absorbs the lag. Not a blocker.
- **1080p FAIL (writer_overflow) — the gate working.** Bandwidth-bound, per §13. Good.
- **⚠️ BLOCKER — `frame_ptr` absolute reconstruction (items 2+4).** `pg_cadence` rebuilds an
  absolute `write_idx` from `fp_delta = (fp_use+N−fp_prev)%N`, assuming small monotonic +1
  pointer moves. **`pg_genlock.v`'s own comments record that S2MM Dynamic-Master genlock was
  BENCH-DISPROVEN (2026-06-01) to advance framestores linearly — that's why v2 follows the raw
  pointer.** `pg_cadence` reintroduces that assumption in a new form: a single backward pointer
  move (fp 2→1) gives `fp_delta=(1+6−2)%6=5` → `write_idx += 5`, permanent unrecoverable
  corruption; a forward skip counts a stale framestore as completed. **And both TBs feed
  `frame_ptr = wid%N` (clean +1), so the gate is blind to exactly the behavior the project
  bench-proved is real** — the same class as the "model used true R" confound.
- **Blend coverage 63% — metric uninterpretable** (divides blends by ALL frames, not α-
  fractional frames; P3/P4/P6 are near-integer so low is partly correct). Non-blocking; fix the
  denominator before judging.

**Fix before `pg_cadence` replaces `pg_genlock` (the agent's caveat: confirm the real pointer
BEFORE rewriting):**
1. **Confirm real `s2mm_frame_ptr_out` behavior** (ILA / bench) — monotonic +1, or irregular
   (skip/backward)? Prior bench evidence says irregular, but confirm in *this* genlock config.
2. **Make write-tracking robust to non-monotonic `frame_ptr`** — either stay in mod-N space and
   follow the raw pointer like `pg_genlock` v2 (no absolute reconstruction), or clamp `fp_delta`
   to small forward deltas + recover from backward/large moves.
3. **Add non-monotonic + async `frame_ptr` injection to `pg_cadence_tb`** and re-gate (close the
   blind spot the gate currently has).
4. **(cheap)** clamp uses `⌈max(inc, dnew)⌉` (react to measured rate in 1 frame; matters at
   1080p where reads stretch). **(housekeeping)** fix the blend-coverage denominator.

Net: the RTL is well-built and the feedforward departure is sound + absorbed, but it traded
v2's raw-pointer-follow for an absolute reconstruction that reintroduces the v1 assumption, and
the gate can't see it because both TBs feed an idealized pointer. **Close this before bench.**

## 16. Robust redesign + signed-clamp fix + chaos-validated (session 2, 2026-06-03) ✅

Resolves the §15 blocker. `pg_cadence.v` (commits 06ec7e4, c14fe5a) rewritten to follow the
raw pointer in mod-N space — **no absolute write-index reconstruction** (the v1 assumption is
gone): `read_slot = (frame_ptr − lag) mod N`, `lag = clamp(N − eff − J − O − MARGIN, LAG_MIN,
N−2)`, `eff = max(⌈inc⌉, dnew)`. The rate IIR `inc` only sizes lag + weights blend α (non-safety).

- **Signed-clamp bug found by review + fixed:** the lag clamp used an unsigned bit-select
  (`ml_s < LAG_MIN[13:0]`), so a negative `ml_s` escaped the clamp and latched garbage (lag 62/63
  → read ahead of the writer). All-signed now. Gate went green N=4–8.
- **min-N re-pinned (the "N=8 knee" was the bug):** safety floor **N=4** (min_lap 3–5); full
  Mackin blend **N=7** (lag≥2 achievable); blend-disable any N. 1080p-720pBW FAILs on
  `writer_overflow` (correct); 1080p-scaledBW PASS.
- **Robustness EXERCISED (not asserted) — chaos `frame_ptr` injection (`FP_CHAOS`):**
  - forward skip +2/+3 + repeat (strictly NON-DECREASING — the generator injects **0 pointer
    decreases**, asserted by a TAXONOMY-ERROR guard; this is the physically-real "non-linear but
    forward-writing" behavior that broke v1): **N=6/7/8 PASS**, min_lap=2 (=MARGIN held under
    skips) → `dnew` is demonstrably live (lag adapts to the skip). Headline property proven.
  - +pointer DECREASE (`FP_CHAOS=2`, 44 decreases injected): **FAIL** (collisions) — EXPECTED +
    documented: a writer moving to an older slot writes onto the read slot, a physical hazard no
    read-side logic can prevent (it breaks `pg_genlock` v2 too). **The TESTED dividing line is
    exactly "any pointer decrease"** — not a sampling artifact. So the design sits at **v2's
    robustness level**: relies on the forward-writing-ring property (`frame_ptr` never decreases).

## 17. Pre-integration checklist (review pts #1–#3, 2026-06-03)

1. **`frame_ptr`-monotonicity capture is THE gate, not a "cheap confirm."** The entire safety
   argument now rests on one physical assumption — `s2mm_frame_ptr_out` never decreases. It's the
   load-bearing validation. **The existing sub-frame ILA captures CANNOT confirm it** (~27 µs ≪ a
   16 ms frame → `frame_ptr` is constant across them); need a **multi-frame trigger sampling the
   pointer over hundreds of frames**, captured **under the conditions that would provoke a
   non-monotonic move if one exists**: genlock drift at a near-1:1 mismatch (the wrap) AND a
   resolution-change / hot-plug — not steady state.
2. **Chaos dividing line is explicit + tested** — "decrease = the one unhandled hazard" (§16),
   `pointer_decreases_injected` reported; forward chaos = 0 decreases → PASS.
3. **Re-pin min-N on the corrected gate before BD numbers bake in.** Post-fix: safety floor N=4,
   full-blend enable N=7. The framestore count that goes into the **BD/firmware must be the
   coverage-driven number (≥7, re-measured with the bracketing pair at the worst deployment
   ratio)** — NOT the buggy run's apparent N=8, nor the legacy 5-slot ring. Decide the exact ring
   depth from re-measured blend coverage at integration time.

**Status:** the cadence RTL is robust to the realistic non-linear pointer and gated across
clean + forward-chaos + 1080p corners. Remaining before integration: (1) a cheap bench/ILA
confirm that real `s2mm_frame_ptr_out` is forward-monotonic (never decreases — same assumption
v2 already ships on); (2) integrate into `pg_read_engine_top` (replace `pg_genlock`) + BD +
firmware `blend_mode` GPIO; (3) Q7 round-3 on the integrated controller; (4) Vivado build + bench.

## 18. End-state simplifications + unblock-by-borrowing (session 2, 2026-06-03)

Two architectural moves that remove dependence on blocked hardware and on the frame_ptr
assumption. Recorded as targets; not changing the current transitional build.

**(A) S2MM → plain circular writer (makes the frame_ptr assumption true BY CONSTRUCTION).**
The decrease concern (§15–§17) exists only because S2MM runs in **`Dynamic Master` genlock
(`c_s2mm_genlock_mode=2`)** — a holdover from when the VDMA's own MM2S did the FRC (Slave). That
master-mode framestore management is what makes `s2mm_frame_ptr_out` non-linear. Now that our
read engine + `pg_cadence` own ALL the FRC, the S2MM genlock-master role is redundant. **In the
end-state (dual read engines, VDMA MM2S retired), set S2MM to a plain circular writer (genlock
off):** it then writes framestores 0,1,2,3,4,0,… monotonically and `s2mm_frame_ptr_out` becomes
a monotonic counter — **a decrease is impossible by design**, and `fp_mon_detector` demotes from
load-bearing gate to a cheap permanent sanity-check. *Not a today-switch:* the current build
still has the VDMA MM2S in the mux (`sel=0` passthrough), whose Slave genlock needs the S2MM
Master to follow — so this lands when the VDMA MM2S is retired (which the dual-engine end-state
does anyway). If it ever jumps back before then: the pointer-follow design degrades to a
one-frame tear and self-heals next frame (NOT permanent — that was the old absolute-index trap).

**(B) Borrow an FPGA clock to validate the architecture NOW — don't wait on the Si5351.**
`pg_cadence` + the dual-engine path are **clock-source-agnostic** (they convert the async source
to whatever the output rate is, regardless of clock origin). The Si5351 only adds two *separable*
features: runtime-programmable rate, and steering/locking to an external reference — neither is
needed to prove the FRC stack. So **synthesize the second output rate from a fixed on-chip clock**
(on-board crystal / PS `FCLK` / `clk_wiz`) at a rate deliberately different from output A (e.g.
A=60, B=59.94 or 50) → two genuinely independent rates exercising the two per-engine cadence
controllers in the final topology. Swap the Si5351 in later only to add programmability +
external lock to an already-proven core. Caveats: (i) MMCM/CMT budget is tight on the 7020 — a
fixed borrowed clock fits where 2×HDMI wouldn't, and the analog leg's 27 MHz needs no serializer
(cheap on-chip); (ii) the clock is not the analog path's only dependency — the **ADV7393 DAC**
(dead, replacement inbound) is still needed for a physical analog *output*, but the dual-engine /
dual-cadence / independent-rate **logic** is testable now (engine B to a borrowed clock domain,
verified via ILA/scope, or a second HDMI at a borrowed offset rate as a stand-in).

### Repo pointers for the reviewer
- Read engine: `hdl/pg_read_engine_top.v`, `hdl/pg_compose.v`, `hdl/pg_genlock.v`,
  `hdl/pg_addrgen.v`, `hdl/pg_linefetch.v`
- Output adapter (SOF realign): `hdl/axis_to_vid_io.v`
- Mackin blender + sim: `hdl/` (mackin) + `sim/mackin/`
- BD build: `tcl/build_phase_b.tcl` (+ `tcl/readengine_b_bd.tcl` additive integration)
- Prior forensics: `docs/readengine-b.md`, `docs/build-manifest.md`, project wiki
  `docs/wiki/START-HERE.md`
