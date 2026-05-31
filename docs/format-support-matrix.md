# Schindler Format Support Matrix

> **New to the project?** Start at [`wiki/START-HERE.md`](wiki/START-HERE.md). This matrix is the QA truth ledger; see [`wiki/FRC-ARCHITECTURE.md`](wiki/FRC-ARCHITECTURE.md) for the conceptual map of Methods A-E.

## v1 scope policy (committed 2026-05-31)

Per Direction A scope cut [`matrix-scope-cut-v1.md`](matrix-scope-cut-v1.md):

- **Inputs supported:** 1080p and 720p @ 24/30/60 fps each (6 input formats).
- **HDMI outputs supported:** 1080p and 720p @ 24/30/60 fps.
- **Analog outputs supported:** NTSC composite @ 24/30 fps (via Phase G ADV7393).
- **No upscaling.** Architectural commitment. Matched-rate passthrough and downscale only on the HDMI path.
- **Out of scope for v1:** PAL inputs/outputs (50Hz family), Component output, S-Video, all interlaced inputs, 4K, VRR, all upscale paths.

Cells categorized in the matrix below as:
- ✅ — v1 ship, bench-verified on current production substrate
- ⚠️ — v1 ship target, awaits formal bench re-verification (3-boot rule + monitor) on current substrate
- 🅰 — v1 row blocked on Zybo Z7-20 -1 silicon BUFIO (1080p60 OUT). Production carrier (TE0720 -2) + external HDMI PHY chip resolves. See `[[zynq7020_rgb2dvi_1080p60_limit]]`.
- 🅱 — v1 row blocked on Phase G ADV7393 chip arrival + re-interlace HDL.
- 🔲v2 — explicit deferral to v2 ship
- ❌ policy — out of scope by v1 no-upscale architectural commitment
- ❌ scope — out of v1/v2/v3 scope entirely (interlaced inputs, 4K, VRR, etc.)

---

Living document. Source of truth for **what input → output combinations Schindler supports, by what method, with what caveats.** Updated each iter as features ship. Also serves as the QA test plan — every ✅ row should have a bench-validated pass; every 🟡 is the current iter's focus.

Last updated: 2026-05-24 — iter12+iter13 scaler kernel rework shipped, resolves residual H-shift + V missing-lines from iter6. Production substrate is `iter5-1080p-clean` branch (iter5 + iter6 hardware-fsync + iter12 H scaler `(s_axis_tdata + window[0])/2` + iter13 V scaler `(tap2 + tap3)/2`). HDMI TX = 720p60 (1280×720 @ 1650×750, 74.25 MHz).

**Key iter12+13 change:** scaler_h.v and scaler_v.v MAC switched from NN single-tap (the iter6-era bypass that caused the H-shift by reading leftover row-tail data, and dropped 1/3 source rows vertically) to 2-tap boxcar with newest-tap from `s_axis_tdata` (H) or post-rotation `tap3` (V). Full source col 0..1919 and row 0..1079 ranges now sampled. See `docs/build-manifest.md` "2026-05-24" section for the iter7→iter13 patch progression + per-resolution generalization rules.

**Pre-iter12 history:** iter6 (`bfdc627`) introduced hardware fsync via `c_use_s2mm_fsync=1` + `c_flush_on_fsync=1` + `s2mm_fsync_pulse_gen` cell, resolving the 27-row bottom-bars artifact ([docs/iter6-s2mm-fsync-fix.md](iter6-s2mm-fsync-fix.md)). iter12+13 fixes the residual scaler-kernel issues iter6 unmasked. All prior ✅ entries below were on pre-iter6 substrate and remain suspect.

---

## Legend

**Status:**
- ✅ Shipped + bench-validated on the current production substrate
- ⚠️ Validated on an OLD substrate (pre-iter5 bisect); needs re-test on current substrate
- 🟡 In progress (current iter)
- 🔲 Planned (Phase E or later)
- ❌ Not supported / explicitly out of scope

