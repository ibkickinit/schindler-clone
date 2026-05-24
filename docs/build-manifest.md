# Schindler Build Manifest

**Status:** living document. Source of truth for **which builds exist, which ones produce a clean image, and what's broken.** Pairs with [`format-support-matrix.md`](format-support-matrix.md) — that doc tracks **format axis** (what input→output combos), this doc tracks **build axis** (what bitstream lineage).

Last updated: 2026-05-22 ~15:30 — iter6 bottom-bars artifact resolved via S2MM hardware fsync.

## Why this document exists

Justin 2026-05-21: "If you cant look at any particular build and identify whether that build passes clean image, we have failed somewhere. Every build should be snapshotted and recreateable. every snapshot should have clear notes on IS THIS BUILDABLE. If not, why, and what is broken."

Memory entries claiming `SHIPPED` or matrix entries claiming `✅` are **point-in-time observations**, not live state. This document is the live state.

## How to use this document

- Before bench-testing: look up the substrate row. If status is anything other than `✅ CLEAN (verified <date>, N boots)`, **do not bench-test other features on it** — see memory `schindler-no-coin-flip-rule`.
- After every build + bench session: update the relevant row (or add a new one).
- Bench claims require: explicit reboot count, explicit modes tested, explicit symptom if any.

## Legend

**Buildable:**
- `✅` — verified buildable today (clean run, .bit + .xsa + .elf produced, exit 0)
- `⚠️` — last build OK but source may have drifted since (e.g., uncommitted edits, dep changes)
- `❌` — known to fail at build time (specify which stage)
- `?` — never tried or no evidence on disk

**Bench-image (1080p60 input passthrough/scaling, the primary regression-detection mode):**
- `✅ CLEAN` — phase-correct picture, stable across ≥3 reboots, on date in cell
- `⚠️ LUCKY-BOOT` — appeared clean at least once but coin-flip not ruled out
- `❌ COIN-FLIP` — stable horizontal tear (vsync phase coin-flip per memory `schindler-phase-d-vsync-phase`)
- `❌ SCROLL` — slow vertical scroll (per memory `schindler-iter5-bisect-findings`)
- `❌ OTHER` — see notes
- `?` — never bench-tested or no recent bench evidence

---

## Branches snapshot — 2026-05-21

Walked `git branch` 2026-05-21 16:30. Tip commits + best-known status:

| Branch | Tip | Date | Buildable | Bench-image | Notes |
|---|---|---|---|---|---|
| `main` | `045f09b` | 2026-05-16 | ? | ? | Merged PR#3 = iter4g-counter-infra. Pre-iter5. Never tested on current bench. Treat as cold storage. |
| `iter4f-wip-pattern-diag` | `383f173` | 2026-05-16 | ? | ? | Abandoned WIP. Re-added scaler_v row-index test pattern for artifact diag. Not a production candidate. |
| `iter4g-counter-infra` | `14a693e` | 2026-05-16 | ? | ? | Per-stage counter infrastructure. Bug narrowed but not fixed at branch close. See memory `schindler-phase-d-iter4g-state`. |
| `iter4h-axis-fifo` | `7d5fe09` | 2026-05-17 | ? | ❌ SCROLL | iter4h S2MM VSIZE=747 + AXIS FIFO + c_flush_on_fsync=1. Later proved **structurally wrong** by iter5-bisect — caused 1-row-per-frame scroll. **DO NOT USE.** See memory `schindler-iter5-bisect-findings`. |
| `iter5-wip` | `f5a9aa6` | 2026-05-17 | ? | ❌ SCROLL | Pre-bisect iter5 attempt with iter4h additions still present. Same scroll bug. Superseded by `iter5-bisect-720p`. |
| `iter5-bisect-720p` | `81e17a8` | 2026-05-17 | ? | ⚠️ LUCKY-BOOT | The bisect endpoint — iter4d-3 restoration with iter4h additions stripped AND iter3i +STRIDE shift dropped. Claimed CLEAN at 2026-05-17 bench but pre-dates the no-coin-flip rule. **Status: UNTESTED under multi-reboot methodology.** |
| `iter5-1080p-clean` | `f97da45` + iter6 WIP (uncommitted) | 2026-05-22 | ✅ (verified 2026-05-22 15:16) | ⚠️ LUCKY-BOOT (1 boot, iter6 applied) | Tip = iter5-bisect-720p + 1080p substrate + color stack + iter6 S2MM fsync fix. **2026-05-22 ~15:20 bench on 1080p60→720p60: monitor CLEAN, DDR3 dump confirms no leak.** Needs ≥3 cold-boot re-validation + motion-source test + commit before promoting to CLEAN. See "2026-05-22 — iter6" section below. |
| `mackin-impl-wip` | `aff2c43` | 2026-05-18 | ? | ? | Mackin HDL + sim suite (3360/3360 PASS) + placeholder axis_clone wiring. Sim is golden; bench placeholder validated by UART roundtrip only. Dual-VDMA real wiring deferred. **No clean-image bench-validation under no-coin-flip rule.** |
| `phase-e1-pll-spike` | `54a464d` | 2026-05-20 | ? | ? | Phase E1 MMCM tracking work. Memory `schindler-phase-e1-state` claims "Phase E1 SHIPPED 2026-05-19" at `42fe057` — tip has moved since with experiments. **Tip status uncertain; ship-point may be earlier commit.** Untested under no-coin-flip rule. |
| `phase-g-iter1` | `d94f6cb` | 2026-05-21 | ⚠️ (likely; ADV7393 BD + Si5351 BD) | N/A | Today's WIP commit on top of Phase G ADV7393 + Phase E2 Si5351. Both BLOCKED on hardware (chips dead, replacements ordered). No video-path regression — Phase G isn't about image quality. |

---

## Bitstream artifacts on disk — 2026-05-21 16:30

Only artifacts newer than the 2026-05-11 `schindler-2.0.bit` baseline. All sized 4045694 bytes (Zynq-7020 standard).

| Path | Mtime | Branch when built | Commit | Status |
|---|---|---|---|---|
| `build/vitis-phase-b/phase_b_pf/export/phase_b_pf/hw/phase_b.bit` | 2026-05-21 16:25 | `iter5-1080p-clean` | `f97da45` | Today's rebuild. Tested at bench → COIN-FLIP at 720p60 output. |
| `build/vitis-phase-b/vdma_init/_ide/bitstream/phase_b.bit` | 2026-05-21 16:25 | same | same | Same .bit, Vitis duplicate. |
| `build/vitis-phase-b/phase_b_pf/hw/phase_b.bit` | 2026-05-21 16:24 | same | same | Same .bit, Vitis duplicate. |
| `build/phase-b-vdma-passthrough/phase-b-vdma-passthrough.runs/impl_1/phase_b_bd_wrapper.bit` | 2026-05-21 16:23 | same | same | Source bitstream from Vivado impl_1 run. Same content. |
| `build/phase_b.bit` | 2026-05-18 01:41 | `iter5-1080p-clean` | `7af40e1` | Previous build, **older by one commit** (firmware-only diff to current `f97da45`). Bitstream identical. Pre-2026-05-21 build evidence — **untested under no-coin-flip rule**. |

