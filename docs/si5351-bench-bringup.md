# Si5351 bench bring-up

**Status:** PENDING board arrival (JESSINIE Si5351A 3-channel breakout, ordered ~2026-05-18). This doc is the starting point; bench work begins when the board is in hand.

**Goal:** validate the Si5351A as the production-target pullable clock source ("the actuator") that replaces the MMCM used in the Phase E1 sync spike. Once these phases pass, the Si5351 takes over from the MMCM in the closed-loop controller with effectively unlimited pull range.

**Related docs:**
- [`sync-architecture.md`](sync-architecture.md) — THE plan; Si5351 is the production NCO referenced in §6 and §3.7 of [`01-spec.md`](01-spec.md)
- [`phase-e1-ground-up-plan.md`](phase-e1-ground-up-plan.md) — sync spike that validates the loop architecture with MMCM as the interim actuator
- [`adv7393-bench-bringup.md`](adv7393-bench-bringup.md) — parallel bench bring-up, similar shape

---

## 1. What the part is

**Si5351A** (3-output PLL clock generator, Silicon Labs / Skyworks).

- 3 independent outputs (CLK0 / CLK1 / CLK2), 8 kHz–160 MHz each
- I²C-configurable fractional dividers (sub-ppb resolution achievable)
- 25 MHz reference crystal on the breakout
- 3.3–5 V power, onboard LDO; 3 Vpp square-wave outputs (3.3V-logic-compatible)
- Default I²C address 0x60 (some breakouts expose ADDR strap for 0x61)

**Variant note:** the **A** variant has no CLKIN pin — its reference is the internal crystal. The **C** variant (not what we have) has an external CLKIN that lets the chip's PLL hardware-lock to an external clock. That matters later if we want hardware-genlock to recovered analog references (black burst, tri-level). With the A variant, we close the loop in firmware instead — same architecture, just software in the loop. **Not a blocker.** See §8.

---

## 2. Where it fits architecturally

The Si5351 is the **actuator** of the production sync loop. Block view:

```
 Reference selector            Actuator                          Output
 ──────────────────            ────────                          ──────
 [synthetic vsync]   ──┐                                          
 [HDMI source vsync] ──┤  mux ─→ [phase tracker (firmware)] ──I²C──┐
 [analog reference   ──┤                                            ↓
  recovery, later]    │                                       ┌──────────┐
 [free-run]          ─┘                                       │ Si5351A  │
                                                              │ frac div │
                                                              └────┬─────┘
                                                                   │ CLK0
                                                                   ↓
                                                              FPGA clock-in pin
                                                                   ↓
                                                              clk_wiz buffer
                                                                   ↓
                                                              pixel clock domain
                                                              (VTC TX, etc.)
```

This replaces the MMCM (`clk_wiz_pixclk_out` driven by FCLK_CLK0) used in the Phase E1 spike. The control loop is identical — same phase tracker, same PI controller. Only the actuator changes: instead of MMCM DRP writes, the controller issues Si5351 I²C writes.

**The Phase E1 spike must be done first.** This bring-up depends on having a working closed-loop sync controller against the MMCM actuator. Once that's proven, swapping in Si5351 is well-scoped.

---

## 3. Wiring plan

### 3.1 I²C bus

Reuse the existing ADV7393 I²C master (`axi_iic_adv7393` at base `0x41600000`, 100 kHz SCL). The Si5351's default address is 0x60; ADV7393's is 0x2A. **No conflict** — they coexist on one bus cleanly.

Net result: the Si5351 SDA/SCL just tap into the existing JD7 / JD8 lines. No new I²C master needed.

| Signal | Zybo pin | PMOD pin | Note |
|---|---|---|---|
| SDA | U14 | JD7 | Shared with ADV7393; pull-up already in place (2.2 kΩ) |
| SCL | U15 | JD8 | Shared with ADV7393; pull-up already in place |

