# Si5351 Phase D — Next session handoff

**Status:** OPEN — bench-blocked on intermittent Si5351 I²C ACK failures. Previous session diagnosed the root-class problem (per-transaction SOFTR anti-pattern) and implemented the canonical fix from PG090, but the post-fix behavior still has issues — probe needs retries, init fails at register 0x12.

**This doc is the resumption point for a fresh agent.** Sections 1–3 are onboarding; section 4 onward is the actual bench session plan.

---

## 1. Project onboarding (read this first — ~5 min)

### What this project is

**Schindler 2.0** — an FPGA-based professional video frame rate converter, replacement for the discontinued Cal Media MVPHD-24. Drives film-set CRT monitors at 24 fps cadence converted from modern HDMI sources. Target platform: Zynq-7020 on Trenz TE0720 SOM, with a Digilent Zybo Z7-20 as bench-development platform.

Core product requirement: **genlock to film camera reference** (LTC, tri-level analog sync, black burst, word clock, SDI VITC). This isn't a stretch goal — it's the core feature. The architecture is documented in [`docs/sync-architecture.md`](../../docs/sync-architecture.md).

### Where you are in the broader plan

The "Phase E1/E2 sync spike" was a multi-day effort to validate the production sync architecture using the FPGA's MMCM as a stand-in actuator (the Si5351 dev board hadn't arrived yet). Result: **MMCM bench-falsified as production actuator** — its psincdec slew rate is too slow to follow a Bresenham-divided source-vsync reference. The architectural conclusion is documented in [`tests/phase-e1/phase_e2_psincdec_limit.md`](phase_e2_psincdec_limit.md).

The Si5351 board arrived. **Si5351 is the production actuator.** Phases A, B, and C-lite of [`docs/si5351-bench-bringup.md`](../../docs/si5351-bench-bringup.md) all passed earlier today:

- **Phase A** (commit `f021ad2`): chip alive, I²C probe ACKs at 0x60.
- **Phase B** (commit `3656870`): 10 MHz on CLK0 verified with scope.
- **Phase C-lite** (commit `35d41ef`): Si5351 reconfigured to 25 MHz, drives FPGA PLL via Pmod JB Pin 7 (PACKAGE_PIN Y7, MRCC bank 13). LD3 lit = MMCM locked to external clock.

**You are now in Phase D** — open-loop pullability characterization. The full spec is at [`tests/phase-e1/si5351_phase_d_pullability.md`](si5351_phase_d_pullability.md). Phase D needs `si5351_set_offset_ppm()` to work, plus a sweep across ppm offsets to confirm Si5351's fractional divider produces clean ppm-accurate output.

### Branch + commits

- **Branch:** `phase-g-iter1`
- **Last passing commit:** `35d41ef` (Phase C-lite PASS)
- **Last uncommitted WIP:** `1ddfa4c` (Phase D Stage 1 firmware — `si5351_set_freq_hz` helper, UART command parser for `f <ppm>`, diagnostic switch). This is where you start. The canonical PG090 fix was implemented but the work was not committed cleanly at session end.

### Key docs to know exist (don't read in full; just be aware)

