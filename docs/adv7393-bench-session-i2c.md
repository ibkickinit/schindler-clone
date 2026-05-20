# ADV7393 bench session — I²C alive, then pack up

**Purpose:** resume from the 2026-05-17 paused state (chip not detected, three open bench checks queued), bring I²C to a known-working state, and disconnect the ADV7393 board for storage. Sync project is paused; this is a fast standalone session before the bench gets cleared.

**Background:** [`adv7393-bench-bringup.md`](adv7393-bench-bringup.md) is the full reference. Reading it cold is not required — this doc is self-contained.

**Expected duration:** 60–90 minutes if Check 3 lands cleanly. Up to 2 hours if signal-integrity work is needed.

**Source branch:** `mackin-impl-wip` (the branch with `66e1a06` — has the I²C master + 27 MHz clock + firmware probe). **Do not use the `phase-e1-pll-spike` branch** — that's branched from `d71c994` and doesn't have the ADV7393 infrastructure.

### Two new high-priority pre-checks (added 2026-05-20)

Before running any of the original steps, two issues are now suspected as likely root causes — both verifiable in under 5 minutes total, and either one alone could explain every prior NAK:

1. **RESET / CLKIN may be swapped** at the chip end (user-reported suspicion). Symptom is "NAK forever, no other obvious fault" which matches both swap permutations.
2. **I²C address representation** may be wrong in firmware. ADV7393's ALSB-low address is `0x2A` in 7-bit form (which Xilinx XIic_Send expects) or `0x54`/`0x55` in 8-bit-with-R/W form. Using `0x54` thinking it's a 7-bit address would silently mis-address the chip on every probe.

These are now **Steps 0.5 (pin audit) and 0.6 (firmware address audit)** before Step 1. Run both before applying power. Either one resolving the issue alone will save the rest of the session.

### Reference: support-engineer checklist (received 2026-05-20)

For cross-reference during the session — the ADV support engineer's general I²C-bring-up checklist. Items that overlap with this doc are flagged; new items have been incorporated into the steps below.

- Power rails good. → **Step 1.**
- Device out of reset; reset goes high AFTER both power rails stable. → **Step 1 + Step 0.5.**
- SDA/SCL going to right pins (engineer notes: "I've swapped them, very embarrassing"). → **Step 1 wiring.**
- Pull-up resistors 2.2k–10k. → **Step 1 wiring (we have 2.2k).**
- SDA/SCL signals wiggle, 0–3.3V amplitude. → **Step 4 / Step 6.**
- **NEW: Master tri-states SDA during ACK** so chip can pull low. → **Step 6, new sub-test.**
- Correct device address (ADV7393 ALSB low: `0x54` write / `0x55` read in 8-bit, = `0x2A` 7-bit). → **Step 0.6 (firmware audit).**
- Correct START command per datasheet Figures 49, 50. → AXI IIC handles automatically; out of scope unless Step 6 hangs.
- **NEW: Cross-check bus** by tying a known-good I²C device (EEPROM) to verify the bus is functional independent of ADV7393. → **§10 failure-mode triage.**

---

## 0. Pre-flight (10 min)

### Gear

- [ ] Zybo Z7-20 board (USB-attached to host).
- [ ] EVAL-ADV7393 bare breakout (the 40-pin chip + passives + 3× RCA breakout).
- [ ] Dual benchtop power supply with 3.3V and 1.8V channels (or two separate supplies).
- [ ] Bench multimeter (DC voltage, sub-100 mV resolution).
- [ ] Oscilloscope with at least 50 MHz bandwidth.
- [ ] Scope probe with **short ground spring** (the spring that attaches to the probe-tip barrel, not the long-lead clip). If you don't have one, you can fashion one from a bent piece of bare wire — much better than the standard ground clip at 27 MHz.
- [ ] Pmod jumper wires.
- [ ] Standard USB cable, host computer, serial terminal.

### Branch + software prep

- [ ] `git checkout mackin-impl-wip` (or whatever branch currently has `66e1a06` and forward). Confirm with `git log --oneline | grep ADV7393` — should show `66e1a06`.
- [ ] Bitstream + firmware ELF for that branch, ready to load.

