# V1 Critical Path — What's left to ship

Written 2026-05-31 after the V0a control plane shipped and the audit panel concluded.

This is the **executable** plan to ship v1. Out-of-scope is captured in [`v0a-scope-fence.md`](v0a-scope-fence.md). Live state lives in [`build-manifest.md`](build-manifest.md) and [`format-support-matrix.md`](format-support-matrix.md); this doc is the synthesis.

## Decision: V1 = Method D only

Frame Rate Conversion in v1 ships **Method D (Dynamic Genlock)** only.

| Method | Status | V1? |
|---|---|---|
| A — pure passthrough | shipped on iter5 substrate | ✅ for matching-rate cells |
| B — drop/repeat (clean integer ratios) | not implemented | ❌ v2 |
| C — frame lock (output drifts with source) | not implemented | ❌ v2 |
| D — Dynamic Genlock + 5-frame ring | bench-clean 60→24 5:2 + 60→60 1:1 (`86dc034` on iter5-1080p-clean) | ✅ **v1 standard** |
| E — Mackin virtual-shutter blend | sim-clean 3360-vector + bench placeholder on `mackin-impl-wip`; dual-VDMA wiring deferred | ❌ v2 |

**Why D and only D**: it's the only method with bench-clean coverage of both 1:1 and the worst-case 5:2 cadence. B and C aren't implemented. E is sim-validated but requires substantial bench work (dual-VDMA wiring + classic-Genlock topology) before it could be operator-ready. v1 ships what's actually verified.

[PHASE-E-FRC](wiki/PHASE-E-FRC.md) covers the longer-form architecture; [FRC-ARCHITECTURE](wiki/FRC-ARCHITECTURE.md) covers the methods catalog.

## Critical path

```
┌─────────────────────────────┐
│ TODAY (2026-05-31)          │
│ iter5-1080p-clean ✅ CLEAN  │
│ V0a control plane shipped   │
│ V1 scope cut accepted       │
│ 8h bench debt bounded       │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ MATRIX PHASE 2 (bench)      │  ~7-10 bench hours
│ Walk 20 ⚠️ cells through    │  Batchable across 4-6 sessions
│ the v1 ship list. Each      │
│ either confirms ✅ or is    │
│ explicitly defected.        │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ PHASE G CHIP ARRIVAL        │  External blocker
│ ADV7393 replacement on      │  No control over ETA
│ order. NTSC composite       │
│ color-bars first-light      │
│ (matrix row V1).            │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ TE0720 VERIFY PASS (option) │  ~3-4 bench hours
│ Single session on the       │
│ production carrier. Closes  │
│ 1080p60-OUT column.         │
│ Skippable if v1 ships at    │
│ 720p60-OUT only.            │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ V1 SHIP                     │
└─────────────────────────────┘
```

## Per-stage detail

### Matrix Phase 2 — ~7-10 bench hours, batchable

20 ⚠️ cells in [`format-support-matrix.md`](format-support-matrix.md) need verification on `iter5-1080p-clean`. Pair-wise plan:

- 3 cells per session × 4 sessions × ~30 min/cell + setup overhead = ~7-10 hours.
- Each session ends with manifest entry + ✅/❌/⚠️ promotion.
- "No coin flip" rule applies per cell — 3 cold boots minimum.

### Phase G NTSC bring-up

ADV7393 chip is dead; replacement on order. When it arrives:
1. Solder + bench-verify chip power-up.
2. I²C config sweep against current Phase G firmware (`bb06224` on `phase-g-iter1` branch).
3. Composite color-bars first-light against TVOne pattern generator.
4. Matrix rows V1–V4 (NTSC variants) flip from ⚠️ → ✅ as each verifies.

[PHASE-G-ANALOG](wiki/PHASE-G-ANALOG.md) has the resume plan.

### TE0720 verification pass — optional

If v1 ships at "720p60 OUT only" (no 1080p60-OUT cell), this pass is unnecessary; matrix row 1 stays ❌-on-Zybo / ✅-planned-on-TE0720 as a documented v1+ feature.

If 1080p60-OUT is in scope:
1. Swap to TE0720 test carrier.
2. Run iter5 substrate against the same matrix Phase 2 sessions.
3. Confirm 1080p60-OUT cells in spec on -2 silicon.
4. Single bench session, ~3-4 hours.

[HDMI-COMPLIANCE](wiki/HDMI-COMPLIANCE.md) covers why Zybo can't and TE0720 can.

## Calendar math (forward projection)

Counting only the controllable work (no Phase G ETA):

- 8h bench (matrix Phase 2): batchable across ~2 weeks of evening + weekend availability
- 4h bench (TE0720, optional): single session

**Earliest ship window ignoring Phase G**: 2-3 weeks bench-availability-limited.

Phase G chip arrival is the only material external dependency. If it lands within that window, Phase G NTSC can run in parallel with the matrix sweep. If it lands later, ship slides until first-light is verified.

## What's explicitly NOT on the critical path

- V0a+2 firmware-side periodic re-emit of more telemetry fields. (Already shipped today for source_format / output_format.)
- V0b PetaLinux transition. (See [`v0a-scope-fence.md`](v0a-scope-fence.md).)
- V0c RP2040 + EVE TFT. (Same.)
- Branch resync (task #65). Siblings are sandboxes; iter5 ships.
- Mackin / Phase E1 v2 development.
- HDL refactor for Mackin dual-VDMA wiring.
- Web UI polish beyond V0a+1 (mobile, multi-pane, etc.).
- `make sim` extension to xsim TBs (`make sim-vivado` scaffolded but optional).

## Open questions for the maintainer

1. **Is 1080p60-OUT on the v1 ship list, or v1+?** If yes, TE0720 verify pass is in. If "v1 at 720p60-OUT, 1080p60-OUT in v1.1", skip.
2. **Phase G chip ETA** — once known, set the soft target date.
3. **Single-customer pilot vs broader v1 release?** Affects bench coverage depth: a pilot can ship at "matrix Phase 2 verified" without exotic edge-case coverage; a broader release needs more bench iterations.

## Cross-links

- [`v0a-scope-fence.md`](v0a-scope-fence.md) — what's deliberately NOT in v1
- [`format-support-matrix.md`](format-support-matrix.md) — the ⚠️/✅/❌ source of truth
- [`matrix-scope-cut-v1.md`](matrix-scope-cut-v1.md) — the scope-cut decision
- [`build-manifest.md`](build-manifest.md) — live build state
- [`wiki/PHASES.md`](wiki/PHASES.md) — phase status
- [`wiki/PHASE-G-ANALOG.md`](wiki/PHASE-G-ANALOG.md)
- [`wiki/HDMI-COMPLIANCE.md`](wiki/HDMI-COMPLIANCE.md)
- [`wiki/FRC-ARCHITECTURE.md`](wiki/FRC-ARCHITECTURE.md)
