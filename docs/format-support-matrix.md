# Schindler Format Support Matrix

Living document. Source of truth for **what input → output combinations Schindler supports, by what method, with what caveats.** Updated each iter as features ship. Also serves as the QA test plan — every ✅ row should have a bench-validated pass; every 🟡 is the current iter's focus.

Last updated: 2026-05-17 (post-iter4h, entering iter5).

---

## Legend

**Status:**
- ✅ Shipped + bench-validated
- 🟡 In progress (current iter — iter5)
- 🔲 Planned (Phase E or later)
- ⚠️ Supported with caveat (see Notes)
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

## 1. HDMI → HDMI Matrix

Primary output path (rgb2dvi). Covers everything we ship today and most of Phase E.

| # | Input format | Output format | Status | Method | Scaling | Notes |
|---|---|---|---|---|---|---|
| 1 | 1080p60 | 1080p60 | ✅ | — | none | Phase A passthrough. Bench-validated. |
| 2 | 1080p60 | 720p60 | ✅ | — / A | down | iter4d-3 substrate. Scaler in input-side. Bench-validated. |
| 3 | 1080p60 | 720p50 | ✅ | D (6:5) | down | iter4d-3 FRC validation. Genlock + drop/repeat. Bench-validated. |
| 4 | 1080p60 | 1080p24 | 🟡 | D (5:2) | none | **iter5 target.** Clean integer FRC, scaler bypassed. |
| 5 | 1080p59.94 | 1080p23.976 | 🟡 | A / B | none | **iter5 stretch.** Tests MMCM tracking under 1000/1001 drift. |
| 6 | 1080p59.94 | 1080p24 | 🔲 | B | none | Phase E1. Needs MMCM tracking to absorb 59.94→60 drift before 5:2 FRC. |
| 7 | 1080p60 | 1080p30 | 🔲 | D (2:1) | none | Phase E. Trivial integer ratio; should "just work" once iter5 validates substrate. |
| 8 | 1080p60 | 1080p25 | 🔲 | E (12:5) | none | Phase E2. Ugly ratio (12:5), benefits from Mackin blend. |
| 9 | 1080p60 | 1080p50 | 🔲 | E (6:5) | none | Phase E2. Ugly near-1:1 ratio. |
| 10 | 1080p50 | 1080p60 | 🔲 | E (5:6) | none | Phase E2. Inverse of #9. |
| 11 | 1080p50 | 1080p25 | 🔲 | D (2:1) | none | Phase E. Trivial. |
| 12 | 1080p50 | 720p50 | 🔲 | — / A | down | Phase E4 (scaler moved to output side). |
| 13 | 1080p24 | 1080p24 | 🔲 | — | none | Phase E. Pure passthrough; should be trivial. |
| 14 | 1080p24 | 1080p60 | 🔲 | D (2:5 pulldown) | none | Phase F? Reverse pulldown / cadence-aware repeat. Non-trivial. |
| 15 | 1080p23.976 | 1080p60 | 🔲 | D + B | none | Phase F. 3:2 telecine, classic NTSC pattern. |
| 16 | 720p60 | 720p60 | ✅ | — | none | Phase A heritage. Bench-validated. |
| 17 | 720p60 | 1080p60 | 🔲 | — | up | Phase E4. Needs scaler on output side AND upscale support. |
| 18 | 720p60 | 720p24 | 🔲 | D (5:2) | none | Phase E. |
| 19 | 720p50 | 720p60 | 🔲 | E (5:6) | none | Phase E2. |
| 20 | 480p60 | 720p60 | 🔲 | — | up | Phase E4. Needs upscaler. |
| 21 | 480p60 | 1080p60 | 🔲 | — | up (heavy) | Phase E4+. ~2.25× upscale; quality TBD. |
| 22 | 576p50 | 720p50 | 🔲 | — | up | Phase E4. PAL SD→HD. |
| 23 | 1080i60 | * | ❌ | — | — | **No deinterlacing.** Phase F territory. |
| 24 | 1080i50 | * | ❌ | — | — | Same as #23. |
| 25 | 480i / 576i | * | ❌ | — | — | Same as #23. |
| 26 | 2160p (4K) any | * | ❌ | — | — | **Out of scope for Zybo Z7-20** — bandwidth + LE budget insufficient. |
| 27 | VRR / Freesync source | * | ❌ | — | — | dvi2rgb assumes fixed timing. |

### HDMI special-case notes

- **HDMI out is enabled in all rows above** unless explicitly disabled. There is no current combination where HDMI out is electrically disabled.
- **kClkRange limit (rgb2dvi):** pixel clock floor ~40 MHz blocks native 480p over HDMI. See memory: digilent-rgb2dvi-kclkrange-limit. Worked around in earlier Phase work; track here if any row hits the floor.
- **PHY refclk dependency:** all HDMI out depends on Zybo's 125 MHz Ethernet PHY refclk; PHY must be linked or refclk glitches. See memory: zybo-z7-clk125-phy. Bench-noted.

---

## 2. HDMI → Component (YPbPr) Matrix

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

Phase G via ADV7393. CVBS = luma + chroma + sync combined on one wire. Lowest pin count, lowest quality — but it's the first-light target for Phase G.

| # | Input format | Output format | Status | Method | Scaling | Notes |
|---|---|---|---|---|---|---|
| V1 | (none — test pattern) | NTSC composite color bars | 🟡 | — | — | **Phase G first-light target.** Pattern from Phase 2 HDL (sample_gen.v) → ADV7393. No input path involved. |
| V2 | 1080p60 | NTSC composite (480i59.94) | 🔲 | D | down (heavy) + interlace | Phase G iter2. End-to-end first useful conversion. |
| V3 | 1080p50 | PAL composite (576i50) | 🔲 | D | down (heavy) + interlace | Phase G iter2. |
| V4 | 720p60 | NTSC composite | 🔲 | D | down + interlace | Phase G. |
| V5 | 480p60 | NTSC composite | 🔲 | D | downscale + interlace | Phase G. Trivial-ish; lowest stress on scaler. |

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
