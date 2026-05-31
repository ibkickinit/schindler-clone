# Branches

**Source of truth:** `../build-manifest.md` "Branches snapshot — 2026-05-30" table. This wiki page summarizes; the manifest is canonical.

## Quick guide

**Working today? Use `iter5-1080p-clean`.** It's the production substrate.

**Want to add features?** Branch from `iter5-1080p-clean` for HDMI-only work. Branch from `phase-e1-pll-spike` for FRC/clock work. Branch from `phase-g-iter1` for analog-out work (when hardware unblocks).

**Avoid `main`** — it's cold storage from 2026-05-16, pre-iter5.

## Live branches as of 2026-05-30

### `iter5-1080p-clean` — **PRODUCTION SUBSTRATE**

Tip: `4c0400e` (after this session's later cleanup; verified clean substrate is at `ec13ab2`).
Status: **✅ CLEAN** at `ec13ab2` — verified 2026-05-31, 3 cold reloads showing identical clean picture on ImagePro static SMPTE via Osee input 1. Formally satisfies the no-coin-flip rule. Subsequent commits add additional fixes queued for next Vivado verify (SOFLate DIAG suppression, iter13c top-of-frame suppression, async-CDC XDC fix, VTC mode #ifdef, tcl OUTPUT_MODE / COLOR_PIPELINE / kClkRange parametrization).
Contains: iter4d-3 lineage + 1080p substrate + color stack + iter6 S2MM hardware fsync + iter12 (H 2-tap boxcar with `s_axis_tdata` newest tap) + iter13 (V 2-tap `tap2+tap3` post-rotation) + iter13b (+1 round-to-nearest, removes −0.5 LSB DC bias) + iter13c (lbuf_fresh-gated emit suppression, queued).

### `phase-e1-pll-spike` — MMCM tracking ("Gen Lock" mode)

Tip: `81df37b`.
Status: Bench-clean 60→60 matched-rate + diagonal motion. ⚠️ LUCKY-BOOT formally.
Contains: iter5 substrate + iter6 + iter12+iter13 + MMCM `psincdec` closed-loop tracking. **iter13b backport owed.**
Scope: ±500 ppm pull range. NOT designed for large FRC ratios (5:2, etc.).

### `mackin-impl-wip` — Temporal blender (placeholder wiring)

Tip: `fedb51a`.
Status: HDL + sim suite passes 3360/3360 bit-exact. Bench wiring is placeholder `axis_clone` — alpha command roundtrips but **no actual temporal blending happens** yet.
Contains: iter5 substrate + iter6 + iter12+iter13. **iter13b backport owed.**
Real bench validation requires dual-VDMA + classic-Genlock topology (deferred).

### `phase-g-iter1` — Analog out (hardware-blocked)

Tip: `d94f6cb`.
Status: ADV7393 BD + Si5351 Phase A→D firmware. Both ADV7393 and Si5351 are hardware-blocked.
Notes: 4 clk_wiz cells (MMCM budget at ceiling per `../zynq7020_mmcm_budget` memory). See [PHASE-G-ANALOG](PHASE-G-ANALOG.md) + [PHASE-E-FRC](PHASE-E-FRC.md).

### `iter5-bisect-720p`, `iter4*`, `iter5-wip` — Forensic / archaeology

Keep for git archaeology; do not ship from. See manifest for symptoms (mostly ❌ SCROLL or abandoned WIP).

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
