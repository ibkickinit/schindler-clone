# Projective front-end — Phase P2 results (full-engine integration, sim-proven)

**Scope:** P2 only — integrate the P1 projective address generator (`pg_projective`) into the full
warp datapath (`pg_warp_engine` / `pg_warp_top`) and prove, **in simulation**, that keystone /
corner-pin **completes a full frame with no wedge/deadlock and is bit-exact to the P1 Python golden**,
through the faithful AXI MM2S DataMover model and under back-pressure. **No BD edits, no bitstream, no
hardware** — that is P3–P5. The `m_g`/`m_h` ports are exposed at the top level but NOT wired into any BD
tcl (P3).

**Status: PASS.** All projective geometries (affine-equivalent, keystone H/V/HV, 4-corner pin, plus an
extreme-foreshortening probe) complete a full frame and are bit-exact to the golden, clean and
back-pressured, through the faithful DataMover. The affine build (`PROJECTIVE=0`) is unchanged
byte-for-byte.

## Files changed

| File | Change |
|------|--------|
| `hdl/pg_warp_engine.v` | Swapped **both** `pg_affine` instances (consumer `u_aff_c`, prefetch `u_aff_p`) for `pg_projective`. Added params `PROJECTIVE`(=0 default), `GCW/GFB/RF/LUT_BITS/NR_ITERS/AW/WW` and ports `m_g`,`m_h` (signed `[GCW-1:0]`), routed to BOTH instances. Cache / DMA / bilinear / output stages **untouched**. |
| `hdl/pg_warp_top.v` | Added the same `PROJECTIVE` + precision params; new top-level inputs `input signed [GCW-1:0] m_g, m_h`; a 2-FF `ASYNC_REG` CDC for `m_g`/`m_h` mirroring the `m_a..m_f` CDC (latched into the engine, which re-latches at `sof`); plumbed all through to `pg_warp_engine`. **No BD tcl touched** — ports are exposed only. |
| `tools/pg_projective_golden.py` | Added `src_px()` (synthetic source, matches the TB), bit-exact `lerp8/lerp24/golden_pixel()` (mirrors the engine's 2-stage bilinear, weight = frac[11:4], neighbour-clamp at IN_W/H-1), `emit_pixels()` → `.pix`, and `--emit-pix`/`--matte` CLI flags. The P1 coord golden (`.vec`) is unchanged. |
| `sim/pg_warp_projective_faithful_tb.v` | **New.** Faithful full-engine gate (see below). |
| `sim/run_warp_projective_faithful.sh` | **New.** Regenerates golden (`.coef/.vec/.pix`) then xvlog/xelab/xsim. |

## The `PROJECTIVE` param + `m_g`/`m_h` interface decisions

- **`PROJECTIVE` default = 0** (affine) on both `pg_warp_engine` and `pg_warp_top`. This keeps every
  existing affine build (and the affine BD, which instantiates these modules) **bit-identical**: with
  `PROJECTIVE=0` + `FB=12` + `m_g/m_h` tied 0, `pg_projective` elaborates its `g_affine` branch, which
  is byte-for-byte `pg_affine` (the divide/reciprocal is elided). Verified: the affine faithful TB and
  `pg_warp_real_tb` produce **identical** results pre- and post-swap (same underrun/bit-err/collected
  counts). The projective BD (P3) will instantiate with `PROJECTIVE=1`, `FB=24`.
- **`m_g`/`m_h` port width `GCW = 40`** (Q4.36, `GFB=36`), matching the P1 budget exactly. This is the
  width the P3 AXI GPIOs and the P4 firmware homography solver must emit. `CW`/`FB` for the numerators
  stay 32/24 (projective) — the affine GPIO format (Q.12 in 32-bit) is unchanged.
- The `m_g`/`m_h` CDC in `pg_warp_top` is 2-FF `ASYNC_REG`; **its first stage `D` must be false-pathed
  in the XDC at P3**, the same GPIO→pclk trap as `m_a..m_f` / `lr1` / `sr1`. Flagged below.

## Faithful-TB harness (`sim/pg_warp_projective_faithful_tb.v`)

Drives `pg_warp_engine#(PROJECTIVE=1, FB=24, GCW=40, GFB=36, RF=28, LUT=9, NR=2)` (consumer + prefetch
both `pg_projective`, identical coeffs → coherent cache) through:

- **The faithful AXI MM2S DataMover model** (verbatim from `pg_warp_real_faithful_tb`): deep command
  FIFO, cmd→first-beat latency (`CMD_LAT=28`), mid-burst gaps (`GAP=3/2`), never drops a beat. This is
  the model the rotation work used to reproduce the on-silicon mid-stream freeze, so "completes" here is
  a real no-wedge proof, not a gap-free-model artifact.
- **A buffered sink with capture-on-accept checking.** A line-FIFO the engine fills ahead (models
  `v_axi4s_vid_out`); each drained pixel is compared to the golden `.pix` in raster order. Capture keyed
  on accept (`o_valid && o_ready`) makes the compare immune to pipeline latency / stall phase, so
  **`collected == N` is an unambiguous "frame completed / no wedge" verdict** and the per-pixel compare
  is unambiguous bit-exactness. A back-pressure pass randomly stalls both the accept and the drain.
- **Small frame** (64×48 out ← 96×72 in) so the golden is reusable and the run is deterministic; `LEAD`
  is deep enough (32768) to warm the whole frame, isolating wedge + bit-exactness as the only verdict
  (the full-1080p faithful TB is dominated by lead-underrun noise unrelated to projective correctness).
  Coeffs come from the same `tools/pg_projective_golden.py` homographies as P1, evaluated at the TB dims.

> **TB note (a real gotcha, fixed):** the synthetic source frame must pack R/G/B as three *8-bit* fields.
> The existing affine TBs write `{x[7:0], y[7:0], (x*3+y*5+7)}` where the blue term is a full 32-bit
> expression inside the concat — it over-fills the 24-bit word and **zeroes R and G**. That is harmless
> in the affine TBs (their golden reads the same frame) but here the golden is the Python model, so the
> projective TB masks each field to 8 bits. (This produced a "blue-correct, R/G=0 on every pixel"
> symptom while the DUT was already correct — the engine faithfully reproduced the TB's malformed source.)

## Results — `sim/run_warp_projective_faithful.sh` (ALL PASS, bit-exact, no wedge)

```
PROJ-FAITHFUL affine-id      bit-err=0 collected=3072/3072 | PASS    (g=h=0; reciprocal-of-1.0 boundary)
PROJ-FAITHFUL affine-id [bp] bit-err=0 collected=3072/3072 | PASS
PROJ-FAITHFUL keystoneH      bit-err=0 collected=3072/3072 | PASS
PROJ-FAITHFUL keystoneH [bp] bit-err=0 collected=3072/3072 | PASS
PROJ-FAITHFUL keystoneV      bit-err=0 collected=3072/3072 | PASS
PROJ-FAITHFUL keystoneHV     bit-err=0 collected=3072/3072 | PASS
PROJ-FAITHFUL keystoneHV[bp] bit-err=0 collected=3072/3072 | PASS
PROJ-FAITHFUL cornerpin      bit-err=0 collected=3072/3072 | PASS    (4-corner pin, real foreshortening)
PROJ-FAITHFUL cornerpin [bp] bit-err=0 collected=3072/3072 | PASS
```

- **Completes (no wedge):** `collected == 3072/3072` for every case including the 4-corner pin — the
  demand-fetch covers the non-uniform projective coordinate spread with **no deadlock**. This is the
  load-bearing P2 guarantee and it holds.
- **Bit-exact:** `bit-err == 0` against the P1 Python golden's output pixels (full chain: addr-gen →
  cache → 2-stage bilinear → output), clean and under random back-pressure on both the accept and drain
  handshakes.
- **Regression:** P1 self-check still PASS (`sim/run_pg_projective.sh`); the affine faithful TB and
  `pg_warp_real_tb` are byte-identical pre/post swap (PROJECTIVE=0 path unchanged).

## Worst-case foreshortening / fetch behavior

An opt-in extreme probe (`-d EXTREME`: keystone H=0.55, and a corner-pin strong enough to push 38 of
3072 output pixels out-of-window → matte) also **completes 3072/3072 bit-exact, no wedge**, at the same
LEAD=32768. So even aggressive foreshortening does not wedge the demand-fetch in this harness — the
read engine fetches the worst-case crowded edge tiles on demand and the bounded prefetch lead never
evicts an unconsumed tile.

**Caveat for P3/P5 (NOT a P2 wedge):** the small-frame harness uses a deep LEAD and the whole 96×72
source fits the cache. At true 1080p, foreshortening **concentrates** output samples into a small band
of source tiles at the near edge and **spreads** them at the far edge — exactly the regime where the
affine engine already shows lead-dependent *underruns* (a throughput/lead knob, never a wedge; see
`pg_warp_real_faithful_tb` header). Projective will have the same character: a per-geometry LEAD (the
existing `lead_rt` GPIO) likely needs to be set from the homography's worst-case local magnification,
just as rotation/downscale already do. This is a tuning task for P3/P5 bring-up, not a correctness gap —
P2 proves the geometry is correct and never deadlocks.

## P3 / P5 concerns (carried forward)

- **P3 GPIO width = `GCW = 40`** for `m_g`/`m_h` (Q4.36). The numerator coeffs stay `CW=32`/`FB=24` in
  the projective build. The firmware (P4) homography solver emits a..f in Q8.24 and g,h in Q4.36.
- **P3 false-paths:** the two new `m_g`/`m_h` GPIO→pclk CDC crossings (`g1`,`h1` first stage) MUST be
  false-pathed in the XDC, identical to the `m_a..m_f` / `lr1` / `sr1` traps. The CDC structure is in
  place in `pg_warp_top`; only the constraint is missing (P2 sim doesn't exercise CDC).
- **P5 timing (from P1, still applies):** force the 4 output multiplies (`nx·iw`, `ny·iw` per instance)
  and the 4 NR `m·x` multiplies to DSP48; keep the leading-1 detect + the two barrel shifts isolated as
  their own stages. The current demand-fetch build is at WNS ≈ +0.045 ns @ 74.25 MHz on xc7z020-1; the
  reciprocal is deeply pipelined (its latency is hidden by the prefetch lead, throughput stays 1 px/clk)
  so the exposure is the multipliers, not the divide. `RF` (28→24) is a free precision-margin timing
  knob if P5 closes short. Validate WNS empirically before committing the projective bitstream.
- **Per-region lead (open):** if 1080p projective bring-up shows underruns at the foreshortened edge,
  the fix is a deeper / homography-derived `lead_rt`, not an architectural change — the geometry and the
  demand-fetch are proven correct here.
```
