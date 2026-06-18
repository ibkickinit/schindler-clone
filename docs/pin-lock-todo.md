# Schindler 2.0 — Pin-Lock TODO (carrier A1, `SchindlerCarrierBoard_V1`)

**Date:** 2026-06-17 · **Status:** open tracker. The PS-EMIO / PL pin-lock has become the defining piece of remaining carrier work. Everything below draws from **one shared SoM pin pool** (TE0720 via J200/J201/J202 — LSHM) and **must be allocated as a single pass**, not piecemeal — otherwise signals get wired against an assignment that later moves.

This doc is the index of what that pass must cover. Detail lives in the linked docs; this is the scope + dependency map.

---

## The pin pool

Per [`pin-budget.md`](pin-budget.md): **152 PL I/O** across banks — now **extracted to concrete pins** in [`pin-lock-substrate.md`](pin-lock-substrate.md) (from the Trenz TEBA0841 workbook, sheet `RAW_m_TE0720_REV04`). Real bank/voltage split: **B35 (48, JM1) + B13 (50, JM2) = 3.3 V; B34 (36, JM3) + B33 (18, JM2) = 1.8 V.** Demand 119/152 reconciles, every bank within capacity (B35 fullest at 42/48). Plus **PS-MIO** (dedicated, mostly spoken-for by DDR/QSPI/SD/etc.) and **PS-EMIO** (64-wide GPIO from the PS, but each externally-routed line costs **one PL package pin** in a voltage-matched bank). Current PL ≈ 78 % used (~33 free) **before** the items below are all placed.

**Golden rule:** EMIO control lines and parallel data buses compete for the same PL package pins. Free-pin headroom must be checked **after** the fast buses are allocated.

---

## Items the pin-lock pass must allocate

### A. Fast parallel data buses (front-end PL egress) — the bulk of the pins
Enumerate exact widths/pins at lock; approximate scope:

| Bus | Chip | ~width | Voltage / bank | Clock pin? |
|-----|------|--------|----------------|-----------|
| BT.656 video out | ADV7280 (U500) | 8 data + LLC (+3 if discrete HS/VS/FIELD) + INTRQ* | 3.3 V | **LLC = clock-capable** |
| Pixel bus in | ADV7393 (U600) | ~16 data + CLKIN + HS/VS | 3.3 V | CLKIN (MMCM out) |
| Pixel bus out | ADV7511 (U403) | ~16–24 data + DE/HS/VS/PCLK | **1.8–3.3 V — inputs accept either (flex bank)** | PCLK (MMCM out) |
| RGB out | LT8619C (U402) | ~24 data + DE/HS/VS/PCLK | 3.3 V | **PCLK recovered = clock-capable** |
| SDI RX parallel | GS3470 (U700) | 20 (DOUT) + PCLK + status | 1.8 V (B34) | **PCLK recovered = clock-capable** |
| SDI TX parallel | GS2962 (U701) | 20 (DIN) + PCLK | 1.8 V (B34) | PCLK (MMCM out) |
| ADC out | AD9204 (U801) | dual 10-bit + DCO | (verify) | **DCO = clock-capable** |
| DAC in | AD9742 (U903) | ~10–14 + sample clk | (verify) | sample clk (PLL out) |

⚠ Widths are from interface knowledge — **enumerate against the netlist's deferred (`unconnected-`) bus pins at lock.**

### B. Control / housekeeping EMIO + I²C
- **I²C buses:** I2C_VID (PS-EMIO → ADV7280/7393/7511 + LT8619C), I2C_HK (PS → U803 PCA9555 + others), I2C_GENLK (RP2040-side). The EMIO-routed ones consume PL pins.
- **SPI buses:** SDI_SPI (GS3470/GS2962 host), GENLK_SPI, LCD_SPI — confirm which ride PL vs PS-MIO.
- **Status/interrupts:** ADV7280 INTRQ* and any per-chip IRQ/status that needs a host pin.

### C. Reset / power-down nets — see [`reset-strategy.md`](reset-strategy.md)
**TWO named reset nets, both PS-EMIO-driven, pull-DOWN + PS-drives-HIGH-to-release** (the parts mandate a power-up reset — see reset-strategy.md). Allocate here so reset isn't wired twice:
| Net | Voltage | Idle pull | Release | Members |
|-----|---------|-----------|---------|---------|
| `VIDEO_RESET_N` | 3.3 V | 10 kΩ → **GND** | PS-EMIO drives HIGH | ADV7280 RESET*, ADV7393 *RESET, LT8619C RESET_N |
| `SDI_RESET_N` | 1.8 V | 10 kΩ → **GND** | PS-EMIO drives HIGH | GS3470 ~RESET, GS2962 ~RESET |