**Method (FRC handling):**
- **A = Frame Lock** — output clock derived from input pclk (or matched via clk_wiz, no tracking). No FRC; matched rate only. Lowest lag.
- **B = Gen Lock** — MMCM `psincdec` tracks input rate via vsync-delta feedback into clk_wiz DRP. Eliminates drop/repeat for near-matched drift. *(Phase E1, prototyped in iter5.)*
- **C = Triple Buffer / Async Ring** — free-running output + 5-slot ring + firmware hysteresis. Compatibility mode for picky sinks or significant rate change. Accepts visible drop/repeat. *(Phase E3.)*
- **D = Drop/Repeat (current Dynamic Genlock)** — what iter4h ships. Nearest-neighbor frame pick at output vsync. Works for clean integer ratios (5:2, 6:5); degrades at near-1:1 ugly ratios.
- **E = Mackin Virtual-Shutter Blend** — phase-weighted 2-frame blend (Phase E2). Degenerates to drop at clean ratios; smooth at ugly ratios.
- **—** = No method needed (matched rate AND matched res = passthrough).

**Scaling status:**
- `none` — passthrough or same resolution
- `down` — downscale (e.g. 1080→720)
- `up` — upscale (e.g. 480→720)
- `crop` — identity / windowed crop only (no resampling)

**Conditional methods:** rows may show "A if matched, B if drifting" — the firmware selects automatically based on `dvi2rgb pLocked` + VTC rate detector + drift accumulator.

---

## Global caveats

- **No deinterlacing implemented yet.** Any interlaced input (480i, 576i, 1080i) is unsupported until Phase F or later. Currently shows half-height field or sync loss.
- **No upscaling implemented yet.** Scaler is downscale-only (1080→720 polyphase). Phase E4 plan moves scaler to output side; upscaling becomes possible there.
- **Analog out (component / S-Video / composite) requires Phase G ADV7393 bring-up.** Hardware on bench as of 2026-05-16; firmware/HDL TBD.
- **RF Modulator subsystem** is documented but not yet integrated. Out of scope until analog out is solid.
- **All "🟡 iter5" rows** are pending bench validation by Justin. Don't claim "supported" until that pass is recorded.

---

## v1 Ship List (committed 2026-05-31)

Under the v1 scope policy, the in-scope HDMI cells form a 6×6 grid (6 inputs × 6 outputs, less upscale-policy). Production substrate is `iter5-1080p-clean` @ `1ec218c`.

| Input ↓ / Output → | 1080p24 | 1080p30 | 1080p60 | 720p24 | 720p30 | 720p60 |
|---|---|---|---|---|---|---|
| **1080p24** | ⚠️ pass | ⚠️ 5:4 | 🅰 | ⚠️ 1:1 | ⚠️ 5:4 | ⚠️ 5:2 |
| **1080p30** | ⚠️ 4:5 | ⚠️ pass | 🅰 | ⚠️ 4:5 | ⚠️ 1:1 | ⚠️ 2:1 |
| **1080p60** | ⚠️ 5:2 | ⚠️ 2:1 | 🅰 | ⚠️ 5:2 | ⚠️ 2:1 | ✅ Row 2 |
| **720p24** | ❌ policy | ❌ policy | ❌ policy | ⚠️ pass | ⚠️ 5:4 | ⚠️ 5:2 |
| **720p30** | ❌ policy | ❌ policy | ❌ policy | ⚠️ 4:5 | ⚠️ pass | ⚠️ 2:1 |
| **720p60** | ❌ policy | ❌ policy | ❌ policy | ⚠️ 5:2 | ⚠️ 2:1 | ⚠️ pass (Row 16) |

**Net v1 HDMI scope:**
- 24 cells in-scope (15 HDMI 1080-OUT + 9 HDMI 720-OUT)
- **1 cell ✅ formally verified** (Row 2)
- 20 cells ⚠️ awaiting Phase 2 verification on production substrate
- 3 cells 🅰 blocked on production silicon (entire 1080p60-OUT column)
- 12 cells ❌ retired by no-upscale policy

Plus 12 NTSC cells (6 inputs × 2 cadences) all 🅱 blocked on Phase G chip arrival.

