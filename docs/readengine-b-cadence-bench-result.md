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

**CONFIRMED (build #22, 2026-06-03):** `axis_to_vid_io.predrain_snap` routed to diag GPIO ch1,
firmware `DRAIN:` line. Measured every frame, perfectly constant:

    DRAIN: delta_px=6 (stale=6 starve=0)

δ = **6 px constant**, **100% stale, 0 starve**. So pixel 0 lands at output column 6 because six
residual beats from the prior frame's tail are discarded inside active video; the producer is
never late (starve=0 ⇒ not a `pg_compose` priming issue). This selects the **blanking-flush** fix
unambiguously. NOTE: `axis_to_vid_io` is **shared** by the scaler/VDMA path and the read-engine
path, so the fix affects both (expected — the wrap is common to all builds, "as before").

**Lower-likelihood alternates:** producer leaves a deterministic FIFO residue at frame end
(fixable producer-side instead); rgb2dvi DE-vs-sync skew (but that wouldn't wrap content).

## RESOLVED (build #23, 2026-06-03) — bounded blanking-flush

Root cause (agent-confirmed): the shared color stack (sat→correct→matrix) holds the prior frame's
last ~6 pixels in its pipeline at the frame boundary; they emerge ahead of the new frame's SOF
pixel 0. Fix in `hdl/axis_to_vid_io.v`: drain pre-SOF residue during **VBLANK** (black, not shown)
so the SOF beat is at the head when active begins → pixel 0 at column 0. **Bounded to
`MAX_DRAIN=16`** beats/frame so a missing/late SOF reverts to the old 1-frame-black-flash instead
of cascading (the failure the cap introduces, raised in review). `vtg_vblank`-scoped.

- **Sim** (`sim/axis_sof_tb.v`): PASS 230+6 checks, 0 errors — anchor/clean intact (no regression on
  the shared module), δ==0 on the residue frame (was δ=3 pre-fix), missing-SOF frame capped + clean
  re-anchor.
- **Silicon:** `DRAIN: delta_px=0` across static, 2× zoom (`G 960 540 480 270`), full
  (`G 1920 1080 0 0`), and passthrough (`G 0`). δ holds at 0 through geometry transitions and on the
  VDMA path. Monitor: position perfect, wrap gone, motion clean.
- Commit `78ce592` on `readengine-b-integration`. Reviewed + endorsed by external agent.
- ⚠️ 3-cold-boot verify still owed before the no-coin-flip ✅ CLEAN promotion.

## Color note (separate, closed)

A "too warm" report was chased to ground: MS2109 digital capture of the output measured whites =
`(255,255,255)`, all channels reach 255, global B/R = 1.00. Channel-isolation probe confirmed
correct R/G/B mapping (no R-B-G swap). The box's color is accurate — the warmth was **f.lux** on
the test machine. Not an FPGA issue.
