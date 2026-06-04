# Strategic direction review — 2026-06-04

Source: a strategic-review subagent (read the memory index, build-manifest, format matrix,
dual-engine plan, wiki, frc-gate-review-prompt, and skimmed the FRC/scaler/color HDL).
Verdict (main agent): grounded and specific — caught the branch-split issue, confirmed the
read-side nearest-neighbor aliasing by reading the code, and flagged the `NUM_FRAMES==c_num_fstores`
footgun and the blend-coverage-metric bug. Two numbers to verify before planning on them: the exact
"1 of 24 ✅ / ~20 ⚠️" matrix tally, and the blend-coverage-denominator claim (5-min firmware check).

The two highest-leverage follow-ups (main-agent read): **(1) merge `readengine-b-integration` →
trunk**, **(2) add a read-side anti-alias box filter** (zoom aliases without it — relevant the
moment #29 pan/zoom ships).

> **Correction (2026-06-04, post-git-check):** the memo below repeatedly calls the branch merge a
> "deliberate operation" with "two production stories to reconcile." Git says otherwise: merge-base
> `a7e3671`, branch is **67 commits ahead**, trunk is **0 commits ahead** (hasn't moved since fork),
> **zero files changed on both sides**. It's a **fast-forward** (`git merge --ff-only`), not a two-way
> reconcile. The real cost is verification discipline (gate the FF behind #28 3-boot + #29), not the
> merge. Retiring VDMA-MM2S (§18A / risk #1) is a *separate optional* cleanup, not part of the merge.
> See task #106.

---

## Memo (verbatim)

### 1. Achieved vs. the v1 goal
Done + silicon-confirmed (branch `readengine-b-integration`, the live frontier — NOT merged to the
`iter5-1080p-clean` trunk): one route-B read engine (packed-beat fill) → fixed 720p60 HDMI, runtime
geometry; per-line wrap fixed (build #23, 3-boot ✅ CLEAN); FRC cadence validated across
60/59.94/50/30/29.97/24 → 60 (incl. 3:2 pulldown), all delta_px=0, no per-ratio special-casing; the
Gray-code discovery (`s2mm_frame_ptr_out` is Gray-coded; now `gray2bin()`-decoded); Mackin blend
ENGAGES (build #28: 5→7 framestores + mode-dependent lag, BLEND 60/60, errflags=0 — DDR holds);
3-way blend mode; color pipeline (sat→correct→3×3 matrix, R-B-G); web control plane (color +
geometry-to-200% + blend); #29 source-pan in flight.

Gap to shippable v1 (per format-support-matrix v1 scope cut): of 24 HDMI cells, ~1 formally ✅,
~20 ⚠️ awaiting the 3-boot+monitor sweep — **and those ⚠️ were last verified on the *trunk*
VDMA-MM2S path, while the FRC wins are on the *branch*** (must reconcile). 1080p60-out column
hardware-blocked (Zybo -1 silicon). All NTSC cells blocked (dead ADV7393). Runtime output-rate
selection doesn't exist (multi-rate IN → fixed 720p60 OUT).

### 2. Trajectory / critical path to the dual-engine end-state
Locked architecture: two independent read engines off one S2MM-written DDR ring; Out A = HDMI
(Si5351 #1), Out B = analog NTSC (Si5351 #2 → ADV7393). Ordered big rocks:
1. Cadence → engine A — ✅ DONE.
2. Dual-fetch + Mackin → engine A — ✅ ENGAGES (#28); 3-boot + judder soak owed.
3. **Merge readengine-b branch → trunk — doable now, highest-leverage non-hardware move.**
4. Runtime output format — **MMCM-DRP (clk_wiz DRP + VTC reprogram + rgb2dvi relock) doable now**
   for in-spec on-chip modes (720p60, 1080p30). Si5351 is the eventual per-output clock but is
   hardware-blocked → not on the critical path for single-output v1.
5. 2nd read engine (engine B) — HDL/sim doable now on a borrowed on-chip clock (plan §18B); analog
   *physical* output needs the chip, but the dual-cadence logic is testable now.
6. Si5351 ×2 — hardware-blocked (I²C SI: 1 kΩ pull-ups + 0.1 µF decoupling; AXI-IIC firmware fixes).
7. ADV7393 + re-interlace HDL — hardware-blocked (chip dead) + new HDL (field decimation + V lowpass).

### 3. "While we're in here" opportunities (the key ask)
| # | Item | Why now | Effort | Priority |
|---|---|---|---|---|
| 1 | Verify/characterize α-gated conditional dual-fetch DDR headroom (esp. 1080p, the binding constraint for engine B) | bandwidth number gates engine-B single-vs-dual fetch; cheap while blend path is hot | firmware/bench | High |
| 2 | Read-side box filter (G2) + iter14 runtime kernel-mode toggle | read engine is **nearest-neighbor**, no read-side filter — zoom/upscale (#29) WILL alias; HDL-heavy, must re-open pg_compose + re-close timing if done later | HDL-heavy / iter14 sim+build | High (filter needed before any zoom ships) |
| 3 | Gamma / per-channel LUT color stage | color stack already being rebuilt for #28/#29; gamma is the top missing color tool + analog-out wants it | sim+build | Med-High |
| 4 | Color profiles/presets + RGB→YCbCr matrix (Phase-G dep) | catalog in flux; YCbCr matrix is a hard analog dependency authorable on HDMI now | firmware/daemon | Med |
| 5 | Blend-mode UX + telemetry in web UI; **fix blend-coverage metric denominator** (divides by all frames not α-fractional → uninterpretable) | observability cheap while firmware loop is open; metric fix needed before sizing decisions | firmware/daemon | Med-High (metric fix High) |
| 6 | Finish/clamp source-pan (#29) | in-flight; pan-past-edge reads garbage without bounds clamp | firmware + small HDL | High (current task) |
| 7 | Runtime matte color + aspect-preserving letterbox/pillarbox | compositor open for #29; film/NTSC need 16:9→4:3 bars | firmware + sim | Med |
| 8 | MMCM-DRP runtime output rate (720p60↔1080p30) | unblocked path; lets the verification sweep cover output variants in one bench batch | HDL-heavy (BD+DRP) | Med |

### 4. Risks / debt
- **Two production stories** (branch vs trunk) — biggest structural debt; ⚠️ matrix cells verified on the path the end-state retires. Plan §18A retires VDMA MM2S → plain circular writer (also makes Gray-monotonicity true by construction).
- **`NUM_FRAMES==c_num_fstores` manual invariant** across 5 places (#28 coordinated edit) — no single source of truth; silent desync → wrong-slot reads. Single-source it.
- **Gray decode→slot offset** only validated indirectly on motion; cycle period changes at 7 stores — re-confirm.
- **`axis_to_vid_io` shared** by read-engine + VDMA passthrough; wrap fix was non-additive — preserve the `MAX_DRAIN=16` bound on further edits.
- **Recurring CDC false-path-pattern class** (chronic WNS ≈ −3.5 on hierarchical-name mismatch) — establish a verified convention before gamma/LUT or more GPIO.
- **Mode-dependent lag** = 1-frame hitch on a deliberate blend-mode switch (expected, document it). +1-frame latency is inherent to interpolation, not ring depth — UI must communicate "7 stores ≠ 7 frames delay."
- **Backward-pointer hazard** unhandled by design (safe only because pointer is Gray-monotonic on silicon); the §17 multi-frame ILA capture under drift/hot-plug is owed before the dual-reader topology.
- **MS2109 verification trap** — monitor-direct, 3-cold-boot for every "clean/smooth" claim; #28 3-boot still owed.
- **Read-side NN aliasing** — latent trap for any zoom/upscale (#29 and beyond).

### 5. Recommendation
(a) Finish-while-here: finish/clamp #29 pan; 3-boot verify #28; fix blend-coverage metric + surface
telemetry in UI; measure real 1080p DDR headroom; iter14 toggle + scope read-side box filter;
single-source NUM_FRAMES/c_num_fstores; lock CDC false-path convention; add gamma/LUT + RGB→YCbCr.
(b) Needs hardware (don't gate logic): Si5351 ×2, ADV7393 + re-interlace, 1080p60-out — but exercise
dual-cadence logic on a borrowed on-chip clock now.
(c) Defer: Si5351-based runtime clocking (do MMCM-DRP first), 2nd physical output integration,
PAL/component/S-Video/4K/VRR/interlaced-in (out of v1 scope).

**Single highest-leverage move: converge `readengine-b-integration` → `iter5-1080p-clean`.**