**Verification debt under v1 scope:** ~21 cells × 1 bench session each ≈ 7-10 bench hours (down from the Risk Auditor's ~40 hours pre-scope-cut).

### v1 ship-list test plan

Each ⚠️ row needs the standard 3-boot rule + monitor-direct check. Recommend batching by input rate (set ImagePro/source rate once, sweep through output rates). 6 batches:

1. **ImagePro 1080p60 source** → output sweep through 1080p24/30, 720p24/30/60 (5 cells)
2. **ImagePro 1080p30 source** → output sweep through 1080p24/30, 720p24/30/60 (5 cells)
3. **ImagePro 1080p24 source** → output sweep through 1080p24/30, 720p24/30/60 (5 cells)
4. **ImagePro/laptop 720p60 source** → output sweep through 720p24/30/60 (3 cells)
5. **ImagePro/laptop 720p30 source** → output sweep through 720p24/30/60 (3 cells)
6. **ImagePro/laptop 720p24 source** → output sweep through 720p24/30/60 (3 cells — assuming ImagePro can do 720p24)

Each batch ≈ 1 bench session of ~1 hour.

---

## 1. HDMI → HDMI Matrix (detailed rows)

Primary output path (rgb2dvi). Covers everything we ship today and most of Phase E.

> **Reading the Status column:** entries reflect v1-scope tier. Same legend as v1 Ship List above (✅, ⚠️, 🅰, 🅱, 🔲v2, ❌ policy/scope).

| # | Input format | Output format | Status | Method | Scaling | Notes |
|---|---|---|---|---|---|---|
| 1 | 1080p60 | 1080p60 | ❌ on Zybo / ✅ planned on production | — | none | **Dev-board-blocked, production-OK.** Investigated 2026-05-31 (final): (a) initial rgb2dvi kClkRange=2 caused AVAL-46 (VCO 1485 MHz > 1200 MHz -1 max); (b) fixed to kClkRange=1 (VCO 742.5 MHz, in spec), build closed timing with WNS +0.13 ns; (c) bench monitor reported **"signal out of spec"** — OSERDESE2 SerialClk = 5×148.5 = 742.5 MHz exceeds -1 BUFIO 600 MHz max, producing non-HDMI-compliant TMDS. **Production carrier has external HDMI PHY chip (TBD: TFP410/SiI9134/IT6802) that bypasses FPGA TMDS generation entirely AND production silicon is -2 grade with higher BUFIO/VCO ceilings.** Either alone solves this row; together makes it trivially fit. Sole-Zybo workaround = external TFP410 PMOD ($20, ~1 day BD rework). See memories `zynq7020_rgb2dvi_1080p60_limit` + `hdmi_compliance_rule`. |
| 2 | 1080p60 | 720p60 | ✅ | — | down | **iter12+iter13+iter13b (`iter5-1080p-clean` @ `ec13ab2`, 2026-05-31)** fixes the 27-row V-wrap (iter6), H-shift + V missing-lines (iter12+13 scaler kernel rework), and −0.5 LSB DC bias (iter13b round-to-nearest). **3-boot rule satisfied 2026-05-31** on ImagePro static SMPTE via Osee input 1; picture identical across 3 cold reloads. DDR3 dumps + bench-monitor grid pattern confirm: source col 0..1919 fully sampled (left + right vertical lines at output cols 0 + 1279), source row 0..1079 fully sampled (no horizontal line dropouts). Vertical and horizontal lines render as 2-pixel half-bright instead of 1-pixel full-bright (2-tap boxcar trade). |
| 3 | 1080p60 | 720p50 | ❌ scope | D (6:5) | down | **Out of v1 scope** (PAL family — 50Hz not in v1 input/output policy). Forensic only. |
| 4 | 1080p60 | 1080p24 | ⚠️ v1 | D (5:2) | none | **v1 ship target.** Prior ✅ on commit `86dc034` was MS2109-tainted; Phase 2 verify on iter5+iter13b substrate per v1 ship-list test plan above. |
| 5 | 1080p59.94 | 1080p23.976 | 🔲 v2 | A / B | none | **v2.** Requires Phase E1 MMCM tracking for 1000/1001 NTSC drift. Partly shipped on `phase-e1-pll-spike`; needs Phase E2 Si5351 actuator for full pull range. |
| 6 | 1080p59.94 | 1080p24 | 🔲 v2 | B | none | **v2.** Same Phase E1/E2 dependency as #5. |
| 7 | 1080p60 | 1080p30 | ⚠️ v1 | D (2:1) | none | **v1 ship target.** Prior ✅ MS2109-tainted; Phase 2 verify. Note: most desktop monitors reject sub-50Hz refresh (Dell verified rejecting 1080p30 2026-05-31); TV/AVR likely required for bench verify. |
| 8 | 1080p60 | 1080p25 | ❌ scope | D (12:5) | none | **Out of v1 scope** (PAL family). |
| 9 | 1080p60 | 1080p50 | ❌ scope | E (6:5) | none | **Out of v1 scope** (PAL). |
| 10 | 1080p50 | 1080p60 | ❌ scope | E (5:6) | none | **Out of v1 scope** (PAL input). |
| 11 | 1080p50 | 1080p25 | ❌ scope | D (2:1) | none | **Out of v1 scope** (PAL). |
| 12 | 1080p50 | 720p50 | ❌ scope | — / A | down | **Out of v1 scope** (PAL). |
| 13 | 1080p24 | 1080p24 | ⚠️ v1 | — | none | **v1 ship target.** Pure passthrough. Phase 2 verify. |
| 14 | 1080p24 | 1080p60 | 🅰 | D (2:5) | none | **v1 ship target on production silicon.** Zybo-blocked (1080p60-OUT BUFIO). TE0720 / TFP410 enables. Non-trivial cadence (reverse-pulldown class). |
| 15 | 1080p23.976 | 1080p60 | 🔲 v2 | D + B | none | **v2.** 3:2 telecine (classic NTSC pattern). Phase F territory. Also Gate 🅰 on Zybo. |
| 16 | 720p60 | 720p60 | ⚠️ v1 | — | none | **v1 ship target.** Phase A heritage. Phase 2 verify on iter5+iter13b. |
| 17 | 720p60 | 1080p60 | ❌ policy | — | up | **Out of v1 scope** (upscale forbidden by v1 architectural commitment). |
| 18 | 720p60 | 720p24 | ⚠️ v1 | D (5:2) | none | **v1 ship target.** Phase 2 verify. Same Dell-monitor caveat as #7 (sub-50Hz HDMI out). |
| 19 | 720p50 | 720p60 | ❌ scope | E (5:6) | none | **Out of v1 scope** (PAL). |
| 20 | 480p60 | 720p60 | ❌ policy | — | up | **Out of v1 scope** (upscale + 480p not in v1 input list). |
| 21 | 480p60 | 1080p60 | ❌ policy | — | up | **Out of v1 scope** (upscale + 480p input). |
| 22 | 576p50 | 720p50 | ❌ scope | — | up | **Out of v1 scope** (PAL SD + upscale). |
| 23 | 1080i60 | * | ❌ scope | — | — | **Out of all scope** — no deinterlacing planned. |
| 24 | 1080i50 | * | ❌ scope | — | — | Same as #23. |
| 25 | 480i / 576i | * | ❌ scope | — | — | Same as #23. |
| 26 | 2160p (4K) any | * | ❌ scope | — | — | Out of scope for Zybo Z7-20 — bandwidth + LE budget insufficient. |
| 27 | VRR / Freesync source | * | ❌ scope | — | — | dvi2rgb assumes fixed timing. |

### v1 ship-target cells not represented as numbered rows above

The v1 ship list table at the top includes ~18 more cells than the original numbered rows. These are the 1080p30 / 720p30 / 720p24 input variants × 24/30 HDMI output, which weren't in the original matrix because they weren't a focus pre-scope-cut. They share the same Method D drop/repeat infrastructure as the existing rows. Phase 2 verification batches will exercise them at the same time as numbered rows.

### HDMI special-case notes

- **HDMI out is enabled in all rows above** unless explicitly disabled. There is no current combination where HDMI out is electrically disabled.
- **kClkRange limit (rgb2dvi):** pixel clock floor ~40 MHz blocks native 480p over HDMI. See memory: digilent-rgb2dvi-kclkrange-limit. Worked around in earlier Phase work; track here if any row hits the floor.
- **PHY refclk dependency:** all HDMI out depends on Zybo's 125 MHz Ethernet PHY refclk; PHY must be linked or refclk glitches. See memory: zybo-z7-clk125-phy. Bench-noted.

---

## 2. HDMI → Component (YPbPr) Matrix

**❌ Out of v1 scope.** v1 policy includes only HDMI + NTSC composite outputs. Component output is deferred to v2 or later (per `matrix-scope-cut-v1.md`). All rows below are 🔲 v2 minimum; forensic only for v1 planning.

Phase G via ADV7393. Hardware on bench, firmware/HDL TBD. **No rows shipped yet — all 🔲 until Phase G iter1.**

| # | Input format | Output format | Status | Method | Scaling | Notes |
|---|---|---|---|---|---|---|
| C1 | 1080p60 | 1080p60 component | 🔲 | — | none | Phase G stretch. ADV7393 HD component @ 74.25 MHz. |
| C2 | 1080p60 | 720p60 component | 🔲 | — / A | down | Phase G. Scaler reused from HDMI path. |
| C3 | 1080p60 | 480p60 component | 🔲 | — | down (heavy) | Phase G. SD component output (~27 MHz). |
| C4 | 1080p60 | 480i59.94 component | 🔲 | D | down + interlace | Phase G. Needs **re-interlace** logic on output side. |
| C5 | 720p60 | 480p60 component | 🔲 | — | down | Phase G. |
| C6 | 480p60 | 480p60 component | 🔲 | — | none | Phase G simplest case. |
| C7 | * → 1080i component | * | 🔲 | — | up + interlace | Phase G stretch. SD↑HDi rare in practice. |

### Component special-case notes

- **HDMI out behavior when component is active:** TBD — likely **both can run simultaneously** since they share the post-MM2S stream (just different output paths). Need to verify ADV7393 doesn't pull AXIS back-pressure that starves HDMI rgb2dvi.
- **Re-interlace on output** (for component 480i / 1080i) is new HDL — not in current pipeline. Phase G internal sub-task.
- **YCbCr conversion:** ADV7393 can take RGB input and convert internally, OR take YCbCr 4:2:2 parallel. First-light plan uses RGB input (matches our pipeline). May switch to YCbCr 4:2:2 if pin count is an issue.

---

## 3. HDMI → S-Video Matrix

**❌ Out of v1 scope.** v1 policy includes only HDMI + NTSC composite outputs. S-Video is deferred to v3 (or later) per `matrix-scope-cut-v1.md`. All rows below are 🔲 v3 minimum; forensic only for v1 planning.

Phase G via ADV7393. Composite-and-S-Video share the chroma encoder; S-Video keeps luma/chroma separated on output cable.

| # | Input format | Output format | Status | Method | Scaling | Notes |
|---|---|---|---|---|---|---|
| S1 | 1080p60 | S-Video NTSC (480i59.94) | 🔲 | D | down + interlace | Phase G. Heavy downscale + re-interlace. |
| S2 | 1080p50 | S-Video PAL (576i50) | 🔲 | D | down + interlace | Phase G. PAL variant. |
| S3 | 720p60 | S-Video NTSC | 🔲 | D | down + interlace | Phase G. |
| S4 | 480p60 | S-Video NTSC | 🔲 | — / D | down (mild) + interlace | Phase G. Closest to source resolution; simplest. |

### S-Video special-case notes

- **NTSC encoder mode** in ADV7393 — needs I²C config for SMPTE 170M color encoding.
- **PAL encoder mode** — separate I²C config; different subcarrier (4.43 MHz vs NTSC 3.58 MHz).
- **HDMI out + S-Video simultaneously:** likely OK (same caveat as component).

---

## 4. HDMI → Composite (CVBS) Matrix

**In v1 scope.** The marquee feature for MVPHD-24 replacement use. Phase G ADV7393 chip required for all rows (currently 🅱).

The user-facing "NTSC 24 / NTSC 30" outputs are both 480i59.94 NTSC composite signals — the cadence labels describe the program rate carried over the NTSC framework via pulldown:
- **NTSC 24 cadence** = 24fps content via 3:2 pulldown → 59.94 fields/sec (the classic film-on-NTSC method)
- **NTSC 30 cadence** = 30fps program → 60 fields/sec (frame-doubled, no pulldown)

| # | Input format | Output format | Status | Method | Scaling | Notes |
|---|---|---|---|---|---|---|
| V1 | (none — test pattern) | NTSC composite color bars | 🅱 v1 | — | — | **Phase G first-light target.** Pattern from Phase 2 HDL (sample_gen.v) → ADV7393. No input path involved. The pre-req gate for V2+. |
| V2 | 1080p60 | NTSC 30 composite | 🅱 v1 | D (60→30 drop) | down (heavy) + interlace | **Phase G end-to-end first useful conversion.** v1 ship target. |
| V3 | 1080p50 | PAL composite (576i50) | ❌ scope | D | down + interlace | **Out of v1 scope** (PAL family). |
| V4 | 720p60 | NTSC 30 composite | 🅱 v1 | D (60→30 drop) | down + interlace | **v1 ship target.** |
| V5 | 480p60 | NTSC composite | ❌ scope | — | downscale + interlace | **Out of v1 scope** (480p not in v1 input list). |
| V6 | 1080p24 | NTSC 24 composite | 🅱 v1 | D + 3:2 pulldown | down + interlace | **v1 ship target.** Classic film-rate-on-NTSC; the MVPHD-24 marquee use case. |
| V7 | 1080p30 | NTSC 30 composite | 🅱 v1 | — (matched rate) + downscale | down + interlace | **v1 ship target.** |
| V8 | 720p24 | NTSC 24 composite | 🅱 v1 | D + 3:2 pulldown | down + interlace | **v1 ship target.** |
| V9 | 720p30 | NTSC 30 composite | 🅱 v1 | — + downscale | down + interlace | **v1 ship target.** |
| V10 | 1080p60 | NTSC 24 composite | 🅱 v1 | D (60→24 ugly) | down + interlace | **v1 ship target.** 5:2 drop pattern; judder may be visible — Mackin blend (Phase E2) deferred to v2 for smoother motion. |
| V11 | 1080p30 | NTSC 24 composite | 🅱 v1 | D (5:4 + 3:2) | down + interlace | **v1 ship target.** Ugly compound FRC. |
| V12 | 720p60 | NTSC 24 composite | 🅱 v1 | D (60→24) | down + interlace | **v1 ship target.** Same as V10 but from 720p source. |
| V13 | 720p30 | NTSC 24 composite | 🅱 v1 | D (5:4 + 3:2) | down + interlace | **v1 ship target.** |
| V14 | 1080p24 | NTSC 30 composite | 🅱 v1 | D (24→30 ugly pulldown) | down + interlace | **v1 ship target.** Reverse-pulldown class; uncommon real-world use. |
| V15 | 720p24 | NTSC 30 composite | 🅱 v1 | D (24→30) | down + interlace | **v1 ship target.** |

### Composite special-case notes

- **First-light Phase G work doesn't go through the input pipeline at all** — pattern generator drives ADV7393 directly. This proves the analog chain works before integration.
- **3.58 MHz NTSC subcarrier** must be locked to pixel clock for stable chroma. Phase G HDL re-uses earlier R2R-DAC-validated `chroma_gen.v`.
- **Composite-vs-S-Video on ADV7393** is typically a runtime I²C select; same encoder block.

---

## 5. RF Modulator (channel 3/4) — future

See `docs/rf-modulator-subsystem.md`. Not in any iter yet. Would consume composite output → RF up-converter → coax. All 🔲. No rows enumerated until Phase G is solid and RF subsystem PCB is in hand.

---

## 6. Methodology selection rules (firmware logic)

When iter5 + Phase E land, firmware picks the FRC method per input/output pair using this priority:

1. **If input rate == output rate exactly** (within ±1 ppm measured): method `—` (passthrough on rate axis).
2. **Else if user has forced method via AXI-GPIO mode register**: use that method, no auto-fallback.
3. **Else if input/output ratio is a clean integer fraction (5:2, 6:5, 2:1, etc.) within ±100 ppm**: method `D` (drop/repeat, deterministic cadence).
4. **Else if input rate is near-matched (within ±1000 ppm) AND MMCM tracking is in range**: method `B` (Gen Lock).
5. **Else**: method `C` (Triple Buffer, accept drop/repeat hitches).

The user-forced override exists so a producer can pick "I want low lag, accept some glitches" (method A) or "I want max compatibility" (method C) regardless of auto-detection.

---

## 7. Test plan derived from this matrix (Phase E onward)

For each ✅ row, every iter must run a smoke test:
1. Config firmware for the (input, output, medium) tuple.
2. Drive input from ImagePro at specified format.
3. Verify on bench monitor (Justin) AND via UART telemetry (Claude) AND DDR3 byte readback if substrate suspect.
4. Photograph or eyeball motion content for FRC quality (mode B/C/D/E rows only).

🟡 iter5 rows above are the active test queue. Once they pass, they become ✅.

---

Cross-references:
- [Schindler dev roadmap](dev-roadmap.md) — phase numbering source of truth.
- Memory: `schindler-frc-architecture-compass` (strategic), `schindler-phase-e-roadmap` (E1-E4 split), `schindler-iter5-plan` (current iter), `schindler-phase-g-kickoff` (analog out hardware bring-up).
