# ADV7393 bench bring-up — paused state

**Status:** PAUSED 2026-05-17. **Not abandoned** — infrastructure is in the build, bench wiring is set up, but the chip is not yet detected. Resumption depends on Justin being back at the bench. This doc captures the state so the next session doesn't re-derive from scratch.

**Anchor commit:** [`66e1a06`](https://github.com/) "Phase G iter1.5: AXI I2C + 27 MHz CLKIN for ADV7393 bring-up"

**Related:** [`color-pipeline.md`](color-pipeline.md) (where `rgb_to_ycbcr` and `ycbcr_444_to_422` live, sim-validated, reserved for this path), [`dev-roadmap.md`](dev-roadmap.md) Phase G, [`01-spec.md`](01-spec.md) §1.4 / §3.x (ADV7393 as the analog DAC for composite / S-Video / component).

---

## 1. What this work is

Standing up the [Analog Devices EVAL-ADV7393](https://www.analog.com/) bare breakout (chip + passives + 3× RCA + 40-pin header) as the first analog-output target. This is *not* the full EVAL-ADV7393EBZ dev board — the bare breakout has no onboard FPGA, no USB, and **no onboard crystal**, which is why the bring-up adds a 27 MHz clock from the Zybo MMCM.

Per [`01-spec.md`](01-spec.md), the ADV7393 is the SD/HD analog encoder driving composite + S-Video + component outputs. It shares a parallel YCbCr 4:2:2 bus with the eventual ADV7511 HDMI-out chip (Pro SKU). The bring-up scope is "chip alive, responds to I²C, configurable from PS" — wiring the actual YCbCr data path comes after.

---

## 2. What infrastructure exists in the build today

All of the following is **already committed** on `mackin-impl-wip` post-`66e1a06`. Nothing here needs to be rebuilt to resume bench work.

### 2.1 Block design ([tcl/build_phase_b.tcl](../tcl/build_phase_b.tcl))

| Element | Purpose | Where |
|---|---|---|
| `axi_iic_adv7393` (Xilinx AXI IIC IP) | I²C master to talk to ADV7393 chip | base `0x41600000`, 100 kHz SCL, [line 1027–1037](../tcl/build_phase_b.tcl) |
| `axi_ic_lite/M11` | Adds the I²C master to the interconnect | NUM_MI grew 6 → 7 |
| `clk_wiz_adv7393` (MMCM) | Generates 27 MHz from FCLK_CLK0 (100 MHz) | [line 198–207](../tcl/build_phase_b.tcl) |
| Top-level port `adv7393_clkin` | Drives the chip's CLKIN (pin 19) | [line 208–209](../tcl/build_phase_b.tcl) |
| Top-level intf port `iic_adv7393` | SDA + SCL bidirectional (IOBUFs autogen by Vivado) | [line 1036–1037](../tcl/build_phase_b.tcl) |

### 2.2 Constraints ([constraints/zybo_z7_20_phase_b.xdc](../constraints/zybo_z7_20_phase_b.xdc))

| Signal | Zybo pin | PMOD pin | Properties |
|---|---|---|---|
| `iic_adv7393_sda_io` | U14 | JD7 | PULLUP TRUE |
| `iic_adv7393_scl_io` | U15 | JD8 | PULLUP TRUE |
| `adv7393_clkin` | T14 | JD1 | SLEW FAST, DRIVE 12 |

(RESET goes to JE6 from 3.3V via a flying lead, pulsed manually at the bench.)

### 2.3 Firmware ([sw/phase-b/src/main.c](../sw/phase-b/src/main.c))

- `adv7393_iic_init()` — initializes the AXI IIC core via Xilinx XIic API
- `adv7393_read_reg(reg, *value)` — polled `XIic_Send` + `XIic_Recv` against the chip's 7-bit I²C address (0x2A when ALSB tied low)
- `adv7393_probe()` — runs at startup *before* the HDMI pLocked wait, so it works without an HDMI source plugged in
- **Currently runs in an infinite probe loop in debug mode** so SDA/SCL traffic is easy to capture on a scope. Revert the `while(1)` once chip detection works.
- Scan trimmed to fast 0x2A-only probe; the broader 0x03–0x77 generic scan was hanging on per-address NAK timeouts with this bitstream.

---

## 3. Bench state at the checkpoint

Everything physical was in place; the chip just wouldn't talk back.

### 3.1 Power
- ADV7393 PSU on, power LED visible.
- Power plan per [`66e1a06`](.) commit message: external dual benchtop supply, 3.3V channel (VAA + VDD_IO) and 1.8V channel (VDD + PVDD). Single-point ground reference tying Zybo, EVAL board, and bench supply.
- VDD_IO set to 3.3V deliberately, to match Zybo PMOD signaling without a level shifter.

### 3.2 Wiring
| Net | From | To | Notes |
|---|---|---|---|
| SDA | JD7 | Chip pin 13 | 2.2 kΩ pull-up (was 5.1 kΩ — tightened for cleaner edges) |
| SCL | JD8 | Chip pin 14 | 2.2 kΩ pull-up |
| ALSB | — | GND | Sets I²C address to 0x2A |
| RESET | JE6 (3.3V) | Chip pin 20 | Pulsed manually to ensure clean release-from-reset edge |
| CLKIN | JD1 | Chip pin 19 | 27 MHz from Zybo MMCM |
| GND | — | — | Common between Zybo + EVAL + bench PSU |

### 3.3 Symptoms
- **Scope probe at JD1** shows ~480 mVpp 27 MHz sine instead of expected ~3 Vpp square wave.
  - Vivado `io_placed.rpt` confirms T14 is OUTPUT / LVCMOS33 / DRIVE 12 / SLEW FAST. XDC took.
  - Possibilities: scope ground-loop artifact at 27 MHz, severe wire attenuation through the PMOD jumper, or genuinely-weak drive (less likely given DRIVE 12).
- **I²C result:** NAK on 0x2A every probe iteration. Chip never ACKs.

---

## 4. The three open bench checks

These are the next actions for the resumption session. Each is concrete and answers a specific question.

### Check 1 — Probe chip pin 19 directly

**Question:** is the 480 mVpp reading a scope ground-loop artifact or genuine signal attenuation?

**Procedure:** Move the scope probe from the JD1 header pin to chip pin 19 directly, keeping the rest of the setup identical. Shorten the probe ground lead to the chip's nearest GND pin (don't use a long ground clip).

**Expected:** If JD1 was a probe artifact, the chip-side waveform should look healthy (~3 Vpp square). If the chip-side reading is also ~480 mVpp, the wire is genuinely attenuating, and that's a wiring problem to solve (shorter jumper, lower-impedance path).

### Check 2 — Shorten the probe ground lead

**Question:** scope grounding hygiene at 27 MHz.

**Procedure:** Replace the scope probe's standard ground clip with a short ground spring (the ones that attach directly to the probe tip's barrel). At 27 MHz, even a few cm of ground lead acts as an inductor and corrupts the reading.

