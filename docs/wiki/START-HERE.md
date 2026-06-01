# START HERE

**You are looking at the Schindler 2.0 project — a modern open replacement for the Cal Media Schindler MVPHD-24** (a niche 24fps frame-rate converter for film-shoot CRT monitors). Currently developed on a Digilent Zybo Z7-20 dev board; production target is a TE0720 SOM on custom carrier.

## Read these first (in order, ~30 minutes total)

1. **[OVERVIEW](OVERVIEW.md)** — Product framing, signal flow at 50-ft level, market context, SKU split.
2. **[BRANCHES](BRANCHES.md)** — Which branch is production today and what each one represents. Don't checkout anything until you read this.
3. **[ARCHITECTURE](ARCHITECTURE.md)** — Pipeline topology, clock domains, AXIS interfaces.
4. **[PHASES](PHASES.md)** — Phase A→G map. What's shipped, what's in flight, what's blocked.

## Then by role

- **HDL/RTL work** → [ARCHITECTURE](ARCHITECTURE.md), [XILINX-IP-NOTES](XILINX-IP-NOTES.md), [FRC-ARCHITECTURE](FRC-ARCHITECTURE.md)
- **Firmware work** → [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md), [COLOR-PIPELINE](COLOR-PIPELINE.md), [DEBUGGING-PLAYBOOK](DEBUGGING-PLAYBOOK.md)
- **Bench / verification work** → [BENCH-WORKFLOW](BENCH-WORKFLOW.md), [KNOWN-BUGS](KNOWN-BUGS.md), [DEBUGGING-PLAYBOOK](DEBUGGING-PLAYBOOK.md)
- **Building from source** → [BUILD-AND-PROGRAM](BUILD-AND-PROGRAM.md)
- **Phase-specific** → [PHASE-E-FRC](PHASE-E-FRC.md), [PHASE-G-ANALOG](PHASE-G-ANALOG.md)
- **Lost? confused by jargon?** → [GLOSSARY](GLOSSARY.md)

## Load-bearing files outside this wiki

The wiki is the **conceptual + onboarding layer**. The following files in `../` are the canonical ledgers; the wiki cross-links to them but does not replace them:

- `../build-manifest.md` — **live build state**. Source of truth for "which build is buildable + bench-clean today." Updated every bench session. Read this when you need ground truth on commits/branches.
- `../format-support-matrix.md` — **QA truth**. Source of truth for "what input/output combinations are supported and at what verification level."
- `../iter6-s2mm-fsync-fix.md` and `../iter6-h-shift-analysis.md` — forensic records of past iter work.
- `../01-spec.md`, `../dev-roadmap.md`, `../packaging-skus.md`, `../bom-v1.md` — product SSOT.
- `../control-plane-architecture.md` — how operator surfaces (web UI, front panel) talk to the FPGA. Three-tier protocol stack + control catalog schema + V0 buildout plan.

## Critical rules

These are NOT negotiable and exist because we've been burned:

1. **[No-coin-flip rule](DEBUGGING-PLAYBOOK.md#no-coin-flip-rule)**: ≥3 cold reboots showing the same output before any ✅ claim.
2. **[MS2109 verification trap](DEBUGGING-PLAYBOOK.md#ms2109-trap)**: NEVER use the HDMI capture stick for motion-artifact verification. Monitor only.
3. **[Build provenance rule](DEBUGGING-PLAYBOOK.md#build-provenance)**: every claim of "works" references a specific commit + reboot count + symptom.
4. **[Suspect equipment first](DEBUGGING-PLAYBOOK.md#equipment-first)** when something seems architecturally impossible.
5. **[HDMI compliance rule](HDMI-COMPLIANCE.md)**: no out-of-spec MMCM operation, no non-standard TMDS, no patched vendor IP for margin tricks.

## Current state at a glance (2026-05-31)

- Production substrate: `iter5-1080p-clean` (verified clean baseline at `ec13ab2`; current tip `d5876c4` adds V0a control plane + iter14 + iter13c + audit follow-ups)
- HDMI in 1080p60 → HDMI out 720p60: ✅ bench-clean, 3-boot rule satisfied
- All known H-shift / V missing-lines bugs: ✅ resolved via iter12+iter13
- 1080p60 HDMI **output**: ❌ on Zybo Z7-20 (silicon-blocked, see [HDMI-COMPLIANCE](HDMI-COMPLIANCE.md)); ✅ planned on TE0720 production carrier
- V0a control plane: ✅ shipped 2026-05-31 (catalog v0.2.0 + firmware `J` UART + Python `schindlerd` + browser UI). See [CONTROL-PLANE](CONTROL-PLANE.md).
- Phase G analog out: ⛔ paused on dead ADV7393 chip; replacement on order
- Phase E2 Si5351 actuator: blocked on hardware fix (1 kΩ pull-ups + 0.1 µF cap on JESSINIE breakout)

## How agents work with this wiki

Embedded `<!-- AGENT_TASK[role-N]: ... -->` markers throughout the wiki list pending work for future agents. Search the wiki for `AGENT_TASK` to find prioritized tasks. Add new markers when work is identified; remove them when done (commit message should reference the marker ID).

<!-- AGENT_TASK[docs-1]: When iter6 H-shift residuals finally formally close on all branches, mark iter6-h-shift-analysis.md as fully closed and consider moving to MIGRATION-NOTES.md. Currently has RESOLVED banner but file location implies "active." -->