**ADV7511 PD is NOT an EMIO net** — it's a **static 2 kΩ → +1V8_A** tie that latches I²C address **0x7A** + active-low PD at power-up (the part has no reset pin; recovery = I²C script or box power-cycle). This **frees the EMIO** the earlier `HDMI_TX_PD_N` net would have cost → reset/PD now costs **2 EMIO, not 3**.

Plus standalone pulls (no EMIO, place anytime but easiest in this pass): GS2962 STANDBY (pull-**down** GND), GS3470 ~TRST (**leave unconnected** — internal pull-down), RP2040 RUN (10 kΩ → +3V3 + 100 nF + test point).

### D. Clock-capable pin constraints
Recovered/reference clocks must land on **clock-capable PL pins** (MRCC/SRCC → BUFR/BUFG), per [`pin-budget.md`](pin-budget.md) §4:
- **Captured (BUFR):** ADV7280 LLC, LT8619C HDMI-in pixel clock, GS3470 SDI recovered clock, AD9204 DCO.
- **Synthesized (MMCM/PLL out → specific pins):** shared HDMI-out/SDI-out pixel clock (ADV7511 + GS2962), ADV7393 27 MHz CLKIN, AD9742 sample clock.
- These take priority for the limited clock-capable pins — allocate **before** general data bits.

---

## Cross-cutting constraints (apply to the whole pass)

1. **Voltage-bank match** — every signal lands in a bank whose VCCO matches its logic level: 3.3 V signals (ADV7280/7393 buses, LT8619C, VIDEO_RESET_N) → 3.3 V bank; 1.8 V signals (GS buses, SDI_RESET_N) → 1.8 V bank (B34/B33). **ADV7511 pixel bus is flex (inputs accept 1.8–3.3 V)** → place in whichever bank has room after the fixed buses. *(Same class of mistake as the C716/C717 GND_A catch — wrong rail/domain is silent until it bites.)*
2. **EMIO accounting after data buses** — confirm ≥2 voltage-matched control pins (the 2 reset nets) remain once A is placed (see reset-strategy.md EMIO note).
3. **Clock pins first** — D's clock-capable requirements constrain placement more than data bits; reserve them up front.
4. **U803 PCA9555 fallback** — on I2C_HK (off I2C_VID, so it survives an I2C_VID wedge); 3.3 V outputs only → fallback for VIDEO_RESET_N only, not the 1.8 V SDI net. PS-EMIO preferred for both reset nets.

---

## Sequencing

Do this as **one allocation pass**: (1) reserve clock-capable pins (D), (2) place the fast parallel buses (A) by voltage bank, (3) confirm control/EMIO headroom (B + C), (4) then wire — reset/PD nets, standalone pulls, and the bus connections together. Wiring any sub-part before the map is fixed means redoing it.

## Source docs
- [`reset-strategy.md`](reset-strategy.md) — the 3 reset/PD nets, per-pin polarity/rail/refdes (ratified plan).
- [`pin-budget.md`](pin-budget.md) — bank counts, MMCM/PLL budget, clock architecture.
- [`decoupling-audit.md`](decoupling-audit.md) — unrelated (decoupling/functional); kept separate on purpose.

## Open / to-confirm at lock
- Exact bus widths from the netlist deferred-pin list (A).
- Exact EMIO bit indices + PL pin locations (live in the Vivado PS block design, not the repo).
- AD9204 / AD9742 interface widths + clock-pin needs (B/D rows marked verify).
- ADV7511 PD polarity/level — **CONFIRMED**: no reset pin; static 2 kΩ → +1V8_A latches addr 0x7A + active-low PD (reset-strategy.md). ADV7511 inputs **accept 1.8–3.3 V logic** → pixel bus is **flex** bank-placement (constraint relaxed, row A updated). *(Residual: confirm U403's supply-pin set all got bypass — minor symbol-match check, decoupling-pass.)*
- Free clock-capable-pin count per bank vs the clock list in D.