If the breakout has its own pull-ups, fine — they'll parallel down. Verify on receipt; lower the ADV7393 pull-up if combined Rpullup gets too low (target Rcombined ≥ 1 kΩ for 100 kHz operation).

### 3.2 Clock output → FPGA clock-input pin

Si5351 CLK0 → a Zybo Z7-20 clock-capable input pin. **Must be MRCC or SRCC** (multi-region or single-region clock capable), otherwise BUFG inference fails.

**Action item: verify pin choice against the Zybo Z7-20 schematic and Vivado pin report.** A reasonable candidate is on PMOD JC (JC1 / JC2 are often MRCC on Zybo); pick a pin that's documented as MRCC and not already in use.

Constraint preview (placeholder pin name — update after schematic check):

```xdc
set_property PACKAGE_PIN <MRCC_PIN> [get_ports si5351_clkin]
set_property IOSTANDARD LVCMOS33  [get_ports si5351_clkin]
create_clock -period <ns> -name si5351_clkin [get_ports si5351_clkin]
```

The period depends on what frequency Phase B drives the Si5351 to — typically start with 10 MHz (cleanly testable on a scope) or 27 MHz (matches ADV7393's CLKIN as a sanity benchmark), then push up to the actual pixel-clock rate later.

### 3.3 Power

3.3 V from a Zybo PMOD power rail (PMOD JD already powers ADV7393, can supply Si5351 too — verify combined current draw is within PMOD spec; Si5351 itself is <50 mA).

Single-point ground tie between Zybo, Si5351 breakout, and (eventually) the ADV7393 board.

### 3.4 SMA output (optional)

The board has an optional SMA connector for one output. Useful for clean scope/counter measurements during Phases B and D. Header pins work fine too if you have decent probes.

---

## 4. The five bench phases

Each phase is independently testable, produces a numeric pass criterion, and gates the next. Stop and fix at the first failure. Same methodology as the Phase E1 spike.

### Phase A — Chip alive

**Goal:** confirm I²C connectivity.

**Procedure:**
1. Wire SDA, SCL, power, GND. Pull RESETB high (or float — board has it pulled up).
2. From firmware, run an I²C scan (or targeted probe at 0x60).
3. Expected: ACK at 0x60.

**Pass:** chip responds to its address.

**If it fails:**
- Check SDA/SCL voltage levels (should idle at 3.3V; bus stuck low means short or pull-up missing).
- Check power rail at the chip's VDD pin (multimeter).
- Verify I²C clock rate is ≤ 100 kHz (Si5351A spec).

---

### Phase B — Synthesize a known frequency

**Goal:** confirm the fractional dividers work; measure the output against a known reference.

**Procedure:**
1. Configure Si5351 to output 10.000 MHz on CLK0 (use the Etherkit library or AN619 register sequence).
2. Measure CLK0 with a frequency counter or scope.
3. Compute error in ppm.

**Pass:** measured frequency within ±50 ppm of commanded. (A typical 25 MHz crystal has ~20–30 ppm drift; anything wildly off suggests a register-write or math error, not a crystal issue.)

**Useful sanity checks at this stage:**
- Try 5 MHz, 10 MHz, 25 MHz, 50 MHz, 100 MHz on CLK0. All should land cleanly.
- Drive CLK1 and CLK2 at different frequencies simultaneously. Confirms multi-output works (needed for the Pro SKU's dual SYNC OUT eventually).
- Power-cycle. Confirm output stops, then resumes after re-init.

---

### Phase C — Drive an FPGA clock input

**Goal:** prove the Si5351 output can clock FPGA logic, end-to-end.

**Procedure:**
1. Wire Si5351 CLK0 to the selected MRCC pin on Zybo.
2. Add a `clk_wiz` in the BD that takes `si5351_clkin` as input and produces a pixel-rate clock (e.g., 74.25 MHz for 720p60). Configure for a typical Si5351 CLK0 input rate (start with the Si5351 at 25 MHz or 27 MHz to keep clk_wiz multipliers conservative).
3. Generate a minimal pipeline: `clk_wiz` → VTC TX → axis_to_vid_io → rgb2dvi → HDMI OUT, with a fixed pattern (test gradient from a constant generator, no VDMA, no scaler, no TPG).
4. Verify HDMI output on the MS2109 capture stick.

**Pass:** clean HDMI output at the expected rate. Sink locks. Picture is the constant test pattern (whatever was wired in).

**Why this matters:** confirms that the Si5351 can be the *source of truth* for the entire pixel-clock domain. Everything downstream of `clk_wiz` (VTC TX, axis_to_vid_io, rgb2dvi internal MMCM) inherits Si5351's stability.

---

### Phase D — Open-loop pullability

**Goal:** characterize Si5351 frequency vs. commanded value. The Si5351 equivalent of Phase E1 spike Phase 5.

**Procedure:**
1. With Phase E1 spike's vsync timestamp infrastructure in place, run a sweep:
   - Step CLK0 across 11 points: −50, −40, −30, ..., +50 ppm (offsets relative to whatever Phase B established as nominal).
   - At each point, hold 30 seconds, measure the actual frequency via FPGA timestamp counters (Phase 3-style drift measurement).
2. Plot measured ppm vs. commanded ppm.

**Pass:**
- Linear, monotonic, slope within 1% of 1.0. (Si5351 fractional dividers are *very* precise — much cleaner than MMCM DRP.)
- R² ≥ 0.999.

**Why it matters:** sizes the controller gains and confirms there are no surprises in the I²C ↔ frequency relationship. Si5351 should be a near-ideal actuator; if it isn't, the register-write math is wrong.

---

### Phase E — Closed-loop with Si5351 as the actuator

**Goal:** swap Si5351 for the MMCM in the Phase E1 controller. Same loop, different output.

**Procedure:**
1. Start from a working Phase E1 spike build (loop locked against synthetic reference, using MMCM as actuator).
2. Replace the actuator: instead of `mmcm_drp_write(correction_ppm)`, call `si5351_set_offset_ppm(correction_ppm)`.
3. The phase tracker, PI controller, lock state machine, and reference mux are unchanged.
4. Lock against the same synthetic FCLK_CLK1 vsync reference. Run for 30 minutes.

**Pass criteria** (same as Phase E1 spike Phase 6):
- Acquire time < 10 seconds.
- |phase_error| ≤ 1 line for 100% of the 30-minute window.
- No unlock events.
- Phase-error histogram bounded with no slow trend.

**Then re-run Phase E1 spike Phases 7 (state machine) and 8 (dual-loop VDMA cooperation) with Si5351 in the actuator slot.** All should pass with the same criteria; if anything regresses, Si5351 control loop dynamics differ from MMCM and need re-tuning.

---

## 5. Reference materials

- **Silicon Labs AN619 — Manually Generating an Si5351 Register Map.** The canonical register-level spec. Heavy reading; you don't need to derive register values by hand, but you do want to understand the divider topology.
- **Etherkit Si5351 library** (originally Arduino, GPL). Battle-tested register-write sequences with all the fractional-divider math worked out. Port to bare-metal Zynq C using Xilinx's `XIic_Send` API (the same pattern as the ADV7393 driver in [`sw/phase-b/src/main.c`](../sw/phase-b/src/main.c)). Worth porting rather than re-deriving — the fractional-PLL math is fiddly and error-prone.
- **Si5351 datasheet.** Pinout, electricals, output drive levels. Important for verifying output is sane on the scope.
- **JESSINIE breakout product page** — captures crystal frequency (25 MHz), voltage range (3–5V), output level (3 Vpp).

---

## 6. Open follow-ups

Carried forward as known items, not blockers.

1. **MRCC pin selection** — verify against Zybo Z7-20 schematic on first bench session; update XDC accordingly.
2. **Combined pull-up resistance** if Si5351 breakout has onboard pull-ups in addition to existing 2.2 kΩ at the bus master end — may need to remove one set.
3. **Output drive cleanliness at the FPGA pin** — scope to confirm 3 Vpp square wave at the FPGA pin (after PMOD jumper). Same caveat that bit us on ADV7393 CLKIN: short ground lead, probe at the chip not the header.
4. **Si5351 register init sequence robustness** — Si5351A is known to occasionally output non-locked junk on cold start until a `PLL_RESET` is issued after configuring. Etherkit library handles this; verify the port preserves the sequence.
5. **Si5351C upgrade path** — if/when analog reference recovery (LTC, tri-level, black burst) is built, the C variant becomes attractive for hardware-locked CLKIN behavior. Architectural impact is small (replace breakout, add CLKIN routing, add a register-config option). Not on the critical path.

---

## 7. Production-architecture notes

Two architectural decisions become relevant once Si5351 is alive:

### 7.1 Si5351 replaces or cascades with the MMCM?

**Replace.** Si5351's fractional divider has finer resolution than MMCM DRP. The MMCM (clk_wiz) becomes a buffer (zero phase shift, no multiplication needed if Si5351 outputs the pixel-clock rate directly) or removable entirely if Si5351 can drive the BUFG. Cascading both would only matter if Si5351's resolution were insufficient — it isn't.

### 7.2 RP2040 enters the picture when?

In production, the RP2040 is the dedicated I²C master for Si5351 (and possibly other clock-gen / reference-recovery silicon). The Zynq PS sends "I want correction = X ppm" commands over UART or similar; the RP2040 translates to register writes.

**This is a separation-of-concerns decision, not a correctness one.** Every bench bring-up step in this doc uses the Zynq's own I²C controller (already there for ADV7393). RP2040 integration is a clean handoff later: same I²C target, just a different master, with a serial protocol between the two micros. Defer until the rest of the path is proven.

---

## 8. The CLKIN question (Si5351A vs C)

For the production analog-genlock path (LTC / tri-level / black burst inputs), there are two architectural choices:

| Approach | How it works | Pros | Cons |
|---|---|---|---|
| **Software loop** (works with current Si5351A) | Recover the analog reference to digital edges → timestamp in FPGA → firmware computes correction → I²C write to Si5351 | No silicon change; same architecture as the spike with a different reference selector input | Software in the timing path; loop bandwidth limited by I²C write rate |
| **Hardware loop** (requires Si5351C) | Recover reference to a clean clock → feed Si5351 CLKIN directly → chip's internal PLL locks autonomously | Lower jitter, lower latency, no firmware in the path | Requires Si5351C variant (different breakout / footprint); reference recovery must produce a clean clock, not just edges |

Both are valid. **Software loop is the right MVP choice** — it shares the loop machinery with everything else, and the loop bandwidth is fine for video timing (~tens of Hz BW is plenty). Migrate to hardware loop only if a measured shortcoming demands it.

The current Si5351A board is fine for shipping. The C-variant upgrade is a future option, not a near-term need.

---

## 9. How this connects to other tracks

- **Phase E1 sync spike** — must succeed before Phase E of this bring-up. Si5351 replaces MMCM as the actuator in the same closed-loop controller; the controller must exist first.
- **ADV7393 bench bring-up** — shares the I²C bus. Bring-up order: ADV7393 first (since it's blocked on bench debug right now anyway), then Si5351 once ADV7393 is alive. Or run them in parallel if you're at the bench and have both boards out — they don't interfere.
- **Mackin functional** — independent; doesn't depend on Si5351. Mackin needs dual-VDMA + α from the PLL phase tracker, which exists regardless of whether the actuator is MMCM or Si5351.
- **Reference mux additions** — once Si5351 is the actuator, the *next* architectural step is adding more reference *inputs* to the mux (HDMI source vsync, eventually analog reference recovery). Si5351 doesn't change the reference selector at all; that's separate work.
