# Read-engine-B cadence — bench result (2026-06-03)

Build #21b: `pg_read_engine_top` with `pg_cadence` in **gen-lock mode** (`blend_mode=0`,
drop/repeat, single fetch) replacing `pg_genlock`. Branch `readengine-b-integration`,
WNS +0.235. Programmed, firmware alive. Verification surface = **bench monitor** (MS2109 masks
artifacts — see `schindler_ms2109_verification_trap`).

## What passed

- **Static grid (Osee input 1, ImagePro SMPTE):** clean, no regression vs prior builds. Same
  small constant pixel offset as every prior read-engine-B build (see "Open" below).
- **Motion (Osee input 2, ~60 Hz motion source) and laptop (input 3, 1920×1080@60):**
  **motion is clean** on the monitor — no judder, no roll, no tearing, no periodic hitch.
  Telemetry tracked throughout (`in=1920x1080 src=60 out=60`, frame_ptr Gray cycle advancing).

  This is the decisive test the static grid could not give us. It validates, on live motion:
  - the **gen-lock cadence** (per-output-vsync slot pick from the S2MM write pointer);
  - the **Gray decode** (`fp_use = gray2bin(fp_stable) % NUM_FRAMES`) — a wrong decode would
    have shown a constant temporal offset / hitch on motion, which it did **not**;
  - the **decode→slot mapping** (round-3 open risk #1) — `gray2bin(fp) % 5` is pointing at the
    freshest completed frame; motion plays temporally correct.

- **Color pipeline verified at identity** (UART `i`): sat=0x8000 (100%), black=(0,0,0),
  white=(255,255,255), matrix `[4000 0/0 4000 0/0 0 4000]` diag (1.0 Q2.14), offsets (0,0,0).
  The box is not altering color; any tint in webcam captures is camera white balance.

## Open: constant per-line horizontal WRAP (pre-dates cadence — "same as before")

**Observed symptom (bench, 2026-06-03):** source pixel 0 lands a few pixels IN from the left;
each line's last few pixels wrap to the START of the next line; the pattern is **identical on
every line and does NOT accumulate** (vertical grid lines stay straight, no shear). Constant δ
≈ a few pixels, source-independent (static/motion/laptop all show it).

**This is a horizontal phase offset in the AXIS→video stream, NOT a rigid raster shift.** A VTC
porch shift moves the whole active rectangle and blanks the edge — it cannot wrap end-of-line
content into the next line. The wrap is the giveaway: pixel 0 is landing at active column δ.

**Datapath resample/address math is clean** (output(0,0)→source(0,0)): `pg_addrgen` DDA resets to
`src=0,frac=0` at SOF (no init phase); `pg_linefetch` `rd_col=0 → o=0,beat_b=0,sub=0` = source
pixel 0; `pg_compose` `push_col` from 0, SOF on genuine first pixel. So the content is correct;
only its horizontal *anchor* in the output raster is off by δ.

**Lead hypothesis — `axis_to_vid_io` SOF-realign drains pre-SOF residue inside the active window:**
`s_axis_tready = vtg_active_video && enable` → the adapter consumes **only during active video**.
The SOF-realign re-arms each frame (`started<=0` at vsync) and discards non-SOF head beats until
the SOF beat appears (then SOF = pixel 0). But because tready is active-gated, those δ residual
beats (frame N's tail still queued in the output FIFO at blanking start) can only be drained by
**burning the first δ active-pixel slots** (shown black at top-left). So the **SOF beat lands at
active column δ**, every subsequent line is shifted +δ, and each line's last δ pixels wrap into
the next line's head — constant, non-accumulating. δ is counted in 64-bit beats (≈2.67 px each)
→ "a few pixels." Matches the symptom exactly.

**Proposed fix:** flush pre-SOF residue during **blanking**, not active video. While `!started`,
assert `tready` to drain non-SOF head beats during blanking; once the FIFO head IS the SOF beat,
hold (deassert) so SOF waits at the head and becomes the first pixel at active column 0. Then gate
to active-video as today. Makes pixel-0 placement deterministic at column 0 → kills the wrap.

**Confirm before fixing (ILA/diag):** count beats drained before the SOF emit per frame (= δ),
and/or output-FIFO occupancy at the vsync rising edge (should be ~0 if no residue). A nonzero,
roughly-constant drain count confirms the mechanism.

**Lower-likelihood alternates:** producer leaves a deterministic FIFO residue at frame end
(fixable producer-side instead); rgb2dvi DE-vs-sync skew (but that wouldn't wrap content).
