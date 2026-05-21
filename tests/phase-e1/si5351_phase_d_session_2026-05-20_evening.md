# Si5351 Phase D — Session log, 2026-05-20 evening

**Status:** OPEN — Si5351 multi-byte write reliability fundamentally unsolved. Single-byte probe works. Multi-byte writes (3 bytes: addr+reg+data) NAK frequently. Pattern is reproducible across power cycles.

## Where we are right now

Code is on branch `phase-g-iter1`, uncommitted changes to:
- `sw/phase-b/src/si5351.c` — see below
- `sw/phase-b/src/main.c` — `p` UART command added; debug toggles removed

Code state: NO debug printf during init or `f` (we just removed those). `write_reg_once` does back-to-back FIFO pushes with `iic_settle(3)` at end. Retries set to 10 with 5 ms gap.

Bench: Si5351 was power-cycled most recently before the last test. Chip currently in unknown but recently-reset state.

## What we positively know works

1. **Single-byte probe at 0x60** — ACKs on attempt 1, every time, from a fresh chip power cycle. Clean SR=0xC0, ISR=0xD0.
2. **SOFTR-per-transaction prologue** — required for ANY transaction to succeed. Canonical "no-SOFTR" prologue (CR=0x03/0x01 + W1C ISR) fails 100% of the time, even at probe. This contradicts PG090 / `XIic_DynSend` documented pattern but is the bench reality.
3. **Bus scan at 0x60** — ACKs when chip is in a good state. Useful sanity check.

## What we positively know does NOT work reliably

1. **Multi-byte writes (addr + reg + data)** — NAK rate varies from ~33% to ~100% depending on:
   - Which register (some registers seem worse than others — reg 0x10/0x11 NAK more than reg 0x03)
   - What other writes happened recently
   - Whether `si5351_debug_write` is on (debug ON correlates strongly with failure; debug OFF correlated with the only successful init)

## The one and only successful init we ever saw

