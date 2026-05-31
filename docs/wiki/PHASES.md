# Phases

Schindler 2.0 development is organized into Phases A through G, each producing a shippable substrate. Source: `../dev-roadmap.md` + `../build-manifest.md` iter ledger + recent memory entries.

## Phase status at a glance

| Phase | Title | Status | Production substrate |
|---|---|---|---|
| **A** | HDMI passthrough | ✅ Shipped 2026-05-13 | `phase-a-hdmi-passthrough` |
| **B** | DDR3 VDMA frame buffer | ✅ Shipped 2026-05-14 | `iter5-1080p-clean` (substrate carries forward) |
| **C** | Polyphase scaler (1080→720) | ✅ Shipped + heavily reworked through iter12+iter13 | `iter5-1080p-clean` |
| **D** | Frame rate conversion (Dynamic Genlock) | 🟢 60→60 production-clean; other ratios ⚠️ pending re-test | `iter5-1080p-clean` (Method D) |
| **E** | Production-grade FRC (sub-phased E1-E4) | E1 spike shipped; E2 blocked; E3/E4 not started | `phase-e1-pll-spike` (E1) |
| **F** | Geometry warp (pincushion, keystone) | Not started, low priority | — |
| **G** | Analog out via ADV7393 | ⛔ Paused (chip dead, replacement on order) | `phase-g-iter1` (hardware-blocked) |

## Sub-iteration ledger (Phase D scaler/VDMA story)

Phase D went through many iterations as the team chased a series of nested bugs. Brief timeline:

- **iter1-iter3** — initial polyphase scaler with Mitchell coefficients. Visible ringing from Mitchell's negative sidelobes amplifying source noise.
- **iter3q** — reverted Mitchell to NN single-tap bypass. Calmed the noise but introduced H-shift + V-line-drop bugs that took weeks to surface (they were masked by other bugs).
- **iter4d-3** — production-clean 60→60 substrate. The ancestor of everything since.
- **iter4g** — diagnostic counter infrastructure added.
- **iter4h** — attempted VSIZE=747 over-allocate "fix" for bottom-bars. ❌ Caused 1-row-per-frame scroll. Abandoned.
- **iter5-bisect-720p** — removed iter4h additions, restored iter4d-3.
- **iter5-1080p-clean** — 1080p substrate + color stack on top.
- **iter6** (2026-05-22) — S2MM hardware fsync from source vsync edge. Fixed the 27-row bottom-bars leak.
- **iter7-iter11** — H scaler kernel experimentation. Hard NN, then various tap picks, then 8-tap boxcar.
- **iter12** (2026-05-24) — final H form: 2-tap boxcar with newest tap = `s_axis_tdata`. Production.
- **iter13** (2026-05-24) — V scaler analog. Production.
- **iter13b** (2026-05-30) — +1 round-to-nearest on boxcar paths. Removes −0.5 LSB DC bias.
- **iter14** — DEFERRED. Runtime kernel-mode toggle (NN / 2-tap / 4-tap, independent H/V) via UART. See `../iter14-plan.md`.

Detailed forensics in `../iter6-s2mm-fsync-fix.md`, `../iter6-h-shift-analysis.md` (with RESOLVED banner), `../iter4g-diagnostic-findings.md`, and `../scaler-v-warmup-fix-plan.md`.

## Phase E sub-phases

- **E1 — MMCM `psincdec` tracking** ("Gen Lock"). Closed-loop output clock nudge. Shipped on `phase-e1-pll-spike`. See [PHASE-E-FRC](PHASE-E-FRC.md).
- **E2 — Si5351 actuator + Mackin temporal blender**. Si5351 brings up an external PLL for clock tracking with full pull range; Mackin handles ugly FRC ratios via temporal blending. Both partially built, both blocked. See [PHASE-E-FRC](PHASE-E-FRC.md).
- **E3 — Triple Buffer / Async Ring** ("Compatibility mode"). Free-running output + framestore ring. Not started.
- **E4 — Scaler reposition** to output side. Required for upscaling (currently downscale-only). Not started.

## Phase G

Hardware bring-up of the ADV7393 DAC for analog out. Paused since 2026-05-20 on dead chip. See [PHASE-G-ANALOG](PHASE-G-ANALOG.md) for resume plan when replacement arrives.

## Phase F

Geometry warp for CRT pincushion/keystone correction. Documented as roadmap; no implementation. Low priority.

<!-- AGENT_TASK[docs-3]: Reconcile dev-roadmap.md's Phase D table (last updated 2026-05-16, stops at iter4d-3) with this living ledger. Roadmap is stale. -->

<!-- AGENT_TASK[hdl-2]: Phase E4 — design upscaling path. Move polyphase scaler to output side. Required for 480p→720p, 720p→1080p, all "SD up to HD" rows in format matrix. -->

## Yet to be tackled

- TE0720 port + custom carrier PCB
- Front-panel UI (Mini SKU + Pro v2 mezzanine)
- SDI subsystem, ADV7280 input decoder, RF modulator
- PetaLinux web UI
- Deinterlacing (Phase F+ scope)
- 3:2 telecine / IVTC / cadence detection
