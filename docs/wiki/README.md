# Schindler 2.0 Wiki

The conceptual + onboarding layer for the project. **Start with [START-HERE](START-HERE.md).**

## Page index

| Page | Purpose |
|---|---|
| **[START-HERE](START-HERE.md)** | 1-pager: what is Schindler, where are we now, what to read next by role |
| [OVERVIEW](OVERVIEW.md) | Product framing, market context, signal flow at 50-ft level |
| [BRANCHES](BRANCHES.md) | Which branch is production today and what each one represents |
| [PHASES](PHASES.md) | Phase A→G map. Status, sub-iter ledger |
| [ARCHITECTURE](ARCHITECTURE.md) | Pipeline topology, clock domains, AXIS interfaces, R-B-G byte order |
| [BUILD-AND-PROGRAM](BUILD-AND-PROGRAM.md) | Vivado + Vitis + program. Toolchain pinning. Common pitfalls |
| [BENCH-WORKFLOW](BENCH-WORKFLOW.md) | Osee switcher, monitor-only rule, no-coin-flip rule, verification protocol |
| [KNOWN-BUGS](KNOWN-BUGS.md) | Open bugs + recently-resolved with iter references |
| [DEBUGGING-PLAYBOOK](DEBUGGING-PLAYBOOK.md) | When-X-happens-do-Y. Core rules + symptoms → root causes |
| [FRC-ARCHITECTURE](FRC-ARCHITECTURE.md) | Methods A/B/C/D/E. RT4K three-mode. Mackin blend |
| [COLOR-PIPELINE](COLOR-PIPELINE.md) | sat → correct → matrix stages. UART tuning. R-B-G byte order |
| [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md) | UART command reference (incl. `J` JSON-RPC). AXI GPIO map. DIAG print meanings |
| [PHASE-G-ANALOG](PHASE-G-ANALOG.md) | ADV7393 status, pin map, why blocked, resume plan |
| [PHASE-E-FRC](PHASE-E-FRC.md) | Phase E1/E2/E3/E4 state. Si5351, MMCM tracking, Triple buffer |
| [SCALER-KERNELS](SCALER-KERNELS.md) | iter14 runtime kernel-mode toggle (NN / 2-tap / 4-tap, H+V independent) |
| **[CONTROL-PLANE](CONTROL-PLANE.md)** | **V0a stack: catalog + firmware J + schindlerd + browser UI. Entry point for the V0a tier.** |
| [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md) | Install / run / troubleshoot the daemon. Operator-facing |
| [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md) | How to extend the catalog. Semver rules. Gating attributes |
| [STATUS-PANEL](STATUS-PANEL.md) | Status push protocol — firmware DIAG → telemetry parser → WS notifications |
| [FACTORY-PROFILES](FACTORY-PROFILES.md) | Four shipped baselines (identity, grayscale, warm, cool). Profile schema |
| [BRANCH-RESYNC-PLAYBOOK](BRANCH-RESYNC-PLAYBOOK.md) | How to resync mackin / phase-e1 with iter5 (task #65) |
| [HDMI-COMPLIANCE](HDMI-COMPLIANCE.md) | The rule: no out-of-spec MMCM / TMDS / vendor IP patches |
| [XILINX-IP-NOTES](XILINX-IP-NOTES.md) | Per-IP gotchas: VTC RU bit, v_vid_in sync wires, VDMA DMASR, CDC traps |
| [GLOSSARY](GLOSSARY.md) | 100+ domain terms across pipeline, phases, FRC, hardware, bugs |
| [MIGRATION-NOTES](MIGRATION-NOTES.md) | Overturned claims, stale references, restructuring notes |
| [HISTORICAL-NARRATIVE](HISTORICAL-NARRATIVE.md) | Chronological story May 2026: how we got here |

## What this wiki is (and isn't)

**Is:** the navigable conceptual map. Onboarding surface for new agents. Cross-referenced index pulling from `docs/` and memory entries.

**Isn't:** the canonical source of truth for current state. The load-bearing files at `../`:

- `../build-manifest.md` — **live build state**. Source of truth for "which build is buildable + bench-clean today."
- `../format-support-matrix.md` — **QA truth**. Source of truth for "what input/output combinations are supported."
- `../iter6-*.md`, `../iter4g-*.md`, `../scaler-*.md`, etc. — forensic records of past iter work.
- `../01-spec.md`, `../dev-roadmap.md`, `../packaging-skus.md`, `../bom-v1.md` — product SSOT.

The wiki cross-links to these; it doesn't replace them. When in doubt about current state, check the load-bearing file first; the wiki gives context.

## Finding pending work

Search the wiki for `AGENT_TASK` markers. Currently ~25 prompts categorized by role:

```bash
grep -rn 'AGENT_TASK' docs/wiki/
```

Pattern: `<!-- AGENT_TASK[role-N]: description -->`. Roles:
- `hdl-N` — RTL design tasks
- `fw-N` — Firmware tasks
- `bench-N` — Bench verification owed
- `docs-N` — Documentation tasks
- `test-N` — Test plans + execution

When you complete a task, remove the marker; reference the marker ID in your commit message.

## Wiki maintenance

This wiki was created 2026-05-30 from the audit-panel Wiki Editor proposal. It reflects state at that moment. To keep it useful:

- After any iter ships: update the relevant phase page + KNOWN-BUGS
- After branch tips move: update BRANCHES (cross-check against `../build-manifest.md`)
- New memory entries: cross-link from the appropriate page
- New domain terms: add to GLOSSARY
- Overturned claims: add to MIGRATION-NOTES
- Major events: add a section to HISTORICAL-NARRATIVE

The wiki is intentionally **lossy compression** of the corpus — not every memory entry deserves a wiki page. The point is navigation, not redundancy.

<!-- AGENT_TASK[docs-15]: DONE 2026-05-31 — SCALER-KERNELS.md authored. -->
