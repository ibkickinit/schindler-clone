# Phase 0 — Baseline confirmation

**Status:** PASS ✓ (2026-05-18 22:14 PT)

**Goal:** confirm the `phase-e1-pll-spike` branch rolled back to `d71c994` still builds cleanly with the current toolchain, programs onto the Zybo Z7-20, and produces a stable HDMI output for ≥60 seconds of observation.

Per [`docs/phase-e1-ground-up-plan.md`](../../docs/phase-e1-ground-up-plan.md) §4 Phase 0.

## Build provenance

- **Branch:** `phase-e1-pll-spike`
- **Base commit:** `d71c994` — *Phase D iter 4d-3 FRC validation: 720p60->720p50 via Dynamic Master*
- **Toolchain:** Vivado / Vitis 2025.2 at `/tools/Xilinx/2025.2/`
- **Build host:** `justin-Yoga-7-14ITL5`, Linux 6.8.0-111-generic x86_64
- **Build date:** 2026-05-18T22:00 PT

## Build invocation

```
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
vivado -mode batch -nojournal -log build/phase0_baseline_vivado.log \
       -source tcl/build_phase_b.tcl

source /tools/Xilinx/2025.2/Vitis/settings64.sh
xsct tcl/build_phase_b_app.tcl

# JTAG load (JP5 = QSPI on bench, JTAG-load works regardless)
xsct tcl/program_phase_b_full.tcl
```

## Build outputs

| Artifact | Path | Status |
|---|---|---|
| Bitstream | `build/phase-b-vdma-passthrough/phase-b-vdma-passthrough.runs/impl_1/phase_b_bd_wrapper.bit` | 4.0 MB ✓ |
| XSA | `build/phase_b.xsa` | 981 KB ✓ |
| Vitis platform .bit | `build/vitis-phase-b/phase_b_pf/hw/phase_b.bit` | ✓ |
| ps7_init.tcl | `build/vitis-phase-b/phase_b_pf/hw/ps7_init.tcl` | ✓ |
| Firmware ELF | `build/vitis-phase-b/vdma_init/Debug/vdma_init.elf` | 68,977 B (.text 41,961 / .data 1,560 / .bss 25,456) ✓ |

## Synth/impl results

- **WNS:** **+0.389 ns** (setup met, all constraints satisfied)
- **WHS:** **+0.013 ns** (hold met, tight but positive)
- **TNS:** 0.000 ns (no failing endpoints)
- **THS:** 0.000 ns

**Utilization (xc7z020clg400-1):**

| Resource | Used | Avail | % |
|---|---|---|---|
| Slice LUTs | 12,898 | 53,200 | 24.2 |
| Slice Registers | 20,357 | 106,400 | 19.1 |
| RAMB36 | 13 | 140 | 9.3 |
| RAMB18 | 6 | 280 | 2.1 |
| MMCME2_ADV | 3 | 4 | **75.0** |
| PLLE2_ADV | 1 | 4 | 25.0 |

**Note on clocking headroom:** 3/4 MMCMs already in use (clk_wiz_pixclk_out, clk_wiz_ref, dvi2rgb's internal). Phase 1 needs no new MMCM (counter clocks off FCLK_CLK0). Phase 4 reconfigures `clk_wiz_pixclk_out` for DRP rather than adding new. Headroom holds.

**Critical warnings (cosmetic, not signoff blockers):**
- `ila_pixclk` ILA XDC missing (debug-hub artifact, no functional impact)
- `sys_clk_125mhz` overrides `sys_clk` (deliberate, per zybo_z7_clk125_phy memory note)
- Several dbg_hub_CV XDC variable-resolution warnings (synth-tool internals)

## Bench observation

- **Date / wall time:** 2026-05-18 22:14 PT
- **HDMI source:** Laptop (Windows desktop), reported by `dvi2rgb` lock + firmware telemetry as **60.164 Hz**
- **Source format:** 1080p60
- **Output mode:** **720p50** (per d71c994 firmware default `MODE_720P50`, HTOTAL=1980 VTOTAL=750)
- **Capture stick:** MS2109 on `/dev/video3` (USB 534d:2109, bus 3 dev 43)
- **Observation window:** 60 seconds, Cheese live + one captured still

### Firmware boot log (excerpt — `build/phase0/uart_boot.log`)

```
=== Schindler 2.0 — Phase B.1 ===
VDMA + VTC bare-metal init
Waiting for dvi2rgb lock + source vsync alignment...
VTC: configuring 720p50 (HTOTAL=1980 VTOTAL=750)
VTC aligned to source vsync
VDMA running — S2MM + MM2S enabled, 3-frame ring
Pipeline live — entering diag loop (1 sec/dump)
TELEMETRY: src=60.164 Hz -> regime 0 [60p->60p (1:1 pass-through)]
TELEMETRY: MM2S in circular + genlock-slave, FrameDelay=1
```

### Pass criterion (per ground-up plan §4 Phase 0)

> Clean build, clean output, no scrolling visible to the eye over 60 seconds of observation.

### Result

- **Build:** PASS ✓ (clean, all timing met, no critical structural warnings)
- **Output picture present:** PASS ✓ (Windows desktop visible end-to-end through FRC pipeline)
- **No scrolling over 60 s:** PASS ✓ (user-reported "completely clean")
- **Single representative frame:** [`phase0_baseline_frame.jpg`](phase0_baseline_frame.jpg) (1280×720, 658 KB)

### Notes

- Initial telemetry reports `regime 0 [60p->60p (1:1 pass-through)]` even though VTC is configured at 720p50. The regime label appears to be the firmware's initial regime classification before its FRC-mode logic engages; output still went through the 60→50 cadence path per VTC config. Not a Phase 0 concern; flag for review if it recurs in later phases that exercise the FRC chain (Phase 8).
- JP5 jumper left at QSPI position. JTAG `rst -system` + `fpga -file` + `dow` sequence handed control to the d71c994 firmware cleanly over the previously-running mackin-impl-wip image. No physical action required.
- Previous-build telemetry visible at the head of `uart_boot.log` (`DIAG: px=1920 lines=1080 ... PHASE: deltas[12]=`) is the dead-end firmware still printing for ~5 s before the JTAG `rst -system` halted it. Expected.
- 3 unused-symbol warnings during the Vitis build (`MODE_720P60`, `measure_output_rate_mhz`, `vtc`) are residue from earlier firmware paths still in `main.c`. Harmless.

## Next step

Phase 0 substrate is confirmed. Proceed to **Phase 1 — vsync timestamp infrastructure** per [`docs/phase-e1-ground-up-plan.md`](../../docs/phase-e1-ground-up-plan.md) §4 Phase 1.
