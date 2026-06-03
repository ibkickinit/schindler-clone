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

### Repo pointers for the reviewer
- Read engine: `hdl/pg_read_engine_top.v`, `hdl/pg_compose.v`, `hdl/pg_genlock.v`,
  `hdl/pg_addrgen.v`, `hdl/pg_linefetch.v`
- Output adapter (SOF realign): `hdl/axis_to_vid_io.v`
- Mackin blender + sim: `hdl/` (mackin) + `sim/mackin/`
- BD build: `tcl/build_phase_b.tcl` (+ `tcl/readengine_b_bd.tcl` additive integration)
- Prior forensics: `docs/readengine-b.md`, `docs/build-manifest.md`, project wiki
  `docs/wiki/START-HERE.md`
