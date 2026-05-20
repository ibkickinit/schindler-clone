# ADV7393 bench session — I²C results (2026-05-20)

**Session driver:** Justin (bench) + Claude (host/build/UART).
**Source branch:** `phase-g-iter1` at commit `7f74298` (equivalent content to `mackin-impl-wip` commit `66e1a06`).
**Outcome:** **Chip never ACKed; root cause shifted from "chip" to "AXI IIC IP in this build."** Bench packed up with new diagnostic action items.

This doc supersedes the pre-session checklist in [`adv7393-bench-session-i2c.md`](adv7393-bench-session-i2c.md) and the paused state in [`adv7393-bench-bringup.md`](adv7393-bench-bringup.md). The companion follow-up build (continuous I²C register-bang from firmware) lands in a subsequent commit.

---

## Summary

| Check | Result |
|---|---|
| Wiring continuity (SDA, SCL, CLKIN, ALSB, all power rails) | ✅ PASS — all beep |
| Pull-ups (SDA, SCL) | ✅ PASS — both 2.2 kΩ |
| Step 0.5: RESET/CLKIN pin audit (pin 20 → RESETB, pin 19 → CLKIN, not swapped) | ✅ PASS — pin 20 reads 3.3V DC steady; pin 19 reads 0–3.3V 27 MHz square |
| Step 0.6: Firmware I²C address audit (7-bit 0x2A) | ✅ PASS — verified in code review |
| Original 2026-05-17 "480 mVpp at JD1" concern | ✅ RESOLVED — clean 3 Vpp at chip pin 19 today |
| Power rails: 3.3V channel, 1.8V channel, VAA, DVDD, PVDD | ✅ All within spec (45 mA / 12 mA draw, voltages all on-target) |
| **Chip ACKs at 0x2A** | ❌ **NO — never ACKed in any configuration** |
| **AXI IIC IP successfully initializes** | ⚠️  Intermittent — hangs in `XIic_CfgInitialize` ~half the time. Only escape is power-cycle of chip. |
| **SDA/SCL show bus traffic on scope during a probe** | ❌ **NO TRAFFIC** — scope shows no SCL/SDA activity even when firmware logs NAK |
| NAK 0x2A printing rate | ~1 NAK per 10 sec (vs nominal 0.5 sec from the firmware loop) |

**The 2026-05-17 "chip not ACKing" diagnosis was incomplete.** After this session, the better hypothesis is **the AXI IIC IP in this build is not driving SDA/SCL.** The chip may also be damaged, but we can't verify chip behavior until the IP actually puts bytes on the wire.

---

## What we did (chronological)

### 1. Wiring re-verification

Multimeter continuity, PSU off. All checks beeped:
- SDA: Zybo JD7 (U14) → chip pin 13 ✓
- SCL: Zybo JD8 (U15) → chip pin 14 ✓
- CLKIN: Zybo JD1 (T14) → chip pin 19 ✓
- ALSB: chip pin 12 → GND ✓
- 3.3V rail continuous to VAA + VDD_IO ✓
- 1.8V rail continuous to VDD + PVDD ✓
- Common GND between PSU, Zybo, ADV7393 ✓
- Pull-ups on SDA, SCL: both 2.2 kΩ to 3.3V ✓

No wiring problems found.

### 2. Step 0.5 — RESET/CLKIN pin audit (new for this session)

Zybo powered + bitstream loaded (driving 27 MHz on JD1). ADV7393 PSU off.

- **Pin 20 (expected RESETB = 3.3V steady):** Measured **3.3V DC steady** ✓
- **Pin 19 (expected CLKIN = 27 MHz square):** Measured **0–3.3V 27 MHz square wave** ✓

This **rules out the pin-swap hypothesis** that was added 2026-05-20 as a high-priority pre-check. Wiring matches spec.

This also **resolves the 2026-05-17 "480 mVpp at JD1" concern.** Today's scope showed a clean 3 Vpp signal at the chip's CLKIN pin. The prior reading was a scope-probe ground-loop artifact, not real attenuation. (The short ground spring made the difference.)

### 3. Step 0.6 — Firmware address audit

Firmware calls `XIic_Send(IIC_ADV7393_BASE, 0x2A, ...)` and `XIic_Recv(IIC_ADV7393_BASE, 0x2A, ...)`. Xilinx `XIic_*` API expects 7-bit address; `0x2A` is the correct 7-bit form for ADV7393 with ALSB=0. Audit passes.

### 4. Power-up + DVDD verification

Bench PSU off, both channels current-limited to 100 mA. 3.3V channel on first; then 1.8V.

| Pin | Expected | Measured |
|---|---|---|
| Current draw, 3.3V channel | ~30–60 mA | **45 mA** ✓ |
| Current draw, 1.8V channel | ~10–30 mA | **12 mA** ✓ |
| VAA | 3.30V | **3.29V** ✓ |
| VDD (= VDD_IO per breakout silkscreen) | 3.30V | **3.29V** ✓ |
| **DVDD (digital core 1.8V)** | **1.80V** | **1.79V** ✓ |
| PVDD (PLL supply 1.8V) | 1.80V | **1.79V** ✓ |

