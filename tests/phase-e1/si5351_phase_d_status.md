# Phase D — Stage 1 status (2026-05-20 evening)

**Verdict:** Phase D Stage 1 firmware code complete. Bench-validation **BLOCKED** on
an AXI IIC + Si5351 multi-byte transaction issue that we partially diagnosed but
did not close. Session-end notes for resumption.

## What works

- `si5351_set_freq_hz(u32 target_hz)` — Etherkit-style PLL+MS register math, computed
  from scratch for any target frequency. PLLA pinned at 800 MHz integer mult,
  MS0 in fractional mode (c=1,000,000). Implementation in `sw/phase-b/src/si5351.c`.
- UART command parser in `main.c` — non-blocking polling of PS UART_1 FIFO,
  accepts `f <signed_ppm>`, `i`, `?` commands.
- Diagnostic switch `si5351_debug_write` that prints per-byte SR/ISR snapshots
  during each multi-byte transaction. Flipped on for one transaction at a time
  by the `f` command handler.

Stage 1 smoke test never completed because writes started NAKing before the
output frequency could be confirmed-changed on scope.

## What we observed

Three distinct failure modes across the session:

1. **Probe NAKs all 5 retries.** Chip was completely silent. Recovery: bench-side
   Si5351 power-cycle. Suggests chip wedged into a bad I²C state from prior
   transaction sequences.

2. **Probe ACKs once, then init NAKs partway.** First few register writes succeed,
   then one or more NAK. Some recover on retry, some don't. Failure register
   varies — saw 0x1A, 0x12, 0x30 across different attempts.

3. **Init succeeds, but first write from `f` command NAKs the address byte.**
   The same 0x60 address that ACKed for the 1-byte probe and the 15 init writes
   NAKs as soon as we try to write again after the UART idle period.

Diagnostic patterns:

- `ISR=0xD6` with bit 1 (TX_ERROR) set after byte 1 of a write → chip NAKed
  the address byte.
- `SR=0x44` (TX_FIFO NOT empty, BB set) at the end of a failing transaction →
  the IP halted mid-stream, bytes 2 and 3 sat undrained in TX_FIFO.
- Probe-only diagnostic occasionally returned `ISR=0xFF` (all bits set) right
  after we W1C'd them, suggesting residual IP state from prior transactions
  was constantly re-asserting interrupts.

## Research findings (delegated agent, late session)

**Canonical cause:** per-transaction SOFTR (which my early code did) releases
SDA/SCL without issuing a proper I²C STOP. If the Si5351's I²C state machine
was mid-frame when SOFTR fires, the chip is left expecting bits that never
come — the next START gets NAKed because the chip sees it as a continuation
of the broken prior frame.

**Canonical fix** (from PG090 + Xilinx embeddedsw `XIic_DynSend` reference):

- SOFTR exactly once at boot, never per-transaction.
- Per-transaction prologue: `CR = TX_FIFO_RESET (0x02) → CR = EN (0x01) → W1C all
  ISR bits`. No SOFTR. No bus glitch.
- Push all bytes back-to-back into TX_FIFO. Dynamic mode autonomously drains.
- Poll ISR.BNB (bit 4, Bus Not Busy edge-triggered) for completion.
- SOFTR only on the failure path, as bus recovery.

I implemented this canonical pattern in the final firmware variant on the
branch (commit pending). Bench result: probe needed 4 attempts to ACK,
then init failed at reg 0x12 (CLK2_CONTROL). Failure pattern shifted but
the bus is still NOT clean.

## Best current hypothesis

The Si5351 chip has accumulated bad I²C state from a long bench session
(~2 hours, many power cycles, many failed transactions, bus-side fault
scenarios). The chip may be marginally damaged or stuck in a stale state
that even our cleanup-on-boot doesn't recover.

**Strongest evidence for this:** Phase C-lite passed earlier today with the
same code base. Three sub-phases (A, B, C-lite) shipped before this debug
session. So the canonical write path DID work; we lost it after extensive
hammering.

**Less likely but possible:** the canonical-pattern code I implemented has
a subtle bug (e.g., CR=0x02 needs more settle time before CR=0x01) and the
research agent's pattern is close-but-not-exact for this specific IP version.

## Resume strategy (next session)

In priority order:

1. **Fresh-state bench test of the canonical-pattern firmware.**
   - Power off everything (Zybo USB unplugged, Si5351 3.3V off) for 60 seconds
   - Power on cleanly
   - Load the committed canonical-pattern firmware
   - If probe ACKs first attempt + init completes cleanly: hypothesis 1 confirmed,
     resume Phase D Stage 1 smoke test (`f +1000` etc.) immediately
   - If still fails: hypothesis 2 confirmed, code-side debug needed

2. **If chip is reproducibly broken** even after cold-boot, swap to a second
   JESSINIE Si5351 board (if available) to rule out chip damage. If the second
   board works, mark the first as bench-collateral damage.

3. **If code-side fix needed**, the most likely culprit is the CR prologue.
   Test variants:
   - `CR=0x03` (both bits) for a few µs, then `CR=0x01` (drops reset bit only)
   - `CR=0x02` with explicit ~10 µs delay before `CR=0x01`
   - Skip the CR writes entirely after boot; rely on TX_FIFO drain semantics
   - Switch to `XIic_Send` library calls (~30 min) — most expensive but
     battle-tested

4. **If Stage 1 passes**, move to Stage 2:
   - Add `hdl/si5351_freq_counter.v` (sample-on-tick 32-bit counter, AXI GPIO 3 readout)
   - BD edit + Vivado rebuild
   - Firmware counter readback + sweep automation
   - Run ±50 ppm sweep, fit, evaluate against spec doc §5 pass criteria

## Files touched this session (all uncommitted as of session end)

- `sw/phase-b/src/si5351.h` — added `si5351_set_freq_hz` and `si5351_scan_bus` prototypes
- `sw/phase-b/src/si5351.c` — implementations + diagnostic switch; per-transaction
  prologue currently in canonical form (CR=0x02 → CR=0x01 → W1C ISR), no SOFTR
- `sw/phase-b/src/main.c` — UART command parser, `f <ppm>` handler with diag toggle
- `tests/phase-e1/si5351_phase_d_execution.md` — my deviations doc

## Open items for memory

- The **2.2 kΩ pull-ups** on SDA/SCL are still in place; bus signal quality
  is excellent on scope. **Not a pull-up issue.**
- The Si5351 has been **power-cycled approximately 6-8 times** today. May or
  may not be relevant to repeatability.
- `phase-g-iter1` branch is where all this work lives. Phase C-lite passing
  commit is `35d41ef`. Phase D WIP commit (about to make) is the resumption
  point.
