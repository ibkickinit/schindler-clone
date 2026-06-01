# Migration Notes

Memory entries and documentation claims that have been **overturned, retracted, or rendered obsolete** by later work. This is the meta-page for "what used to be true."

## Why this page exists

Memory entries are point-in-time observations. Some get overturned by later evidence (sometimes within hours). The original entries are preserved for forensic value — agents reading old session contexts need to know what was claimed then. This page indexes what's been overturned and points to the truth-now.

## Overturned memory entries

### `schindler_bottom_bars_artifact` original "RESOLVED 2026-05-22 via iter4h"

**Overturned 2026-05-21:** The original RESOLVED claim was MS2109-tainted. iter4h's VSIZE=747 over-allocate did NOT fix the bottom-bars on monitor — artifact still present AND iter4h adds 1.5-row/frame scroll. Memory was re-classified as ⚠️ OVERTURNED.

**Now:** Resolved 2026-05-22 via **iter6** S2MM hardware fsync (not iter4h). Plus iter12+13 closed the residual H-shift that surfaced after iter6.

### `schindler_phase_d_iter4h_state` original "iter4h SHIPPED 2026-05-17"

**Overturned 2026-05-21:** monitor re-test on a different bench showed iter4h is strictly worse than iter1 — bottom-bars still present AND scroll introduced. iter4h is forensic-only.

**Now:** the production substrate is iter5-1080p-clean lineage, which removed all iter4h additions.

### `schindler_scaler_architecture_findings` original "lbuf race under back-pressure" theory (2026-05-16)

**Overturned 2026-05-16 (same day, bench iter4h disproof):** the lbuf race theory was the leading hypothesis for bottom-bars at the time. iter4h tested it and disproved it.

**Now:** documented as memory `schindler_scaler_architecture_findings` with the original theory + the disproof + canonical patterns for future reference.

### `schindler_iter5_plan` original 2026-05-17 plan

**Partially overturned:** iter5 step 1 ran into 1.5-fps scroll bug. The plan's S2MM VSIZE=1107 component was abandoned. The bisect to iter4d-3 became the new iter5 substrate.

**Now:** iter5-1080p-clean per `schindler_scaler_kernel_iter12_iter13`. The original `schindler_iter5_plan` memory now has a 2026-05-30 status update appended.

### `schindler_phase_e1_state` ship-point claim

**Partially stale:** memory says "Phase E1 SHIPPED 2026-05-19 (commit 42fe057)" — true at the time. But the branch tip has moved since with experiments. Recent commit (`fcd722c`) added the ±500 ppm scope-constraint that wasn't in the original ship claim.

**Now:** branch tip is `81df37b`; treat memory as describing the initial ship, not the current state. See [BRANCHES](BRANCHES.md) for current tips.

## Stale documentation references (informal session notes that never landed on disk)

The following file references appear in memory entries and in some `docs/*.md` files but **do not exist in the repo:**

- `tests/phase-e1/phase_e2_psincdec_limit.md`
- `tests/phase-e1/phase_e2_bench_session_2.md`
- `tests/phase-e1/phase_e1p6_baseline_root_cause.md`
- `tests/phase-e1/phase7_states.md`
- `tests/phase-e1/phase8_cadence.md`
- `tests/phase-e1/phase0_baseline.md`
- `tests/phase-e1/si5351_phase_d_session_2026-05-20_evening.md`
- `docs/sync-architecture.md`
- `docs/mackin-blender-design.md`
- `docs/si5351-bench-bringup.md`

These were informal session notes / planning docs that lived in agent working memory during prior sessions. **Treat each reference as "see surrounding context, not a file to open."** Memory entries that reference these still contain the substantive content inline.

A meta-note has been added to `MEMORY.md` (the index) documenting this pattern.

<!-- AGENT_TASK[docs-13]: If any session-notes content gets recreated on disk in the future, update this list. Better yet, recreate them as proper docs and remove the references from this page. -->

## Documentation files moved or restructured

### `docs/iter6-h-shift-analysis.md`

Started as "diagnostic plan for tomorrow" 2026-05-22. Now carries a RESOLVED 2026-05-24 banner. Narrative below the banner preserved as archaeology since the diagnostic methodology (boundary-col DDR3 dumps, hypothesis ranking) is reusable.

### `docs/build-manifest.md` "Branches snapshot — 2026-05-21" table