**The "missing 1.8V regulator" hypothesis from 2026-05-17 is RULED OUT.** The bare breakout has all four rails (3.3V analog, 3.3V I/O, 1.8V core, 1.8V PLL) cleanly powered by the external bench PSU.

### 5. First firmware load — partial success

JTAG-loaded bitstream + firmware. UART output (in picocom):

```
=== Schindler 2.0 — Phase B.1 ===
VDMA + VTC bare-metal init
Frame buffers: 0x... (garbled due to xil_printf %08lx limitation — cosmetic only)

Phase G iter1.5: fast 0x2A probe loop
  IIC base = 0x41600000  CLKIN driven 27 MHz on JD1
NAK 0x2A
NAK 0x2A
NAK 0x2A
...
```

Firmware booted, AXI IIC initialized, probes returned NAK. **At this point we believed: firmware healthy, chip not responding.** Moved to next step.

### 6. Reset pulse attempt — caused Zybo reset

Per doc Step 3, attempted to pulse RESETB low by touching a GND jumper to chip pin 20.

**Result:** the Zybo's onboard 3.3V rail brown-out and the entire Zybo reset. Reason: RESETB jumper went directly from JE6 (Zybo's 3.3V supply) to chip pin 20 with no series resistor. Grounding pin 20 shorted JE6.

**Lesson learned:** for future hardware bring-ups, the RESETB jumper should always have a 1 kΩ series resistor when connected to a direct power rail, so brief grounding is current-limited and safe.

**Workaround used:** disconnected the JE6 end of the wire (so pin 20 floats), briefly grounded pin 20 with a separate jumper (~1 second), then reconnected JE6 → pin 20. Effective reset pulse without rail short.

### 7. Post-reset: firmware hangs in XIic_CfgInitialize

JTAG-reloaded after the reset pulse. UART showed:

```
=== Schindler 2.0 — Phase B.1 ===
VDMA + VTC bare-metal init
Frame buffers: 0x...

Phase G iter1.5: fast 0x2A probe loop
  IIC base = 0x41600000  CLKIN driven 27 MHz on JD1
<HANG — no further output>
```

Firmware reached the `[I] IIC base = ...` print but hung in `adv7393_iic_init()` → `XIic_CfgInitialize`. Same hang signature reproduced across multiple JTAG-reload attempts.

### 8. Workaround: power-cycle of chip rescues init (intermittently)

Discovered that powering the ADV7393 chip down (1.8V off, wait, 3.3V off, wait, both back on in order), THEN JTAG-reloading the firmware, sometimes lets `XIic_CfgInitialize` complete successfully.

After successful init, firmware enters the probe loop and prints `NAK 0x2A` periodically.

This is a **workaround, not a fix.** The init's success appears sensitive to bus-state transients at the moment of init. Power-cycling the chip puts SDA/SCL at idle-high (pull-ups, no chip driving), giving the IIC IP a clean idle bus to start from. Once initialized, the IP keeps running — but the path through `XIic_CfgInitialize` itself is fragile.

### 9. Probe rate observation — 10 seconds per NAK, not 0.5

Once init succeeds, firmware loops:
```c
while (1) {
    adv7393_probe();
    for (volatile int d = 0; d < 50000000; d++); // intended ~0.5s
}
```

The for-loop alone is ~0.225s. So nominal probe-to-probe is ~250 ms.

**Observed:** NAK lines arrive every **~10 seconds**. That's **40× slower than expected**. Means each `adv7393_probe()` call takes ~9.7 seconds — and inside the probe, the only thing that could take that long is the `XIic_Send` call (which on NAK should return in milliseconds).

**Interpretation:** `XIic_Send` is using a long internal timeout (likely ~10 seconds) to wait for a state machine transition that never happens. Eventually times out, returns "failed" (which firmware interprets as NAK), and loops.

### 10. Scope shows NO bus traffic

The critical finding. With firmware in the steady NAK-every-10s state, scope on chip pin 13 (SDA) and pin 14 (SCL):

**No SCL clock pulses. No SDA transitions. Lines sit at the pull-up voltage (3.3V) with only noise.**

This means **the AXI IIC IP is not putting any bytes on the wire** during the "transaction" that firmware perceives as a NAK. The "NAK" is the IP's internal timeout firing without ever attempting bus communication.

The 2026-05-17 conclusion — "chip not ACKing" — was off by one layer. The chip can't NAK what it never received.

### 11. Session pack-up

Per the bench-session doc's stop-loss criterion (2 hours without a working ACK), the session was declared inconclusive and the chip+wiring packed up. ADV7393 PSU off, Zybo USB unplugged, Pmod jumpers left attached to the breakout for next time.

---

## Root cause hypotheses (ranked)

### Hypothesis 1 (most likely): AXI IIC IP wiring / config issue