**Expected:** If the long ground lead was the issue, the same JD1 probe point should now show a clean ~3 Vpp signal. (Do this *before* Check 1 if the ground spring is handy — it might resolve the question without moving probes.)

### Check 3 — Verify chip DVDD with a multimeter

**Question:** does the bare breakout have a 1.8 V regulator at all, or is the chip's DVDD pin floating / wrong-voltage?

**Procedure:** Measure DC voltage at the chip's DVDD pin (consult ADV7393 datasheet for the exact pin — typically there are multiple supply pins for AVDD / DVDD / PVDD / VDD_IO).

**Expected:** Should read 1.8 V steady. If it reads 0 V, ~3.3 V, or unstable, the bare breakout is missing its 1.8 V regulator (a common gotcha on bare evaluation breakouts — they sometimes assume the user supplies all rails externally). Fix: feed 1.8 V from the bench supply's second channel directly to the DVDD pin, since the 3.3 V channel was the only external supply set up at the checkpoint.

**This is the most likely root cause.** A bare breakout missing its 1.8 V regulator → DVDD floats or sits at the wrong rail → core logic doesn't come out of reset → I²C engine never responds. Worth checking *first* despite being listed last in the commit message.

---

## 5. Where this connects in the bigger picture

### 5.1 The reserved-for-analog HDL