### A note on what success looks like

By the end of this session, you want:

1. ADV7393 chip ACKs at I²C address 0x2A (or 0x2B if ALSB is high).
2. Firmware can read register `0x00` (Chip Mode Register / SW Reset on this chip — content is known) and get back a non-zero, deterministic value.
3. Session doc captures the working configuration: power rails, pull-up values, pin-to-pin verifications.
4. Board can be powered down and packed away in a known-working state.

Anything beyond that (configuring composite mode, driving video) is out of scope for this session. The goal is "I²C alive, document, disconnect."

---

## 1. Wiring re-verification (10 min)

The bench has been idle since 2026-05-17. Re-verify the wiring before applying power. Easy to bump a jumper between sessions.

### Power wiring

Per the 2026-05-17 setup:

| Rail | Source | Chip pin(s) | Net name |
|---|---|---|---|
| 3.3V | Bench PSU ch1 | VAA, VDD_IO | (separate jumpers) |
| 1.8V | Bench PSU ch2 | VDD, PVDD | (separate jumpers) |
| GND | Both PSU ch GND, Zybo GND | All chip GND pins | single-point bond |

Verify with multimeter (PSU off):
- [ ] 3.3V rail continuous from PSU output to VAA pin.
- [ ] 3.3V rail continuous from PSU output to VDD_IO pin.
- [ ] 1.8V rail continuous from PSU output to VDD pin.
- [ ] 1.8V rail continuous from PSU output to PVDD pin.
- [ ] Common GND bond.

### Signal wiring (Zybo → chip)

| Net | Zybo PMOD | Zybo pin | Chip pin | Pull-up |
|---|---|---|---|---|
| SDA | JD7 | U14 | 13 | 2.2 kΩ to 3.3V |
| SCL | JD8 | U15 | 14 | 2.2 kΩ to 3.3V |
| RESETB | JE6 | (3.3V via header) | 20 | (manual pulse) |
| CLKIN | JD1 | T14 | 19 | (driven, no PU) |
| ALSB | — | GND | (sets I²C addr 0x2A) | tied to GND |

Verify with multimeter (PSU off):
- [ ] SDA continuity Zybo JD7 → chip pin 13.
- [ ] SCL continuity Zybo JD8 → chip pin 14.
- [ ] CLKIN continuity Zybo JD1 → chip pin 19.
- [ ] ALSB tied to GND.
- [ ] Pull-up resistors (2.2 kΩ) present on SDA and SCL between net and 3.3V.

---

## 1.5 — Step 0.5: RESET / CLKIN pin audit (5 min, do this first)