Evidence:
- Scope shows zero SDA/SCL activity during transactions
- `XIic_CfgInitialize` hangs intermittently, suggesting the IP isn't responding to register accesses correctly
- ~10-second NAK indicates internal IP timeout, not chip-side NAK
- Power-cycle of chip "rescues" init, suggesting bus-state at init time is critical (which it shouldn't be for a healthy IP)

Suspect BD-level configuration items to audit:
- `axi_iic_adv7393` IP's clock-source attachment (should be FCLK_CLK0, 100 MHz)
- AXI-Lite interface wiring to `axi_ic_lite/M06`
- IOBUF inference at the `iic_adv7393` interface port
- XDC pin assignments (PULLUP TRUE on both)

### Hypothesis 2: Chip damaged

Evidence:
- Chip subjected to a brief 3.3V→GND short via JE6 when reset pulse was attempted incorrectly
- Bare breakouts handle poorly during bench iteration (ESD, voltage transients)

But this can't be confirmed until Hypothesis 1 is ruled out — we need to see the IP actually drive bus traffic before we can claim "chip damaged."

### Hypothesis 3: Both

Even if the AXI IIC IP gets fixed and starts transmitting, the chip may still be unresponsive due to accumulated bench damage. This is the case to plan for if Hypothesis 1's fix doesn't immediately produce an ACK.

---

## What I would have done differently

- **Series resistor on RESETB from day 1.** Any manually-pulsable reset line connected to a power rail needs 1kΩ in series. Discovering this by shorting the Zybo's 3.3V rail was avoidable.
- **Scope the SDA/SCL BEFORE assuming chip is the problem.** The 2026-05-17 session went deep on "chip not ACKing" hypotheses (DVDD, pin swap, address) before ever verifying that the IIC master was actually transmitting. Scoping the bus would have surfaced the "no traffic" finding much earlier.
- **Read the AXI IIC's status register from firmware.** The IIC IP has a `IIC_STATUS` register (offset 0x104) that reports bus state (busy, idle, error, arbitration lost). Reading it after each probe failure would tell us whether the IP thinks the bus is busy or whether some other error is firing. We didn't do this.

---

## Next iteration plan (Phase G iter2 startup)

### Step A: Continuous register-bang firmware (no XIic library)

Replace the XIic-library-based probe with a tight loop that writes directly to the AXI IIC's TX FIFO. Bypasses XIic's timeouts and abstractions. If the IP is electrically capable, scope will see continuous traffic.

The build for this lands in a subsequent commit (iter1.6 — "I²C scope-bang continuous mode").

If scope sees traffic: AXI IIC IP can drive bus → original XIic library was misbehaving, not the IP → move to ACK diagnosis.
If scope sees nothing: AXI IIC IP is genuinely non-functional → BD audit time.

### Step B (if scope sees traffic): chip diagnosis

With confirmed IP capability, try:
- Multiple probe rates (10 kHz, 100 kHz, 400 kHz) to test if chip is timing-sensitive
- Address scan (0x03–0x77) — maybe ALSB strap interpretation is different than assumed
- EEPROM cross-check (any I²C device on the same bus) — confirms bus works independent of ADV7393
- Cold RESETB pulse via PSU power-cycle ONLY (no manual pin grounding)

### Step C (if scope sees nothing): BD audit

- Open the BD in Vivado, inspect `axi_iic_adv7393` cell connections
- Confirm `IIC` interface is exposed and goes to top-level IOBUFs correctly
- Verify clock + reset wiring
- Possibly rebuild with explicit `CONFIG.C_GPO_WIDTH` and other config items
- Read `IIC_STATUS` (offset 0x104) post-init via JTAG-poke

### Step D: hardware retry with safer wiring

- Add 1kΩ series resistor on RESETB
- Use the JE6 → 1kΩ → pin 20 + a momentary switch from pin 20 → GND as the reset-pulse mechanism
- If still no progress, swap to a fresh ADV7393 breakout (the current one may be damaged)

---

## Open items carried forward

- The 10-second NAK rate (internal IIC timeout) is a real symptom that should be quantified — measure it more precisely with the iter1.6 build.
- The xil_printf `%08lx` formatting bug (frame buffer addresses print as nonsense) is cosmetic but worth fixing for cleaner UART output.
- The `program_phase_b.tcl` vs `program_phase_b_full.tcl` confusion in the bench-session doc — `program_phase_b.tcl` only loads bitstream; firmware doesn't run. Doc should be updated to reference `program_phase_b_full.tcl`.

---

## Files committed this session

| File | Purpose |
|---|---|
| `docs/adv7393-bench-session-i2c-results.md` | This doc — session results |
| (subsequent) `sw/phase-b/src/main.c` | iter1.6 firmware: continuous AXI IIC register-bang for scope diagnosis |
| (subsequent) `docs/adv7393-bench-bringup.md` | Update status from "PAUSED — three open checks" to "PAUSED — IP-level diagnosis needed; bench checks all pass" |

Branch: `phase-g-iter1`. No changes to BD or constraints in this session.
