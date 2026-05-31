# Known Bugs

Open and recently-resolved bugs tracked by status. Source: `../build-manifest.md` "Outstanding" sections + memory entries.

## Open (cosmetic; not blocking)

### 1080p60 HDMI output on Zybo Z7-20

**Substrate:** any 1080p60-output build on the Zybo dev board.
**Symptom:** monitor reports "signal out of spec" — bench-confirmed 2026-05-31.
**Impact:** 1080p60 output on Zybo dev board unusable.
**Root cause:** rgb2dvi soft IP serializes pclk × 5 to drive TMDS at 1080p60. SerialClk = 5 × 148.5 = 742.5 MHz exceeds -1 BUFIO 600 MHz max → non-HDMI-compliant TMDS. Vivado doesn't critical-warn; monitor enforces spec.
**Resolution path:** production hardware (TE0720 -2 silicon AND external HDMI PHY chip TBD). On Zybo, only TFP410 PMOD external chip would unblock — not pursued. See `[[zynq7020_rgb2dvi_1080p60_limit]]` and `[[hdmi_compliance_rule]]`.

Matrix Row 1 reclassified as "❌ on Zybo / ✅ planned on production."

### Bench monitor refuses 1080p30

**Substrate:** Dell bench monitor (specific to this hardware).
**Symptom:** monitor reports "signal out of range" on otherwise-valid CEA-861 1080p30 timing.
**Impact:** 1080p passthrough validation can't use this monitor.
**Root cause:** Dell desktop monitors typically enforce ≥50 Hz refresh on HDMI inputs. 1080p30 is valid CEA-861 mode 34 but rejected at the sink. Not a pipeline bug.
**Workarounds:** use TV/AVR for 1080p30 work, or accept that 1080p validation lives on production hardware.

### ~~SOFLate flag every frame on S2MM_SR~~ — RESOLVED 2026-05-31

**Substrate:** iter5-1080p-clean (and to-be-backported).
**Resolution:** firmware DIAG print suppression — commit `0937574`. S2MM SOFLate is cosmetic post-iter6 (hardware fsync arrives slightly ahead of AXIS TUSER). Suppressed from DIAG print; raw `s2mm_sr` hex still visible for diagnostics. MM2S SOFLate NOT suppressed (no fsync re-timing on that side).

### ~~Async-CDC WNS = -3.5 ns~~ — FIX QUEUED 2026-05-31

**Substrate:** all branches with color stack.
**Resolution queued:** XDC false-path constraints added for color_matrix's `m**_q1`/`off_*_q1` and scaler_top's `in_w_q1`/`in_h_q1` synchronizer flops — commit `5881322`. The existing constraints covered color_correct and color_saturation but were never extended when color_matrix + scaler_top runtime-IN_W/H landed. Will be picked up by the next Vivado run after the in-progress 720p60 restore build.

### ~~Top-of-frame black band (iter13 cosmetic)~~ — FIX QUEUED 2026-05-31

**Substrate:** iter5-1080p-clean (and to-be-backported).
**Resolution queued:** iter13c suppression in `scaler_v.v` — commit `5881322`. When both lbufs that'll become tap2/tap3 post-rotation are unfresh, `stage0_valid_q` is held low so no output is emitted instead of `(0+0)/2 = 0` black band. Will be picked up by the next Vivado run.

### ~~`.claude/settings.local.json` not gitignored~~ — RESOLVED 2026-05-31

**Resolution:** `.gitignore` updated — commit `ec13ab2`.

### `docs/adv7393-breakout-header-pinout.md` untracked — RESOLVED 2026-05-31

File now committed at `docs/adv7393-breakout-header-pinout.md` (commit `ec13ab2`). AGENT_TASK[docs-7] cleared.

### Open Phase E1 questions

**Substrate:** phase-e1-pll-spike.
**Symptom:** MMCM `psincdec` tracking holds for ±500 ppm; behavior outside that range untested.
**Risk:** the `+102 ppm baseline` per `schindler_phase_e1_state` memory is described as "load-bearing." MMCM hardware floor + system design lean on it. If breaks, FRC strategy needs Si5351 (currently blocked).

See [PHASE-E-FRC](PHASE-E-FRC.md).

## Recently resolved (with iter references)

### ✅ Bottom-bars artifact (27-row leak)

**Resolved 2026-05-22 via iter6 S2MM hardware fsync.** Full writeup in `../iter6-s2mm-fsync-fix.md`. Memory: `schindler_bottom_bars_artifact`.

### ✅ H-shift + V missing-lines (residual after iter6)

**Resolved 2026-05-24 via iter12+iter13 scaler kernel rework.** Diagnostic narrative preserved in `../iter6-h-shift-analysis.md` (with RESOLVED banner). Memory: `schindler_scaler_kernel_iter12_iter13`.

### ✅ DC-bias darkening (boxcar truncation)

**Resolved 2026-05-30 via iter13b round-to-nearest fix.** −0.5 LSB per channel per pixel; cumulative H+V cascade = −1 LSB per channel. Fix: `+ 9'd1` before `>>1` in scaler_h.v and scaler_v.v boxcar lines.

### ✅ iter5b 48→64-bit CDC truncation

**Resolved 2026-05-22 via axi_sync_inputs.v reg widening.** Documented in memory `axi_sync_inputs_cdc_width`.

### ✅ Vivado phantom — none

All cited commit hashes in `../build-manifest.md` exist. Per 2026-05-30 Git audit.

### ✅ Firmware VTC mode hardcoded to 720p

**Resolved 2026-05-31 via `#ifdef OUTPUT_1080P` switch — commit `083239a`.** Discovered during 1080p30 bench test: firmware always called `vtc_setup(&MODE_720P60)` regardless of the `OUTPUT_1080P` compile define. VDMA HSIZE was correctly parametrized; VTC active-video gating to 1280 cols caused visible horizontal doubling on 1080p builds. Fix wires `MODE_1080P30` selection to the existing `OUTPUT_1080P` define.

## Verification debt (the "MS2109 catch-up tax")

Format matrix has ~20 rows still at ⚠️ that need monitor re-verification on the post-iter6/12/13 substrate. The 2026-05-30 Risk Auditor estimated this at 40+ bench hours.

**Recommendation in audit:** scope-cut matrix to ≤5 ✅ rows + 1 analog row (NTSC composite only) for v1 ship; defer rest.

<!-- AGENT_TASK[bench-4]: Score the 20+ matrix ⚠️ rows by priority. Pick top 5 for v1 verification sprint. -->

## Bug-class triggers we know to look for

When something seems off, look for these classes first (from `DEBUGGING-PLAYBOOK`):

1. **Coin-flip** (different per boot) → suspect vsync-phase alignment
2. **Deterministic offset** (same per boot) → suspect firmware alignment math or fsync timing
3. **MS2109 says clean, monitor doesn't** → MS2109 trap
4. **Scope sees the I²C event but firmware doesn't** → bench diagnostic Heisenbug
5. **Picture freezes mid-row but TLAST counts say OK** → AXIS tready combinational loop (silicon-deadlock)
