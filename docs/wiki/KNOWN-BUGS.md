# Known Bugs

Open and recently-resolved bugs tracked by status. Source: `../build-manifest.md` "Outstanding" sections + memory entries.

## Open (cosmetic; not blocking)

### SOFLate flag every frame on S2MM_SR

**Substrate:** iter5-1080p-clean, mackin-impl-wip, phase-e1-pll-spike.
**Symptom:** firmware DIAG print shows `SOFLate` set every frame.
**Impact:** none on picture — image is clean. Pure flag noise.
**Root cause:** TUSER arrives at S2MM after the source vsync edge fires fsync. Hardware fsync is doing the right thing; the TUSER is "late" relative to the new slot.
**Fix paths:** (1) mask the flag in firmware DIAG print (cosmetic); (2) add small delay between fsync edge and S2MM transfer-arm so TUSER lines up. Original iter6 doc considered this "Open item #3."

<!-- AGENT_TASK[fw-1]: Suppress benign SOFLate flag in DIAG print, OR fix the TUSER timing alignment. Cosmetic only — no picture impact. -->

### Async-CDC WNS = -3.5 ns

**Substrate:** all branches with color stack.
**Symptom:** Vivado reports WNS=-3.5 (or sometimes -3.72) ns on async-CDC paths. Soft timing fail.
**Impact:** functional via `ASYNC_REG` attribute on the CDC flops. No observed image impact at 720p60.
**Risk:** could bite at 1080p60 output if/when E4 ships scaler-at-output-side.
**Root cause:** the timing-ignore constraint patterns in the XDC don't match Vivado's hierarchical names for the color pipeline CDC paths.

<!-- AGENT_TASK[hdl-5]: Fix the async-CDC false-path constraint pattern so WNS reports clean. Functional via ASYNC_REG but Vivado complains every build. -->

### Top-of-frame black band (iter13 cosmetic)

**Substrate:** iter5-1080p-clean (and backported to others).
**Symptom:** first ~2 emit rows of each frame are black until `lbuf_fresh` flags warm up.
**Impact:** invisible at normal viewing; visible only with diagnostic test patterns or close inspection.
**Root cause:** iter13's V scaler reads `tap2 + tap3` post-rotation. On first emit of each frame, both can have `lbuf_fresh=0`, gating tap reads to zero. Output = `(0+0)/2 = 0`.
**Fix (optional):** hold `stage0_valid_q ← 0` for those rows so the output is properly invalid rather than black. Identified by 2026-05-30 HDL audit.

<!-- AGENT_TASK[hdl-6]: Implement lbuf_fresh-gated output suppression in scaler_v.v so top-of-frame is clean-blank instead of black-band. Optional cosmetic. -->

### `.claude/settings.local.json` not gitignored

**Substrate:** all branches.
**Symptom:** `git status` always shows `.claude/` as untracked.
**Impact:** visual noise; risk of accidentally committing macOS-host-specific paths.
**Fix:** add `.claude/` to `.gitignore`.

<!-- AGENT_TASK[docs-6]: Add .claude/ to .gitignore. ~30 seconds. -->

### `docs/adv7393-breakout-header-pinout.md` untracked

**Substrate:** all branches.
**Symptom:** Real bench-reference doc but never committed.
**Decision needed:** commit (it complements existing adv7393 docs) or intentionally gitignore.

<!-- AGENT_TASK[docs-7]: Decide adv7393-breakout-header-pinout.md fate. Either commit or gitignore. ~1 minute either way. -->

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
