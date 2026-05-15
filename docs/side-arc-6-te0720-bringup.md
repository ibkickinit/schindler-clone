# Side-arc 6 — TE0720 + TE0703-07 production-target bring-up

**Status:** Banked 2026-05-14. Hardware on bench.
**Type:** Bench bring-up side-arc (parallel to main HD pipeline Phase A–G).
**Goal:** Validate the production-target silicon stack (TE0720 SOM + TE0703-07 dev carrier) by powering it up, booting PetaLinux on it, and demonstrating that Zybo-validated HDL ports to it 1:1. De-risks the eventual Zybo → TE0720 production migration without disrupting active HD-pipeline work on Zybo.

## Why this is its own side-arc

The active dev platform for Phase A–G is the Digilent Zybo Z7-20 (same Z-7020 silicon family, eval-ready out of the box with HDMI source/sink chips). Spec § 4.1 commits to staying on Zybo until the HD pipeline validates, then porting 1:1 to TE0720.

Now that the TE0720 SOM and TE0703-07 carrier are physically on the bench, the *port-to-production* step can be de-risked incrementally — without making it the active dev platform yet. This is what Side-arc 6 covers.

**Does not change the active dev plan.** Zybo remains the HDMI-pipeline dev platform for Phase A–G. Side-arc 6 runs in parallel on its own schedule.

## What the stack does and doesn't include

**On the bench (this side-arc):**
- **TE0720-04-31C33MA** — commercial -1 speed grade SOM. Same Z-7020 silicon, same memory config, **identical pinout** as the production-target -04-62I33MA industrial -2 grade. HDL portable 1:1; only difference is speed-grade-related timing margin.
- **TE0703-07** — Trenz's general-purpose dev carrier. Brings out FPGA I/O on headers (2× B2B / 2× 40-pin). Includes USB/UART/JTAG, SD slot, some buttons/LEDs, power input.

**Not yet on the stack:**
- HDMI source/sink chips. TE0703-07 doesn't have them. Until external HDMI eval boards are wired to TE0703 headers, or the production carrier is fabricated, **TE0720 stack cannot run the HDMI pipeline.** This is the structural reason Zybo stays the active dev platform.
- All the other production carrier silicon (ADV7393, ADV7280, LT8619C, Si5351, AD9204, LTC6912, RP2040). Those each have their own EVAL boards covered by Side-arcs 1–5.

## Sub-arc breakdown

### Sub-arc 6a — Power and JTAG sanity

**Goal:** SOM is alive, FPGA configures, an LED blinks.

- Power TE0703 from its 12 V (or appropriate) input.
- JTAG via on-carrier USB-JTAG to host laptop.
- Simple "blink LED" Vivado design built using Trenz's board files + reference design template.
- Program over JTAG → on-carrier LED blinks.

**Validates:** SOM power tree, JTAG path, basic Vivado toolchain integration with Trenz files.

**Effort:** ~½ day.

### Sub-arc 6b — Trenz toolchain integration

**Goal:** "Hello World" bitstream built end-to-end using the Trenz-recommended workflow.

- Pull Trenz's reference design for `TE0720 + TE0703` from their reference design wiki/SVN.
- Confirm board files + hardware definition + constraints package is consistent.
- Build a small standalone PL design (e.g., UART loopback or counter-to-LED) using their template.
- Program and validate on hardware.