Boot UART (Edit#2 of this session, SOFTR-per-attempt firmware):

```
=== Phase E2: Si5351 bring-up ===
si5351_probe attempt 1: SR=0xC0 ISR=0xD0
Si5351 probe OK (chip acks at 0x60)
Si5351 init OK — CLK0 should now be at 25.000 MHz.
Phase D ready. UART commands: ...
```

Firmware at that point:
- SOFTR per transaction (CR=0x02→0x01 was original; my edit used SOFTR + CR=EN)
- Back-to-back FIFO pushes (no inter-byte delay)
- `iic_settle(3)` at end
- NO debug printf during init (debug was 0 during init)
- 3 retries on NAK

Immediately after init, `f +1000` was issued. It NAK'd 3/3 retries on reg 0x1A (first PLLA P3 reg). Debug WAS enabled for `f` so we saw per-transaction diag printfs. The chip then progressively wedged — by the next reprogram, even probe failed all 5 attempts and bus scan found nothing. Recovery required full Si5351 3.3V power cycle.

## Failure data we have

### Cold-boot canonical-no-SOFTR (initial state of session)

```
si5351_probe attempt 1: SR=0x44 ISR=0xFF
... (all 5 NAK)
```
SR=0x44: BB=1, RX_EMPTY=1, TX_EMPTY=0 — bus busy, FIFO didn't drain.

### After CR=0x02 → CR=0x03 fix (still canonical, no SOFTR)

```
si5351_probe attempt 1: SR=0x44 ISR=0xFF
si5351_probe attempt 2: SR=0x40 ISR=0xD2
...
```
Pattern alternates BB=0 / BB=1 across attempts. FIFO still doesn't drain. Conclusion: CR=0x02 vs 0x03 doesn't fix root issue.

### SOFTR-per-attempt with debug ON (latest, 2026-05-20 evening)

Reg 0x03 = 0xFF takes 4 tries to succeed:
```
diag reg=0x03 data=0xFF: after_settle: sr=0xC0 isr=0xD2
diag reg=0x03 data=0xFF: after_settle: sr=0xC0 isr=0xD2
diag reg=0x03 data=0xFF: after_settle: sr=0xC4 isr=0xD2
diag reg=0x03 data=0xFF: after_settle: sr=0x40 isr=0xD0    <- ACK!
reg 0x03 succeeded on try 4
```

Reg 0x10 = 0x80 NAKs all 10 tries:
```
diag reg=0x10 data=0x80: after_settle: sr=0x40 isr=0xD2   (×10)
NAK on reg 0x10 after 10 tries (last SR=0x40 ISR=0xD0)
```

The "after_settle" snapshot at end of transaction:
- Success: SR=0x40 (BB=0, RX_EMPTY=1, TX_EMPTY=0) ISR=0xD0 (BNB, NAS, TX_FIFO_HALF_EMPTY, **no TX_ERROR**)
- Failure: SR=0x40 same, ISR=0xD2 (above + **TX_ERROR**)

The TX_ERROR is the only state-diff between success and failure of an outwardly-identical transaction.

## Hypotheses, status

### H1 — JESSINIE clone signal integrity (most likely now)

JESSINIE Si5351A breakouts are known marginal. Doc said: "JESSINIE clones are sometimes marginal at 100 kHz. If 50 kHz works and 100 kHz doesn't, that's a production finding."

Evidence for:
- Probabilistic per-attempt NAK with otherwise-identical retries
- Per-register variability (reg 0x10 worse than reg 0x03)
- Hardware-clone history

Evidence against:
- Probe (single byte) works reliably — would expect SI to affect both
- Failure correlates with debug-printf timing, which suggests something more than pure SI

### H2 — Si5351 inter-transaction timing requirement

Chip needs specific window between transactions; if it's too long (or too short), chip NAKs the next one.

Evidence for:
- Init with no debug printf (back-to-back fast transactions): SUCCEEDED (n=1)
- Init with debug printf (~5 ms gap between transactions): FAILS reproducibly
- The 200 µs inter-transaction delay I added didn't fix things

Evidence against:
- n=1 sample size for "no-printf success"
- We haven't isolated whether removing printf alone fixes it

**NEXT TEST when we resume:** confirm/refute H2 by testing init with diag DISABLED, see if it consistently succeeds. We have NOT actually run this test yet — only inferred from the original one-time success.

### H3 — `xil_printf` itself is breaking something

Beyond just timing — maybe the printf is calling some Xilinx library function that touches a shared resource or triggers a side effect.

Evidence: thin. PS UART is unrelated to PL AXI IIC. But not ruled out.

### H4 — AXI IIC IP needs different config

PG090 has knobs we haven't touched: GIE register, RFD register, dynamic master/slave config. Xilinx's `XIic_DynInit` initializes these; our code doesn't. Maybe the IP is in a sub-optimal config and that exposes us to issues.

### H5 — `iic_settle(3)` insufficient at end of transaction

3 ms is supposedly enough for 3 bytes at 100 kHz. But what if the chip's internal write cycle is longer than the I²C transaction itself? We start the NEXT transaction (SOFTR + start) while chip is still digesting prior write.

The 200 µs inter-transaction delay should help with this but didn't. May need ms-scale.

## What we should NOT do until we understand more

- Burn more chip cycles thrashing. Each failed attempt may be accumulating chip state.
- Add more retries hoping it'll converge. We've seen 0/10 NAK rates — retries don't save us.
- Trust intermediate state. The chip's behavior changes across runs without obvious cause.

## What to research

1. **Si5351A datasheet (Skyworks Si5351A)** specifically:
   - I²C inter-transaction timing requirements (tBUF, plus any chip-specific value)
   - Status register reads — does the chip have a Busy bit we should poll before writes?
   - Errata sheets — is there a known issue with register 0x10 specifically?
   - Whether enabling outputs (OEB) puts the chip in a state where further writes are time-restricted

2. **Xilinx AXI IIC PG090** specifically:
   - When does SOFTR cause incomplete-frame conditions on the bus?
   - Are there known errata for dynamic mode multi-byte writes?
   - GIE / RFD initialization requirements
   - Recommended completion-detection patterns (BNB vs TX_FIFO_EMPTY vs polling SR.BB)

3. **JESSINIE Si5351A breakout** community reports:
   - Are there well-known issues with this specific board?
   - What pull-up resistor values do people typically use?
   - Decoupling cap requirements?

4. **AN619** (Si5351 register map) — anything about ordering of register writes, lockout windows, etc.

5. **Etherkit Si5351 Arduino library source** — what timing/retry strategy does the proven-working community library use? Specifically the i2cWrite() implementation.

## What to do at the bench next session

Listed in order:

1. **Power-cycle chip fully** (3.3V off, 60 s, on). Fresh baseline.
2. **Re-program** current firmware (debug already disabled in init AND `f` handlers).
3. **Observe boot**: probe attempt and init.
   - If init OK → H2 confirmed (debug printf timing was the failure cause). Move on to `f` testing.
   - If init fails → H1 or some other root cause. Pause and consider scope.
4. **If init passes, run on picocom**: `p`, `f 0`, `f +1000`, `f -1000`, `i`. Observe.
5. **Decision tree**:
   - All `f` commands pass → Phase D Stage 1 complete; proceed to sweep.
   - `f` commands NAK with debug off → not a printf-timing issue; need scope.
   - Init NAKs even with debug off → fundamental electrical or chip issue; scope SDA/SCL.

## Bench equipment we should bring out next session

- **Oscilloscope** — capture SDA/SCL during a failing transaction. Look for: signal-integrity issues, chip clock-stretch, NAK ACK-slot levels, rise time.
- **Multimeter** — verify SDA/SCL pull-up voltages, chip VDD.
- **Optional second Si5351 breakout** (Adafruit) — if available, swap to rule out JESSINIE marginality.

## Files at session pause

- `sw/phase-b/src/si5351.c` — SOFTR-per-transaction; back-to-back byte pushes; 200 µs inter-transaction delay; 10 retries with 5 ms gap.
- `sw/phase-b/src/main.c` — `p` (probe) UART command added; debug toggles removed for init AND `f`.
- Build artifacts: `build/vitis-phase-b/vdma_init/Debug/vdma_init.elf` is current (last `xsct tcl/build_phase_b_app.tcl` was at 17:11 then later for the diag enable; latest rebuild needs to be triggered after the debug-removal edits).

**Rebuild needed before next program**: yes — the diag-disable edits to main.c are not yet built.

---

## Research synthesis (2026-05-20 evening, after pause)

Three parallel research agents reported. The combined finding is that we have **three independent reinforcing root causes**, which is why every fix we tried only got us partway:

### Root cause 1 (Xilinx PG090 / XIic_DynSend): our prologue was wrong

The "canonical no-SOFTR prologue" we were using (`CR=0x03 → CR=0x01 → W1C ISR=0xFF → push bytes`) is **Xilinx's NAK/error-recovery sequence, not the happy-path prologue**. Using error-recovery code as a normal prologue leaves the dynamic-master FSM in a half-armed state — START-flagged address in TX_FIFO never triggers START on the wire. That's why even single-byte probe fails 100% under that pattern.

The **actual** Xilinx per-transaction sequence (from `xiic_l.c` `XIic_DynSend`, lines 813–877) has **zero CR writes per transaction**:

```
1. WaitBusFree (poll SR.BB == 0 with timeout)
2. W1C IISR = 0x07  (TX_EMPTY | TX_ERROR | ARB_LOST)
3. Push (DYN_START | addr<<1 | WR) to TX_FIFO
4. Wait for BB == 1
5. W1C IISR.BNB (NOW that bus is busy; clearing before sees stale latch from prior txn)
6. Push payload bytes; last byte ORed with DYN_STOP (0x0200)
7. Poll IISR.BNB for completion (NOT TX_FIFO_EMPTY, NOT SR.BB)
```

And the **one-time DynInit** at boot:

```
RESETR=0x0A → small delay → RFD=15 → CR=0x02 → CR=0x01 → read SR, expect 0xC0
```

Per-transaction SOFTR works as brute-force because it resets the FSM every time, masking the bug. But it introduces other issues (chip wedge from many SOFTRs).

### Root cause 2 (Si5351 datasheet / AN1423): SYS_INIT not polled

Si5351 datasheet: "It is not recommended to read or write registers in RAM through the I²C interface until initialization is complete." Readiness = **Register 0, bit 7 (SYS_INIT) clearing to 0**. Etherkit polls in a tight loop before any other write; we don't.

Symptom match: probe ACKs (I²C state machine up immediately) but reg writes intermittently NAK (chip's RAM not yet initialized). The PLL_RESET in init may re-trigger SYS_INIT, explaining why later writes / post-init `f` commands fail.

### Root cause 3 (JESSINIE clone hardware): inadequate VDD decoupling

Cheap Si5351 clones routinely skip the per-VDD/VDDOx 0.1 µF caps the datasheet requires "as close to the VDD/VDDOx pins as possible without using vias." This produces exactly the "behavior worsens with longer gaps between transactions" fingerprint we observed — supply droop during burst, recovery requires bus idle.

Standard pull-ups for Si5351 at 100 kHz: 1–10 kΩ. We have 2.2 kΩ. With breadboard/long-wire capacitance + FPGA pin load, may want to drop to 1 kΩ for faster rise time.

### Why all three are needed

- Fix only AXI IIC prologue → still hit SYS_INIT race, still hit SI marginality.
- Fix only SYS_INIT → AXI IIC FSM still broken, multi-byte writes still flaky.
- Fix only hardware → AXI IIC FSM still broken.

This is why our session was so confusing: fixing one cause unmasked another. SOFTR-per-transaction "worked" until SYS_INIT race + supply droop killed multi-byte.

---

## Resume plan (next session)

In strict order:

1. **Hardware check (~10 min)**
   - Visual inspect JESSINIE breakout for 0.1 µF cap near Si5351 VDD pin
   - If missing or routed through vias: piggyback solder a 0.1 µF cap directly on VDD pin
   - Scope SDA/SCL idle rise time — if slower than ~1 µs to 90%, drop pull-ups 2.2 kΩ → 1 kΩ
   - Confirm chip is alive (probe ACK still works after hardware changes)

2. **Firmware rewrite — AXI IIC layer (~30 min)**
   - Add new `si5351_iic_init()` matching `XIic_DynInit`: SOFTR → delay → RFD=15 → CR=0x02 → CR=0x01 → SR sanity check
   - Rewrite `si5351_write_reg_once`: zero CR writes; do `WaitBusFree` → W1C ISR=0x07 → push addr → wait BB==1 → W1C BNB → push payload → poll BNB
   - Add `si5351_read_reg()` for SYS_INIT poll
   - Remove ALL per-transaction SOFTR, retry logic, and 200µs inter-transaction delays
   - Optionally remove `iic_settle` entirely (BNB poll replaces it)

3. **Firmware — Si5351 layer (~15 min)**
   - Add `si5351_wait_sys_init()` that polls reg 0 bit 7 in a tight loop with reasonable timeout
   - Call it once after probe ACK, before any init writes
   - Consider calling again after PLL_RESET — datasheet ambiguous but Etherkit doesn't, so probably not needed

4. **Bench validate**
   - Boot should show: probe ACK → SYS_INIT poll completes → init OK with no retries
   - `f` commands should work without retries, without debug printf timing affecting them
   - Repeatable across power cycles

5. **If still flaky after all three fixes:** scope SDA/SCL during the failing transaction. We've ruled out the obvious software causes; remaining suspects are bench-side electrical only.

Files to edit in step 2/3:
- `sw/phase-b/src/si5351.c` — substantial rewrite of `si5351_probe`, `si5351_write_reg_once`; new `si5351_iic_init`, `si5351_read_reg`, `si5351_wait_sys_init`
- `sw/phase-b/src/si5351.h` — new prototypes
- `sw/phase-b/src/main.c` — call `si5351_iic_init()` once at boot before `si5351_probe()`; call `si5351_wait_sys_init()` after probe

Estimated total bench time including hardware: ~60–90 min.

---

---

## Session continuation 2026-05-21 evening

Resumed bench. Major findings:

**Hardware improvements made:**
- Moved I²C pull-ups from chip 3.3V to Zybo 3.3V (independent supply reference). Cleaned up SI immediately — probe ACK clean on attempt 1.

**Firmware improvements made:**
- Removed redundant powerdown-drivers loop (regs 16-23 = 0x80) from init — Etherkit pattern. Init now goes straight: reg 3 → xtal load → PLL params → MS params → CLK_CTRL → PLL reset → enable.
- Added `wait_for_bnb()` helper polling IISR.BNB with 50ms timeout. Replaces fixed `iic_settle` in probe, write_reg_once, and read_reg. **This fixed the "SCL clocks forever after init" symptom** — IP now properly waits for STOP before returning.
- Added `si5351_read_reg()` (dynamic-mode RESTART read) and UART `r <hex>` command.

**The key bench finding — Si5351 missing RESTART:**

After all above fixes:
- Probe clean ACK
- Init reports OK (all writes ACK'd)
- BUT chip output stays at factory-default 1.311 MHz (writes not applied to RAM)
- Reads fail with `rc=-3` (BNB fires, no TX_ERROR, RX_FIFO empty — chip ACKs but doesn't drive data)
- **Crucially: `r 10` (read CLK0_CTRL) killed CLK0 output**, indicating the chip treated our read transaction as a malformed write. The byte after the missed RESTART (`addr+R = 0xC1`) got written into CLK0_CTRL — bit 7 (CLK_PDN) set → output powered down.

This is a **signal-integrity fingerprint, not a chip-state issue.** The chip's I²C state machine isn't sampling SDA cleanly during the START-within-transaction (RESTART) window. Memorialized as [[si5351-chip-missing-restart]].

**Hypothesis update:** SYS_INIT may or may not be a problem. The SI-induced missed RESTART is dominant and may explain everything we've seen — including writes "succeeding" but not taking effect (PLL_RESET write at reg 177 is probably the one being garbled by SI, leaving PLL stuck at factory config).

**Next session priority — hardware first:**

1. **Drop pull-ups 2.2 kΩ → 1 kΩ** (within Si5351 spec, faster rise time). Cheapest fix; should be tried before anything else.
2. **Scope SDA rise time during a read transaction.** Capture the RESTART edge. If rise time >1 µs, that's the smoking gun. If <500 ns and chip still misses RESTART, suspect chip damage.
3. **Add 0.1 µF cap directly to Si5351 VDD pin** if not already present on the breakout.
4. **Re-test reads.** If `r 0` now returns a real Device Status byte, SI hypothesis confirmed.

After hardware: keep all firmware changes from this session. They're improvements regardless. The current code is on top of branch `phase-g-iter1` (last commit `1ddfa4c`), uncommitted.

---

## Session continuation 2026-05-21 — full day

**Wins:**

1. **Root-caused the hand-rolled AXI IIC bug**: our `si5351_write_reg_once` only landed 2 of 3 bytes on the wire (data byte dropped). Scope of writes showed 18 SCL pulses (2 bytes) when 27 (3 bytes) was expected. Chip ACK'd both transmitted bytes, code returned "success," but chip RAM never updated. **The IP-config path we were using had some subtle bug; rather than chase it, we replaced with XIic library.**

2. **Refactored `si5351.c` to use XIic library** for all writes/reads. Bench-validated end-to-end:
   - `W 1b ab` → `X 1b` returns `0xAB`
   - Full 22-register manual config sequence: every `W <reg> <val>` succeeded, every readback (`X <reg>`) returned exactly the written value
   - Probe via `XIic_Send + XIic_Recv` of reg 0 returns real Device Status byte (0x11)

3. **Added bench infrastructure**:
   - `R <hex>` UART command — bare 2-byte read (hand-rolled, for diagnostic)
   - `X <hex>` UART command — XIic library read
   - `W <reg> <val>` UART command — XIic library write
   - SCPI access to Rigol DHO814 via `/dev/usbtmc0` (works after `sudo chmod 666 /dev/usbtmc0` and any Local-key press if SCPI gets locked)
   - Python termios-based UART driver as picocom alternative

4. **Established that the chip pin assignment is correct**: AXI IIC IP on Pmod JD (PL), pins U14 (SDA) / U15 (SCL). JF is MIO-only — not us.

**Critical caveats / what we never did:**

- Never enabled CLK0 with a fully-working chip. Last attempt on board 2 wedged the chip post-`W 3 fe` (probably JESSINIE VDD decoupling brownout when output started drawing current).
- Never measured CLK0 frequency with confidence — saw ~2.41 kHz which was probably chip running on fallback reference due to LOS=1.
- Phase D ppm sweep not run.

**Hardware status — burned all three JESSINIE boards:**

- Board 1 (original): I²C read path damaged. Writes seemed to work (chip output 1.311 MHz from factory). Crystal driver was working. Crystal transplanted off this board to Board 2 mid-session.
- Board 2: I²C path fully validated (both reads and writes work via library). Crystal driver damaged (LOS=1 even with known-good crystal swapped on).
- Board 3: SDA-stuck-low wedge mode. Any transaction wedges it.

**Justin ordered fresh non-JESSINIE boards 2026-05-21 evening, ETA next day.**

**Resume plan when new boards arrive:**

1. Connect new board. Verify pull-ups still on Zybo 3.3V (not chip VIN). Verify wiring: SDA→JD7(U14), SCL→JD8(U15), VIN→3.3V, GND→common.
2. Reprogram Zybo with current firmware. Firmware state on branch `phase-g-iter1`, uncommitted:
   - `sw/phase-b/src/si5351.c` — refactored to use XIic library for writes (`si5351_lib_write_reg`) and reads (`si5351_read_reg`), probe via XIic_Send+XIic_Recv of reg 0.
   - `sw/phase-b/src/main.c` — `R`, `X`, `W` UART commands added; **boot auto-init is currently SKIPPED for diagnostic** (search for "AUTO-INIT SKIPPED" comment to restore).
3. Boot output should show: probe ACK with Device Status (LOS=**0** ideally on a healthy crystal).
4. Send `X 0` from picocom or `printf "X 0\r" > /dev/ttyUSB1` — expect val != 0x11 (specifically LOS bit = 0).
5. Run the 22-write config sequence (full sequence in earlier transcript or in `si5351_init_25mhz_clk0` code).
6. `W 3 fe` to enable CLK0. Watch for chip wedge — if it wedges, add 0.1 µF cap to chip VDD pin (JESSINIE-class issue per agent 1 research) before continuing.
7. Verify 25 MHz via scope: `echo ":MEAS:FREQ? CHAN3" > /dev/usbtmc0; sleep 0.5; head -c 50 /dev/usbtmc0`
8. **Restore boot auto-init** — remove the "AUTO-INIT SKIPPED" diagnostic, replace with normal `rc = si5351_init_25mhz_clk0(IIC_ADV7393_BASE);` call.
9. Test `f +1000` etc — `si5351_set_freq_hz` routes through XIic library now, should work.
10. Run Phase D ppm sweep (UART loop sending `f -50` through `f +50` in 10 ppm steps, capturing scope frequency at each).

If new board's chip is also fragile in the same ways, fall back to:
- Verify VDD decoupling visually before powering (look for 0.1 µF caps near chip VDD pins)
- Reduce CLK0 drive strength from 8 mA to 2 mA (CLK0_CTRL bits 1:0 = 00 → write `W 10 4C` instead of `W 10 4F`)

---

## Session continuation 2026-05-21 morning

Bench resumed. Built diagnostic infrastructure and ran A/B test of hand-rolled IIC code vs Xilinx XIic library.

**Hardware changes this session:**
- I²C pull-ups verified moved to Zybo 3.3V (already done end of prior session).
- SDA rise time scope-measured: **0.65 µs** at idle high. Within I²C spec (1 µs max at 100 kHz). So SI rise time is NOT the bug.

**Firmware changes this session:**
- Added `wait_for_bnb()` helper polling IISR.BNB with 50ms timeout. Replaces fixed `iic_settle` everywhere — IP now correctly waits for STOP before returning, eliminated "SCL clocks forever" bug.
- Added `R` UART command (uppercase) — bare 2-byte read with no pre-write, tests basic read direction at hand-rolled level.
- Added `X <hex>` UART command — XIic library-based read using `XIic_Send` + `XIic_Recv`. Battle-tested implementation.
- Removed AN619 powerdown-drivers loop (regs 16-23 = 0x80) from init — Etherkit/Adafruit don't do this step; reg 3 = 0xFF is sufficient.

**Pin verification:**
- AXI IIC IP is on Pmod JD (PL fabric): SDA = PACKAGE_PIN U14 (JD7), SCL = PACKAGE_PIN U15 (JD8). Correct for PL-side IP.
- JF is the MIO Pmod (PS hard IP only); not in our path. Pin config is consistent.

**Scope findings:**

1. **Hand-rolled read (`R` command):** Scope shows only ~18 SCL pulses = 2 bytes on the wire. Should be 4 bytes for proper read. Code is generating START+addr+W and reg pointer, but the RESTART+addr+R and STOP+count entries in TX_FIFO are NOT being consumed by the IP. Probable bug in our framing OR config (RFD=15 write didn't fix it).

2. **XIic library read (`X 0` command):** Scope shows ~36 SCL pulses = 4 bytes with visible RESTART transition. Library framing is correct.

**UART results:**
- Hand-rolled `R`: `bare-read: SR=0x40 ISR=0xD0 (BNB-on-poll=yes); RX_FIFO empty (no data byte received)`
- Library `X 0`: `XIic read reg 0x00: sent=1 recvd=0 val=0xAA`

Library successfully generates the full 4-byte transaction with RESTART, but **chip still doesn't return data**. This eliminates Zybo IP framing as the bug.

**Definitive A/B established:**
| Test | Wire | RX | Conclusion |
|---|---|---|---|
| Hand-rolled | 2 bytes (bug) | empty | Our code has framing issue too, BUT |
| XIic library | 4 bytes + RESTART | empty | Chip is the dominant problem |

**Strongest hypothesis: chip damage from ~24 hours of bench abuse.** Many SOFTRs, supply droop, ~10+ power cycles, repeated wedges. Read-direction output stage may be marginal/damaged while basic addr-decode still works. Library writes "succeed" (chip ACKs) but reads "fail" (chip doesn't drive data).

Independent evidence consistent with chip damage: init writes appear to ACK but chip output stays at factory default 1.311 MHz — writes aren't actually changing RAM. Like the chip is in some half-locked state.

**Plan for next session (chip swap):**

Justin has a spare Si5351 board. Definitive A/B test:

1. Power down current chip, disconnect 3.3V
2. Disconnect SDA/SCL from current chip
3. Wire spare chip: SDA → JD7, SCL → JD8, VIN → 3.3V, GND → GND
4. Pull-ups stay on Zybo 3.3V (already wired)
5. Power up new chip
6. Reprogram board (firmware unchanged from this session)
7. Send `X 0` — if returns sane Device Status byte → chip swap fixed it, full stack validated
8. If new chip also fails → BD config, IP version, or wiring problem we missed. Will need scope-decode of the failing transaction to go deeper.

**Open firmware bugs deferred to after chip-swap A/B:**
- Hand-rolled `si5351_read_reg`: only sends 2 bytes when it should send 4. Root cause unknown — could be CR.MSMS handling, AXI IIC dynamic-mode subtlety with read-direction byte after pre-write.
- Hand-rolled init: writes ACK but chip output doesn't reprogram (likely chip-side issue, but worth re-testing with fresh chip).

If new chip works, both of these might evaporate (chip-state-dependent behavior we couldn't repro with damaged chip).

---

## Research sources

- [PG090 v2.0 AXI IIC](https://docs.amd.com/v/u/2.0-English/pg090-axi-iic) — Programming Sequence, Dynamic Controller Logic Flow
- [xiic_l.c (embeddedsw)](https://github.com/Xilinx/embeddedsw/blob/master/XilinxProcessorIPLib/drivers/iic/src/xiic_l.c) — `XIic_DynInit` (984–1022), `XIic_DynSend` (813–877), `XIic_WaitBusFree` (1062–1074)
- [xiic_l.h](https://github.com/Xilinx/embeddedsw/blob/master/XilinxProcessorIPLib/drivers/iic/src/xiic_l.h) — register offsets/masks
- [Si5351A datasheet (Skyworks)](https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/data-sheets/Si5351-B.pdf)
- [AN1423 Si5350/Si5351 FAQ](https://www.skyworksinc.com/-/media/SkyWorks/SL/documents/public/application-notes/AN1423_Si5350_Si5351_FAQs.pdf)
- [AN619 Si5351 Register Map](https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/application-notes/AN619.pdf)
- [Etherkit Si5351Arduino src/si5351.cpp](https://github.com/etherkit/Si5351Arduino/blob/master/src/si5351.cpp) — reference implementation, SYS_INIT poll pattern
- [Adafruit_SI5351 library](https://github.com/adafruit/Adafruit_Si5351_Library/blob/master/Adafruit_SI5351.cpp)
- [Xilinx Forums #703706: bus stuck at busy](https://forums.xilinx.com/t5/Embedded-Processor-System-Design/What-happened-to-my-AXI-IIC-design-Bus-stuck-at-busy/td-p/703706)
