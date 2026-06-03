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

## Open: constant few-pixel offset (pre-dates cadence — "same as before")

A small constant spatial offset is present on **every** read-engine-B build, **independent of
source** (static grid, motion, laptop all show it identically). It is therefore **structural to
read-engine-B's output geometry**, not a cadence/genlock/Gray artifact, and not source-side.

**Datapath audited clean — the offset is NOT born in the resample/unpack/adapter:**
- `pg_addrgen`: H/V DDA reset to `src=0, frac=0` at SOF; at 1:1 `src_col(0)=0`. No init phase.
- `pg_linefetch` (packed-beat): `rd_col=0 → o=3*0=0 → beat_b=0, sub=0 → window[23:0]` = source
  pixel 0 exactly. The 64-bit-beat byte-address read introduces no fixed pixel offset at col 0.
- `pg_compose`: `push_col` tracks raster from 0; SOF/EOL computed at push. No offset.
- `axis_to_vid_io`: `{vid_data, vid_active, vid_hsync, vid_vsync}` all registered **together**
  (uniform 1-cycle delay) → no data-vs-sync skew, no relative H shift.

So output(0,0) maps to source(0,0) through the whole read-engine datapath. **The remaining
suspect is the output stage's raster *placement* relative to sync**, common to all builds:

1. **VTC TX generator porch split (lead hypothesis).** Totals are correct (`HTOTAL=1650
   VTOTAL=750`, confirmed via UART), but the active-region *position* is set by the porch split
   (HFP/HSYNC/HBP, VFP/VSYNC/VBP). If the firmware's VTC config deviates from CEA-861-D 720p60
   (HFP=110, HSYNC=40, HBP=220; VFP=5, VSYNC=5, VBP=20), a digital panel that keys active off
   sync shows a constant shift. **Discriminator:** is the offset H, V, or both? H → HBP/HFP
   split; V → VBP/VFP split. Then dump the programmed VTC generator porch regs vs CEA.
2. **rgb2dvi DE-vs-sync handoff** — lower likelihood (axis_to_vid_io registration is uniform),
   but a fixed 1–2 px DE/sync skew at the rgb2dvi boundary would also be source-independent.

**Next datum to collect:** measure whether the offset is horizontal, vertical, or both, and its
magnitude in pixels — that single fact localizes it to HBP vs VBP and confirms/kills hypothesis 1.