**Why this is first:** if RESETB and CLKIN are swapped at the chip end (a real possibility per the user's suspicion), nothing else in the session will help. The failure mode is silent — chip just NAKs forever — and a multimeter + scope confirms the issue in 60 seconds before applying power to the chip.

Failure-mode logic if swapped:

| Spec wiring | If swapped |
|---|---|
| Pin 19 = CLKIN (27 MHz square from JD1) | Pin 19 = static 3.3V from JE6 → chip sees no clock → core PLL never locks → I²C engine never starts → **NAK forever** |
| Pin 20 = RESETB (static 3.3V from JE6) | Pin 20 = 27 MHz square → chip is being reset 27M times per second → never comes out of reset → **NAK forever** |

### Procedure (before applying power to the chip — Zybo can be on, providing CLKIN, but ADV7393 rails OFF)

1. [ ] Power Zybo on; program board so CLKIN at JD1 is actively driven.
2. [ ] **Do NOT power the ADV7393 rails yet** — keep them off so the chip is in a known safe state.
3. [ ] Multimeter, DC volts. Probe **chip pin 20** to GND. Expected: **~3.3V steady** (RESETB tied to JE6's static 3.3V rail).
4. [ ] If pin 20 reads ~0V steady or floating: trace the jumper — it should connect to JE6 (3.3V).
5. [ ] If pin 20 reads ~1.65V or fluctuating AC: **it's getting the 27 MHz clock by mistake.** RESETB and CLKIN are swapped.
6. [ ] Scope, DC coupling, 1V/div. Probe **chip pin 19** to GND (short ground spring if you have it). Expected: **27 MHz square wave, ~3 Vpp.**
7. [ ] If pin 19 reads static 3.3V: **it's tied to RESETB by mistake.** Swap is confirmed.

### Outcome

- **Both pins correct as spec:** good, move to Step 0.6.
- **Swapped:** physically swap the jumpers at the chip end (or at the Zybo PMOD end — same result). Re-verify. **This single fix may resolve the entire session's failure mode.** Still run the rest of the session for completeness, but don't be surprised if everything lights up on first probe.

### Recording

```
Step 0.5 — RESET/CLKIN pin audit:
  Pin 20 (RESETB expected): ______ V (DC)
  Pin 19 (CLKIN expected):  ______ Vpp at ______ Hz
  Swap detected? Y / N
  if Y: jumpers physically swapped, re-verified — confirm above readings now correct
```

---

## 1.6 — Step 0.6: Firmware I²C address audit (5 min)

**Why this matters:** ADV7393's I²C address with ALSB=GND is `0x2A` in 7-bit form. Xilinx's `XIic_Send` and `XIic_Recv` conventionally take **7-bit** addresses (the API shifts left internally and appends R/W bit). But the chip's datasheet and the support engineer's notes describe the address as `0x54` (write) / `0x55` (read), which is the **8-bit with R/W** representation. If firmware accidentally uses `0x54` or `0x55` thinking they're 7-bit values, the call silently mis-addresses the chip on every probe.

This is the most common single-character bug in I²C bring-up. Worth a 60-second grep before powering up the chip.

### Procedure

1. [ ] In the repo, grep for the address constants in firmware:
   ```
   grep -n "0x2A\|0x54\|0x55\|0x2a\|0x54\|0x55" sw/phase-b/src/main.c | grep -i "adv\|iic\|i2c\|addr"
   ```
2. [ ] Also check the `XIic_Send` and `XIic_Recv` calls in `adv7393_probe()` and `adv7393_read_reg()` — note the address argument value.
3. [ ] Cross-reference Xilinx PG090 (AXI IIC) docs — confirm whether the API expects 7-bit or 8-bit address. As of the relevant Vitis version, it's **7-bit**.

### Outcome

- **Firmware passes `0x2A`** to XIic_Send/Recv → **correct.** Move to Step 0.7 / Step 1.
- **Firmware passes `0x54` or `0x55`** → **THE BUG.** Change to `0x2A`, rebuild firmware (no Vivado rebuild needed), reload. This alone could be the entire issue.
- **Firmware passes something else** (e.g., `0x60`, `0x55`-with-comment-claiming-it's-7-bit, etc.) → fix per datasheet (`0x2A` in 7-bit form).

### Recording

```
Step 0.6 — Firmware I²C address audit:
  XIic_Send address argument: ______
  expected (7-bit): 0x2A
  PASS / FAIL: ______
  if FAIL: corrected to 0x2A, firmware rebuilt, board reloaded
```

---

## 2. Power-up sequence (5 min)

Order matters — apply rails in spec sequence to avoid latch-up.

1. [ ] Bench PSU off. Both channels set to **current limit ~100 mA** as safety.
2. [ ] Connect 3.3V channel; turn it on. Confirm rail at 3.30 V ±50 mV at chip's VAA/VDD_IO pins.
3. [ ] Connect 1.8V channel; turn it on. Confirm rail at 1.80 V ±50 mV at chip's VDD pin.
4. [ ] Total current draw should be ~30–60 mA. If much higher (>200 mA), there's a short — power off, recheck wiring.
5. [ ] **Do not yet** connect the Zybo USB / program the board. The chip needs to be powered for ~5 ms before the FPGA drives CLKIN; doing it in reverse causes some chips to enter unexpected states. (For ADV7393 specifically this is precautionary, not strictly required by the datasheet.)
6. [ ] Once rails are stable: connect Zybo USB, power on Zybo, program the board (`xsct tcl/program_phase_b.tcl`).

If the chip is responding correctly, the firmware's `adv7393_probe()` loop will start running and producing UART output within ~2 seconds of program complete.

---

## 3. Step 1 — Check 3 first: DVDD verification (10 min, most likely root cause)

The most likely root cause of the 2026-05-17 NAK is **the bare breakout lacks an onboard 1.8 V regulator** for the digital supply (DVDD). If the chip's DVDD pin isn't at 1.8 V, the core logic never comes out of reset and I²C never responds.

### Procedure

1. [ ] **Locate DVDD pin on the chip.** Consult the ADV7393 datasheet pinout — typically there are multiple supply pins (VAA, AVDD, DVDD, PVDD, VDD_IO). DVDD is the one for digital core; usually labeled "DVDD" on the package or the breakout silkscreen.
2. [ ] **Multimeter the DVDD pin directly at the chip pin** (not at the breakout header — the breakout may have a regulator between header and pin, or may not).
3. [ ] Read voltage.

### Outcomes

- **Reads ~1.80 V** → DVDD is fine. Move to Step 2 (signal integrity).
- **Reads 0 V** → No power to DVDD. The breakout is missing a regulator or has a broken connection. **Workaround: jumper a wire from your 1.8 V bench supply directly to the chip's DVDD pin.** Confirm 1.80 V at the pin. Then move to Step 4 (skip Step 2/3 — DVDD was the issue).
- **Reads 3.3 V or some odd value** → The breakout is connecting DVDD to the wrong rail. Same workaround as above — feed 1.8 V from bench supply, disconnect whatever's on the pin currently (cut a trace or lift the pin).
- **Reads ~1.8 V but unstable / oscillating** → Decoupling issue. Add a 100 nF + 10 µF cap from DVDD to GND at the chip pin.

### Recording

```
Step 1 — DVDD verification:
  measured DVDD voltage: ______ V
  expected: 1.80 V
  PASS / FAIL: ______
  if FAIL, workaround applied: ______
```

If Step 1 resolved the issue (DVDD was 0 V or wrong rail), **skip directly to Step 4.** Steps 2 and 3 are only needed if Step 1 was already correct but I²C still doesn't respond.

---

## 4. Step 2 — Signal integrity on CLKIN (15 min)

Only needed if Step 1 didn't resolve the issue.

The 2026-05-17 scope reading was ~480 mVpp at JD1 instead of expected ~3 Vpp. This could be:
- A real signal-attenuation issue (long jumper wires acting as low-pass filter at 27 MHz)
- A scope-probe ground-loop artifact (long ground clip resonating at 27 MHz)

### Procedure (in order — Check 2 then Check 1 from the original doc)

**Check 2 first — shorten probe ground:**
1. [ ] Replace scope probe's standard ground clip with a short ground spring.
2. [ ] Probe at JD1 header pin (Zybo end), with the spring attached directly to a nearby GND on the Zybo header.
3. [ ] Capture waveform.

Expected: clean ~3 Vpp square wave at 27 MHz. If you see this, the 2026-05-17 reading was a ground-loop artifact, and the signal is fine — move to Step 3.

**If JD1 reads ~3 Vpp:** the cable to the chip is the variable. Continue to Check 1.

**Check 1 — probe at chip pin 19 directly:**
1. [ ] Move scope probe to chip pin 19 (CLKIN input), spring still attached to nearest GND.
2. [ ] Capture waveform.

Expected: also clean ~3 Vpp square wave (or close to it — some attenuation through the jumper is OK as long as it's >1.5 Vpp; the chip's logic input threshold is around 1.2 V).

### Outcomes

- **Both JD1 and chip pin 19 show clean ~3 Vpp:** signal is fine. The 2026-05-17 reading was a ground-loop. Move to Step 3.
- **JD1 clean, chip pin 19 attenuated to <1.5 Vpp:** the jumper wire is the issue. Use a shorter wire (ideally <50 mm). If the chip's input doesn't reach logic-high threshold, the internal PLL won't lock and the chip won't start its I²C engine.
- **JD1 still shows ~480 mVpp:** the Zybo XDC says T14 is DRIVE 12 SLEW FAST, which should be ~3 Vpp into reasonable loads. If it's still attenuated with a short ground spring, the FPGA output may not be driving correctly. Check the Vivado utilization report for T14 to confirm it's actually configured as output.

### Recording

```
Step 2 — CLKIN signal integrity:
  JD1 amplitude (short ground spring): ______ Vpp
  Chip pin 19 amplitude: ______ Vpp
  expected: ~3 Vpp clean square at 27 MHz
  PASS / FAIL: ______
```

---

## 5. Step 3 — Reset pulse (5 min)

After power and clock are confirmed correct, the chip needs a clean release-from-reset edge to start its internal logic and the I²C engine.

### Procedure

1. [ ] With everything powered up and clock running, confirm RESETB is currently held high (3.3 V) at chip pin 20 — multimeter it.
2. [ ] Manually pulse RESETB low: temporarily connect chip pin 20 to GND for ~10 ms (just touch a jumper wire from chip pin 20 to GND, then remove).
3. [ ] Confirm RESETB returns to 3.3 V.
4. [ ] Wait ~5 seconds for the chip to come fully out of reset and stabilize.

### What to expect

If everything is correct, the chip is now in its default state and ready to accept I²C transactions. The firmware's probe loop should start producing UART output if it isn't already.

---

## 6. Step 4 — I²C probe (10 min)

### Procedure

1. [ ] Open serial terminal: `picocom -b 115200 /dev/ttyUSB1` (or platform equivalent).
2. [ ] If firmware is in infinite probe loop (the 2026-05-17 debug mode), it'll be continuously sending I²C transactions and printing results. Watch the output.

### Outcomes

- **`ACK at 0x2A`** (or 0x2B if ALSB is wired differently than expected): **SUCCESS.** Chip is alive. Move to Step 5 for functional verification, then to disconnect.
- **`NAK at 0x2A`** continuously: chip is not responding. Re-check Step 1 (DVDD) — most common cause. If DVDD is confirmed correct, re-check the SDA/SCL pull-ups at the chip end (they're 2.2 kΩ at the Zybo end — verify the trace to the chip pin is intact). Then run sub-test 6a below.
- **`I²C timeout` or `arbitration lost`**: bus is stuck. Power-cycle the chip (turn off 1.8V then 3.3V, wait 10s, re-power in order). If bus stays stuck, SDA may be shorted somewhere — multimeter SDA to GND while powered off; should be ~∞Ω with the pull-up disconnected.

### Step 6a — SDA tri-state-during-ACK sub-test (only if Step 6 NAKs)

Per support engineer's checklist: the master must release SDA (let it tri-state) during the ACK bit slot so the chip can pull it low. The AXI IIC IP handles this automatically per PG090, but worth verifying with a scope when nothing else works.

1. [ ] Scope ch1 = SCL, ch2 = SDA, both at chip pin (or as close as possible). Short ground spring on both.
2. [ ] Trigger on SCL falling edge.
3. [ ] Run a probe attempt; capture one full transaction.
4. [ ] Count 9 SCL clock pulses (8 data bits + 1 ACK). The 9th SCL high pulse is the ACK slot.

**What to look for during the 9th SCL pulse:**

- **SDA stays high through the 9th pulse** → either the master isn't tri-stating (master-side bug) OR the chip didn't pull low (chip-side problem). To discriminate: scope SDA continuously through the 9th pulse — does it briefly dip then recover (chip tried to ACK but pull-up dragged it back), or stay rock-solid at 3.3V (master is actively driving high, chip can't pull low)?
- **SDA goes low during the 9th pulse** → the chip IS ACKing. The bug is elsewhere — probably in how the firmware interprets the ACK status, or in the START/STOP framing.
- **No 9th SCL pulse at all** → the AXI IIC's transaction is malformed (probably an unhandled error condition). Read the IIC's status register after the transaction to see what state it's in.

### Step 6b — EEPROM cross-check (only if Step 6 NAKs and Step 6a is ambiguous)

Per support engineer's checklist: tie a known-good I²C device to the bus to verify the bus itself is functional, independent of the ADV7393.

If you have any of: a 24LC256-style EEPROM, an MPU-6050 IMU breakout, a BME280 sensor, an OLED I²C display, or any other I²C device on a breakout — wire it to SDA/SCL/3.3V/GND.

1. [ ] Power off everything.
2. [ ] Tie the second device's SDA to the same SDA line as ADV7393; SCL likewise.
3. [ ] Provide whatever supply the second device needs (typically 3.3V or 5V).
4. [ ] Power up. Confirm both devices are powered.
5. [ ] Modify firmware temporarily to scan a broader address range (or know the second device's address and probe specifically). For 24LC256 EEPROM: address `0x50` (7-bit). For MPU-6050: `0x68` or `0x69`.
6. [ ] Run probe.

Outcomes:

- **Second device ACKs, ADV7393 NAKs** → bus is fine, ADV7393 is the problem. Most likely: chip is damaged, or one of the chip-specific signals (DVDD, RESETB, CLKIN) is still wrong.
- **Both NAK** → bus is broken. Check pull-ups, master config, wiring at the bus level.
- **Both ACK** → bus is fine AND ADV7393 was fixed by something earlier in the session (rare, but possible — maybe the act of re-wiring exposed a flaky jumper).

### Recording

```
Step 4 — I²C probe:
  UART output: ______
  expected: "ACK at 0x2A" or similar
  PASS / FAIL: ______
```

---

## 7. Step 5 — Functional verify: read a known register (10 min)

ACKing is necessary but not sufficient — a chip can ACK its address while being in a confused state. Read a register to confirm functional I²C.

### Suggested register reads

The firmware has `adv7393_read_reg(reg, *value)`. Pick a register with a known reset value from the ADV7393 datasheet. Candidates:

- **Register `0x00`** (Power Mode 1): bit field; reset value typically `0x1C` (chip-dependent — check datasheet).
- **Register `0x01`** (Power Mode 2): another known reset value.
- **Register `0x1C`** (Software Reset): writes are functional after this; reads may be 0.

Pick one. The point is to read a register, get a deterministic value, and compare against the datasheet.

### Procedure

1. [ ] Either modify firmware temporarily to read+print a specific register, OR if there's already a `r <addr>` UART command (check `?` for help), use it.
2. [ ] Read register `0x00`. Print the value.
3. [ ] Compare against datasheet reset value.

### Outcomes

- **Reads the expected reset value:** SUCCESS. I²C is fully functional. Chip is in known-good state.
- **Reads `0x00` or `0xFF`:** the read transaction is failing silently (returning bus-default). Re-verify probe ACK in Step 4.
- **Reads something other than expected reset value:** chip may have been previously written to. Pulse RESETB (Step 3) again and re-read; should return to reset value.

### Recording

```
Step 5 — Register read:
  register: ______
  value: ______
  datasheet expected: ______
  PASS / FAIL: ______
```

---

## 8. Disconnect prep (10 min)

Assuming all five steps pass: pack up the ADV7393 board for storage.

### Procedure

1. [ ] Power down in reverse order: 1.8V channel off, then 3.3V channel off.
2. [ ] Disconnect Zybo USB.
3. [ ] Disconnect Pmod jumpers from Zybo side (leave them attached to the breakout if you want — easier to re-wire next time).
4. [ ] Note in this doc which jumpers connect to which Zybo PMOD pin (you'll thank yourself when you come back to this in a few weeks).
5. [ ] Pack the breakout + jumpers in a labeled ESD bag if you have one, or just a clean container.

### Firmware revert before storing the build (5 min, optional but recommended)

The firmware probe currently runs in an infinite loop in debug mode. With the chip now confirmed working, change the probe to a one-shot at boot that reports `ACK/NAK` once and moves on. This way, future builds on `mackin-impl-wip` won't have a busy I²C bus.

1. [ ] In [`sw/phase-b/src/main.c`](../sw/phase-b/src/main.c), find the `while(1)` around the `adv7393_probe()` call.
2. [ ] Replace with a single `adv7393_probe()` call.
3. [ ] Rebuild firmware. Doesn't need a Vivado rebuild — firmware-only change.
4. [ ] Commit: `phase-g iter1.6: ADV7393 chip alive — revert probe to one-shot, ready for next iter`

---

## 9. After-session

- [ ] Write up results as `docs/adv7393-bench-session-i2c-results.md` (or update [`adv7393-bench-bringup.md`](adv7393-bench-bringup.md) status header from "PAUSED" to "I²C CONFIRMED, awaiting Phase G iter2").
- [ ] Commit any firmware changes from Step 8's revert.
- [ ] Update [`dev-roadmap.md`](dev-roadmap.md) Phase G status — chip-alive milestone complete.
- [ ] Add to the post-spike work queue: Phase G iter2 (config sequence + parallel YCbCr 4:2:2 data path).

---

## 10. Failure-mode triage

If you get to the end of the session and the chip still isn't responding:

### Symptom: NAK persists after Step 1, 2, 3 all pass

- **Most likely:** the chip is damaged. Bare breakouts handle poorly during prior bench sessions (static discharge from probing, voltage spikes from supply transients). If you have a second breakout, swap it in.
- **Less likely:** the I²C address is different from 0x2A. Some ADV7393 revisions or breakout variants use 0x55 or other addresses. Try a full 0x03–0x77 scan (slower but exhaustive — fix the firmware's timeout if needed first).
- **Unlikely but possible:** the Zybo's `axi_iic_adv7393` core has a configuration issue. Read its `IIC_STATUS` register after a probe attempt to see what state the bus is in.

### Symptom: Step 1 fails (DVDD not at 1.8 V) and external 1.8 V doesn't help

The chip is probably damaged or the breakout has a manufacturing defect. Time to swap or RMA the breakout. Don't burn a session chasing a hardware fault — the I²C master, clock, and firmware are all proven correct (they worked against the 2026-05-17 setup up to "trying to talk to the chip"); the issue is silicon-side.

### Symptom: Everything passes but probe still NAKs

- Check the I²C clock rate. Spec says 100 kHz; if the AXI IIC is somehow running faster, the chip may not respond. Read the IIC core's clock divisor register.
- Check SCL clock stretching — some chips hold SCL low briefly while processing; if AXI IIC is impatient, transaction fails. Increase the I²C timeout in firmware.

### Stop-loss

If you've spent 2 hours and the chip still isn't ACKing, declare the session inconclusive, document everything you tried, and pack up. The ADV7393 path can resume later with fresh eyes (or a new breakout). Don't sink more time into bench debug when there are other forward paths (the sync work is paused but still progressable in other directions once Si5351 arrives).

### If Step 6b EEPROM cross-check showed bus-OK but ADV7393 still NAKs

That's strong evidence the chip itself is the problem. Two paths:

- **Swap the breakout.** If you have a spare ADV7393 breakout, swap and re-run from Step 0.5. Damaged silicon won't fix itself with firmware.
- **Document the dead chip and order a new breakout.** Don't burn more session time on a likely-bricked part.

---

## Quick reference — UART commands for this session

```
?              Help banner
q              Query state (if implemented for ADV7393 mode)
```

If the firmware doesn't yet have ADV7393-specific UART commands, the probe loop's stdout is the only signal. Read the `adv7393_probe()` implementation to know what to expect on success vs failure.

---

## After this session

The plan opens back up. Three threads are independently progressable:

1. **Phase G iter2 — ADV7393 config + data path.** When you're back at the bench and want to drive composite output, this is next.
2. **Si5351 dev board arrival.** When it lands, [`si5351-bench-bringup.md`](si5351-bench-bringup.md) is the session checklist — Phase A (chip alive) doesn't even need the sync spike branch.
3. **Sync project resumption.** Blocks on Si5351 arrival; resumes per `phase_e2_psincdec_limit.md`'s Si5351 acceptance criteria.

None of these blocks the others. Pick whichever has hardware available when bench time comes back around.
