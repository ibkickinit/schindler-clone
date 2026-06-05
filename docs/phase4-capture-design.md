# Phase 4 — Capture / Still-Buffer / Robust Freeze / Output-Grab (design)

Status: **DESIGN** (2026-06-05). Implementation gated on **#114** (read-engine base-fetch
chroma fix) landing first — Phase 4 adds a source-select mux *inside* the read engine, so it
must build on a clean read-engine substrate, not stack on the open defect. This doc is the
build-ready spec.

## Goal (MVPHD parity, final batch)
1. **Robust Freeze** — hold a perfect still indefinitely. Replaces the abandoned #111 VDMA-halt
   approach (halting S2MM didn't reliably un-freeze; the cadence ring laps the held pointer).
2. **Still buffers** — capture N frames to protected DDR, recall any slot to the output.
3. **Output-grab** — capture the *processed* output frame (post color/gamma/geometry) to DDR for
   GUI download at full resolution (the PetaLinux/Ethernet payoff — UART is minutes for 6 MB).

## Core mechanism: read-engine source-select
The read engine (`pg_addrgen`→`pg_linefetch`→`pg_compose`) currently fetches from the **cadence
ring** — the gen-locked S2MM framebuffers. Add a **static-source mode**:

- New input `still_en` + `still_base[31:0]` (DDR byte address of the frozen frame) + `still_slot`.
- When `still_en=1`, `pg_linefetch` fetches from `still_base` (a fixed, write-protected frame)
  instead of the live `s2mm_frame_ptr` ring. The DDA/geometry/color/gamma all still run, so a
  frozen still is still pan/zoom/gamma-adjustable — a genuine freeze, not a pipeline halt.
- Freeze = (a) **capture** the current live frame into a still region, then (b) set `still_en=1,
  still_base=<that region>`. Un-freeze = `still_en=0` (back to the live ring). Because the still
  lives in its OWN protected region, the cadence ring may keep running or stop freely — no lap race.

## Capture (live frame → protected DDR still region)
Three options, in preference order:
1. **DataMover frame copy (preferred)** — a one-shot MM2MM `re_datamover`-style burst copies the
   last-good live frame (1920×1080×3 ≈ 6.2 MB) to the target still region. ~ms at HP-port bandwidth.
   Firmware issues the copy command, polls done, then flips `still_en`.
2. **Firmware memcpy** — PS reads the live framebuffer, writes the still region. Simple, no new HDL,
   but ~6 MB through the PS is slower (still one-shot/acceptable). Good first cut.
3. **Pointer-freeze (rejected)** — just stop S2MM and read its last frame in place: this is the
   #111 approach that lapped/torn. Do not revisit.

Capture must latch on a **frame boundary** (use the S2MM/VTC SOF) so the copied frame is whole.

## Still slots + DDR map
- N=4 still slots (configurable). Each slot = one full-raster 1080p frame region (align 64B).
- Reserve a DDR block ABOVE the cadence ring + framebuffers + color/MM2S regions. Pick a base that
  does not overlap any existing VDMA/DataMover region (audit `XPAR_*` + the BD address map first).
  Sketch: `STILL_BASE = <top of used DDR, rounded up>`, slots at `STILL_BASE + slot*FRAME_BYTES`.
- Mark the still region as **not** part of any auto-managed VDMA ring (firmware-owned).

## Output-grab (processed frame → DDR → GUI)
- Tap the AXIS stream **after** the color pipeline (post color_matrix/gamma), before/at
  `axis_to_vid_io`, into a small **S2MM-style writer** (or a DataMover fed by an axis_to_mem) that
  lands one processed frame in a DDR grab region on a SOF-gated one-shot.
- Today's `debug.dump` grabs the *input* (thumbnail, UART-limited). This grabs the *output* at full
  res. Transport: bare-metal UART = minutes (don't); **PetaLinux + Gigabit Ethernet ≈ 70–125 ms**
  for 1080p (see earlier analysis) — so full-res output-grab is the headline PetaLinux feature.

## Firmware / daemon / UI
- Firmware: `capture <slot>` (DataMover/memcpy to slot, SOF-gated), `still <slot>` / `still off`
  (set `still_en`+`still_base` via a new GPIO field), `grab` (output-grab one-shot). Re-enable the
  Freeze button path (#111 disabled it) to call capture-current + still-on.
- Daemon: `freeze.set {on, slot}`, `still.capture {slot}`, `still.recall {slot}`, `grab.output`.
- UI: re-enable **Freeze**; add **Still slots** (capture/recall ×4) + **Grab frame** (full-res).

## GPIO budget note
Source-select needs a few read-engine GPIO bits (`still_en`, `still_slot`, maybe `still_base` if not
firmware-fixed). Fold into a spare GEO GPIO channel if bits remain, else one new axi_gpio (mirror the
axi_gpio_11 @ M14 pattern: NUM_MI bump + slice + XDC false-paths on any new CDC `*_q1` regs).

## Sequencing
1. Land #114 (clean read engine). 2. Source-select mux + capture (sim-prove the still reads bit-exact
from a known DDR region; prove freeze holds + un-freeze returns to live). 3. Bitstream + bench (Freeze
+ slots). 4. Output-grab writer (sim + bitstream). 5. PetaLinux transport for full-res grab download.
