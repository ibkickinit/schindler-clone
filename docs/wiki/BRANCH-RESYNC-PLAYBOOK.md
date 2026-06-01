# Branch Resync Playbook

How to bring `mackin-impl-wip` and `phase-e1-pll-spike` back in sync with iter5-1080p-clean. Tracks task #65.

The detailed mechanical plan lives in [`../branch-resync-plan.md`](../branch-resync-plan.md) — this wiki page is the navigable summary.

## When to invoke this playbook

- Sibling branch is "weeks behind trunk" and the next planned work on it needs a feature trunk has shipped.
- About to start a bench session on a sibling and want to clear LUCKY-BOOT debt while you're at it.
- iter4* / iter1X work on trunk has produced HDL changes that the sibling's local work depends on (today's iter4e + iter14 → kernel-mode toggle being a clean example).

## Current divergence (2026-05-31)

| Branch | Behind trunk | Ahead | Bench-promoted? |
|---|---|---|---|
| `iter5-1080p-clean` | 0 (trunk) | — | ✅ CLEAN (3-boot rule satisfied) |
| `mackin-impl-wip` | 19 commits | 7 | ⚠️ Sim-validated only; bench wiring is placeholder |
| `phase-e1-pll-spike` | 37 commits | 11 | ⚠️ LUCKY-BOOT (single-boot evidence) |
| `phase-g-iter1` | 57 commits | 11 | ⛔ Hardware-blocked |

## The two structural blockers found 2026-05-31

Today's cherry-pick attempts for iter14 (`abb83e8`) revealed two issues that prevent the obvious `git cherry-pick` approach:

### Blocker 1 — `axi_gpio_7` slot collision on mackin

mackin already owns `axi_ic_lite/M10_AXI` for `mackin_alpha`. iter14 puts a new `axi_gpio_7` at the same slot for `kernel_mode_async`. Direct cherry-pick yields two cells of the same name on the same M-port.

**Resolution**: introduce a `KERNEL_GPIO_INDEX` env-var on `tcl/build_phase_b.tcl`. iter5 defaults to 7; mackin builds with `KERNEL_GPIO_INDEX=8` so kernel_mode lands at axi_gpio_8 / M13 while mackin_alpha stays at 7 / M10. See the plan doc §"Proposal".

### Blocker 2 — Missing iter4e substrate on phase-e1

phase-e1's `scaler_top.v` predates iter4e (no `in_w_async`/`in_h_async` ports). iter14 layers `kernel_mode_async` on top of those ports. A cherry-pick would replace the whole module — silently dragging in iter4e as a side-effect.

**Resolution**: do a real merge-from-iter5 onto phase-e1 (not a cherry-pick), accept the substrate change, and bench-verify against phase-e1's prior LUCKY-BOOT baseline (60→60 matched-rate + motion).

## Phases

| Phase | Wall-clock | Bench | What lands |
|---|---|---|---|
| 1. Parameterize iter5 | ~1 h | XSA diff only | ✅ **SHIPPED 2026-05-31** — `KERNEL_GPIO_INDEX` + `KERNEL_M_SLOT` env vars on trunk; firmware abstraction via `SCALER_KERNEL_GPIO_BASEADDR` |
| 2. Resync mackin | ~2 h + 30 min bench | 720p60 + alpha + k-cmd | V0a + iter14 + audit follow-ups (mackin builds with `KERNEL_GPIO_INDEX=8 KERNEL_M_SLOT=13`) |
| 3. Resync phase-e1 | ~3 h + 1 h bench | 60→60 + motion + k-cmd, 3-boot | iter4e + V0a + iter14 + audit follow-ups; chance to clear LUCKY-BOOT |
| 4. Documentation | ~30 min | none | Update manifest + BRANCHES.md |

Total: ~6.5 h work + 1.5 h bench. Bench sessions for Phases 2 and 3 can be independent.

## Why not just keep cherry-picking?

The cost-control argument was that soft consolidation kept the iter5 → siblings drift bounded. Today's session confirmed it stayed bounded for **iter13c** (a HDL-only change) but broke for **iter14** (BD + firmware + HDL stack with slot-allocation politics). Each new BD-touching feature on trunk that doesn't have a slot-picker abstraction adds another cherry-pick blocker.

Phase 1 of this playbook (`KERNEL_GPIO_INDEX`) is the abstraction that prevents this class of blocker from recurring. Once it ships, future BD slot allocations on trunk default to safe defaults and siblings override the env-var.

## Gates per phase

Each phase has an explicit bench gate (or "no bench, just XSA diff" gate for Phase 1) that the resync must pass before the next phase starts. If a gate fails, the resync stops there and the failure goes in the manifest as an open item.

For phase-e1 specifically, Phase 3's gate is the first chance to clear its long-standing LUCKY-BOOT status by satisfying the 3-boot rule on the resync'd build.

## Out of scope

- Phase G bring-up (chip hardware-blocked).
- Phase E2 Si5351 (firmware fix staged at `bb06224`, bench-blocked).
- iter14 mode 3 (polyphase MAC — not implemented anywhere).
- V0b PetaLinux transition (separate track).

## Cross-links

- [`../branch-resync-plan.md`](../branch-resync-plan.md) — the full plan with code-level proposals
- [BRANCHES](BRANCHES.md) — current branch state
- [CONTROL-PLANE](CONTROL-PLANE.md) — V0a, which siblings need to inherit
- [PHASE-E-FRC](PHASE-E-FRC.md) — phase-e1 substrate context
- [`../build-manifest.md`](../build-manifest.md) — live ledger