**All other older .bit/.xsa on disk:** Phase A (`schindler-2.0.bit`, 2026-05-11), Phase-TPG, ila-capture-victory builds, etc. **None are current production candidates.** Listed in `git log` archaeology, not regularly maintained.

---

## Current bench state — 2026-05-21

**Loaded on FPGA:** `iter5-1080p-clean` @ `f97da45` (today's rebuild, programmed via XSCT at 16:25).

**Last bench observation 2026-05-21 16:27:** SMPTE-like color bars from ImagePro fed as 1080p60 → output to bench monitor at 720p60 with scaler. Stable horizontal/vertical offset mid-screen — top half shifted relative to bottom half. Initially suspected vsync-phase coin-flip.

**EOLLate** flag set every frame on S2MM_SR.

**2026-05-21 ~17:00 follow-up (cold-boot from QSPI ×3):** offset is **DETERMINISTIC** — identical offset across 3 cold boots. **Rules out vsync-phase coin-flip** from [[schindler-phase-d-vsync-phase]] (that one is random per boot). This is a different, systematic bug. Three candidate root causes under investigation:

1. **EOLLate-driven buffer offset.** S2MM stalls per frame → row pointer rolls forward by fixed N → consistent offset.
2. **Firmware VTC alignment off by deterministic delta.** Boot prints "VTC aligned to source vsync" but the math may miss by a fixed line count.
3. **Scaler pipeline latency unaccounted.** v_v polyphase warmup (4-8 input rows) shifts the first valid output line; if VTC TX starts before that warmup completes, the picture is offset by exactly that amount every boot.

Next probe: read S2MM_SR + MM2S_SR over many frames to characterize EOLLate cadence; check firmware vtc_setup() for the alignment math; compute expected scaler latency vs. VTC TX start.

**Status on builds in QSPI:** unknown which commit was last `program_flash`'d. Boot was from QSPI, shows similar offset → strongly suggests the bug pre-dates today's rebuild and exists in whatever-was-burned-last. Likely the same `iter5-1080p-clean` lineage. **No "previously known clean" build is currently identifiable** — all candidates are now suspect.

**2026-05-21 ~17:30 — Critical re-read of session record.** Mining `tests/phase-e1/` session docs (`phase0_baseline.md`, `phase_e2_bench_session_2.md`) reveals:

1. **`phase_e2_bench_session_2.md` documented this exact bug** as a product-blocker on 2026-05-20: *"the picture shows the same vertical wraparound pattern... Top of one frame fills the upper ~80% of screen; bottom ~20% shows the top of the next frame. This is a product-blocker failure mode."* Bug was diagnosed but **never resolved** — Phase E2 was abandoned at that point and work pivoted elsewhere.

2. **Root cause per that session doc:** VTC TX alignment is run once at boot via `wait_for_aligned_source_vsync()` but has a deterministic offset of ~120 lines at 720p50. PI rate-only controller cannot fix phase offset. Phase E2 session 2 author proposed two fixes (discrete phase jump via VDMA park-pointer write at SOF, OR re-run alignment after `r src` ref-switch) but neither was implemented.

3. **MS2109 verification trap.** Per [[schindler-ms2109-masks-artifacts]], MS2109 capture stick has its own framebuffer that absorbs vertical-wraparound artifacts. Builds previously stamped "PASS" or "✅" that were verified via MS2109 capture may NOT have been clean on the bench monitor. **Justin's report 2026-05-21 ~17:25:** "I am seeing things on the monitor I didnt see in the usb capture, which means I cant trust my own 'good'." All prior PASS claims now require re-verification on monitor specifically.

4. **Phase 0 baseline (`d71c994`, 2026-05-18 22:14)** claimed PASS with WNS +0.389 / WHS +0.013. May or may not be monitor-verified — phase0_baseline.md says "user-reported 'completely clean'" without specifying which display. Treat as ⚠️ pending re-verification under no-MS2109 rule.

5. **Phase A (`top_phase_a.bit`, branch `phase-a-hdmi-passthrough` era, 2026-05-13)** is architecturally incapable of having this bug. No DDR3 buffer, no scaler, no separate output clock — output vsync IS recovered source vsync. Phase A doc explicitly states "validated stable at 1920×1080@60p ... → external monitor." Monitor-verified PASS. WNS +0.23 / WHS +0.06. **This is the substrate to return to as ground truth.**

## Revised plan: bisect from Phase A forward

Walk forward from Phase A one architectural change at a time, monitor-verified at each step:

| Step | Substrate | What it adds | Should expose bug if it's in this layer |
|---|---|---|---|
| A | Phase A passthrough | nothing — direct dvi2rgb→rgb2dvi | (baseline — must be clean) |
| B0 | Phase B VDMA passthrough | DDR3 buffer in path (S2MM + MM2S, both at source clock) | Tests DDR3 / VDMA ring without rate mismatch |
| B1 | Phase B + scaler | scaler_top in path | Tests scaler latency/sync |
| B2 | Phase B + scaler + output MMCM | separate output pixel clock | Tests rate-domain crossing — likely where offset originates |
| D | iter4d-3 substrate | + FRC dynamic genlock | Tests Dynamic Genlock alignment |

At each step: cold-boot ≥3 times, eyeball bench monitor (not MS2109), document outcome here. Stop bisect at first step that introduces the offset → root cause localized to that layer.

---

## 2026-05-21 17:18 — Phase A confirmed clean on NEW MONITOR

**The previous bench monitor had a fault.** Justin moved to a different monitor and re-loaded today's Phase A rebuild (commit `89f3eff` at `build/phase-a-hdmi-passthrough/phase-a-hdmi-passthrough.runs/impl_1/top_phase_a.bit`, WNS +0.229 / WHS +0.060). Source: ImagePro 1080p60. Result: **clean passthrough confirmed monitor-verified.**

**Implications:**
- **All today's bench observations on the prior monitor are tainted by monitor fault.** Today's iter5-1080p-clean "horizontal tear" and "deterministic 20-30 line offset" findings may have been monitor-driven artifacts on a faulty display, not real bugs in the iter5 substrate.
- The QSPI-boot "flickering and offset" observation also tainted by old monitor.
- **Until each candidate build is re-verified on the new monitor, NO conclusions about iter5/Phase E/iter4 substrate quality from today's session are trustworthy.**
- The Phase A baseline is solid. WNS reproducible, bitstream produces clean output on a known-good monitor.

**Lesson banked:** when bench observations don't match HDL/architectural expectations, suspect bench equipment (monitor, cable, source) BEFORE rebuilding/reverting. The MS2109 verification trap had a sibling: the monitor itself can be a confounder.

**Re-verification queue under new monitor:**
| Build | Was reported as | Re-test |
|---|---|---|
| Phase A (`89f3eff`) | ⚠️ flicker (old monitor) → ✅ CLEAN (new monitor, 2026-05-21 17:18) | DONE — baseline holds |
| iter5-1080p-clean (`f97da45`) | ❌ tear (old monitor) → **❌ flicker + EOLLate (new monitor, 2026-05-21 17:35)** | DONE — real bug, not monitor |
| iter4d-3 (`d71c994`) | claimed clean 2026-05-18 | Untested today |
| Each other candidate | various | Untested today |

## 2026-05-21 17:35 — iter5-1080p-clean confirmed broken on NEW MONITOR

Re-programmed today's iter5-1080p-clean rebuild (.bit from 16:24, ELF from 16:25) on the new monitor. **Flicker is still present.** UART telemetry confirms:
- `S2MM_SR=0x0001D000[FrmCnt EOLLate frmcnt=1]` set EVERY FRAME
- `MM2S_SR=0x00011000[FrmCnt frmcnt=1]` clean
- `PHASE deltas={1,1,1,...}` — 1:1 matched rate (no FRC active)
- `RDSTORE=0 WRSTORE=0` — parked (WRSTORE reads-as-0 per `xilinx-vdma-dmasr-bits`)
- Source detected at 1920×1080, scaler programmed IN_W=1920 IN_H=1080
- Output VTC = 720p60 (firmware default; scaler downscale 1080→720 active)

**Diagnosis:** EOLLate every frame = S2MM AXI write side reports it couldn't end-of-line in time. This is a real pipeline issue, not the prior monitor's confound. The scaler→S2MM path has a back-pressure or sync issue that's been there since at least 2026-05-18.

**Visual evidence:** `~/Pictures/Webcam/2026-05-21-173328.jpg` (Dell monitor, ImagePro SMPTE bars source) — shows the iter5-1080p-clean failure mode: SMPTE bars with **multiple horizontal discontinuity bands** at fixed positions, bars not aligned across split lines. Consistent with EOLLate-driven row-pointer drift creating cumulative within-frame offsets at specific scanlines. Canonical reference image for this bug.

## 2026-05-21 17:40 — ROOT CAUSE HYPOTHESIS: scaler/firmware config mismatch

Reading `tcl/build_phase_b.tcl` line 304-305: `SCALER_MODULE` env var default is **`scaler_bypass_1080p`** (introduced in iter5; pre-iter5 default was `scaler_top`).

`scaler_bypass_1080p` is a **no-op pass-through** — output dimensions equal input dimensions. With 1080p60 input, it delivers 1920×1080 frames downstream.

Firmware `main.c` line 1180 default: `MODE_720P60` — configures VTC TX for 1280×720 timing AND configures VDMA S2MM/MM2S with HSIZE=3840 (1280×3 bytes) and VSIZE=720.

**These are incompatible:**
- Data path: 1920×1080 per frame (5760 bytes/line × 1080 lines)
- VDMA S2MM expectation: 1280×720 per frame (3840 bytes/line × 720 lines)
- S2MM sees end-of-line at byte 3840 but pixel data keeps streaming → **EOLLate every frame** (matches UART observation)
- The visible flicker = S2MM corrupting frame buffers because its line/frame boundaries don't match what the data delivers

This appears to be **a regression that landed during iter5** when someone flipped the SCALER_MODULE default from `scaler_top` to `scaler_bypass_1080p` to test 1080p paths, but the firmware MODE default was never updated to match. Format-matrix Row 2 ✅ entry explicitly references `scaler_top` — that combination was the validated one.

**Two paths to fix (next iteration):**
- **A.** Rebuild with `SCALER_MODULE=scaler_top` → restores the matrix-validated combination (1080p60→720p60 with real downscale). Same firmware works.
- **B.** Change firmware mode to `MODE_1080P30` or `MODE_1080P24` → matches `scaler_bypass_1080p` no-op (1080p frames end-to-end, FRC on rate axis only). Different test path.

A is the "back to known-good config" iteration. Doing it first.

## 2026-05-21 18:00 — Iter1: SCALER_MODULE=scaler_top result

**Build:** branch `iter5-1080p-clean` @ `f97da45`, `SCALER_MODULE=scaler_top vivado -mode batch -source tcl/build_phase_b.tcl`. WNS=-3.747 / WHS=+0.014 (timing closure same character as previous color-stack-async-CDC build — ASYNC_REG mitigated). Bitstream 17:57, ELF 17:58, programmed 17:58.

**UART telemetry verdict: substrate is healthy.**
```
DIAG: px=1080 lines=1080 maxpx=720 mm2s=0  S2MM_SR=0x00011000[FrmCnt frmcnt=1] MM2S_SR=0x00011000[FrmCnt frmcnt=1]  RDSTORE=2 WRSTORE=3  src=59 out=60
PHASE: deltas[12]={1,1,1,1,1,1,1,1,1,1,1,1}
```
- **EOLLate eliminated** (was 0x0001D000, now 0x00011000). Real win — confirms config-mismatch hypothesis.
- Both S2MM and MM2S status registers clean every frame.
- VDMA Dynamic Genlock pointers cycling (RDSTORE=2, WRSTORE=3).
- Source rate matched 1:1 (PHASE deltas all 1).
- Full UART capture: `Images/2026-05-21_iter1_scaler_top_uart.log`

**Visual verdict on bench monitor (via Brio webcam /dev/video10): STILL BROKEN, but DIFFERENTLY.**

Three webcam captures across ~3 sec each show different content positions:
- Frame 030: `Images/2026-05-21_iter1_scaler_top_frame030.jpg` — yellow rectangles lower-right
- Frame 090: `Images/2026-05-21_iter1_scaler_top_frame090.jpg` — yellow rectangles upper-left
- Frame 150: `Images/2026-05-21_iter1_scaler_top_frame150.jpg` — yellow gone, small dark blocks on left

**SMPTE bar features are DRIFTING across screen.** This is the vertical wraparound + slow phase drift bug documented in `tests/phase-e1/phase_e2_bench_session_2.md` (2026-05-20). It was always present in iter5-1080p-clean — the prior EOLLate was just SO bad that it masked the wraparound visually.

**Net iter1 result:**
- ✅ EOLLate root cause confirmed and fixed (config-mismatch: SCALER_MODULE=scaler_bypass_1080p default mismatched MODE_720P60 firmware default; using scaler_top restores matrix-validated combination)
- ❌ Vertical wraparound + drift persists (a SECOND bug, documented Phase E2 product-blocker, not fixed by this iteration)

The drift implies output VTC vsync is not phase-locked to source vsync — output rate is *averaged* close to source (deltas=1) but absolute phase is sliding. Per `tests/phase-e1/phase_e2_bench_session_2.md`: VTC TX alignment runs once at boot (`wait_for_aligned_source_vsync()` per the firmware) but has deterministic offset; rate-only control cannot fix phase offset; needs either a discrete phase jump at SOF or a re-run of the alignment dance.

## 2026-05-21 18:00 — Iter2 plan

Two diagnostic paths to disambiguate WHICH alignment layer is broken:

**A. Try `MODE_1080P30` firmware + `scaler_bypass_1080p` HDL** — matched 1080p frame size end-to-end, scaler bypassed entirely, ONLY rate-axis FRC (drop every other frame). If wraparound persists → bug is in VTC TX alignment math, independent of scaler. If wraparound goes away → bug requires scaler in path.

**B. Try a passthrough sub-case: 1080p60 in → 1080p60 out** — would require BD reconfig for 148.5 MHz output clock (clk_wiz change), so not a firmware-only test. **Skipping for now** since it's an extra Vivado+BD-rebuild.

Iter2 is path A. Firmware-only change (edit MODE_720P60 reference → MODE_1080P30 in main.c), Vitis rebuild, reprogram. ~3 min cycle. No Vivado rebuild needed; current scaler_top bitstream still works because scaler with IN_W=IN_H is a no-op when output dimensions are not configured (actually need to verify this — scaler may not gracefully handle out_w=in_w; might need scaler_bypass_1080p HDL for that test).

Reconsider: iter2 may need both Vivado rebuild (revert to scaler_bypass_1080p HDL) AND firmware change (MODE_1080P30). ~30 min cycle for full iter2.

## 2026-05-21 18:10 — Drift characterization (15s window, 450 frames)

Captured 15 seconds of webcam frames after iter1 build was running. ImagePro had auto-cycled from SMPTE bars to a checkerboard + "Quantum" text test pattern between captures. Result:

| Frame | Time | "Quantum" text position |
|---|---|---|
| 000 | 0.0 s | middle-right |
| 100 | 3.3 s | top edge |
| 200 | 6.7 s | middle-right |

**Text sweeps the screen vertically with a period of ~6.7 seconds.** This is monotonic vertical wraparound at ~150 lines/sec drift = ~2.5 lines/frame at 60 Hz output = ~2300 ppm rate mismatch between source and output clocks.

**Root cause confirmed: independent output clock without tracking.**
- Source pixel clock: recovered from `dvi2rgb` at whatever rate ImagePro is sending (likely NTSC 1000/1001 = 59.94 Hz, possibly slightly different given measured ~2300 ppm offset).
- Output pixel clock: `clk_wiz_pixclk_out` MMCM at nominal 74.25 MHz, free-running. No feedback path from source-vsync drift to MMCM frequency.
- Dynamic Genlock keeps S2MM/MM2S frame buffer pointers in lockstep BUT cannot fix output-clock-vs-source-clock rate difference.
- The slow drift accumulates → visible roll on monitor.

**This is exactly the architectural problem Phase E1 MMCM tracking was built to solve.** Per [[xilinx-mmcm-psincdec-tracking]] and `tests/phase-e1/phase_e1p6_baseline_root_cause.md`: closed-loop nudges MMCM phase via DRP to track source vsync. Phase E1 ground-up plan ships at commit `42fe057` per [[schindler-phase-e1-state]] (claimed bench PASS for tracking loop + cadence handoff).

## Iter1 net findings

| Symptom (before iter1) | Status after iter1 |
|---|---|
| EOLLate every frame (S2MM_SR bit 15 set) | ✅ FIXED — config mismatch eliminated. Confirmed by `S2MM_SR=0x00011000` (clean). |
| Stable horizontal banding (multiple discontinuities) | ✅ FIXED — was a downstream effect of EOLLate. |
| Vertical wraparound + drift | ❌ PERSISTS — architectural (independent output clock). Cannot be fixed at iter5-1080p-clean substrate level. Needs MMCM tracking layer (Phase E1) or shared-clock architecture (Phase A-style). |

**iter5-1080p-clean is fixable for matched-rate-passthrough by using `SCALER_MODULE=scaler_top` + `MODE_720P60` firmware, BUT will always exhibit slow visible drift due to free-running output MMCM.** This is the FRC substrate's inherent limitation pre-Phase-E1.

## Iter2 plan (next session)

Switch to `phase-e1-pll-spike` branch + verify MMCM tracking eliminates the drift. The Phase E1 ground-up plan session docs (`tests/phase-e1/phase_e1p6_baseline_root_cause.md`, `phase7_states.md`, `phase8_cadence.md`) all claim PASS for tracking loop + reference mux + cadence handoff. Build, program, capture webcam over 15+ seconds, check for drift.

- If Phase E1 build is drift-free → Phase E1 work was real, iter5 + E1 tracking is the production substrate.
- If Phase E1 build also drifts → Phase E1 "PASS" claims may have been MS2109-tainted; tracking loop needs real bench fix.

Build artifacts/logs for iter1 archived under `Images/2026-05-21_iter1_*` for diff-reference next session.

## 2026-05-21 19:15 — Iter1 visual conclusion INVALIDATED then CORRECTED

**Topology discovery that invalidated iter1's drift claim:** The bench monitor's HDMI input is fed from the **Osee GoStream Duet switcher's PGM output** at `192.168.0.10:19010`. The Osee selects between 3 sources:
- input 1 (protocol value 0) = ImagePro 1080p60 static SMPTE bars (the only known-static source)
- input 2 (protocol value 1) = motion loop (the "Quantum" text source I captured during iter1)
- input 3 (protocol value 2) = laptop (remote-controllable)

When I did the iter1 webcam captures autonomously, the Osee was on **input 2 (motion loop)**, NOT a static source. The "rolling/drifting" I observed and characterized as 2300 ppm output-clock drift was actually **the motion loop's own intrinsic content motion** passing through iter5 — the FPGA pipeline was faithfully reproducing motion.

**Re-test with Osee on input 1 (static ImagePro):**

- Two frames captured 5 seconds apart at `Images/2026-05-21_iter1_static_t0.jpg` and `Images/2026-05-21_iter1_static_t5.jpg`.
- Both frames **visually identical** in content/positions (MD5 differs only from webcam JPEG/exposure noise).
- Output shows clean SMPTE bars **with a small thin strip at the very bottom of the screen** containing what looks like the start of the next frame (~5-10% of vertical height = ~36-72 lines at 720p output).
- No motion, no drift, no roll — the wraparound stays at the same position frame after frame.

**Corrected iter1 verdict:**

| Symptom | Status |
|---|---|
| EOLLate every frame | ✅ FIXED by SCALER_MODULE=scaler_top |
| Output rate drift (claimed earlier) | ❌ FALSE — was Osee input 2 motion loop content; not a pipeline bug |
| Deterministic vertical wraparound | ❌ EXISTS — ~5-10% of frame at bottom is from next-frame top |
| Output stability with static source | ✅ STABLE — no drift, no roll |

**The wraparound IS the same bug `tests/phase-e1/phase_e2_bench_session_2.md` documented:** VTC TX alignment runs once at boot with a deterministic line-count offset. ~50 lines at 720p60 (today) vs ~120 lines at 720p50 (their test) — same order of magnitude, consistent with the same firmware bug.

**Tools added 2026-05-21:**
- `/tmp/osee_switch.py` — minimal GSP client for Osee at 192.168.0.10:19010. Usage: `osee_switch.py <1|2|3|status>`. User-label inputs are 0-indexed in protocol (input N = protocol value N-1).

**Bench methodology lesson:** Always check Osee input before drawing visual conclusions from the monitor. ImagePro on input 1 is the only known-static source. Saved as memory feedback.

## Iter2 plan (revised)

The drift bug doesn't exist. The vertical wraparound is the remaining bug. It's deterministic — a firmware alignment math problem.

Iter2 should be **a firmware investigation**, not another build. Read `sw/phase-b/src/main.c::wait_for_aligned_source_vsync()` and `vtc_setup()` to find the alignment math. The Phase E2 session 2 doc proposed two fixes: (a) discrete phase jump via VDMA park-pointer write at SOF, or (b) re-run alignment after ref-switch. Neither requires a Vivado rebuild — just firmware. ~3 min cycle per attempt.

## 2026-05-21 20:17 — Iter2: move printf in vtc_setup AFTER CTL write

**Hypothesis:** `xil_printf("VTC: configuring %s...", ...)` at the TOP of `vtc_setup()` adds ~3.5 ms delay (UART at 115200 baud × ~40 chars) before the CTL register write that triggers VTC generator start. This violates the caller's explicit "NO printfs between wait_for_aligned and CTL write" rule at `main.c:1156-1168`. ~3.5 ms = ~227 source lines of misalignment at 1080p60.

**Change:** moved `xil_printf` from line 1019 (before register writes) to after the CTL register write at line 1054-1058.

**Result:** VISUALLY IDENTICAL to iter1. Wraparound at the bottom of frame remains the same size and same position. Saved at `Images/2026-05-21_iter2_printf_moved.jpg`.

**Conclusion: the existing comment at main.c:1161 was correct** — "alignment is driven by VDMA frame-buffer timing rather than VTC vsync_out phase." Latency between `wait_for_aligned_source_vsync()` and VTC GE-write does not affect the displayed image. The printf move is a cleanup (matches the caller's stated design intent) but does NOT address the wraparound bug.

**Iter2 firmware change kept** in source as a correctness improvement (it doesn't hurt and matches the documented design contract), but the bug is elsewhere.

**Where the wraparound actually originates — narrowing the search:**

| Suspect | Evidence | Status |
|---|---|---|
| VTC GE-write timing (printf) | iter2 disproved | RULED OUT |
| Source clock vs output clock drift | iter1 static-source proves no drift | RULED OUT |
| EOLLate-driven buffer corruption | iter1 telemetry shows no EOLLate | RULED OUT |
| MM2S +STRIDE shift (1 row offset) | Math checks out — only 1 row | INSUFFICIENT — wraparound is ~25-50 lines |
| GUARD region not zeroed | Code zeroes it before Xil_DCacheDisable() which flushes | UNLIKELY but worth confirming |
| Scaler emits more than 720 rows | Unknown — need to read scaler HDL | **OPEN — iter3 candidate** |
| VTC TX VTOTAL/V_BACK math off | MODE_720P60 looks standard CEA-861 | UNLIKELY |
| VDMA reads past buffer end | HSIZE=3840 VSIZE=720 per UART, should be exact | UNLIKELY but a diagnostic memcmp would confirm |

## 2026-05-21 20:20 — Iter3 plan

Two diagnostic candidates:

**A. Buffer-fill diagnostic.** Fill all DDR3 frame slots with a recognizable color (e.g., red), DON'T start VDMA S2MM, only start MM2S to read from buffers. Whatever shows on monitor = what MM2S is actually reading. If wraparound shows red at the bottom → MM2S reads stale buffer data past valid region (GUARD not protecting). If wraparound shows other content → it's coming from elsewhere.

**B. Scaler emit row count.** Read `hdl/scaler_top.v` and `hdl/scaler_v.v` to check whether scaler emits exactly OUT_H rows per frame or potentially overruns. The scaler is the most complex part of the pipeline and the +STRIDE shift comment suggests row-count edge cases exist.

I'd start with B — purely reading code, no rebuild needed.

## 2026-05-21 20:30 — Bug identified as the documented bottom-bars artifact

Read `docs/iter4g-diagnostic-findings.md` (2026-05-16). The wraparound today is **exactly** the bug that doc describes:

- Symptom: "~25 rows of next-frame-top at bottom" of every output frame
- Counter telemetry shows scaler emits 720 rows correctly, but **slot rows 694..719 contain wrong data** (next frame's top color bars instead of current frame's PLUGE bottom)
- +STRIDE offset moves visible boundary by 1 row but doesn't change the bug

**Bug history:**
- 2026-05-16: identified in iter4g; documented as open question.
- 2026-05-16 evening: iter4h tried fix via S2MM VSIZE=747 (over-allocate by 27 rows, spillover written into GUARD area). Confirmed fixed bottom-bars by bench observation. Memory `schindler-bottom-bars-artifact`.
- 2026-05-17 evening: iter5 bisect found iter4h's VSIZE over-allocate caused a 1-row-per-frame slow scroll. Bisect removed iter4h fix to eliminate scroll. Memory `schindler-iter5-bisect-findings`.
- 2026-05-17 / 2026-05-21: bottom-bars present again on current iter5-1080p-clean substrate, but bench claimed "clean" — likely because validation was MS2109-tainted (memory `schindler-ms2109-verification-trap`).

**Today's iter1+iter2 work made the bug visible for the first time on a monitor.** Phase A baseline + Osee topology fix + EOLLate elimination + new monitor all combined to make the previously-hidden artifact unambiguous.

**Open question from iter4g still open:** Why does scaler emit 720 rows (per counter) but slot rows 694..719 contain wrong data? Either:
- Scaler emit counter is wrong (TUSER timing); or
- Scaler MAC pulls wrong data for last ~25 emits (lbuf or v_phase issue at frame boundary); or
- S2MM partially writes frame N+1 into frame N's slot during frame transition; or
- Dynamic Genlock advances S2MM to next slot mid-write under some condition.

Per iter4g doc proposed next step: "Add a counter at scaler_v's m_axis output (count m_axis_tlast firings vs v_cross firings — should be equal but verify)." That's an HDL change + Vivado rebuild.

## Session close 2026-05-21 20:30

Real wins this session:
- ✅ Phase A baseline reconfirmed clean on new (working) monitor
- ✅ Bench equipment confounders banked as feedback memories (faulty monitor, MS2109 trap, Osee topology)
- ✅ EOLLate root cause identified + fixed (SCALER_MODULE / firmware mode mismatch)
- ✅ Drift hypothesis disproven (it was source motion via Osee input 2)
- ✅ Bottom-bars wraparound visually quantified (~25-50 lines)
- ✅ Bug identified as the documented unresolved iter4g artifact
- ✅ Iter2 printf-move ruled out as cause; that hypothesis now negative-falsified

Active state: board on Phase A (clean baseline). Iter5-1080p-clean rebuild artifacts on disk + new firmware (printf moved). Bottom-bars artifact is the next real work — requires HDL diagnostic counters per iter4g doc's open question.

**Iter3 (next session):** Either add m_axis_tlast counter to scaler_v's output, OR test the S2MM VSIZE over-allocate fix paired with a different S2MM completion mechanism that doesn't introduce scroll. Both require Vivado rebuild.

## 2026-05-21 21:20 — iter4h-axis-fifo bench validation REWRITES memory

Built and tested `iter4h-axis-fifo` @ `7d5fe09` on new monitor with Osee input 1 (static SMPTE bars). Memory `schindler-phase-d-iter4h-state` claimed it "fixes bottom-bars but introduces 1-row-per-frame scroll." Today's monitor-verified test shows:

**Build numbers:** WNS=+0.238, WHS=+0.009. Clean timing (no color stack → no async CDC paths). Vitis ELF rebuilt, programmed via XSCT. UART telemetry: `DIAG: h_in=1080 v_in=1080 v_emit=720 ... S2MM_SR=0x0001D000[FrmCnt EOLLate frmcnt=1] MM2S_SR=0x00011000[FrmCnt frmcnt=1] RDSTORE=2 WRSTORE=0`. EOLLate IS still set every frame (S2MM VSIZE=747 over-allocate produces it).

**Visual observation across 5 seconds (150 webcam frames captured):**

| Time | What's at top of screen | What's at middle | What's at bottom |
|---|---|---|---|
| t=0.0s | thin strip (PLUGE remnant + I/Q) | SMPTE bars | PLUGE (white box, Q-square) |
| t=1.0s | SMPTE bars (full) | I/Q strip | PLUGE + thin strip of next-frame bars |
| t=2.0s | SMPTE bars (top portion) | PLUGE + I/Q | larger strip of next-frame SMPTE bars |
| t=5.0s | PLUGE at top + thin strip | SMPTE bars (top half) | SMPTE bars (bottom half) |

Reference images: `Images/2026-05-21_iter4h_t{0.0,1.0,2.0,3.0,4.0,5.0}s.jpg`.

**Findings — both memory claims OVERTURNED:**

1. **❌ "Fixes bottom-bars"** — FALSE. The bottom-bars wraparound strip is **STILL PRESENT in every frame**, exactly like iter1. iter4h does NOT eliminate the artifact.
2. **✅ "Introduces scroll"** — TRUE, but rate is **~1.5 lines/frame** (≈90 lines/sec at 60Hz), not 1.0 as memory said. Picture moves UPWARD continuously, content cycles fully in ~8 seconds.

**iter4h is STRICTLY WORSE than iter1** (iter5-1080p-clean + scaler_top + MODE_720P60). Iter4h has the same bottom-bars artifact PLUS continuous scroll. The previous "iter4h fixed bottom-bars" claim must have been MS2109-tainted — the capture stick's internal framebuffer absorbs the scroll AND the wraparound, making everything look stable on capture.

**Memory corrections required:**
- `schindler-phase-d-iter4h-state` — claim "FIXES bottom-bars" needs strikethrough; revised to "introduces scroll without fixing bottom-bars"
- `schindler-bottom-bars-artifact` — claim "RESOLVED 2026-05-16 evening: Path 2 (S2MM VSIZE=747 + fsync wiring) eliminates the leak" needs strikethrough; the leak is NOT eliminated.
- `schindler-iter5-bisect-findings` — the bisect's "iter4h was structurally wrong" verdict stands, but the rationale needs adjustment: iter4h is wrong because it adds scroll WITHOUT fixing the actual bug.

**Path forward:** the bottom-bars fix is NOT in S2MM VSIZE over-allocate. The actual cause needs identification — likely scaler_v emit-at-frame-boundary issue per the iter4g doc's open question. That's HDL-level investigation (m_axis_tlast counter at scaler_v output).

**The previous "deterministic 20-30 line offset" finding (Justin observing QSPI boot) is consistent** with EOLLate-driven row-pointer drift: S2MM rolls into the next row late, accumulates a fixed offset per frame, visible on monitor as deterministic mid-frame discontinuity. The old monitor's panel issue made it look like a single horizontal tear; the new monitor reveals the actual flicker character.

## Next bisect step: Phase B VDMA passthrough (no scaler)

To localize whether the bug is in (a) the DDR3/VDMA path itself, or (b) the scaler:

- Need: a Phase B variant with **VDMA in path but scaler bypassed**, 1080p60 in → 1080p60 out (matched rate, no scaling, no rate conversion).
- If Phase B passthrough is **clean** → bug is in scaler interactions with S2MM (most likely candidate).
- If Phase B passthrough also **has EOLLate / flicker** → bug is in the DDR3 / VDMA / AXI write path itself.

Candidate substrates:
- `scaler_passthrough.v` (HDL exists per `tcl/build_phase_b.tcl`) — was Phase B's no-scaling variant
- Earlier Phase B commit `3d67170` ("Phase B + C: VDMA frame buffer + polyphase scaler") — might need to roll back to a pre-scaler Phase B commit if such exists

---

## How to recreate any build

For Schindler builds (Phase B and later), the canonical flow is:

```bash
cd /home/justin/Dropbox/_PROJECTS/Schindler-2.0
git checkout <branch>            # e.g. iter5-1080p-clean
git status                       # must be clean (or document edits)

# Bitstream + XSA
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
vivado -mode batch -nojournal -log build/build_<name>.log -source tcl/build_phase_b.tcl

# Firmware ELF
source /tools/Xilinx/2025.2/Vitis/settings64.sh
xsct tcl/build_phase_b_app.tcl

# Program
xsct tcl/program_phase_b_full.tcl
```

**Timing for full rebuild:** ~25-30 min Vivado synth+impl, ~2-3 min Vitis app build. WNS reference: `iter5-1080p-clean` builds at WNS ≈ -3.57 (known async-CDC false-path issue from color stack; functional via ASYNC_REG per memory `schindler-color-pipeline`).

## 2026-05-22 — iter6: bottom-bars artifact RESOLVED via S2MM fsync

**Status:** **CLEAN.** Monitor + DDR3 dump verified on `iter5-1080p-clean` head with iter6 changes. Single bench session, single reboot — not yet re-verified under multi-cold-boot rule but visually unambiguous and the DDR3 dump is byte-conclusive.

### Diagnostic chain that landed iter6 (single session, ~5 hours)

1. **iter3 — firmware DDR3 dump probe.** Fixed `dump_slot_bytes` (was using iter4h stride + 1920-wide cols). Confirmed slot 0 rows 694-719 contain identical fingerprint to slot 1 rows 0-8 (SMPTE main-bars top) on static SMPTE source. **LEAK CONFIRMED, 26 rows.**
2. **iter4 — two-shot dump for A1/A2 disambiguation.** Dump 1 at iter 1 + dump 2 at iter 4 (~3 s apart), motion source on Osee input 2. Dumps showed byte-different content in slot rows 694-719 → leak is LIVE, not stale-from-boot. **A1 REFUTED, A2 confirmed.**
3. **iter5 — scaler_v `m_axis_tlast` output counter.** Added new 16-bit snapshot output to `scaler_v.v`, forwarded via `scaler_top.v`'s new `out_tlast_snap` port, rewired `diag_concat/In1` from the dead `axis_to_vid_io_0/mm2s_tlast_snap` to the new source. First read returned `v_out_tlast=0` — uncovered a **48→64-bit CDC truncation bug** in `axi_sync_inputs.v` that had been silently dropping `diag_counts_async[63:48]` since iter4g. Widened CDC to 64-bit, rebuilt, second read returned **`v_out_tlast=720` per frame**. Scaler emits 720 valid TLAST handshakes per source frame; **A2-scaler REFUTED, A2-S2MM CONFIRMED.**
4. **iter6 — S2MM external fsync.** Set `c_use_s2mm_fsync=1`, `c_flush_on_fsync=1`, instantiated `vsync_cdc_pulse` to emit a 1-cycle pclk_in pulse on rising edge of `dvi2rgb_0/vid_pVSync`, wired pulse to `axi_vdma_0/s2mm_fsync`. Monitor: **clean.** DDR3 dump: slot 0 rows 690-719 all show PLUGE fingerprint (`col90=000000 col270=FFFFFF col460=FFFFFF col640=000000 col820=000000 col1010=000000`), no leak. Slot 1 row 0 = `0x000000` (the known scaler_v lbuf_fresh cosmetic), rows 1+ = SMPTE main-bars top. **LEAK ELIMINATED.**

### Files changed in iter6

| File | Change |
|---|---|
| `tcl/build_phase_b.tcl` | `c_flush_on_fsync 0→1`; `c_use_s2mm_fsync 0→1`; added `vsync_cdc_pulse.v` to add_files; added `s2mm_fsync_pulse_gen` module-ref cell + 4 wire connections after rst_axi block. Rewired `diag_concat/In1` from `axis_to_vid_io_0/mm2s_tlast_snap` → `scaler_0/out_tlast_snap`. |
| `hdl/scaler_v.v` | Added `out_tlast_count_snap` output + counter logic (increments on `m_axis_tvalid && m_axis_tready && m_axis_tlast`; snapshot+reset at input TUSER). |
| `hdl/scaler_top.v` | Added `out_tlast_snap` output port; wired from `scaler_v/out_tlast_count_snap`. |
| `hdl/axi_sync_inputs.v` | **Fixed pre-existing latent bug.** Widened `diag_counts_q1`, `diag_counts_q2`, and `diag_counts_sync` from 48 to 64 bits. Upper 16 bits had been silently truncated. |
| `hdl/vsync_cdc_pulse.v` | No code change — was orphan HDL until now. Reused as-is. |
| `sw/phase-b/src/main.c` | Renamed `mm2s_tlast` → `v_out_tlast` in `diag_counters_read` + DIAG print. Fixed `dump_slot_bytes` slot stride (iter4h `+27 over-allocate` → iter5 `FRAME_BYTES+STRIDE`) and sample columns (1920-wide → 1280-wide). Two-shot dump trigger logic. |

### Verification at bench (2026-05-22 ~15:20)

- **Source**: Osee GoStream Duet PGM = input 1 = ImagePro 1080p60 static SMPTE bars.
- **Path**: dvi2rgb → scaler_top (1080p→720p downscale) → S2MM (slot K) → MM2S (slot K-1, FrameDelay=1) → axis_to_vid_io → rgb2dvi → HDMI TX → bench monitor.
- **Monitor**: clean. No thin colored strip at the bottom of the SMPTE bars frame.
- **UART telemetry**:
  - `h_in=1080 v_in=1080 v_emit=720 v_out_tlast=720` — scaler healthy.
  - `S2MM_SR=0x00011810[SOFLate FrmCnt frmcnt=1]` — `SOFLate` flag (bit 11) sets each frame, benign side effect of `c_flush_on_fsync=1` + source-vsync-edge-anchored fsync arriving slightly before AXIS TUSER. No `EOLLate` (bit 15). No actual data error.
  - `RDSTORE=2 WRSTORE=0` — VDMA cycling slots correctly.
- **DDR3 dump**: slot 0 rows 690-720 = uniform PLUGE fingerprint, guard row 720 = `000000`, slot 1 row 0 = `000000` (scaler cosmetic), slot 1 rows 1+ = main-bars-top.

### Outstanding (not blockers)

- Multi-cold-boot validation under [[schindler_no_coin_flip_rule]] to formally retire the "COIN-FLIP" status in the branches table above.
- Motion-source re-test (Osee input 2) to confirm leak stays gone under non-static content.
- SOFLate flag suppression (cosmetic).
- Memory updates: [[schindler_bottom_bars_artifact]] → RESOLVED; [[schindler_phase_d_iter4h_state]] → workaround obsolete.

### Full write-up

See [`docs/iter6-s2mm-fsync-fix.md`](iter6-s2mm-fsync-fix.md) for: detailed root-cause analysis, diagnostic procedure, fix details with code snippets, and replication procedure for other branches that have the same bug.

---

## 2026-05-22 evening — iter6 H-shift discovered on ALL branches (re-opened)

After closing out iter6 across three branches, Justin re-checked iter5-1080p-clean carefully on the monitor and **the 2-3 pixel per-line H-shift is present here too**. Originally seen on phase-e1-pll-spike and attributed there to branch-specific differences (FRC mode, c_num_fstores=3). That theory is now **refuted** — same H-shift on iter5 substrate.

**Net iter6 status:**
- ✅ 27-row vertical bottom-bars artifact: **FIXED** (DDR3 dump confirms uniform PLUGE in slot tails, no leak).
- ❌ 2-3 pixel per-line horizontal shift: **NEW REGRESSION (or pre-existing + unmasked).** Each output row starts ~3 pixels late; last 3 pixels of row N appear at start of row N+1.

**Tomorrow's investigation needs to disambiguate:** was the H-shift pre-existing (hidden behind the more dramatic V-wrap and the MS2109's framebuffer) or newly introduced by the iter6 fsync wiring? Hypotheses ranked in `docs/iter6-s2mm-fsync-fix.md`'s new "Known residual: H-shift" section.

**Matrix Row 2 demoted** back to ⚠️ until H-shift fix lands.

---

## 2026-05-24 — iter7→iter13: scaler kernel rework, H-shift RESOLVED

iter6 left a residual artifact ("each line starts 2-3 pixels late, last pixels of row N appear at start of row N+1"). DDR3 boundary-col dumps localized the bug to **scaler_h.v's MAC window**, not S2MM or MM2S as originally hypothesized: the polyphase 8-tap horizontal scaler was using NN-bypass single-tap output WITHOUT clearing the shift register at row boundaries, so the first 2-3 pixels of each output row read leftover tail data from the previous row. Vertical missing-lines was the same class of bug in scaler_v.v (NN-bypass `mac_r = tap1` dropped 1 of every 3 source rows for 1080→720).

**Tested branch:** `iter5-1080p-clean`. Output config = **720p60** (1280×720 @ 1650×750, ~74.25 MHz pixclk).

### Patch progression

| iter | Change | Bench result |
|---|---|---|
| iter7 | scaler_h.v: clear `window[0..7]` on TLAST | 2-pixel left margin — window now correctly zero at row start, but old-tap-pick reads pre-row pixel |
| iter8 | tap window[3] → window[0] (= newest pre-shift) | Left margin gone but image shifted left ~3 cols, right edge falls off screen |
| iter9 | tap = window[1] (intermediate) | 1-col left + 2-col right hard black margin — better balance but still NN band-aid |
| iter10 | 8-tap boxcar MAC (all 1/8 coefficients) | Vertical lines too soft (~7-col fade), right edge content past col ~1910 still invisible |
| iter11 | 2-tap boxcar `(window[0] + window[1])/2` | Tight 2-col blur, lines visible, **right edge still missing** (last MAC reads cols 1917,1918) |
| **iter12** | **2-tap with newest = `s_axis_tdata`** | **✅ Full src col range 0..1919 sampled. Left + right vertical lines at output cols 0 + 1279 as half-bright.** |
| **iter13** | **scaler_v.v: NN tap1 → 2-tap `(tap2 + tap3)/2`** | **✅ All horizontal grid lines now visible (no dropouts). Previously hidden every-other-line restored. Visible as 2 output rows half-bright (= V-equivalent of H scaler's 2-col half-bright vertical lines).** |

### Verdict

`iter5-1080p-clean` @ iter12+iter13 = **canonical post-iter6 scaler substrate.** Patches are:
- `hdl/scaler_h.v` ~lines 164-179 (2-tap with newest = `s_axis_tdata`).
- `hdl/scaler_v.v` ~lines 170-184 (2-tap with newest = tap3 post-rotation).

### Generalization (for replicating to other output resolutions)

| Output res | Ratio | Min taps | Pattern |
|---|---|---|---|
| 1920→1920 (passthrough) | 1.0 | 1 | NN `s_axis_tdata` only |
| 1920→1440 | 4:3 | 2 | iter12 as-is |
| **1920→1280 (current)** | **3:2** | **2** | **iter12 = sweet spot** |
| 1920→960 | 2:1 | 2 | iter12 |
| 1920→720 | 8:3 | 3 | extend MAC to `(s_axis_tdata + window[0] + window[1]) / 3` |
| 1920→640 | 3:1 | 3 | same as 720 |
| 1920→480 | 4:1 | 4 | 4-tap newest |

Rule: tap count ≥ `ceil(IN_W / OUT_W)`, with newest tap = `s_axis_tdata`. V scaler same pattern with line-buffer taps (newest = tap3 after `tap0_slot` rotation).

### Deferred (planned iter14)

Runtime kernel-mode toggle via AXI GPIO + UART `kh`/`kv` commands, independent H/V:
- mode 0: NN (newest tap only)
- mode 1: 2-tap boxcar (current iter12/13)
- mode 2: 4-tap boxcar (more blur)
- mode 3: reserved (future polyphase or separate blur module)

Cost: ~5 LUTs, ~30 min Vivado rebuild, ~30s UART parser extension. Add when needed for live A/B.

### Known cosmetic

- **First output row of frame:** tap3 lbuf may not be fresh yet (lbuf_fresh gating). Output row 0 reads as half-bright instead of full where source row 0 is bright. Pre-existing warmup; not from iter13.
- **Horizontal lines now half-bright across 2 output rows** instead of full-bright across 1 row. Symmetric to vertical lines on H. Inherent to 2-tap boxcar; user-accepted trade.

### Outstanding

- Replicate iter12+iter13 to `mackin-impl-wip` and `phase-e1-pll-spike`.
- Re-test SMPTE bars / motion (Osee inputs 1 and 2) on iter12+13 substrate; current grid-pattern tests were on input 3.
- iter14 kernel-mode toggle when desired.

---

## Going-forward convention

Every bench session must end with an update to this manifest:
- Date + branch + commit
- What was tested (input format, output format, modes engaged)
- What was observed (image clean? coin-flip? scroll? EOLLate? frame drops?)
- How many reboots verified the result
- If broken: what's the symptom, what's the next investigation step

Memory entries are point-in-time; this manifest is the canonical "current state" SSOT.