- [`docs/sync-architecture.md`](../../docs/sync-architecture.md) — THE plan; the architecture the whole sync subsystem is built around
- [`docs/si5351-bench-bringup.md`](../../docs/si5351-bench-bringup.md) — Si5351 bring-up plan, Phases A–E
- [`tests/phase-e1/si5351_phase_d_pullability.md`](si5351_phase_d_pullability.md) — Phase D spec (the test you're trying to run)
- [`tests/phase-e1/si5351_phase_d_status.md`](si5351_phase_d_status.md) — prior session-end notes (the immediate prior agent's diagnosis)
- [`tests/phase-e1/phase_e2_psincdec_limit.md`](phase_e2_psincdec_limit.md) — why Si5351 matters (MMCM failure characterization)

### Hardware setup at the bench

- Zybo Z7-20 board, USB-attached to host.
- JESSINIE Si5351A breakout, wired to Pmod JD (I²C — SDA/SCL/3.3V/GND on JD7/JD8/power/GND).
- Si5351 CLK0 → SMA → coax → Pmod JB Pin 7 (clock input to FPGA, MRCC pin Y7). GND on Pmod JB Pin 11.
- **External 2.2 kΩ pull-ups on SDA and SCL.** These are critical — FPGA internal weak pull-ups (~50 kΩ) are insufficient.
- ADV7393 breakout: present but not powered. The ADV7393 has its own I²C issues (separate session, dead chip suspected) but does NOT affect Si5351 work as long as ADV7393 isn't actively driving the bus. Confirm ADV7393 power is OFF.

---

## 2. The problem you're inheriting

### What works

- **Probe ACKs** at 0x60 (sometimes — see below).
- **`si5351_set_freq_hz(u32 target_hz)`** — full Etherkit-style PLL+MS register math written and committed (uncommitted as of session end). PLLA pinned at 800 MHz integer mult, MS0 in fractional mode (c=1,000,000).
- **UART command parser** — non-blocking, accepts `f <signed_ppm>`, `i` (info), `?` (help).
- **Diagnostic switch** `si5351_debug_write` — prints per-byte SR/ISR snapshots during multi-byte transactions. Flipped on by the `f` handler for one transaction at a time.

### What's broken

Three failure modes the prior agent observed, in degrees of concern:

1. **Probe NAKs all 5 retries** — chip completely silent. Recovery: bench-side Si5351 power cycle. Suggests chip wedged in bad I²C state.
2. **Probe ACKs once, then init NAKs partway** — first few register writes succeed, then one fails. Failure register varies: saw 0x1A, 0x12, 0x30 across attempts.
3. **Init completes, but first `f` command after UART idle period NAKs the address byte** — same 0x60 that just ACKed 15 register writes now NAKs.

### The diagnosis the prior agent reached

**Canonical cause (PG090 + Xilinx embeddedsw):** per-transaction SOFTR releases SDA/SCL without issuing a proper I²C STOP. If chip was mid-frame when SOFTR fires, chip is left expecting bits that never come; next START is NAKed because chip sees it as a continuation of the broken prior frame.

**Canonical fix:** SOFTR exactly once at boot, never per-transaction. Per-transaction prologue is `CR = TX_FIFO_RESET (0x02) → CR = EN (0x01) → W1C all ISR bits`. Push all bytes back-to-back. Poll `ISR.BNB` (bit 4, Bus Not Busy edge-triggered) for completion.

**Result of the canonical fix:** failure pattern *shifted* but didn't disappear. Probe now needs ~4 attempts to ACK; then init fails at register 0x12.

### Why this matters

Si5351 is the unblocker for the whole sync project. Until Phase D passes and Phase E validates the actuator swap, [`phase_e2_psincdec_limit.md`](phase_e2_psincdec_limit.md) shows the picture has a visible vertical-wrap failure that's blocking everything downstream. **Time spent unblocking Si5351 is time spent unblocking the entire project.**

That said: this is also a JESSINIE breakout (clone of Skyworks's Si5351A), and the chip has been power-cycled 6–8 times today through extensive failed-transaction sequences. Possibility of chip damage is non-zero.

---

## 3. The hypothesis space you're working in

Three hypotheses ranked by likelihood:

### Hypothesis 1 (most likely): Bus-state pollution accumulated during session

The chip has accumulated bad I²C state across many SOFTR-during-transaction events. Even though the current code uses the canonical pattern, the chip itself may be in a stale state that survives short power cycles. **A long cold boot (5–10 min, not 60 seconds) should resolve this if it's the cause.**

### Hypothesis 2: Implementation bug in the canonical pattern

The PG090-canonical pattern is correct in principle, but the implementation may have a subtle bug:

- W1C of ISR may only clear specific bits, not all bits. Residual bits from prior transactions can fire mid-transaction and confuse the IP.
- Timing between `CR=0x02` (TX FIFO reset) and `CR=0x01` (enable) may need an explicit µs-scale delay.
- BNB polling may have an edge-detection issue.

### Hypothesis 3: Chip is marginally damaged

Si5351 silicon doesn't usually fail from logic-level overstress, but extended bench iteration with failed transactions can accumulate stress (especially if any rail glitches occurred). If hypotheses 1 and 2 are ruled out and failure persists, swap the breakout.

---

## 4. Bench session plan

The plan: **structured go/no-go gating, not free-form debugging.** Each gate either passes (proceed to next) or fails (diagnose the specific failure). The session has a defined endpoint regardless of outcome.

### Pre-session checks (5 min)

- [ ] Branch is `phase-g-iter1`, head is at or near `1ddfa4c` (the WIP commit with the canonical fix).
- [ ] Bench wiring per §1 still in place — verify visually before powering anything on.
- [ ] ADV7393 power is OFF. Multimeter the chip's VAA / VDD pins to confirm 0V.
- [ ] External 2.2 kΩ pull-ups on SDA and SCL still connected.

### Pre-session firmware check — verify W1C clears ALL ISR bits (5 min)

This is the cheapest possible "did the canonical pattern implementation get this right?" check.

1. [ ] Find the `XIic_WriteReg(IIC_BASE + IIC_ISR_OFFSET, ...)` calls in `sw/phase-b/src/si5351.c` (or wherever the agent put the W1C logic).
2. [ ] Confirm the value written to ISR is `0xFFFFFFFF` (or at least `0xFF` if it's a byte-wide write), which clears ALL bits via Write-1-to-Clear semantics.
3. [ ] If the code clears only specific bits (e.g., `0x10` for BNB only), **fix it to clear all bits** before going any further. Build the firmware. This may be the entire fix.

```c
// Wrong:
Xil_Out32(IIC_BASE + IIC_ISR_OFFSET, IIC_INTR_BNB_MASK);

// Right:
Xil_Out32(IIC_BASE + IIC_ISR_OFFSET, 0xFFFFFFFF);
```

### Cold boot (extended — 10 min minimum)

The prior session noted a 60-second cold boot. Try longer this time:

1. [ ] Unplug Zybo USB (kill JTAG + UART + Zybo power).
2. [ ] Disconnect Si5351 3.3V supply (kill chip power).
3. [ ] **Wait 5 minutes minimum.** During this time, the chip's internal state machine fully releases. Even if it looks dead at 1 min, give it the full window.
4. [ ] Reconnect Si5351 3.3V supply *first*. Wait 30 seconds for chip to reach steady-state idle.
5. [ ] Reconnect Zybo USB. Wait for enumeration.
6. [ ] Open serial terminal: `picocom -b 115200 /dev/ttyUSB1`.
7. [ ] Program board: `xsct tcl/program_phase_b_full.tcl` (note: `_full` — the non-full version only loads bitstream, not firmware).

### Gate 1 — Single probe at 0x60 (5 min)

1. [ ] Watch UART for the firmware's startup banner and probe attempt.
2. [ ] Record: does the first probe ACK, or NAK? How many retries needed if any?

**Outcomes:**

- **First-attempt ACK** → Excellent. Bus is healthy at boot. Proceed to Gate 2.
- **2–3 retries to ACK** → "Wakeup quirk" pattern. Chip needs a few transactions to come out of stale state. Not ideal but workable; proceed to Gate 2 with a flag that startup may need a warmup sequence in production.
- **All retries NAK** → Either chip is dead, or cold boot wasn't long enough. Try another 10-min cold boot. If second cold boot also fails to produce any ACK → consider swapping the breakout (Hypothesis 3 confirmed).

### Gate 2 — Single register READ (5 min)

If Gate 1 passes, verify the chip can ACK reads (different code path than writes):

1. [ ] From UART, send a command to read register 0x00 (Status / Device Status Register on Si5351). If no such command exists in the firmware, add a quick `r <reg>` command that does a single XIic_Recv with addr 0x60 and one-byte read.
2. [ ] Confirm ACK and a returned byte value.

**Outcomes:**

- **ACKs and returns a value** → Read path works. Proceed to Gate 3.
- **NAKs the address** → Chip ACKs probe but not reads. Unusual. Check that the `f` parser isn't somehow corrupting the IIC state before the read.
- **ACKs address but read times out** → Chip is in a confused state. Bus-cycle test fail; consider chip swap.

### Gate 3 — Single register WRITE to a benign register (5 min)

1. [ ] Send a single-register write that's safe to do at any time. Try register `0x03` (Output Enable Control) = `0xFF` (disable all outputs).
2. [ ] Read back register 0x03 to verify the write took effect.

**Outcomes:**

- **Writes and reads back correct** → Single-register write path works. Proceed to Gate 4.
- **Writes but read-back returns old value** → Write transaction "succeeded" (no NAK) but the byte didn't reach the chip's register. Likely an internal IIC FIFO or framing issue. Scope the transaction.
- **Write itself NAKs** → Multi-byte path (address + register + data) has the bug. Investigate canonical pattern implementation more carefully.

### Gate 4 — Multi-byte write (10 min)

The init sequence does multi-byte writes (address + register + multiple data bytes for the PLL/MS dividers). Test one of these:

1. [ ] Pick a single PLL or MS register block (e.g., MS0_P1 = 8-byte write starting at register 0x2A). Use the existing `si5351_set_freq_hz()` to compute the bytes.
2. [ ] Trigger the write with `si5351_debug_write` flag ON.
3. [ ] Capture the UART output of per-byte SR/ISR snapshots.

**What to look for in the diagnostic output:**

- ISR after byte 1 (address): should NOT have bit 1 (TX_ERROR) set. If set → chip NAKed the address.
- ISR after byte 2 (register): should show TX_FIFO partially drained but no TX_ERROR.
- ISR after bytes 3+: should show TX_FIFO continuing to drain.
- SR at end: should show TX_FIFO empty (bit 7 set) and BB cleared.

If you see `SR=0x44` (TX_FIFO not empty, BB set) at end → the IP halted mid-stream. Bytes 2 and onward sat in TX_FIFO. The chip stopped clocking after some point.

### Gate 5 — Full init sequence with per-register UART output (15 min)

If Gates 1–4 all pass:

1. [ ] Run the full init sequence one register at a time, with `si5351_debug_write` ON for the first failure (if any).
2. [ ] Record which register failed (if any) and the SR/ISR state at failure.

**If init completes cleanly** → Phase D Stage 1 firmware is working. Proceed to the sweep test (next section).

**If init fails at register 0x12 again** → that specific register is reproducibly the failure point. Two follow-ups:
- Scope SDA/SCL during the 0x12 write attempt; capture START, address, register, data bytes, ACK slots.
- Try writing 0x12 first in the sequence (before any other registers). If it still NAKs → some specific issue with that register. If it ACKs when written first → some prior register's state causes the chip to NAK 0x12.

### Decision point — lower SCL rate fallback (10 min)

If gates 1–5 all fail in some combination and Hypothesis 3 (chip damage) hasn't been confirmed yet, **try lowering the I²C SCL rate**:

1. [ ] In Vivado, find the `axi_iic_adv7393` (or `axi_iic_si5351` if renamed) IP config. The clock divisor is computed from the IP's `C_SCL_INERTIAL_DELAY` and clock-frequency parameters.
2. [ ] Change configuration to target **50 kHz SCL** (or 25 kHz if 50 doesn't help).
3. [ ] Rebuild bitstream. ~25 min in Vivado.
4. [ ] Re-run Gates 1–5 against the slower-SCL build.

JESSINIE clones are sometimes marginal at 100 kHz. If 50 kHz works and 100 kHz doesn't, that's a production finding (constrain SCL to ≤50 kHz in production firmware) and the path forward is clear.

### Decision point — `XIic_Send` library swap (30 min)

If hand-rolled canonical pattern continues to fail across all gates after lower SCL, **swap to the Xilinx `XIic_Send` / `XIic_Recv` library**:

- These library functions are battle-tested across many Xilinx silicon revisions and slave chips.
- They handle the canonical pattern internally with all the timing/sequencing details correct.
- ~30 min refactor to use them in place of the hand-rolled code.
- If library works where hand-rolled doesn't → hand-rolled implementation has a subtle bug we missed.
- If library also fails → chip is the issue.

### Chip-swap decision point

After all of the above:

- **Gates 1–5 all pass at any point** → Phase D Stage 1 done. Proceed to sweep.
- **Cold boot + library swap + lower SCL all fail** → Chip is damaged. Order a second JESSINIE Si5351 breakout (or any Si5351A breakout — Adafruit's is well-trusted). Session ends; resume when new board arrives.

---

## 5. If Gates 1–5 all pass — running the Phase D sweep

Per [`si5351_phase_d_pullability.md`](si5351_phase_d_pullability.md) §5:

1. Sweep `f <ppm>` across 11 points: `-50, -40, -30, ..., +50`.
2. At each point, capture 30 seconds of timestamp data via the existing FPGA `vsync_timestamp.v` infrastructure.
3. Compute achieved ppm offset per point.
4. Fit `achieved = slope × commanded + intercept`.

**Strict pass criteria:**

- Slope 0.99–1.01 (within 1% of 1.0)
- |intercept| ≤ 5 ppm
- R² ≥ 0.999
- Max residual ≤ ±1 ppm

If any criterion fails by more than a small margin, investigate before declaring done.

**Don't accept a qualified pass.** MMCM Phase 5 accepted a qualified pass (slope 1.08, R² 0.995, intercept +102 ppm) and that became the early-warning of the Hypothesis B failure later. For Si5351, the math says clean pass should be achievable.

---

## 6. Session pass/fail criteria

The session has a defined endpoint regardless of outcome:

| Final state | Declare |
|---|---|
| Gates 1–5 all pass + Phase D sweep meets strict criteria | Phase D done. Commit work. Update [`docs/si5351-bench-bringup.md`](../../docs/si5351-bench-bringup.md). Phase E ready to start next session. |
| Gates 1–5 pass + sweep meets criteria with small qualifiers | Phase D qualified pass. Investigate qualifiers before Phase E. |
| Gates fail but lower SCL or library swap unblocks them | Document the workaround in the Phase D writeup; production firmware needs the constraint applied. |
| All paths fail (canonical, library, lower SCL, two cold boots) | Chip damaged. Order replacement. Session ends with documented dead-end. |

---

## 7. Things you should NOT do this session

- **Don't keep iterating on bench-side firmware variants past the prescribed branches above.** If gates 1–5 + library + lower SCL all fail, the answer is "swap chip," not "try another canonical-pattern variant."
- **Don't power-cycle the chip more than necessary.** Each power cycle is bench iteration; too many in one session is what caused the prior session's accumulating state issues.
- **Don't accept a qualified pass on Phase D sweep** without investigating the qualifier. MMCM's qualified pass was load-bearing on the eventual show-stopper.
- **Don't commit broken intermediate states without clear status markers.** Each commit message should make the state clear so the next handoff can resume from a known point.

---

## 8. Files to commit at session end

Whichever outcome:

- `sw/phase-b/src/si5351.c` — final implementation of `si5351_set_freq_hz` + offset helper.
- `sw/phase-b/src/si5351.h` — exposed prototypes.
- `sw/phase-b/src/main.c` — UART command parser updates.
- `tests/phase-e1/si5351_phase_d_results.md` — session writeup with which gates passed/failed and final verdict.
- `tests/phase-e1/si5351_phase_d_sweep.csv` (only if Phase D sweep ran) — 11 rows of commanded/achieved/residual.

---

## 9. Critical context for any decisions you make at the bench

**The Si5351 path is the unblocker.** The sync project's stop condition ("phase offset persists and is entirely unacceptable") is waiting on Phase E (closed-loop with Si5351 as actuator). Phase E depends on Phase D. Phase D depends on Phase D Stage 1 (the firmware piece you're working on now).

**Time is real.** Two hours of bench iteration on a possibly-damaged chip is two hours not spent on Phase E. The chip-swap option ($15, 2 days) is a real path forward — don't burn an entire afternoon if the bench gives you decisive "chip is broken" data.

**The architecture is sound.** Even if this specific breakout is damaged, the architecture (Si5351 fractional divider replacing MMCM psincdec) is correct and a replacement breakout will work. The slowdown is annoying but doesn't invalidate any of the planning.

**One focused session, structured gates, defined endpoint.** That's the discipline that's been working for this project. Don't drift into open-ended debug.

Good luck.