Was the at-a-glance branch reference for 9 days, became stale (commits moved). Now superseded by a "Branches snapshot — 2026-05-30" table inserted above it. The 2026-05-21 table is preserved as historical record but marked DO NOT USE FOR CURRENT WORK.

### `docs/iter6-s2mm-fsync-fix.md` "Open items" §

Items 1, 2, 4 marked as partially/fully addressed during the iter12+iter13 cycle. Items 3 (SOFLate cleanup) and 5 (memory updates) remain genuinely open.

## Documentation files NOT moved

These are load-bearing and stay at their current paths:
- `../build-manifest.md`
- `../format-support-matrix.md`
- `../iter6-s2mm-fsync-fix.md`
- `../iter6-h-shift-analysis.md`
- `../iter4g-diagnostic-findings.md`
- `../iter14-plan.md`
- `../scaler-v-warmup-fix-plan.md`
- `../dev-roadmap.md`
- `../01-spec.md` + `../01-spec-changelog.md`
- `../packaging-skus.md` + `../bom-v1.md`

The wiki under `docs/wiki/` is the conceptual / onboarding layer; these files are the canonical ledgers.

## 2026-05-31 — Soft consolidation (5 branches → archive tags)

Five WIP branches that had run their course were tagged `archive/<name>` and remain on origin per soft-consolidation policy:

- `iter4f-wip-pattern-diag`
- `iter4g-counter-infra`
- `iter4h-axis-fifo`
- `iter5-bisect-720p`
- `iter5-wip`

Each tag resolves to the terminal commit on its respective branch. Branches stay visible in `git branch -a` (intentional — searchability and history) but are marked dead in `build-manifest.md` and don't receive new commits. Recovery: `git checkout archive/<name>`.

GitHub default branch flipped to `iter5-1080p-clean` (`ef307b6`). `main` is frozen at its 2026-05-16 state pending v1 ship; the documented force-update happens then.

See [BRANCHES.md](BRANCHES.md) for the live branch table and [`../build-manifest.md`](../build-manifest.md) §"Branch model — soft consolidation" for the policy detail.

## 2026-05-31 — V0a control plane introduced (new tier)

The bare-metal firmware UART command parser stayed in place; V0a added a JSON-RPC bracket (`J <json>`) so the new control plane can talk to the firmware over the same UART without disturbing legacy users. The text commands (`s 100`, `m 50`, `b 0 0 0`, etc.) are unchanged.

What's new:
- `control-plane/catalog-v0.2.0.json` — single catalog file, semver-discipline filename.
- `control-plane/schindlerd/` — Python daemon bridging UART ↔ WebSocket + HTTP.
- `control-plane/web/` — browser UI served by the daemon.
- `control-plane/profiles/factory/` — four shipped baselines.
- `sw/phase-b/src/catalog_version.h` — generated at build time from the catalog filename (Risk N2 mitigation).
- `tests/` — pytest harness with FakeSerial drop-in (54 tests, no bench).
- `Makefile` — top-level `make test` / `make sim` / `make ci` / `make build` / `make program`.

The wiki added 7 new pages under `docs/wiki/`: [CONTROL-PLANE](CONTROL-PLANE.md), [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md), [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md), [STATUS-PANEL](STATUS-PANEL.md), [FACTORY-PROFILES](FACTORY-PROFILES.md), [BRANCH-RESYNC-PLAYBOOK](BRANCH-RESYNC-PLAYBOOK.md), [HDMI-COMPLIANCE](HDMI-COMPLIANCE.md), plus [SCALER-KERNELS](SCALER-KERNELS.md) closing the long-pending `AGENT_TASK[docs-15]`. The [ARCHITECTURE](ARCHITECTURE.md) page gained a V0a sidecar block and [GLOSSARY](GLOSSARY.md) gained ~20 V0a terms.

V0b PetaLinux and V0c RP2040 + EVE front panel are explicitly post-v1 per [`../v0a-scope-fence.md`](../v0a-scope-fence.md).

## Pattern for future overturning

When a memory entry or doc claim is overturned:

1. Update the original entry to add an "OVERTURNED" marker + brief reason
2. Don't delete the original — it's forensic
3. Add an entry to this MIGRATION-NOTES.md with: what was overturned, by what evidence, what's true now
4. Update relevant cross-links

This way agents reading old context know what got revised; current context stays canonical.
