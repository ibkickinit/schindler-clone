# Schindler 2.0 — Decoupling Audit (carrier A1, `SchindlerCarrierBoard_V1`)

**Date:** 2026-06-15 · **Type:** REPORT ONLY — no `.kicad_sch` touched, no parts placed, no bom-v1/refdes-map edits. Proposals below await Justin's review + gate.

**Method:** ground truth from the live netlist (`kicad-cli sch export netlist`) + symbol pin maps (authoritative pin numbers/names from `JustinLibrary`/`Memory_Flash`/`CarrierGen`). "Local cap" = a cap on the same **sheet** as the chip **and** on that power pin's net (rail-sharing caps placed elsewhere on a global rail do **not** count as local bypass). Cap ownership cross-checked against the `<value> (<Uxxx>/<rail>)` value-label convention. Datasheet recommendations are from part knowledge; anything not certain from the symbol is marked **⚠ verify**.

**Convention for proposed caps:** value-label `<value> (<Uxxx> <rail/pin>)`, pad 1 → rail, pad 2 → GND. Per-pin 0.1 µF = its own cap at the pin; "bulk" 10 µF = one per rail near the chip.

---

## Headline findings

1. **Sheet 2 (TE0720 SoM) has ZERO decoupling caps.** The assumed `C200–C239` bank **does not exist** — sheet 2 is only J200/J201/J202 (LSHM sockets) + 1 fiducial + 10 test points. The carrier feeds the module **+5V (7 pins), +3V3 (8 pins), +1V8_D (3 pins)** through the connectors with **no carrier-side bypass**. ⚠ Biggest gap.
2. **Every signal/sync chip is bare or near-bare of local per-pin bypass** — they ride on global-rail caps (LDO outputs, or U402's caps). Confirmed fully/largely bare: **U403, U500, U600, U900, U901, U902, U903**, GS3470/GS2962 per-ball.
3. **Partially populated** (some dedicated caps exist): **U801** (C805 AVDD, C806 DRVDD, C802 VREF, C803 VCM — but only 1 per rail, not per-pin), **U800** (C804 0.1 µF V+, missing the 1 µF), **U903** (REFIO C901 present; AVDD/DVDD bare).
4. **Power tree (sheet 3) is well-populated** — LMR33640/TLV62568/ADP7142/TPS7A2018 all have input+output caps. Only minor ⚠ verify items (ADP7142 feed-forward, TPS7A2018 NR/SS).

---

## Sheet 2 — TE0720 SoM (J200/J201/J202, LSHM sockets)

**EXISTS:** Nothing. No caps on sheet 2 at all. SoM supply rails present on the connectors: `+5V` (7 pins), `+3V3` (8 pins), `+1V8_D` (3 pins). Global rails do have caps elsewhere (sheet 3 LDO outputs), but **no decoupling at the module's supply-input pins**.

**DATASHEET WANTS (Trenz TE0720 carrier guidance — ⚠ verify against the current TE0720 carrier reference design):** the module carries its own DDR/PS/PL decoupling, but the **carrier must decouple the supply it delivers** — bulk electrolytic/ceramic on the main feed + HF bypass distributed across the connector supply pins. Typical: bulk (≥100 µF aggregate) + 0.1 µF per supply-pin cluster.

**PROPOSED ADDS** (block C200+, all ⚠ verify counts vs Trenz reference):

| Refdes | Value | Serves | Rail (pad 1) |
|--------|-------|--------|--------------|
| C200, C201 | 47 µF (or 2×22 µF) | +5V SoM feed bulk | +5V |
| C202, C203 | 22 µF | +3V3 SoM feed bulk | +3V3 |
| C204 | 10 µF | +1V8_D SoM feed bulk | +1V8_D |
| C205–C207 | 0.1 µF | +5V bypass (distribute near the 7 pins) | +5V |
| C208–C211 | 0.1 µF | +3V3 bypass (distribute near the 8 pins) | +3V3 |
| C212 | 0.1 µF | +1V8_D bypass | +1V8_D |

≈ **12 caps**. ⚠ This is generic best-practice scaffolding — confirm count/values against Trenz's published TE0720 carrier decoupling note before placing.

---

## Sheet 4 — U403 ADV7511KSTZ (HDMI TX, LQFP-100) — **BARE**

**EXISTS:** No dedicated caps. The 9 supply pins all sit on `+1V8_A`; the only same-sheet caps on that rail are **C407/C408 (U402's CT_HPD/VCCA18)** and **C421 (U402 bulk)** — i.e. it's borrowing U402's decoupling. No per-pin bypass for U403.

Power pins (all `+1V8_A`): DVDD ×5 (1,19,49,76,77), AVDD ×2 (34,41), PVDD ×2 (24,25).

**DATASHEET WANTS (ADI ADV7511):** 0.1 µF per supply pin, 10 µF bulk per supply group (DVDD/AVDD/PVDD), and **PVDD (PLL) ferrite-isolated** from the others with its own 0.1 µF on the isolated side. ⚠ verify whether a separate 3.3 V digital-I/O supply (pixel bus) is required — symbol consolidates everything to 1.8 V.

**PROPOSED ADDS** (block C424+):

| Refdes | Value | Pin | Rail (pad 1) |
|--------|-------|-----|--------------|
| C424–C428 | 0.1 µF | DVDD 1,19,49,76,77 | +1V8_A |
| C429, C430 | 0.1 µF | AVDD 34,41 | +1V8_A |
| C431, C432 | 0.1 µF | PVDD 24,25 | **+1V8_A_TXPLL** (post-FB402) |
| C433 | 10 µF | DVDD/AVDD bulk | +1V8_A |
| C434 | 10 µF | analog/PVDD bulk | +1V8_A_TXPLL |
| **FB402** | ferrite 600 Ω @ 100 MHz | PVDD branch | +1V8_A → +1V8_A_TXPLL |

≈ **11 caps + 1 ferrite**.

---

## Sheet 5 — U500 ADV7280AWBCPZ-M (decoder, 40-LFCSP) — **BARE on supplies**

**EXISTS:** Supply pins have **no local caps**. Reference pins **do**: VREFP (C510 0.1 µF), VREFN (C511 0.1 µF). Y500 crystal present (out of scope). Note PWRDWN* (pin 31) is unconnected — ⚠ verify it should be tied (active-low → pull to DVDDIO).

Power pins: DVDDIO (2 → +3V3), DVDD ×2 (3,13 → +1V8_D), AVDD (21 → AVDD_DEC), PVDD (16 → AVDD_DEC). AVDD_DEC is the dedicated ADP7142 analog LDO (U308), already filtered.

**DATASHEET WANTS (ADI ADV7280):** 0.1 µF per supply pin + bulk; PLL/analog (PVDD/AVDD) clean — already on a dedicated LDO so a ferrite is likely unnecessary, but a 0.1 µF at each AVDD/PVDD pin is still required.

**PROPOSED ADDS** (block C512+):

| Refdes | Value | Pin | Rail (pad 1) |
|--------|-------|-----|--------------|
| C512 | 0.1 µF | DVDDIO p2 | +3V3 |
| C513, C514 | 0.1 µF | DVDD p3, p13 | +1V8_D |
| C515 | 0.1 µF | AVDD p21 | AVDD_DEC |
| C516 | 0.1 µF | PVDD p16 | AVDD_DEC |
| C517 | 10 µF | bulk | AVDD_DEC |

≈ **6 caps**. (Ferrite optional — AVDD_DEC already LDO-isolated; ⚠ verify ADV7280 PLL-supply guidance.)

---

## Sheet 6 — U600 ADV7393BCPZ (video DAC, 40-LFCSP) — **BARE; + COMP/EXT_LF gaps**

**EXISTS:** No local caps on any supply pin. **COMP (pin 29) is unconnected** — it requires a bypass cap to function. **EXT_LF (pin 22) unconnected** — PLL external loop filter. RSET (pin 30) → resistor net (OK, no cap).

Power pins: VDD_IO ×2 (1,6 → +3V3), VDD (35 → +1V8_D), PVDD (23 → +1V8_A), VAA (25 → +3V3_A).

**DATASHEET WANTS (ADI ADV7393):** 0.1 µF per supply pin; **VAA** (DAC analog 3.3 V) 0.1 µF + 10 µF; **PVDD (PLL)** ferrite-isolated + 0.1 µF; **COMP** decoupling cap to GND (⚠ verify value — typ 0.1 µF, sometimes 0.1 µF + 10 nF); **EXT_LF** RC loop filter ⚠ verify if internal LF not selected.

**PROPOSED ADDS** (block C606+):

| Refdes | Value | Pin | Rail (pad 1) |
|--------|-------|-----|--------------|
| C606, C607 | 0.1 µF | VDD_IO p1, p6 | +3V3 |
| C608 | 0.1 µF | VDD p35 | +1V8_D |
| C609 | 0.1 µF | PVDD p23 | **+1V8_A_DACPLL** (post-FB600) |
| C610 | 0.1 µF | VAA p25 | +3V3_A |
| C611 | 10 µF | VAA bulk | +3V3_A |
| C612 | 0.1 µF | **COMP p29** (reference bypass) | COMP → GND |
| **FB600** | ferrite 600 Ω @ 100 MHz | PVDD branch | +1V8_A → +1V8_A_DACPLL |

≈ **7 caps + 1 ferrite.** ⚠ COMP value + EXT_LF requirement to be confirmed from the ADV7393 reference circuit.

---

## Sheet 8 — U801 AD9204BCPZ-20 (dual 10-bit ADC, 64-LFCSP) — **PARTIAL**

**EXISTS:** AVDD ×8 (49,50,53,54,59,60,63,64 → AVDD_GENADC, dedicated ADP7142 LDO U307) has **C805 (0.1 µF)**. DRVDD ×4 (10,19,28,37 → +1V8_D) has **C806 (0.1 µF)**. References: VREF p55 → **C802 (470 nF)**, VCM p57 → **C803 (0.1 µF)**, SENSE p56 → GND (internal-ref mode). So one 0.1 µF per rail + ref caps — but **not per-pin** across 8 AVDD / 4 DRVDD.

**DATASHEET WANTS (ADI AD9204):** 0.1 µF at **each** AVDD and DRVDD pin (the part is sensitive to per-pin bypass), 10 µF bulk per supply, REFT/REFB decoupling (0.1 µF each + a 1 µF differential cap between them), VREF 0.1 µF, VCM 0.1 µF. ⚠ verify: the symbol exposes VREF/VCM/SENSE but **no REFT/REFB pins** — confirm whether this package routes REFT/REFB or handles it internally; if exposed, they need the 0.1 µF + 1 µF.

**PROPOSED ADDS** (block C809+):

| Refdes | Value | Pin | Rail (pad 1) |
|--------|-------|-----|--------------|
| C809–C811 | 0.1 µF | extra AVDD pins (toward 1-per-pin, 8 total) | AVDD_GENADC |
| C812 | 10 µF | AVDD bulk | AVDD_GENADC |
| C813, C814 | 0.1 µF | extra DRVDD pins (toward 1-per-pin) | +1V8_D |
| C815 | 1 µF | VREF/VCM trim (⚠ verify per datasheet) | as datasheet |
| (C816) | 1 µF | **REFT–REFB** differential ⚠ verify pins exist | — |

≈ **5–7 caps** (scales with how close to 1-per-pin you go). ⚠ REFT/REFB existence is the open question.

---

## Sheet 8 — U800 LTC6912CGN-2 (PGA, SSOP-16) — **PARTIAL**

**EXISTS:** V+ (pin 12 → +5V_PGA) has **C804 (0.1 µF)**. Missing the bulk.

**DATASHEET WANTS (ADI/LTC LTC6912):** 0.1 µF **+ 1 µF** on V+.

**PROPOSED ADDS:**

| Refdes | Value | Pin | Rail (pad 1) |
|--------|-------|-----|--------------|
| C816/C817 | 1 µF | V+ p12 | +5V_PGA |

≈ **1 cap** (refdes after the AD9204 block).

---

## Sheet 9 — U900 RP2040 (genlock MCU) — **BARE**

**EXISTS:** Zero caps. IOVDD ×6 (1,10,22,33,42,49), ADC_AVDD (43), USB_VDD (48), VREG_VIN (44) all on `+3V3`; DVDD core ×2 (23,50) + VREG_VOUT (45) on `RP2040_VCORE`. No bypass anywhere, **no VREG_VOUT cap** (the on-chip 1.1 V LDO needs it to be stable).

**DATASHEET WANTS (RP2040 "Minimal Design"):** 100 nF at each IOVDD (6×), 100 nF at each DVDD (2×), **1 µF on VREG_VOUT** (required), 4.7 µF+ bulk on IOVDD, ADC_AVDD via **ferrite (or RC) + 100 nF** off IOVDD, 100 nF on USB_VDD. Plus 12 MHz crystal Y900 + 2 load caps (⚠ verify a crystal exists — if the RP2040 is clocked from Si5351/external, the XOSC caps may differ).

**PROPOSED ADDS** (block C905+):

| Refdes | Value | Pin | Rail (pad 1) |
|--------|-------|-----|--------------|
| C905–C910 | 0.1 µF | IOVDD 1,10,22,33,42,49 | +3V3 |
| C911, C912 | 0.1 µF | DVDD 23,50 | RP2040_VCORE |
| C913 | 1 µF | **VREG_VOUT p45** | RP2040_VCORE |
| C914 | 0.1 µF | USB_VDD p48 | +3V3 |
| C915 | 0.1 µF | ADC_AVDD p43 (post-FB900) | RP2040_ADCVDD |
| C916 | 4.7 µF | IOVDD bulk | +3V3 |
| **FB900** | ferrite 600 Ω @ 100 MHz | ADC_AVDD branch | +3V3 → RP2040_ADCVDD |

≈ **12 caps + 1 ferrite.** ⚠ verify clock source / Y900.

---

## Sheet 9 — U901 W25Q128 (QSPI flash) — **BARE**

**EXISTS:** VCC (pin 8 → +3V3) no cap.
**DATASHEET WANTS:** 0.1 µF at VCC (often + 10 nF).
**PROPOSED:** **C917** 0.1 µF (U901 VCC) → +3V3. ≈ **1 cap.**

---

## Sheet 9 — U902 Si5351A-B-GT (clock gen, MSOP-10) — **BARE**

**EXISTS:** VDD (1), VDDO (7) on +3V3, no caps.
**DATASHEET WANTS (SiLabs Si5351):** VDD 0.1 µF **+ 1 µF** (clean supply, clock jitter), VDDO 0.1 µF. ⚠ verify Y901 crystal (25/27 MHz) + load caps present — not found in inventory.
**PROPOSED** (block continues):

| Refdes | Value | Pin | Rail (pad 1) |
|--------|-------|-----|--------------|
| C918 | 0.1 µF | VDD p1 | +3V3 |
| C919 | 1 µF | VDD p1 bulk | +3V3 |
| C920 | 0.1 µF | VDDO p7 | +3V3 |

≈ **3 caps** (+ ⚠ Y901 + 2 load caps if crystal absent).

---

## Sheet 9 — U903 AD9742ARUZ (sync DAC, TSSOP-28) — **PARTIAL**

**EXISTS:** **REFIO (pin 17) → C901 (0.1 µF)** — present (answers the prompt). FS_ADJ (18) → resistor net (OK). AVDD (24), DVDD (27) on `+3V3` — **no local bypass**.
**DATASHEET WANTS (ADI AD9742):** 0.1 µF at each AVDD and DVDD + 10 µF bulk; REFIO 0.1 µF (have). ⚠ verify AVDD pin count — symbol shows a single AVDD/DVDD; real AD9742 has multiple AVDD pins.
**PROPOSED:**

| Refdes | Value | Pin | Rail (pad 1) |
|--------|-------|-----|--------------|
| C921 | 0.1 µF | AVDD p24 | +3V3 |
| C922 | 0.1 µF | DVDD p27 | +3V3 |
| C923 | 10 µF | bulk | +3V3 |

≈ **3 caps** (more if extra AVDD pins per ⚠ datasheet).

---

## Sheet 7 — GS3470 (U700) / GS2962 (U701) — rail filtering present, **per-ball 0.1 µF absent**

**EXISTS:** Rail-level filtering is in place: `+1V2_A` (FB701) with **4× 1 µF** (C708–C711), PLL loop-filter caps (C712/C713), GS2962 VBG (C714 0.1 µF), DDO_VDD (C715 1 µF), CD_VDD (C720/C721 10 nF). **But no per-ball 0.1 µF HF bypass.** This is a BGA running 3G-SDI (1.485 GHz) — per-ball bypass matters.

GS3470 power balls: CORE_VDD ×4 (+1V2), PLL_VDD ×3 / VCO_VDD ×2 / DDI0_VDD ×2 / DDI1_VDD ×2 (+1V2_A), DDO_VDD ×2 (SDI_DDO_VDD), IO_VDD ×4 (+1V8_D).
GS2962 power balls: CORE_VDD ×4 (+1V2), PLL_VDD ×2 / VCO_VDD ×1 (+1V2_A), IO_VDD ×2 (+1V8_D), A_VDD ×1 (+3V3_A), CD_VDD ×1 (+3V3_SDIDRV).

**DATASHEET WANTS (Semtech GS3470/GS2962):** 0.1 µF (or 0.01 µF) per power ball, placed at the ball, in addition to the existing bulk/filter. ⚠ verify exact value (Semtech often specs 0.01 µF + 0.1 µF pairs on some rails).

**PROPOSED ADDS** (block C723+): **0.1 µF per power ball** —
- GS3470: ~19 balls → ~19× 0.1 µF (C723–C741), rails per ball as above.
- GS2962: ~11 balls → ~11× 0.1 µF (C742–C752).

≈ **~30 caps.** **Layout note:** in a tight BGA fanout, adjacent same-rail balls may share one 0.1 µF — final count is layout-dependent and can be trimmed at place-and-route. This is the single largest line item; flag for Justin to decide per-ball vs. consolidated.

---

## Sheet 3 — Regulators (U300, U303–U310) — **well-populated; minor ⚠ only**

| Reg | Part | Input | Output | Notes |
|-----|------|-------|--------|-------|
| U303 | LMR33640 (5V) | C300/301/302 22 µF bulk + C320 4.7 µF/C321 0.1 µF | C334 22 µF/C335 1 µF | BST C324 100 nF — OK |
| U304 | LMR33640 (3.3V) | (shares C300–302) + C328 4.7 µF/C329 0.1 µF | C326 22 µF/C327 0.1 µF | BST C330 100 nF — OK |
| U305 | TLV62568 (1.2V) | C322 22 µF/C323 0.1 µF | C332 10 µF/C333 0.1 µF | OK |
| U307 | ADP7142 (AVDD_GENADC) | C343 2.2 µF | C340 2.2 µF | ⚠ optional ADJ feed-forward cap absent |
| U308 | ADP7142 (AVDD_DEC) | C344 2.2 µF | C341 2.2 µF | ⚠ as above |
| U309 | ADP7142 (+3V3_A) | C345 2.2 µF | C342 2.2 µF | ⚠ as above |
| U306 | TPS7A2018 (+1V8_A) | C346 1 µF | C336 1 µF/C337 0.1 µF | ⚠ NR/SS pin cap — verify |
| U310 | TPS7A2018 (+1V8_D) | C338/C348 10 nF region | C347 1 µF | ⚠ NR/SS pin cap — verify |
| U300 | TPS26601 eFuse | C303 1 µF, C310 100 nF, C311 0.82 µF (PDT), C312 0.1 µF (ONT), C313 10 nF (dVdt) | — | OK |

**No redesign proposed.** Only ⚠ verify: ADP7142 feed-forward cap across the ADJ top resistor (noise/PSRR), and TPS7A2018 NR/SS pin cap (noise/soft-start). Confirm against each datasheet; add only if the reference design calls for it.

---

## Rollup

### Proposed new caps per sheet

| Sheet | Chip(s) | Proposed caps | New ferrites | Refdes block |
|-------|---------|---------------|--------------|--------------|
| 2 | TE0720 SoM | ~12 ⚠ | — | C200+ |
| 4 | U403 ADV7511 | 11 | FB402 | C424+ |
| 5 | U500 ADV7280 | 6 | (opt) | C512+ |
| 6 | U600 ADV7393 | 7 | FB600 | C606+ |
| 7 | GS3470 + GS2962 | ~30 (layout-trimmable) | — | C723+ |
| 8 | U801 + U800 | 6–8 | (opt) | C809+ |
| 9 | RP2040+flash+Si5351+AD9742 | ~19 | FB900 | C905+ |
| **Total** | | **≈ 91 caps** | **≈ 3–5 ferrites** | |

### New refdes needed per hundreds block
- **C2xx:** ~12 (block currently empty — all new).
- **C4xx:** C424–C434 (11).
- **C5xx:** C512–C517 (6).
- **C6xx:** C606–C612 (7).
- **C7xx:** C723–C752 (~30).
- **C8xx:** C809–C817 (~8).
- **C9xx:** C905–C923 (~19).
- **FB:** FB402 (sh4), FB600 (sh6), FB900 (sh9); FB500 (sh5) / sh8 optional.

### Fully bare vs. partially populated

| State | Chips |
|-------|-------|
| **Fully bare** (no local decoupling) | TE0720 (sheet 2), U403, U500*, U600, U900, U901, U902 |
| **Partially populated** | U801 (AVDD/DRVDD/VREF/VCM present, not per-pin), U800 (0.1 µF, missing 1 µF), U903 (REFIO present, AVDD/DVDD bare), GS3470/GS2962 (rail filtering present, per-ball absent) |
| **Complete** | Sheet 3 regulators (minor ⚠ verify only) |

\* U500 has VREFP/VREFN reference caps but zero supply-pin bypass.

### Open ⚠-verify items (datasheet confirmation before placing)
1. TE0720 carrier decoupling spec (Trenz reference) — count/value of SoM-feed caps.
2. ADV7511 separate 3.3 V digital-I/O supply? PVDD ferrite value.
3. AD9204 REFT/REFB pin existence + differential 1 µF.
4. ADV7393 COMP cap value + EXT_LF loop-filter requirement.
5. RP2040 clock source / Y900 crystal + loads.
6. Si5351 Y901 crystal + load caps (not found).
7. AD9742 full AVDD pin count.
8. GS3470/GS2962 per-ball value (0.1 µF vs 0.01+0.1 pairs) + consolidation at layout.
9. ADP7142 ADJ feed-forward + TPS7A2018 NR/SS pin caps.
10. ADV7280 PWRDWN* pin tie (currently floating).

---
*Audit is read-only. No schematic, bom-v1, or refdes-map changes made. Reconciliation + placement happen after Justin reviews and gates.*

---

# Functional fixes (pre-decoupling)

**Date:** 2026-06-15 · **REPORT + PROPOSE only** — no `.kicad_sch`, bom-v1, or refdes-map writes. These are functional defects (floating required pins / clock integrity), higher-urgency than bypass. Each verified against the live netlist + symbol pin names.

**Clock-source headline:** the audit's "Y900/Y901 not found" was a false alarm — it scanned only `C` refdes. **Both crystals exist and are correctly wired.** No dead-subsystem bug. The only clock-integrity defect is Y900's missing load caps.

| # | Item | PIN ACTUAL NET | VERDICT | PROPOSED FIX |
|---|------|----------------|---------|--------------|
| 1 | **U600 COMP** (ADV7393 p29) | `unconnected-(U600-COMP-Pad29)` — isolated, no co-members | **REAL BUG** — DAC reference-compensation node floating; encoder won't produce correct levels | **C612** 0.1 µF, U600.29 → GND, at pin. ⚠ verify value (ADV7393 ref: 0.1 µF; some designs add 10 nF ∥) |
| 2 | **U600 EXT_LF** (ADV7393 p22) | `unconnected-(U600-EXT_LF-Pad22)` — isolated | **⚠ CONDITIONAL — not a confirmed bug.** PLL loop-filter mode is register-selectable (software), not pin-strapped, so it can't be read from the netlist. If **internal LF** (typical default) → floating is **OK, no action**. If **external LF** is selected → needs the datasheet RC loop filter on p22. | **Default: leave floating (internal LF).** Only if external-LF mode is intended: add RC per ADV7393 datasheet ⚠ verify values. Recommend confirming the intended PLL config in the ADV7393 register init before deciding. |
| 3 | **U500 PWRDWN\*** (ADV7280 p31) | `unconnected-(U500-PWRDWN*-Pad31)` — isolated | **REAL BUG** — active-low power-down floating; decoder state indeterminate (can latch powered-down) | **R508** 10 kΩ pull-up, U500.31 → DVDDIO (+3V3). (R508 = next free R in 500 block.) Optionally also bring p31 to a GPIO for SW reset — ⚠ confirm if host control wanted; pull-up alone is the minimum fix. |
| 4 | **U900 VREG_VOUT** (RP2040 p45) | `/Clock + sync gen/RP2040_VCORE` — members = U900.45 + DVDD p23 + p50 only; **no caps** | **REAL BUG** — on-chip 1.1 V core LDO requires an output cap to be stable; core may not start | **C913** 1 µF, U900.45 → GND, placed at the pin. (RP2040 hard requirement; also the VCORE→DVDD bypass per the per-pin sweep.) |
| 5a | **RP2040 clock** (Y900, XIN p20 / XOUT p21) | XIN=`GENLK_XI` {U900.20, Y900.1}; XOUT=`GENLK_XO` {U900.21, Y900.3}; Y900.2/4 → GND | **Crystal present + wired = OK.** But **REAL BUG (integrity):** **no load caps** on XIN/XOUT — a bare 12 MHz crystal will be off-frequency / may not start | Add **2× load caps**: C905 (XIN→GND), C906 (XOUT→GND). Value = 2·(CL − Cstray) ⚠ verify Y900 CL (e.g., CL=18 pF → ~27 pF; CL=10 pF → ~15 pF). |
| 5b | **Si5351 clock** (Y901, XA p2 / XB p3) | XA=`SI_XA` {U902.2, Y901.1}; XB=`SI_XB` {U902.3, Y901.3}; Y901.2/4 → GND | **OK — no action.** Crystal present + wired. Si5351 has **internal programmable load caps** (CL register), so external load caps are intentionally omitted. | None. ⚠ verify the Si5351 init sets the CL register (6/8/10 pF) to match Y901's spec. |

## Functional-fix rollup

- **Confirmed REAL BUGs (4):** U600 COMP floating (C612), U500 PWRDWN\* floating (R508 pull-up), U900 VREG_VOUT no cap (C913), Y900 no load caps (C905/C906).
- **Conditional / verify-first (1):** U600 EXT_LF — depends on PLL LF-mode register; likely OK floating (internal LF).
- **Cleared (was suspected):** RP2040 and Si5351 clock sources — **both crystals exist and are wired**; not dead. Si5351 needs no external load caps.
- **New parts if all fixes taken:** 4 caps (C612, C905, C906, C913) + 1 resistor (R508). C612/C913 overlap the decoupling sweep (same caps); C905/C906 share the sheet-9 900-block — final numbering reconciled at placement.
- **⚠ verify before placing:** ADV7393 COMP value + PLL LF mode; Y900 crystal CL (load-cap value); Si5351 CL register; ADV7280 p31 (pull-up only vs host-GPIO control).

*No schematic / bom-v1 / refdes-map changes made. Wiring waits for Justin's gate.*
