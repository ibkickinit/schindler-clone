# Branches

**Source of truth:** `../build-manifest.md` "Branches snapshot — 2026-05-30" table. This wiki page summarizes; the manifest is canonical.

## Quick guide

**Working today? Use `iter5-1080p-clean`.** It's the production substrate **and the GitHub default branch as of 2026-05-31** (soft consolidation — `main` stays frozen at cold-storage until v1 ship).

**Want to add features?** Branch from `iter5-1080p-clean`. Period. Even for FRC or analog work — `phase-e1-pll-spike` and `phase-g-iter1` exist for current in-flight work but new features should land on iter5-1080p-clean first and propagate to feature branches only if needed. See `../build-manifest.md` "Branch model — soft consolidation" section.

**Avoid `main`** — it's frozen cold storage from 2026-05-16, pre-iter5. Will be force-updated to iter5-1080p-clean at v1 ship.

## Live branches as of 2026-05-31

### `iter5-1080p-clean` — **PRODUCTION SUBSTRATE** + effective trunk

Tip: `2bfaa7f` (V0a + V0a+1 stack). Clean substrate baseline at `ec13ab2`; promoted ✅ on `eefa6b0`; V0a control plane shipped today on top.
Status: **✅ CLEAN** at `ec13ab2` (3-boot rule satisfied 2026-05-31 morning); V0a control plane bench-verified end-to-end 2026-05-31 afternoon (catalog + firmware J + daemon + browser UI + status push + multi-client + factory presets).
Contains: iter4d-3 lineage + 1080p substrate + color stack + iter6 S2MM hardware fsync + iter12 (H 2-tap boxcar with `s_axis_tdata` newest tap) + iter13 (V 2-tap `tap2+tap3` post-rotation) + iter13b (+1 round-to-nearest, removes −0.5 LSB DC bias) + iter13c (lbuf_fresh emit suppression + XDC false-paths) + iter14 (runtime kernel-mode toggle via axi_gpio_7) + V0a control plane.

### `phase-e1-pll-spike` — ARCHIVED + CLOSED 2026-06-01

**Branch deleted (local + remote); preserved as tag `archive/phase-e1-pll-spike` @ `d7d2acf`.**
Closed because all v1-relevant work was already on iter5 trunk; phase-e1's unique
content is the **Phase-E2 MMCM `psincdec` closed-loop tracking** (vsync_timestamp,
src_vsync_divider, clk_wiz MMCM, refsel/srcdiv GPIOs, PI-loop UART cmds) — that's
**v2**, scope-fenced out of v1. A full merge would've been throwaway (the resync is
better done fresh from then-current iter5 when E2 actually revives).
**Revive E2:** `git checkout -b <new> archive/phase-e1-pll-spike` then merge-from-iter5.
Scope (for reference): ±500 ppm pull range; NOT designed for large FRC ratios (5:2, etc.).

### `mackin-impl-wip` — Temporal blender (placeholder wiring)

Tip: `73e8d04` (iter13c backported today).
Status: HDL + sim suite passes 3360/3360 bit-exact. Bench wiring is placeholder `axis_clone` — alpha command roundtrips but **no actual temporal blending happens** yet.
Contains: iter5 substrate + iter6 + iter12+iter13 + iter13c + Mackin alpha at axi_gpio_7. **iter14 + V0a not backported** (BD slot collision: iter14 also wants axi_gpio_7 — task #65 resolves with a renumber).
Real bench validation requires dual-VDMA + classic-Genlock topology (deferred).

### `phase-g-iter1` — Analog out (hardware-blocked)

Tip: `d94f6cb`.
Status: ADV7393 BD + Si5351 Phase A→D firmware. Both ADV7393 and Si5351 are hardware-blocked.
Notes: 4 clk_wiz cells (MMCM budget at ceiling per `../zynq7020_mmcm_budget` memory). See [PHASE-G-ANALOG](PHASE-G-ANALOG.md) + [PHASE-E-FRC](PHASE-E-FRC.md).

### `iter5-bisect-720p`, `iter4*`, `iter5-wip` — Forensic / ARCHIVED 2026-05-31

**Archived via tags** on 2026-05-31 (Phase 4 of Direction A scope cleanup). Tags pushed to origin:
- `archive/iter4f-wip-pattern-diag`
- `archive/iter4g-counter-infra`
- `archive/iter4h-axis-fifo`
- `archive/iter5-wip`
- `archive/iter5-bisect-720p`

Branches stay on origin (not deleted) — tags preserve refs even if branches eventually get cleaned up. Recover full history at any time via `git checkout archive/<name>`.

Going forward: 4 active branches (`main` cold storage + `iter5-1080p-clean` production + `mackin-impl-wip` + `phase-e1-pll-spike` + `phase-g-iter1` hardware-blocked). See manifest for current tips.

## Branch divergence picture

```
main (045f09b, 2026-05-16, cold storage)
 │
 └── (heavy iteration on iter4* branches; iter4d-3 is the ancestor of iter5)
      │
      └── iter5-bisect-720p (81e17a8)
           │
           └── iter5-1080p-clean ──► (production lineage: iter6, iter12, iter13, iter13b...)
                │
                ├── mackin-impl-wip (Mackin blender added)
                │
                └── phase-e1-pll-spike (MMCM tracking added)

phase-g-iter1 (parallel: ADV7393 + Si5351 work; based on iter4h era)
```

## Merge plan

**No merge plan currently documented.** Each branch carries its own iter6 + iter12+13 backport. Open strategic question (from the 2026-05-30 PM audit): when do these collapse into one production branch?

Implicit assumption: they merge when Phase E2 closes Si5351 + Mackin together, since both extend the same substrate.

<!-- AGENT_TASK[docs-2]: Write a merge strategy doc when Justin decides on it. Three options: declare iter5-1080p-clean the new `main` and force-update / cherry-pick features back into a unified branch / keep parallel indefinitely. Risk Auditor flagged branch sprawl as risk #2. -->

<!-- AGENT_TASK[hdl-1]: Backport iter13b (+1 round-to-nearest in scaler boxcars) from iter5-1080p-clean to mackin-impl-wip and phase-e1-pll-spike. Pure HDL cherry-pick + Vivado rebuild. ~30 min wall-clock per branch. -->

## Branches we've retired (data-loss risk eliminated)

- `phase-g-iter1` had 9 unpushed commits as of 2026-05-30 morning. Pushed during audit work. Safe now.

See `../build-manifest.md` for the full historical 2026-05-21 snapshot table.
