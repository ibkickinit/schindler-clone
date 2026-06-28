# Engine B — analog output system, full scope (2026-06-27)

Operator: new ADV7393 + Si5351 in hand; scope the whole engine-B / analog leg in one shot.
Builds on: dual-engine FRC architecture, Phase-E2 (Si5351), Phase-G (ADV7393), the canon warp engine A.

## 1. System overview
```
DDR 5-slot ring (one writer @ source rate, HD master)  ── shared ──
  ├─ ENGINE A (existing): warp → color → VTC-A(74.25) → rgb2dvi → HDMI OUT A
  └─ ENGINE B (new):      read → SD raster → RGB→YCbCr 4:2:2 → VTC-B(27MHz) →
                          ADV7393 (parallel 8-bit) → composite/component ANALOG OUT B
```
Engine B is SD (720×480 NTSC / 720×576 PAL) → CHEAP DDR fetch (bandwidth dominated by S2MM + engine A,
per dual-engine memory). Each engine genlocks to its OWN reference → cadence/Mackin FRC is PER-ENGINE.

## 2. Clock architecture (the no-CMT win)
**Si5351 is the 27 MHz master for the whole analog leg.** One clock, fed to two sinks:
- Si5351 CLK0 → 27.000 MHz → **ADV7393 CLKIN** (chip pin 19) AND → **Zybo clock-capable Pmod pin** →
  `BUFG` → engine-B pixel-clock domain. No `clk_wiz`/MMCM for 27 MHz → stays inside the 4-CMT budget.
- Si5351 also (optionally) frees a future path: CLK1/CLK2 could drive engine A's 74.25 (the dual-Si5351
  independent-sync endgame), but v1 keeps engine A on its existing clk_wiz.
- **CC-pin requirement:** the chosen Pmod pin MUST be MRCC/SRCC (clock-capable) so it can reach a BUFG.
  Verify against the Zybo master XDC before assigning (most Pmod pins are regular I/O; a few are CC).
- 1000/1001 (NTSC 59.94 vs 60): the Si5351 can synthesize the exact 27 MHz / fractional rate; per-engine
  cadence absorbs source↔output drift. (Si5351 fractional-N covers it; no MMCM psincdec needed here.)

## 3. I²C (one bus, both chips)
ADV7393 = 0x2A, Si5351 = 0x60 → SAME 2-wire bus (SDA/SCL) on one AXI-IIC. On-board 2.2kΩ pull-ups on
both breakouts (good — honor the external-pull-up rule). Firmware drivers for both (reuse the Phase-E2
Si5351 + Phase-G ADV7393 I²C work; mind the dynamic-mode atomicity + SYS_INIT-poll lessons).