**Validates:** Trenz toolchain (different from Digilent's; worth learning before production carrier exists). Reveals any board-file or constraint surprises now rather than under production pressure.

**Effort:** ~1–2 days.

### Sub-arc 6c — PetaLinux bring-up on TE0720

**Goal:** PetaLinux boots on the production silicon family.

- Generate PetaLinux project from the Sub-arc 6b hardware definition.
- Build kernel + rootfs.
- Boot from SD card (TE0703-07 has SD slot).
- SSH in over UART (or Ethernet if TE0703 has a PHY — verify).
- Read `/proc/cpuinfo`, `/proc/meminfo`, dmesg.

**Validates:** PetaLinux toolchain works on real production silicon, boot infrastructure is sound, Cortex-A9 dual-core comes up, DDR3 is recognized at full size.

**Effort:** ~2–3 days.

### Sub-arc 6d — Zybo HDL portability check

**Goal:** Pick a small validated Zybo design, port to TE0720, confirm 1:1 portability.

- Candidate: the Phase 2 first-light Verilog (`vid_timing.v` + `vbi_gen.v` + `sample_gen.v`) — already scope-validated on Zybo + R-2R DAC. Wire R-2R DAC perfboard to TE0703 headers instead of Zybo PMODs.
- Regenerate MMCM for TE0720's reference clocks (different oscillator on TE0720 than on Zybo).
- Update constraints file for TE0703 pinout.
- Rebuild bitstream targeting `xc7z020clg484-1` (TE0720's package, vs. Zybo's `xc7z020clg400-1`).
- Program, scope the R-2R output, confirm same waveforms come out.

**Validates:** "HDL ports 1:1" claim from spec § 4.1. Smoke-tests the eventual production migration.

**Effort:** ~½ day per spec § 4.1's estimate.

### Sub-arc 6e — Mini front-panel driver-stack early-validate via 0.91" OLED

**Goal:** PetaLinux userspace renders text on an I²C OLED — validates the Mini SKU front-panel driver stack months before the spec'd 1.3"/128×64 OLED + 5-way nav + buttons hardware lands.

- Hardware: 0.91" 128×32 SSD1306-class I²C OLED (×5 on hand) wired to one of TE0703's exposed I²C buses. 4 wires: GND/3V3/SCL/SDA.
- Device tree: add the OLED node under the I²C controller, confirm `/dev/i2c-N` enumerates after boot.
- Userspace test: simple Python or C against `i2c-dev` — clear screen, render "Schindler 2.0 / TE0720 alive" text.
- Stretch: render dynamic content (uptime, IP, lock state) — proves the full Mini front-panel `schindler-ui` driver path.

**Validates:** Mini SKU front-panel architecture per spec § 5.1 (PetaLinux user-space app drives OLED via `/dev/i2c-N`). The 0.91" is smaller than the spec'd 1.3" but uses the same SSD1306 controller family → driver code ports 1:1 when the 1.3" arrives.

**Why this is in Side-arc 6, not its own side-arc:** the binding hardware dependency is PetaLinux on the TE0720 (Sub-arc 6c). Once that's up, this is a ~½-day extension that retires meaningful Mini SKU dev risk early.

**Effort:** ~½ day.

## Success criteria

| Sub-arc | Pass condition |
|---|---|
| 6a | LED blinks; Vivado programs successfully over JTAG. |
| 6b | Hello-world bitstream built via Trenz toolchain, runs on hardware. |
| 6c | PetaLinux boots, SSH/serial console works, kernel sees full silicon. |
| 6d | Phase 2 HDL produces identical scope-validated waveforms on TE0720 + R-2R DAC as on Zybo + R-2R DAC. |
| 6e | 0.91" OLED displays static + dynamic text rendered from PetaLinux userspace via `/dev/i2c-N`. |

## Effort estimate (total)

| Sub-arc | Effort |
|---|---|
| 6a | ~½ day |
| 6b | ~1–2 days |
| 6c | ~2–3 days |
| 6d | ~½ day |
| 6e | ~½ day |
| **Total** | **~1 week of focused work** |

## What this enables

Once Side-arc 6 lands:
- **Production migration is de-risked.** The eventual Zybo → TE0720 port has been rehearsed; toolchain surprises and constraint issues are surfaced and resolved.
- **PetaLinux infrastructure** is bring-up'd on real production silicon — ready for the control plane work that comes after HD pipeline validates.
- **TE0720 becomes a viable bench platform for non-HDMI work** — any side-arc that doesn't need HDMI chips (e.g., Side-arc 2 genlock work) can move to TE0720 if there's a reason to.

## Cross-references

- Dev roadmap: [`dev-roadmap.md`](dev-roadmap.md) § 2.5
- Spec — bench port plan: [`01-spec.md`](01-spec.md) § 1.1, § 4.1
- Sibling side-arcs: [`side-arc-1-adv7393-bench.md`](side-arc-1-adv7393-bench.md), [`side-arc-2-genlock-bench.md`](side-arc-2-genlock-bench.md)
- Hardware status: [`../00-index.md`](../00-index.md) § Hardware status
