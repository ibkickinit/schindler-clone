# Schindler 2.0 — 00 Index

**Status:** ACTIVE — HD pipeline development on Zybo Z7-20
**Type:** Personal venture
**Code location:** `_PROJECTS/Schindler-2.0/` (this folder, repo at root)
**GitHub:** `ibkickinit/schindler-clone` *(rename to `schindler-2` planned later)*

## What this is

FPGA-based hardware project to drive video to legacy CRTs at film cadences (24/30 fps), with the broader scope of acting as a general broadcast-grade HD signal processor. Spiritual successor to the Cal Media MVPHD-24 device — replicating that workflow with modern FPGA tech, and extending to HD pipeline + sync conversion + per-CRT color profiles + RF modulator (Pro) for period sets.

The mission: keep heritage display gear functional in modern production workflows, where 24fps cinema cadence needs to drive into displays designed for older signal standards.

## Two SKUs, one electronics design

**One internal electronics design — two packaging variants.** Mini and Pro share the same carrier PCB, the same TE0720 SOM, the same FPGA HDL, the same PetaLinux control plane. They differ in chassis form factor, front-panel hardware, rear-panel I/O complement, and carrier stuffing.

- **Mini v1** — first shipping SKU. Half-rack 1RU chassis. Mono OLED + tactile switches front panel. Subset of stuffing (no SDI, no RF modulator, no dual SYNC OUT, no per-connector LEDs, no rear LCD). Indicative retail $1,500–2,500; parts cost ~$572.
- **Pro v2** — full-rack 1RU chassis. NHD-2.9 color TFT + RP2040 + BT817Q EVE mezzanine front panel. Full silicon stuffing. Indicative retail $2,500+; parts cost ~$816. Gated on Mini selling.

See [`docs/packaging-skus.md`](docs/packaging-skus.md) for SKU stuffing matrix + chassis detail.

## Doc structure

- [`docs/01-spec.md`](docs/01-spec.md) — SSOT for internal electronics architecture and feature set. Applies to both SKUs.
- [`docs/packaging-skus.md`](docs/packaging-skus.md) — Mini vs Pro packaging differences (chassis, front panel, rear panel I/O, stuffing variants).
- [`docs/dev-roadmap.md`](docs/dev-roadmap.md) — SSOT for active development arc and deferred work. **Read this first** to know what's being built right now.
- [`docs/01-spec-changelog.md`](docs/01-spec-changelog.md) — dated decision history.
- [`docs/signal-flow.md`](docs/signal-flow.md) — Mermaid block diagrams (video signal path, sync subsystem, control plane).
- [`docs/panel-layout.md`](docs/panel-layout.md) — Pro panel layout. Mini layout in `packaging-skus.md`.
- [`docs/bom-v1.md`](docs/bom-v1.md) — BOM with Mini/Pro stuffing variants.
- [`docs/ui-menu.md`](docs/ui-menu.md) — Pro UI menu hierarchy. Mini UI hierarchy authored when Mini PetaLinux UI work activates.
- [`docs/mvphd-comparison.md`](docs/mvphd-comparison.md) — MVPHD-24 feature comparison + gap analysis.
- [`docs/rf-modulator-subsystem.md`](docs/rf-modulator-subsystem.md) — RF modulator detail (Pro feature).
- [`docs/opamp-stage.md`](docs/opamp-stage.md) — output op-amp design.
- [`docs/r2r-dac.md`](docs/r2r-dac.md) — R-2R DAC perfboard reference (Zybo bench).
- [`docs/schindler-playbook.md`](docs/schindler-playbook.md) — development narrative.
- [`docs/Hardware/`](docs/Hardware/) — archived future-evaluation hardware (Smart Artix, Smart Zynq SL, TE0712, TinyZynq) — **NOT** on the active dev path. Preserved for archival reference.

## Active development arc

Building **HD pipeline top-down** on Zybo Z7-20:

```
Phase A: HDMI passthrough        (next up)
Phase B: VDMA frame buffer
Phase C: Polyphase scaler
Phase D: Frame rate conversion
Phase E: Color pipeline
Phase F: Geometry warp
Phase G: Re-attach analog terminal encoders (Phase 2 HDL plugs back in here)
```

Migration from Zybo to TE0720 production target comes after the HD pipeline validates. See [`docs/dev-roadmap.md`](docs/dev-roadmap.md) for current status, deferred work, and forward-looking work.

## Recently completed

**Phase 2 first-light** on Zybo Z7-20 + R2R DAC perfboard:
- Monochrome NTSC composite at 24.000 fps exact — scope-validated
- `hdl/vid_timing.v` + `hdl/vbi_gen.v` + `hdl/sample_gen.v` validated
- `hdl/chroma_gen.v` written + integrated + builds clean; chroma burst bench verification deferred per HD-pipeline-first priority shift

