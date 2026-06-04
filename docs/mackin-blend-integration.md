# Mackin blend integration — read-engine-B (task #103)

Goal: turn `pg_cadence`'s drop/repeat into **smooth Mackin blended FRC** by consuming the blend
params the cadence already computes (`read2_base_addr` = slot S+1, `alpha`, `blend_en`) and
blending the two source frames per output pixel.

Branch: `readengine-b-integration` (off the ✅-CLEAN build #23 substrate, commit `78ce592`).

## Architecture decision (2026-06-04): approach B, per-engine, conditional

- **One DataMover per engine** (not one shared, not two-per-engine). The engine time-multiplexes
  its own bracketing pair (S, S+1) on its single port. Two-engine product = 2 read ports total
  (Zynq has 4 HP), vs approach A's 4 ports — B is the port-scalable choice. Bit-identical blend
  output to A; A just fetches in parallel.
- **Conditional dual-fetch (α-gated):** fetch the 2nd line ONLY when `blend_en` is set for the
  frame. At clean/near-integer ratios most output frames are exact repeats (alpha in the
  `BLEND_EPS` deadband → `blend_en=0`), so the 2× bandwidth is paid only on frames that actually
  blend. This is the bandwidth lever.
- This is per-engine and replicates verbatim to engine B (analog) when that pipeline is added
  (own DataMover + own Si5351 clock). Capture-once (single S2MM ring) → each engine reads what it
  needs independently.

## Blend math (from `mackin_blender.v`, branch `mackin-impl-wip`)

Per channel, R-B-G order preserved (`tdata[23:16]=R,[15:8]=B,[7:0]=G`):
```
out_c = clamp( prev_c + ((alpha_q15 * (curr_c - prev_c) + 0x4000) >> 15), 0, 255 )
```
- `prev` = slot S (older, `read_base_addr`), `curr` = slot S+1 (newer, `read2_base_addr`).
- `alpha_q15` (Q1.15, 0..0x8000): 0 → prev (repeat), 0x8000 → curr (pass-through).
- Cadence emits `alpha[7:0]`; scale to Q1.15 in `pg_compose` (`alpha_q15 = {alpha,7'b0}` ≈ ×128,
  with a small +`alpha[6:0]` term to reach full-scale — see HDL). Blend is done **inline** in
  `pg_compose` (we already have `rd_data` there); no separate AXIS blender instance needed.

## Module changes

1. **`pg_linefetch.v`** — dual-line fill. Add `frame_base_addr2` + `blend_en` inputs and a second
   bank set (`mem_e2`/`mem_o2`) + `rd_data2` output. Fill FSM: `S_IDLE → S_FILL_A → (blend_en?
   S_FILL_B : S_IDLE)`. Issues 1 or 2 DataMover commands per prefetch (A from base, B from base2,
   same `pf_row`). When `blend_en=0`, behaves exactly as today (single fetch) — zero regression to
   the gen-lock path.
2. **`pg_compose.v`** — pass `frame_base_addr2`/`alpha`/`blend_en` to linefetch; take `rd_data2`;
   inline lerp `push_data = blend_en ? mackin(rd_data, rd_data2, alpha) : rd_data` (pipelined +1
   stage; `push_col`/SOF/EOL bookkeeping shifted to match).
3. **`pg_read_engine_top.v`** — add `blend_mode` input (drive `pg_cadence.blend_mode`); wire
   `cad_read2_base`/`cad_alpha`/`cad_blend_en` into `pg_compose` (they're currently dangling).
4. **BD `readengine_b_bd.tcl`** — `blend_mode` from a GPIO bit (axi_gpio_10 ch2 bit1, alongside
   mux-sel bit0).
5. **Firmware** — UART command to toggle `blend_mode` live (A/B drop-repeat vs blend on motion).

## Risk + gate (bandwidth — DO FIRST)

Dual-fetch doubles line-fill: at the 1920-wide master, ~720→~1440 beats per output window-row vs
~1650-cycle row budget (720p60) — ~13% margin, into the DDR shared with the S2MM write. This is
the tightness that caused the original read-engine underrun. **Gate in sim before build:** extend
`sim/pg_latency_tb.v` to drive dual-fetch (blend_en=1 worst case) and confirm output-FIFO
`starv=0` (ring stays fed). Plus a blend-correctness check vs the mackin formula. If the latency
sim underruns at 2×: rely on conditional-fetch (only blend frames pay), deepen the ring (NBUF↑),
or fall back to approach A (2nd port). Build only after the sim gate is green.

## Verify

Sim green (latency starv=0 + blend bit-exact) → Vivado build → bench: `blend_mode=1` should
visibly **smooth the judder** at 29.97→60 / 59.94→60 vs drop/repeat (the FRC matrix we just
validated), with `delta_px=0` preserved. MS2109 masks tearing → verify on monitor.