## 4. Engine-B datapath (HDL/BD)
- 2nd read engine reading the SAME ring (frame_base/genlock from the same s2mm_frame_ptr / wr_cmd as A).
  Reuse pg_warp_top (or a slimmer pg_read_engine for SD if warp-on-B isn't needed v1 — DECISION below).
- DataMover on **HP3** (free; A=HP1, S2MM=HP0, +HP2 used).
- CDC: ring written on pclk_in (source); engine B reads on the 27 MHz domain → axis_clock_converters
  (like engine A's cmd/dat/sts cc's) between the 27 MHz engine and the 143 MHz DataMover.
- Output stage on 27 MHz: VTC-B (gen, SD timing) → axis_to_vid_io-B → **RGB→YCbCr 4:2:2** convert +
  parallel formatter (P0–P7, HSYNC, VSYNC) → Pmod pins → ADV7393.
- Per-engine CADENCE controller + Mackin blend (the source is async to B's 27 MHz reference).

## 5. ADV7393 output format (v1 pick)
8-bit **YCbCr 4:2:2** with external HSYNC/VSYNC (simplest; SAV/EAV embedded-sync is a later option).
Need: RGB→YCbCr (Rec.601) color convert + 4:2:2 chroma subsample + the P0–P7 byte multiplex (Y/C
interleave at 2× pixel = 27 MHz word rate). ADV7393 SD mode (NTSC-M or PAL-B) set via I²C registers.

## 6. Pmod pin allocation (strategy; finalize exact pins at XDC time)
| Signal group | Pins | Pmod |
|---|---|---|
| ADV7393 data P0–P7 | 8 | JA[7:0] |
| ADV7393 HSYNC, VSYNC | 2 | JB[1:0] |
| Si5351 27MHz → FPGA (CC pin!) | 1 | a JB/JE clock-capable pin |
| I²C SDA, SCL (both chips) | 2 | JD7/JD8 (existing) |
| ADV7393 RESET (+1kΩ series!) | 1 | JE6 (existing) |
| (Si5351 27MHz also wired to ADV7393 CLKIN off-board) | — | jumper |
JC stays the existing 8-bit DAC. Plenty of headroom across JA/JB/JE.

## 7. Firmware
- AXI-IIC driver: Si5351 (0x60) 27 MHz setup + ADV7393 (0x2A) SD-mode setup. RESET sequencing (1kΩ
  warning), power-up order 3.3V-before-1.8V (bench note).
- Engine-B geometry GPIOs (its own scale/sheet-warp/rotation/matte set, mirroring engine A — but per the
  canon law, SCALE via the write side; engine B reads its own SD-sized LOD or the shared HD ring + SD crop).
- Cadence-B control (drop/repeat + Mackin alpha) — reuse engine A's cadence firmware per-engine.

## 8. Build phasing (1 scope, staged builds — de-risk bottom-up)
- **G1 Si5351 bring-up:** I²C config on the NEW chip, 27 MHz on the scope. (Unblocks the clock.)
- **G2 clock-in:** 27 MHz → CC Pmod pin → BUFG → ILA/counter on the 27 MHz domain (prove the clock lives).
- **G3 ADV7393 first light:** simple VTC-B + color-bar pattern gen on 27 MHz → ADV7393 → composite →
  analog display shows bars. (Proves the analog output path end-to-end, no engine B yet.)
- **G4 engine-B datapath:** 2nd read engine reads the ring → SD raster → ADV7393 (real picture on B).
- **G5 per-engine cadence/Mackin FRC** for engine B (independent sync).
- **G6 UI Engine-2 section** (mirror engine A controls; activate the stub).

## 9. Open decisions (need operator input)
- **NTSC-M (480i/60) or PAL-B (576i/50) first?** (sets VTC-B timing + ADV7393 register set.)
- **Composite, S-Video, or component first?** (ADV7393 DAC routing; composite = 1 DAC, simplest.)
- **Warp on engine B v1, or passthrough+scale only?** (full pg_warp_top on B = more DSP/BRAM at the SD
  size = cheap; or a slim SD read engine first, add warp later.)
- **Interlaced output:** SD analog is INTERLACED (480i/576i). Engine B must produce fields (odd/even) —
  a real addition (the warp/read engine is progressive today). This is the biggest net-new piece.

## DECISIONS LOCKED (operator 2026-06-27)
- **Standard: NTSC-M 480i59.94** (720×480 interlaced, 27 MHz, ~59.94 fields/s).
- **Connector: composite (CVBS)** on one ADV7393 DAC — simplest first-light.
- **Engine B = full warp** (mirror engine A: corner-pin/pincushion/rotation + canon scale: shrink
  write-side / enlarge read-side warp zoom).

### Interlace — the net-new piece (G4)
NTSC 480i is INTERLACED; the warp/read engine is PROGRESSIVE. Engine B must emit ODD/EVEN FIELDS
(240 lines each, 1/2-line offset, ~59.94 fields/s = 29.97 frames/s). Options for HOW:
- (a) Engine B reads/warps a full 480p frame then a field-splitter emits alternate lines per field
  (simplest; warp stays progressive, a field-select stage downstream subsamples lines). Risk: inter-field
  motion judder unless paired with the cadence/Mackin (which we have per-engine).
- (b) Engine B warps directly to field rasters (240-line VTC-B, line-doubled addressing). More HDL.
  v1 = (a): progressive 480 warp + downstream field-splitter + per-engine cadence. Clean separation.
- The cadence controller already converts the async HD source → engine-B's 27 MHz field rate.

### Build start = G1 (Si5351 bring-up). Needs operator to wire Si5351 (I²C SDA/SCL + CLK0 out) + scope.
Reuse Phase-E2 Si5351 I²C firmware (mind: AXI-IIC dynamic-mode atomicity, SYS_INIT poll, external pull-ups
already on-board). Port the AXI-IIC + I²C pins onto the current warp BD (they're on a different branch today).

## CORRECTION (operator 2026-06-27) — output format is a RUNTIME STACK, not engine-B HDL
Field/interlace + scan-mode + VTC timing are a SHARED, RUNTIME-CONFIGURABLE OUTPUT STAGE that BOTH
engines instantiate (GPIO-driven), NOT hardcoded into engine B. ANY engine can be ANY format at runtime:
engine A (HDMI) could emit 480i; engine B (analog) could emit 480p. Only the PHYSICAL interface is fixed
per engine (A = rgb2dvi/TMDS, B = ADV7393 parallel). So the field-splitter is a runtime stage:
  output AXIS -> [runtime VTC (res+scan)] -> [field-splitter: bypass when progressive, odd/even subsample
  + cadence when interlaced] -> [format: RGB / YCbCr422] -> physical interface.
Engine A already has runtime VTC res switch (720<->1080); generalize it to add scan (p/i) + the field
stage, and instantiate the SAME stack on engine B. Interlace stops being "engine B net-new" and becomes a
shared runtime feature. (Bigger up-front factoring, but matches the any-engine-any-format product goal.)