## Hardware status

**Active bench platforms:**
- ✅ **Digilent Zybo Z7-20** — primary HD-pipeline dev platform (Phase A–G)
- ✅ **Trenz TE0720-04-31C33MA + TE0703-07 carrier** — production-target silicon stack, now on bench for Side-arc 6 (TE0720 bring-up, PetaLinux + portability validation). Same Z-7020 family as Zybo; HDL ports 1:1. Does not yet have HDMI hardware — Zybo remains the HDMI-pipeline dev platform.
- ✅ R-2R DAC perfboard + op-amp output stage (Phase 2 first-light validated)
- ✅ **EVAL-ADV7392/93EBZ** — Side-arc 1 bench target (composite output via ADV7393)
- ✅ **Si5351A breakout with 3× BNC outputs** + **Adafruit Si5351 #2045 ×2** — Side-arc 2a bench targets (clock-gen standalone bring-up)
- 🟡 **MIKROE-2555 ×2** (LTC6912 GainAMP click) — Side-arc 2b PGA bench target. **Arrives 2026-05-15.** Two boards enable parallel setups: chain-with-ADC + PGA-only characterization.
- ⏳ **AD9204-80EBZ** — Side-arc 2b ADC bench target. **Procurement in-flight (4th attempt, 2026-05-14).** ADI flags this chip under tight export/distribution control; ships only to verified corporate addresses. Side-arc 2b cannot start in earnest until this lands.
- ✅ **BNC 75 Ω terminators (CP-88T-75 ×4)** + **Molex BNC PCB jacks** — bench measurement + perfboard prototyping

**Bench tools / MCUs:**
- ✅ **RP2040 dev board** — production-spec'd genlock slow-control MCU, bench prototype
- ✅ **Teensy 4.0** — bench utility, candidate BB / tri-level / LTC waveform synthesis source for Side-arc 2c testing (Cortex-M7 @ 600 MHz; intentionally not on production carrier)
- ✅ **0.91" 128×32 I²C OLED ×5** (SSD1306-class) — Mini SKU front-panel driver-stack bring-up target. Smaller than spec'd 1.3"/128×64 but same controller family → driver code ports 1:1 when the 1.3" arrives. Used as the early-validate target in Side-arc 6e.
- ✅ **1.5" 128×128 SPI OLED** (SH1107 controller, GME128128-01-SPI) — Pro SKU rear status display driver-stack bring-up target. Different exact part than the spec'd NHD-1.5, but same role (rear status window). 128×128 = square, so chassis-rotation 90° is free (controller register flag). Used as the rear-status leg of Side-arc 6e.
- ✅ Phase 2 NTSC composite HDL on bench, scope-validated through monochrome

**Component selection status:**
- ✅ **EC11E18244AU encoders** — bench-validated, locked in as the Pro mezzanine choice (spec § 5.2).
- 🟡 **Knob selection** — narrowed to 3 candidates from the 7 ordered (CP34501 / FC7229NML / CL178883 / FC1611 / CL1730 / 1202CY / SPK-023A). Final pick pending bench evaluation.

**Future-evaluation / parts inventory** (procured but NOT on the active arc):
- LT8619C-EVB, ADV7280 EVAL, LTC6912 EVAL — pending Side-arcs 3/4/5 + 2b finish
- Digilent Arty S7-25 — toolchain learning + Spartan-7 comparison only
- Smart Artix V1.3 / Smart Zynq SL V1.3 / TE0712-02 / TinyZynq — evaluation archive (`docs/Hardware/`)

The TE0720 is the **production-target SOM**; bench dev for HD pipeline continues on Zybo Z7-20 (same Z-7020 silicon family). Production migration after HD pipeline validates.

## Operating principle (code in vault)

`.git/` syncs to Dropbox cloud. NEVER delete `.git/` from cloud — propagates to local and destroys repo. See `_PROJECTS/NovaTool/00-index.md` for full rationale on code-in-vault.

## Migration status

- [x] Migrated from `~/schindler-clone/` to `_PROJECTS/Schindler-2.0/` (2026-05-06)
- [x] Remote URL cleaned (no embedded PAT)
- [x] Two-SKU strategy banked (Mini v1 / Pro v2) (2026-05-12)
- [x] Doc tree consolidated: mini-spec + carrier-board absorbed into 01-spec; packaging-skus + dev-roadmap created (2026-05-13)
- [ ] Rename GitHub repo: `schindler-clone` → `schindler-2`
- [ ] Document FPGA-specific `.dropboxignore` patterns once active build artifacts appear

## Naming history

- Working title: `schindler-clone` (placeholder during initial setup)
- Final name: **Schindler 2.0** (chosen 2026-05-06; emphasizes spiritual successor framing rather than direct clone)
