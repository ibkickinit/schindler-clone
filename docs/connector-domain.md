# Schindler 2.0 — Connector Domain & Analog I/O Partition

**Created 2026-06-18 (Claude's call; Justin delegated the connector choice).** Resolves how every rear-panel connector reaches the carrier, driven by the two-row backplane layout (`Chassis_Planning` rough pass).

## Mechanical premise (Justin)
Rear panel is **two rows** of connectors.
- **Bottom row → on the carrier** (board-mount BNC/HDMI directly on the carrier PCB edge, which aligns to the panel at bottom-row height).
- **Top row → analog I/O riser** (a vertical daughtercard holding the top-row BNCs, mezzanine/board-to-board connector down to the carrier).

## Decision: top row = mezzanine riser, not coax landings
For the top-row signals — all **baseband analog video** (composite ~6 MHz, component Y/Pb/Pr up to ~30 MHz, genlock reference: sync edges sub-MHz, burst ~4 MHz) — a board-to-board mezzanine is **not a meaningful SI compromise**:
- At ≤30 MHz the interconnect is electrically *short* (λ/4 > 1 m vs a mm-scale hop), so the controlled-75 Ω benefit of coax buys almost nothing — there's no electrical length for reflections to matter. (This is why coax is mandatory for SDI/GHz and optional for baseband video.)
- The one real risk is **inter-channel crosstalk** among the 8 analog channels — bounded and controllable, not fundamental.

**Conditions (required for the mezzanine to be sound):**
1. **Ground pinning** — high-density mezzanine with a ground structure (Samtec QSH/QTH-class), pinned **G-S-G** (a ground adjacent to each of the 10 analog nets). Target >-50 dB channel separation at 30 MHz (meets component crosstalk spec). A generic 0.1″ header is **not** acceptable.
2. **Analog-only riser, short 75 Ω traces** — nothing digital crosses the mezzanine. SDI/HDMI stay board-mount on the carrier; the **analog PHYs (ADV7280/ADV7393/genlock front-end) stay on the carrier**, so only baseband analog crosses the riser. This keeps fast edges off the mezzanine and leaves the FPGA pin-lock untouched.

Genlock reference is the most timing-sensitive net — ground it best — but its meaningful content is sub-MHz sync edges, negligible jitter over a short grounded hop.

**Fallback if the new-PCB scope is unwanted:** MCX (75 Ω) coax landings on the carrier (10×) + panel BNC pigtails — no new board, genlock just swaps U.FL→MCX. Lower rework, belt-and-suspenders SI. Not chosen, recorded as the off-ramp.

## Per-connector table

### Top row — RISER (board-mount BNC on riser → mezzanine → carrier)
| Panel | Signal | Carrier-side destination | BOM domain |
|---|---|---|---|
| COMPOSITE IN | composite analog in | ADV7280 U500 (sheet 5) | riser |
| Y In / Pb In / Pr In | component analog in (3ch) | analog front-end (sheet 5) | riser |
| COMPOSITE OUT | composite DAC out | ADV7393 U600 (sheet 6) | riser |
| Y Out / Pb Out / Pr Out | component DAC out (3ch) | ADV7393 U600 | riser |
| REF IN | genlock ref in | genlock front-end U800/U801 (sheet 8) | **NOT mezzanine — U.FL coax (J802/J803)**; riser-mounted BNC + **riser LED** |
| REF LOOP | genlock loop-through | carrier J803 | **NOT mezzanine — U.FL coax**; riser-mounted BNC, **no LED** |

Mezzanine carries: **8 analog video nets** (composite + Y/Pb/Pr, in & out), signal-over-ground. **Genlock REF IN/LOOP do NOT ride the mezzanine** — phase-critical sync stays on U.FL coax to the carrier (J802/J803), per `01-spec.md` §3.7 / `panel-layout.md` §3 ("no riser hop on phase-critical sync"). The 2 sync BNCs are top-row physically but reach the carrier by 75 Ω coax pigtail → U.FL, regardless of which board they mount on.

**Per-signal LEDs (simplified 2026-06-18):** **5 riser LEDs**, not one per BNC. Composite is its own signal → its own LED (1 IN + 1 OUT); each **Component set (Y/Pb/Pr) shares ONE LED** (1 IN + 1 OUT); plus **SYNC IN** (1). SYNC LOOP none. **Why not per-leg component LEDs:** a component set is one logical signal — the decoder locks on Y's sync and Pb/Pr carry no independently-sensed status, so per-leg LEDs would mirror Y or falsely indicate presence the hardware can't detect (Pb/Pr sit near 0 at black even when connected). 5 bi-color = 10 channels → **one TLC59116** (16-ch, 10 used) — the 2×-driver question from the 9-LED version is moot. Mezzanine crossing unchanged: I2C (SCL/SDA) + LED supply + separate digital/LED ground + optional /RESET ≈ 4–5 pins, ground-barriered, digital ground joined to analog only at the carrier star point. The SYNC IN LED is riser-local; SYNC IN/LOOP *signals* stay coax to the carrier (J802/J803). Carrier BNC LEDs (SDI/HDMI/REF-OUT/RF) stay per-connector on the carrier chain (each is its own signal). *(Propagate to `panel-layout.md` §6: per-connector → per-signal for the analog groups.)*

**Header split (decided 2026-06-18):** use **two mezzanine headers** — an **IN header** (4 video → ADV7280 U500) and an **OUT header** (4 video ← ADV7393 U600) — to physically separate the full-swing DAC outputs from the sensitive decoder inputs (kills output→input ghosting better than zoning within one connector, and lets each group route straight to its PHY). Each header ≈ 4 signal + G-S-G grounds ≈ **2×6 to 2×8**. The LED I2C/supply/digital-ground (~5 pins) rides the **OUT header** in its own ground-barriered corner (outputs tolerate I2C switching far better than inputs), or a small dedicated control header. Both headers tall-stack (height = panel BNC row pitch) to clear the carrier BNCs; support with standoffs.

### Bottom row — CARRIER (board-mount, no change)
| Panel | Signal | Carrier destination |
|---|---|---|
| SDI IN / SDI Loop | HD-SDI in + loop | GS3470 U700 (sheet 7) |
| SDI OUT 1 / SDI OUT 2 | HD-SDI out | GS2962 U701 (sheet 7) |
| HDMI IN | HDMI in | LT8619C U402 (sheet 4) |
| HDMI OUT | HDMI out | ADV7511 U403 (sheet 4) |
| REF OUT 1 / REF OUT 2 | sync/genlock out | sheet 9 J900/J901 (board BNC) |
| RF OUT | RF modulator out | RF daughterboard |

### Left cluster (context — not analog video)
Power IEC; 2× SMA/MCX top-left (ESP32 antenna / aux — **clarify**); RJ45 + USB-B (control); white square (blank/expansion — **clarify**).

## Scope this commits to
- **New riser PCB** — daughtercard holding **all 10 top-row BNCs**: 8 analog-video (composite + Y/Pb/Pr, in & out, via the mezzanine) + SYNC IN/LOOP (coax-pigtail to carrier J802/J803, *not* the mezzanine). **5 bi-color LEDs** (per-signal: Composite IN, Component IN, Composite OUT, Component OUT, SYNC IN — SYNC LOOP none) + **one on-riser TLC59116** + **two mezzanine headers (IN / OUT)**. The sync region of the riser is **shallow / cut-back** (no mezzanine connector there) so it slips past the carrier BNCs below. Second board (design/fab/assembly).
- **Sheet 8 genlock STANDS (correction 2026-06-18)** — J802/J803 U.FL landings are correct per spec §3.7: phase-critical sync = panel BNC → 75 Ω coax pigtail → U.FL on carrier, **no riser hop**. **Not superseded.** (Earlier draft of this doc wrongly moved them to the riser; reverted after reading `panel-layout.md` §3.)
- **Carrier** — add **two mezzanine headers (IN/OUT)** + route the 8 analog video nets to their PHY inputs (ADV7280 U500 in, ADV7393 U600 out). No MCX landings. J802/J803 U.FL (genlock) unchanged.
- FPGA PL pin-lock **unaffected** (PHYs stay carrier-side).

## Open
- Mezzanine connector selection (tall stack height to clear carrier BNCs; ~8 signal + grounds, signal-over-ground).
- Riser schematic/layout (new sheet or separate project).
- Final crosstalk validation at layout (component channels, 30 MHz).
- ~~Clarify the 2× top-left SMA + white-square panel features.~~ **Resolved from `panel-layout.md`:** 2× SMA = RP-SMA WiFi antennas; white square = Newhaven NHD-1.5-240240AF-CSXP rear status LCD (~28×28 mm cutout). Neither touches the analog domain.
- **Gated on Justin's go** before the agent reworks sheet 8 / starts the riser. Nothing pushed.
