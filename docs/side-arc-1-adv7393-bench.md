# Side-arc 1 — ADV7393 EVAL composite bench bring-up

**Status:** Banked 2026-05-14
**Type:** Bench bring-up side-arc (parallel to main HD pipeline Phase A–G)
**Goal:** Validate ADV7393 silicon end-to-end on the bench by driving the EVAL-ADV7393EBZ from Zybo PMODs and seeing NTSC composite output on a scope. Establishes the BT.656 → ADV7393 output path that becomes the back end of every analog-side test from here on.

## Why this is a side-arc, not a main phase

The Phase A–G arc builds the HD signal pipeline top-down. This work is parallel: it brings up the analog output silicon standalone so that when Phase G re-attaches the terminal encoders, the analog back end is already validated and trusted. Independent of Phase A–G ordering — can land any time after the EVAL board is on the bench.

Future side-arcs (Side-arc 2: ADV7511, Side-arc 3: ADV7280, Side-arc 4: LT8619C) will follow the same pattern: bench-validate each silicon piece standalone on its EVAL board before the production carrier exists.

## Architectural decision banked here

**Day-1 split bus: HDMI and analog get their own dedicated parallel YCbCr 4:2:2 buses from the FPGA.** This supersedes the earlier "shared bus" plan in `01-spec.md` § 3.2. Cost: ~16 extra PL pins (well within TE0720 headroom). Benefit: HDMI and analog run **independent cadences simultaneously** — the spec's promised "1080p60 HDMI OUT + NTSC composite OUT live from the same source" works because each output bus has its own scaler instance and its own pixel clock.

```
HDMI in → decoder → VDMA framebuffer (DDR3)
                         │
                         ├── Scaler A (HD) → color → HDMI TX bus  @ 74.25 / 148.5 MHz → ADV7511
                         │
                         └── Scaler B (SD) → color → FRC (5:2 / 3:2) → analog TX bus @ 27 MHz → ADV7393
```

**Resource cost on Z-7020:** two polyphase scaler instances ≈ ~40 DSP + ~30 BRAM + low-thousands LUTs. Well under 20% of the part. DDR3 bandwidth for 1080p60 + 480i parallel reads is under 5% of available. Non-issue.

`01-spec.md` § 3.2 to be updated with this lock-in.

## Bench plan

### Pin budget (Zybo PMODs)

| Signal group | PMOD | Pins |
|---|---|---|
| BT.656 8-bit data P[7:0] | JB (high-speed) | 8 |
| CLKIN 27 MHz | JC | 1 |
| I²C SCL + SDA | JC | 2 |
| RESET | JC | 1 |
| GND tie | via PMOD ribbon | — |

8-bit BT.656 (embedded SAV/EAV sync codes inside the YCbCr 4:2:2 stream) is used instead of the 16-bit parallel mode — fits in one PMOD for data, leaves headroom, and exercises the same input path ADV7393 will see from the production carrier in 16-bit mode (just narrower).

### Power and ground

The EVAL-ADV7392/93EBZ back-end board has **no on-board power source** — no wall-wart jack, no LDOs. Per ADI eval-board doc Rev. B Dec. 2006: *"These back-end boards do not have an independent power source and rely on the supplies coming across on J5."* In normal use it draws all four rails from the EVAL-ADV739xFEZ front-end board (~$1k, not on the bench here).

Standalone bench powering injects the four rails directly into the back-end board's 40-pin interface connector (labeled **P1** on back-end, mates to **J5** on the FEZ).

**Rails required at the P1 connector:**

| Pin | Net | Voltage | Purpose |
|---|---|---|---|
| P1-1 | `VAA_3.3V_IN` | **3.3 V** | ADV7393 analog (DACs) |
| P1-3 | `VDD_IO_IN` | **3.3 V** (selectable 1.8/2.5/3.3 — pick 3.3 to match Zybo PMOD signaling) | ADV7393 I/O pins |
| P1-5 | `VDD_1.8_IN` | **1.8 V** | ADV7393 digital core |
| P1-7 | `PVDD_1.8V_IN` | **1.8 V** | ADV7393 internal PLL |
| Even-numbered pins | GND | — | Returns (verify silkscreen on the board before clipping) |

Each rail goes through an EMC filter on-board before reaching the chip's pins. Total current draw is well under 100 mA across all four rails.

**Bench config — dual benchtop supply (Option 1):**

