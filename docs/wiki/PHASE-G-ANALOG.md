# Phase G — Analog Out (ADV7393)

Analog output via Analog Devices ADV7393 DAC: NTSC/PAL composite + S-Video + component (YPbPr).

**This is the project's whole product purpose.** Without analog out, Schindler is a 720p downscaler. With it, it's an actual MVPHD-24 replacement for film-shoot CRT use.

**Status: ⛔ PAUSED 2026-05-20** on dead chip. Replacement on order. Resume gated on chip arrival.

Source corpus: memories `schindler_phase_g_kickoff`, `schindler_phase_g_iter1p5_state`, `schindler_phase_g_paused`, `schindler_phase_g_clkwiz_zombie`. Docs: `../adv7393-breakout-header-pinout.md` (untracked), `../Hardware/ADV7393*`.

## Hardware

- **EVAL-ADV7393EBZ breakout board** from Analog Devices. Has the DAC, output filters, BNC connectors for component/composite/S-Video.
- **Connection to Zybo:** Pmod JD pins for I²C config + 27 MHz CLKIN (the breakout has no onboard crystal at pin 19; we drive it from FPGA via `clk_wiz_adv7393`).
- **Power:** External PSU on bench. The breakout's 1.8V DVDD rail is suspected marginal on this specific unit (per `schindler_phase_g_iter1p5_state`).

## Why paused

Per `schindler_phase_g_paused`, the chip is **dead at the bench:**
- Single-byte probe NAKs at expected I²C address (verified via AXI IIC IP and scope).
- Scope shows 9th SCL falling edge with no slave ACK — chip is not responding.
- iter1.6 firmware (`1c32d01`) proves AXI IIC IP healthy — the failure is on the chip side.

**Suspected root causes:**
1. DVDD 1.8V rail on the bare breakout (per `schindler_phase_g_iter1p5_state`)
2. Damaged chip from earlier debug sessions
3. RESETB float (need 1 kΩ series resistor mod)

Replacement ordered 2026-05-20. Resume plan inline in `schindler_phase_g_paused` memory.

## Status snapshot per phase

| Sub-phase | Status |
|---|---|
| **iter1.0** | BD scaffolding: AXI IIC IP, Pmod pinout, clock fanout | ✅ Done |
| **iter1.5** | 27 MHz CLKIN via `clk_wiz_adv7393` driven from `FCLK_CLK0` | ✅ Done |
| **iter1.6** | Firmware direct-register-bang I²C path | ✅ Done — proves IIC healthy |
| **iter2.0** | Chip alive: probe ACK, identify revision | ⏳ Blocked on replacement |
| **iter3.0** | NTSC composite color bars first-light | ⏳ Blocked |
| **iter4.0** | PAL / S-Video / component variants | ⏳ Blocked |
| **iter5.0** | Re-interlace logic on output side for 480i/576i/1080i output | ⏳ Major HDL work |

<!-- AGENT_TASK[bench-6]: When replacement ADV7393 arrives: (a) wire 1 kΩ series on RESETB; (b) verify DVDD 1.8V rail under load; (c) re-run iter1.6 probe sweep. -->

<!-- AGENT_TASK[hdl-13]: Re-interlace logic on OUTPUT side. Required for 480i / 1080i / S-Video output (matrix rows C4, S1-S4, V2-V5). Phase G internal sub-task — substantial HDL work. -->

<!-- AGENT_TASK[fw-7]: ADV7393 register sweep: write known-good NTSC composite config; verify output via scope. Per AD datasheet's "quick start" register list. -->

## MMCM budget concern when resuming

The `clk_wiz_adv7393` cell (line 182 of `tcl/build_phase_b.tcl` on `phase-g-iter1`) consumes 1 of 4 MMCMs. With Phase E2's Si5351 work also adding `clk_wiz_si5351`, the budget is at the ceiling (4 clk_wiz cells = 4 MMCMs).

**Resolution options** when chip arrives (documented in `schindler_phase_g_clkwiz_zombie` memory):
- **A:** Keep clk_wiz_adv7393 as load-bearing. Any 5th-clock work must use PLLE2_ADV.
- **B:** Remove + route 27 MHz from PS via `FCLK_CLK1`. PS clock has more jitter; probably acceptable for CVBS rate.
- **C:** Drop ADV7393 in favor of a different DAC strategy. Unlikely given product spec.

## Phase G format matrix subset

Format support matrix (`../format-support-matrix.md`) lists 16 component/S-Video/composite output rows, all 🔲. Each requires re-interlace HDL not in the current pipeline.

**Risk Auditor 2026-05-30 recommendation:** scope-cut Phase G to **NTSC composite only for v1**. PAL + S-Video + component variants defer to v2. Phase G is at least 2-3 months of pure work even when chip arrives. v1 ship needs to be defensible scope.

<!-- AGENT_TASK[docs-9]: When Phase G unblocks, write the actual NTSC composite bring-up test plan. Reference the AD register quick-start table. -->

## Open Phase G design questions

1. **Composite color subcarrier**: how tightly does it have to be phase-locked to source? Some DPs care; some don't. Worth research before committing to a clock strategy.
2. **NTSC 7.5 IRE setup pedestal**: keep or omit by default? US broadcast convention disappeared decades ago; period CRT users may want either.
3. **Component (YPbPr) vs RGsB**: which is more common in target market?

These are user-research questions, not technical ones.

## Why this is the highest-leverage open question

From 2026-05-30 PM agent: **Phase G is what makes Schindler a Schindler**. Without analog out, the project ships a 720p HDMI downscaler — useful for nothing the market needs. With analog out, even at NTSC-composite-only, it covers the most common MVPHD-24 use case.

**Stated plan:** Si5351 first (Phase E2), ADV7393 second (Phase G).
**PM-suggested alternative:** ADV7393 first when chip arrives, even at the cost of pausing Si5351 mid-debug.

This is a strategic call. Document it when made.

<!-- AGENT_TASK[docs-10]: Document the Phase G vs Phase E2 priority decision when Justin makes it. Affects what gets touched first when ADV7393 chip replacement arrives. -->