[`color-pipeline.md` §2](color-pipeline.md) lists two HDL modules that are sim-validated but deliberately not yet in the BD:

- [`hdl/rgb_to_ycbcr.v`](../hdl/rgb_to_ycbcr.v) — RGB 4:4:4 → YCbCr 4:4:4 (Rec.601 / Rec.709 selectable)
- [`hdl/ycbcr_444_to_422.v`](../hdl/ycbcr_444_to_422.v) — chroma downsample 4:4:4 → 4:2:2

These are the modules that will eventually drive the ADV7393's parallel YCbCr 4:2:2 input. Their bit-exact Python golden references live in [`sim/analog/`](../sim/analog/). When this bring-up resumes and reaches the "configurable from PS" milestone, the next iter is "wire these modules' AXIS output into a parallel-bus driver feeding the ADV7393 data pins."

### 5.2 Spec commitments

[`01-spec.md`](01-spec.md) treats the ADV7393 as a Mini-SKU baseline part (composite + component + S-Video output). It is in the BOM. The architectural decision to share a parallel YCbCr 4:2:2 bus between ADV7393 and the future ADV7511 (HDMI out) is documented in `01-spec.md` §3.x — that decision drove the day-1 PMOD allocation and the eventual carrier-board pin budget.

### 5.3 What's *not* in the current build

- No YCbCr data path wired from the color pipeline output to the ADV7393 — only the I²C control path and the 27 MHz clock.
- No firmware register writes to actually configure the ADV7393 (mode select, levels, etc.) — only the probe. Configuration sequence is in the ADV7393 datasheet; not yet implemented.
- No top-level ports for the parallel data bus to the chip. That's a future iter once the chip is alive and configurable.

---

## 6. Why this work is well-scoped despite not succeeding yet

The infrastructure (`66e1a06`) is independent of the bench issue. The I²C master, MMCM clock, pin assignments, and firmware skeleton are correct regardless of why the chip isn't ACKing. Even if Check 3 reveals "the bare breakout has no 1.8 V regulator," that's a wiring fix on the bench side — the FPGA-side infrastructure stays as-is.

So the asymmetric state is: **build is ready, bench isn't.** When the bench session resumes:
1. Verify Checks 1–3 in order (or Check 3 first, given likelihood).
2. Once the chip ACKs at 0x2A, write the configuration sequence per the datasheet.
3. Replace the infinite-loop debug probe with a one-shot probe + status report over UART.
4. Move on to wiring the parallel YCbCr 4:2:2 data path.

None of that requires architectural changes to the current build.

---

## 7. Open follow-ups (carry forward)

- Resolve the JD1 27 MHz waveform amplitude question (Checks 1–2).
- Verify chip DVDD rail (Check 3) — most likely root cause.
- Once chip ACKs: write configuration sequence (NTSC composite mode as first target).
- Revert the `while(1)` debug loop in `adv7393_probe()` to a one-shot probe.
- Add a separate UART command to issue arbitrary I²C reads/writes for bench iteration.
- Plan the parallel-bus integration: where does the YCbCr 4:2:2 stream emerge from the color pipeline (or from a dedicated SD path), what PMOD pins host the parallel bus, what HDL drives DCLK / HS / VS.

---

## 8. Why this matters for the Phase E1 spike

The Phase E1 sync spike branches from `d71c994`, which **predates this ADV7393 work**. That means the spike branch will not have the I²C master, the 27 MHz clock generator, or the firmware probe. **This is fine** — Phase E1 is about the output-clock sync loop, not analog output. The ADV7393 infrastructure stays on `mackin-impl-wip` and rejoins when the spike merges back, exactly like the color pipeline modules.

When you're ready to resume ADV7393 bench work, the right environment is `mackin-impl-wip` (which has `66e1a06`), not the spike branch. Don't accidentally re-implement the I²C master on the spike branch — the work is already done, just not on that branch.