- **Channel 1** set to **3.3 V** → wire to P1-1 (VAA) and P1-3 (VDD_IO).
- **Channel 2** set to **1.8 V** → wire to P1-5 (VDD) and P1-7 (PVDD).
- **Common GND** tied to a P1 ground pin **and** to the Zybo via one PMOD ribbon GND pin only — single ground reference between the three pieces of equipment (Zybo, EVAL board, bench supply).
- Bring up 1.8 V *before* 3.3 V is fine for ADV7393 (no documented sequencing requirement) — use current-limit protection during first power-up.

Other options considered: single 3.3 V supply + on-board 1.8 V LDO mezzanine (cleaner long-term, but adds hardware build); piggybacking on the FEZ (requires the $1k FEZ, ruled out).

**Bench verification:** P1 pinout (P1-1/3 = 3.3 V rails, P1-5/7 = 1.8 V rails) confirmed via continuity check on the board — 2026-05-14.

### Phase 0 — chip alive (no FPGA data)

1. PetaLinux on Zybo writes I²C config: NTSC composite mode + **internal test pattern enabled** (ADV7393 register-driven feature).
2. Scope CVBS BNC on EVAL board.
3. **Expect:** ADV7393's internal color bars, ~1 Vpp into 75 Ω, sync tip −300 mV, peak white +700 mV.

Validates: power, I²C bus, DAC output stage, BNC back-termination, scope setup. Zero HDL involvement.

### Phase 1 — FPGA-sourced bars over BT.656

1. New top-level `hdl/top_side_arc_1_adv7393.v` (independent of `top.v` and `top_phase_a.v`):
   - MMCM generates 27 MHz pixel clock.
   - Test-pattern gen (color bars) → BT.656 formatter (SAV/EAV codes embedded).
   - Outputs P[7:0] + clk on PMOD JB.
2. I²C config switches ADV7393 to **8-bit BT.656 embedded-sync input mode**, internal test pattern OFF, NTSC composite output.
3. Scope CVBS BNC.
4. **Expect:** SMPTE bars identical-looking to Phase 0, but now sourced from FPGA data path.

### Phase 2 — pattern variety

- Extend pattern gen with PLUGE, ramp, multiburst, zone plate.
- These become the standing test patterns for Phase C scaler verification and Phase D FRC verification later.

## Success criteria

| Step | Pass condition |
|---|---|
| Phase 0 | Chip's internal color bars on scope; amplitudes match SMPTE 1 Vpp / 75 Ω. |
| Phase 1 | Visually identical bars sourced from FPGA HDL; sync structure matches NTSC. |
| Phase 2 | Each added pattern visually correct; line/field timing rock-solid. |

## Effort estimate

| Sub-phase | Effort |
|---|---|
| Phase 0 | ~½ day (I²C bring-up only) |
| Phase 1 | ~1–2 days (BT.656 formatter + pattern gen + top-level + register tweaks) |
| Phase 2 | Incremental as needed during Phase C/D work |

## Deliverables

- `hdl/top_side_arc_1_adv7393.v` — bench top-level
- `hdl/bt656_format.v` — BT.656 formatter (reusable, lands in production HDL)
- `hdl/tpg_color_bars.v` — color bar pattern gen (also reusable)
- I²C init sequence (PetaLinux user-space or simple `i2cset` script) for ADV7393 NTSC composite mode
- Scope captures banked in `docs/scope-captures/side-arc-1/` (folder TBD)

## What this retires from the active path

The Phase 2 first-light HDL (`vid_timing.v` + `vbi_gen.v` + `chroma_gen.v` + `sample_gen.v`) generates composite **in HDL** for direct R-2R DAC output. Once Side-arc 1 validates, the ADV7393 owns analog encoding from here on — the chip is purpose-built for it and runs at production rates without subcarrier-NCO gymnastics in fabric.

The R-2R DAC + Phase 2 HDL stays banked as a "we did it ourselves once" reference; **not** a live path post-Side-arc-1.

## Cross-references

- Dev roadmap: [`dev-roadmap.md`](dev-roadmap.md) § Side-arcs
- Spec — ADV7393 details: [`01-spec.md`](01-spec.md) § 3.4
- Spec — bus sharing (to be updated for split-bus lock-in): [`01-spec.md`](01-spec.md) § 3.2
- Reference designs: [`reference-designs.md`](reference-designs.md)
- Earlier R-2R bench reference (retired post-Side-arc-1): [`r2r-dac.md`](r2r-dac.md)
