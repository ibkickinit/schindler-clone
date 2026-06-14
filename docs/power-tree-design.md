# Schindler 2.0 Carrier — Power-Tree Design (Sheet 3)

**Status:** Decisions locked 2026-06-13; corrections 2026-06-13b (datasheet verify pass, see §0a) — Justin delegated the open calls ("this carrier board is your brain child"); the ❓ items are now Claude's committed calls (see §0), each flagged so any can be overridden at wiring time. Topology + netlist unchanged; 🧮/🔧 values keep their verify-before-fab flags. Derived from `01-spec.md` §1.3 + `bom-v1.md` §3 + `refdes-map.md` (300s block). Resolves capture-log gap #1 (no pin-level netlist / no passive values) and gap #6 (3 under-specified connections).
**How to read the confidence flags:** ✅ deterministic (datasheet typical-app or spec) · 🧮 computed, equation shown — **verify the datasheet constant** · 🔧 starting value, **bench-tune** · ❓ genuine design decision — **Justin's call**.
**Scope:** Sheet 3 only. TE0720 core rails (Vccint 1.0 V / 1.8 V / DDR3L 1.35 V) are made **on-module** from 5 V VIN — not on the carrier.

---

## 0. Decisions locked (2026-06-13, Claude's calls under delegation)

- **eFuse enable / UVLO (was gap #6a) — RESOLVED.** The placed TPS2660x symbol exposes **separate `SHDN`, `UVLO`, `OVP` pins** — no coexistence conflict. **LTC2954 `EN` → TPS26601 `SHDN`** (soft-power gate); **`UVLO`** divider from `+12V_RAW`; **`OVP`** divider from `+12V_RAW`. ⚠ At wiring, verify `SHDN` polarity (active-low shutdown) vs the LTC2954 `EN` sense — add an inverter only if they oppose.
- **eFuse `MODE` — latch-off; part = TPS26601 (DECIDED 2026-06-13b, see §0a-1).** The '601's `MODE`-open default *is* circuit-breaker-with-latch, so **`MODE` is left open — no strap**. (Swapped from the '600, whose open default is auto-retry; identical pinout, symbol reused.) Pairs correctly with LTC2954 → `SHDN` reset (button cycle clears a latched fault).
- **INA226 (was gap #6b) — RESOLVED.** Shunt **R300 in `+12V_PROT`** (load current; bus ≈ PSU); **VS from `+3V3`**; address **0x40** (A0/A1→GND); **I²C master = Zynq PS** on `I2C_HK_SDA/SCL`.
- **ADP7142 POLs.** U307 → AD9204 clean AVDD (**1.8 V**) · U308 → ADV7280 analog (**1.8 V**) · U309 → **`+3V3_A`** (ADV7393 VAA, **3.3 V** — *ADV7511 analog removed, it's 1.8 V; see §0a-4*). `+3V3_A` is a **dedicated LDO (U309), not a bare ferrite tap** — cleaner for the DAC analog. POLs may relocate to their load sheets during wiring (**set each ADJ divider there, against the device datasheet**).
- **L302 added.** The 1.2 V buck needs its own inductor → L-block becomes L300 / L301 / **L302** (extends the refdes-map allocation).
- **TPS2660x symbol — DONE.** OUT pins retyped in JustinLibrary 2026-06-13: pin 15 `OUT` → `power_out`, pin 16 `OUT-1` → `passive` (kills the false pin-to-pin error, gives `+12V_PROT` a driver). *(Symbol reused for the TPS26601 — identical pinout; set value/MPN to '601.)*

- **B33 = 1.8 V + new `+1V8_D` digital rail (DECIDED 2026-06-13c).** The AD9204 runs DRVDD = 1.8 V (confirmed), so its CMOS data won't clear a 3.3 V bank's ~2.0 V VIH. B33's VCCIO33 is re-strapped to **1.8 V** (module allows 1.2–3.3 V on B33; carrier-fed on JM2-5 — see `sheet3-te0720-som-backbone.md` §2). Adds a small **U310 1.8 V LDO off `+3V3`** (`+1V8_D`, ~0.1 A) feeding VCCIO33 + AD9204 DRVDD, kept separate from analog `+1V8_A`. AD9204 AVDD stays on its dedicated POL (U307 = `AVDD_GENADC`); LTC6912 PGA SPI confirmed RP2040-mastered (not on B33). **Sheet 3 gains the U310 LDO — the agent revisits Sheet 3 for this one part.**
- **B34 = 1.8 V + `+1V8_D` resized (DECIDED 2026-06-13e, Option A).** GS3470 SDI-RX I/O = 1.8/2.5 V, GS2962 SDI-TX = 1.8/3.3 V → only common I/O = **1.8 V**, so VCCIO34 is re-strapped 3.3 V → **1.8 V** (module allows 1.5–3.3 V on B34). The **AD9742 SYNC-1 DAC is a 2.7–3.6 V part** and can't run 1.8 V, so it moves off B34 → **B35** (3.3 V) — no DAC rail change (stays AVDD/DVDD/CLKVDD = 3.3 V). **`+1V8_D` now also feeds VCCIO34** → resize the U310 LDO from ~0.1 A to **~0.3–0.4 A** (B34 adds ~22 output pins of switching VCCIO load; confirm against the bank toggle estimate before locking the LDO). No new rail, no new part — just the U310 spec bump + the VCCIO34 strap. See `sheet3-te0720-som-backbone.md` §2/§5/§6.
- **Digital-1.8 V pins re-homed onto `+1V8_D` (DECIDED 2026-06-13e).** The digital-core / digital-I/O 1.8 V pins (**ADV7280 DVDD, ADV7393 digital VDD, LT8619C VDD18**) move off the precision analog `+1V8_A` onto the digital `+1V8_D` — analog rail stays quiet, digital switching stays on the digital rail. Analog/PLL 1.8 V (ADV7280 AVDD/PVDD = POL U308, ADV7393 PVDD, ADV7511 analog/PLL, AD9204 AVDD = POL U307) stays on `+1V8_A` / its dedicated POLs. **The agent sets the exact per-pin split at each load sheet against the device datasheet.** `+1V8_D` grows to ~0.4–0.5 A (VCCIO33 + VCCIO34 + AD9204 DRVDD + the three digital cores).

All 🧮 (datasheet-constant) and 🔧 (bench-tune) values below keep their flags — those are verify-before-fab, not design-authority calls.

---

## 0a. Corrections (2026-06-13b — datasheet verification pass)

Four corrections from a datasheet check (Claude); each overridable at wiring time.

1. **eFuse fault response — RESOLVED 2026-06-13b → TPS26601.** Latch-off is the posture; the '601's `MODE`-open default *is* circuit-breaker-with-latch (TI SLVSDG2G, Device Comparison Table), so **`MODE` is left open (NC) — no strap component**. Swapped from the TPS26600 (whose open default is auto-retry); same family/pinout, so the placed symbol is reused — just set its value/MPN to TPS26601. Latch-off pairs correctly with the LTC2954 → `SHDN` chain — cycling `SHDN` clears a latched fault, exactly what the power button does. BOM line updated in `bom-v1.md` §3.
2. **LTC2954 `PDT` value was wrong.** `PDT` is a **capacitor-only** timer at **6.4 s/µF** (no series R — the prior "R·C" note was incorrect). The specced 0.1 µF gives only ~0.64 s force-off, not the intended ~5 s. **For ~5 s hard-off use C311 ≈ 0.82 µF** (5 ÷ 6.4 = 0.78 µF → E-series 0.82 µF). 🔧 bench-confirm.
3. **LTC2954 `ONT` (turn-on timer) was missing from the netlist.** `ONT` sets extra hold-to-turn-on time at 6.4 s/µF; **floating = default ~64 ms debounce** (valid). For anti-accidental power-on on a rack box, **C312 ≈ 0.1 µF (+~0.64 s deliberate hold)** is recommended. Added to the §2.1 netlist table.
4. **ADV7511 analog does not belong on `+3V3_A`.** The ADV7511's analog/PLL supplies (AVDD/PVDD) are **1.8 V**, not 3.3 V (3.3 V is only DVDD-IO). `+3V3_A` correctly serves **ADV7393 VAA (3.3 V)**; **ADV7511 analog moves to the 1.8 V analog domain** (`+1V8_A` or its own POL) — resolve at the ADV7511 load sheet. *(Confirm against the ADV7511 datasheet.)*

**ADP7142 POL target voltages** (set each ADJ at its load sheet, confirm vs device datasheet): U307 = **1.8 V** (AD9204 AVDD) · U308 = **1.8 V** (ADV7280 AVDD/PVDD) · U309 = **3.3 V** (`+3V3_A`, ADV7393 VAA).

---

## 1. Rail tree + current budget

| Rail | Source | V | I budget | Feeds |
|---|---|---|---|---|
| `+12V_RAW` | PSU → J301 Mini-Fit | 12 V | ~2 A pk | eFuse IN, LTC2954 VIN, INA226 sense |
| `+12V_PROT` | TPS26600 OUT (U300) | 12 V | ~2 A (I_LIM 2.5 A) | 5 V buck, 3.3 V buck, bulk |
| `+5V` | LMR33640 U303 | 5.0 V | ~3 A | TE0720 VIN, USB host, LMH6643 ×2, 1.2 V buck IN |
| `+3V3` | LMR33640 U304 | 3.3 V | ~2.5 A | TE0720 3V3IN, **2× VCCIO (B13/B35)**, carrier digital, 1.8V-A + 3.3V-A + 1.8V-D LDO inputs |
| `+1V2` | TLV62568 U305 | 1.2 V | ~0.4 A | GS3470, GS2962 core [Pro] |
| `+1V8_A` | TPS7A2018 U306 | 1.8 V | ~0.3 A | **Precision analog 1.8 V only:** ADV7393 PVDD (PLL) + ADV7511 analog/PLL (§0a-4). *(ADV7280 analog/PLL = dedicated POL U308; AD9204 AVDD = U307. Digital-1.8 V pins moved to `+1V8_D` — 2026-06-13e.)* |
| `+1V8_D` | LDO U310 (off `+3V3`) | 1.8 V | **~0.4–0.5 A** | **Digital 1.8 V:** VCCIO33 (B33) + VCCIO34 (B34) + AD9204 DRVDD **+ ADV7280 DVDD + ADV7393 digital VDD + LT8619C VDD18** — kept off analog `+1V8_A`. New 2026-06-13c (B33); **resized 2026-06-13e** (B34 1.8 V + digital-pin re-home) — confirm LDO current vs the total digital load. |
| `+3V3_A` | ferrite tap + ADP7142 POL | 3.3 V | ~0.3 A | ADV7393 VAA (GS2962 driver = own ferrite branch). **ADV7511 analog removed — it's 1.8 V, see §0a-4** |
| `GND` | single-point earth at chassis stud | — | — | all |

❓ **Current budgets** are from §1.3's stated figures; confirm against `pin-budget.md` / measured loads before locking buck inductor + output-cap selection.

---

## 2. Per-block design

### 2.1 Soft-power + protection front end (U302 LTC2954, U300 TPS26600)

**Intent (from §1.3):** always-on 12 V domain holds the LTC2954; debounced front-panel button → LTC2954 EN → drives the eFuse enable; eFuse provides reverse-polarity/-current, OVP, OCP (I_LIM ≈ 2.5 A), controlled inrush.

**LTC2954-1 (U302) netlist:**
| Pin | Net | Notes |
|---|---|---|
| V+ | `+12V_RAW` | ✅ always-on domain |
| GND | `GND` | ✅ |
| PB̄ | `PWR_BTN_N` → hier label to Sheet 11 (front-panel button via J1100) | ✅ active-low, button to GND; 100 nF debounce cap to GND (C310 🔧) + internal pull-up |
| EN | `EFUSE_EN` → U300 enable | ✅ push-pull enable output (see eFuse EN note below) |
| INT̄ | `PWR_INT_N` → hier label to Sheet 2 (Zynq GPIO, orderly-shutdown request) | ✅ open-drain, 10 k pull-up to +3V3 (R310 ✅) |
| KILL̄ | `PWR_KILL_N` ← hier label from Sheet 2 (Zynq GPIO, clean power-down) | ✅ 10 k pull-up to +3V3 (R311 ✅) |
| ONT | C-ONT to GND sets hold-to-turn-on (6.4 s/µF); **float = default ~64 ms** | 🔧 **added 2026-06-13b** — recommend **C312 ≈ 0.1 µF** (+~0.64 s deliberate hold, anti-accidental) or float for default. See §0a-3 |
| PDT | **C-only** power-down (hold-to-off) timer, **6.4 s/µF, no series R** | 🔧 **corrected 2026-06-13b**: for ~5 s hard-off **C311 ≈ 0.82 µF** (prior 0.1 µF = only ~0.64 s). Turn-on KILL-blank 512 ms is internal. See §0a-2 |

❓ **gap #6(a) — which eFuse pin EN drives.** Proposed: LTC2954 `EN` (push-pull, high = on) → TPS26601 **EN/UVLO** pin. **Caveat to verify:** if the UVLO divider also sits on EN/UVLO, a push-pull EN output fights the divider — so either (i) drive EN/UVLO from LTC2954 EN and set UVLO via the internal threshold only (no external divider), or (ii) use a separate SHDN̄/control pin for the soft-power gate and keep the UVLO divider independent. **Confirm against the TPS26601 variant's pin map before wiring.**

**TPS26601 (U300) netlist + set components** — *(swapped from '600 2026-06-13b — latch default; identical pinout, symbol reused)* functional pin groups (the symbol exposes IN/IN-1, OUT/OUT-1, GND, EN/UVLO, OVP, ILIM, dVdt, MODE, IMON, FLT̄):
| Function | Net / component | Value | Flag |
|---|---|---|---|
| IN, IN-1 | `+12V_RAW` | — | ✅ paralleled input pins, same node |
| OUT, OUT-1 | `+12V_PROT` | — | ✅ paralleled output pins (see symbol fix below) |
| GND / thermal pad | `GND` | — | ✅ |
| EN/UVLO | `EFUSE_EN` | — | per EN note above |
| ILIM | R_ILIM to GND | 🧮 set for **2.5 A**: I_LIM = K_ILIM / R_ILIM — **look up K_ILIM in the datasheet**, then pick E96. Flag 🧮 |
| OVP | divider from `+12V_RAW` | 🧮 set trip ~15–16 V (headroom over 12 V PSU); R_OVP_top/bot per datasheet V_OVP threshold. Flag 🧮 |
| dVdt | C_dVdt to GND | 🔧 set inrush slew to charge the 66 µF bulk without tripping I_LIM; start ~10 nF, **bench-tune** |
| MODE | **open (NC)** — latch on the TPS26601 | ✅ **resolved 2026-06-13b**: TPS26601 chosen; `MODE`-open default is circuit-breaker-with-latch, so leave MODE open — no strap. Add an ERC NC flag. See §0a-1 |
| IMON | to GND via R_IMON, or to an ADC | 🔧 only if used; INA226 already gives telemetry → can leave IMON per datasheet default |
| FLT̄ | `EFUSE_FLT_N`, 10 k pull-up to +3V3 (R312) → hier label to Sheet 2 (Zynq fault GPIO) | ✅ open-drain |

**Bulk (gap #6(c)):** ❓ C300–C302 = 3× 22 µF 25 V X7R (GRM32) on **`+12V_PROT`** (eFuse output / bucks' input) — the dVdt soft-start is sized to charge exactly this node. Add 1× 1 µF 25 V at the eFuse **input** (`+12V_RAW`, C303 ✅) per datasheet. Recommend `+12V_PROT` for the bulk; confirm.

### 2.2 INA226 power monitor (U301) + shunt (R300)

❓ **gap #6(b) — sense location + supply + I²C identity.** Proposed:
- **Shunt R300 = 5 mΩ in `+12V_PROT`** (high-side, just after eFuse OUT) → measures real system load; bus voltage ≈ PSU output (eFuse RON drop ~tiny). Full-scale: 81.92 mV / 5 mΩ = **16.4 A** range, **0.5 mA LSB** ✅ (ample for ~2 A).
- IN+ / IN− across R300; VBUS → `+12V_PROT`; **VS → `+3V3`** (telemetry is on-state only — acceptable). ✅
- A0/A1 → both GND = **0x40** 🔧 (deconflict on the housekeeping bus).
- SDA/SCL → **`I2C_HK_SDA` / `I2C_HK_SCL`** hier labels. ❓ **master = Zynq PS** (telemetry "to Zynq PS" per §1.3) — confirm PS-I²C vs genlock-RP2040 bus; this net is defined here and joined on Sheet 2/10. ALERT̄ → optional `INA_ALERT_N` + 10 k pull-up (R313), or leave NC.

### 2.3 5 V buck — LMR33640 (U303), 12→5 V, ~3 A

Standard LMR33640 fixed-freq buck, external FB divider. ✅ topology / 🧮 divider / 🔧 L+C.
| Pin | Net |
|---|---|
| VIN | `+12V_PROT` (+ C320 4.7 µF + C321 0.1 µF input ✅) |
| SW | `SW_5V` → L300 |
| VOUT(node) | `+5V` (L300 other end; C322/C323 output) |
| FB | divider `+5V`→FB→GND |
| BOOT | C324 100 nF to SW ✅ |
| EN/VCC/PG | EN → enable (tie to `+12V_PROT` via R or to EFUSE domain — **always-on after eFuse**); VCC 1 µF (C325); PG → optional `PG_5V` pull-up |
| GND / pad | `GND` |

🧮 **FB divider:** V_OUT = V_REF·(1+R_top/R_bot). LMR33640 **V_REF = 1.0 V (verify)**. For 5.0 V: R_top/R_bot = 4.0 → R301 = 100 k, R302 = 24.9 k (5.02 V). 🔧 **Inductor L300:** target ~30–40 % ripple at 3 A → L ≈ 4.7 µH (verify with f_SW and the datasheet ripple eqn). 🔧 **Output cap:** 2× 22 µF + 0.1 µF (C322/C323). FPWM vs auto-mode = the ADDA/ADDD suffix (gap #4) ❓ — recommend FPWM (ADDA) for low-noise / predictable spectrum near the video analog.

### 2.4 3.3 V buck — LMR33640 (U304), 12→3.3 V, ~2.5 A

Identical part/topology to U303. 🧮 FB for 3.3 V: R_top/R_bot = 2.3 → R303 = 100 k, R304 = 43.2 k (3.32 V). L301 ≈ 4.7 µH 🔧; C326/C327 output; C328/C329 input; C330 boot; C331 VCC. Same EN/PG treatment. ✅/🧮/🔧 as 2.3.

### 2.5 1.2 V buck — TLV62568 (U305), 5→1.2 V, ~0.4 A [Pro]

| Pin | Net |
|---|---|
| VIN | `+5V` (+ C332 10 µF + C333 0.1 µF) |
| SW | `SW_1V2` → L302 (note: refdes-map allocated L300/L301 only — **add L302** 🔧, flag refdes-block extension) |
| VOS/FB | divider `+1V2`→FB→GND |
| EN | enable (tie to +5V or a Pro-stuff gate) ❓ |
| GND | `GND` |

🧮 **FB:** TLV62568 **V_REF = 0.6 V (verify)** → 1.2 V needs R_top = R_bot; R305 = 100 k, R306 = 100 k. L 🔧 = 1.0–2.2 µH per datasheet; C334 output 22 µF. (Adjustable `DBV` part assumed; if a fixed 1.2 V variant is chosen the divider drops out — gap #4 ❓.)

### 2.6 1.8 V analog LDO — TPS7A2018 (U306), 3.3→1.8 V, ~0.4 A

✅ **Fixed 1.8 V** part (the "18" suffix) → **no FB divider**. Ferrite-isolated from the buck.
| Pin | Net |
|---|---|
| IN | `+3V3` via **FB300** ferrite (+ C335 1 µF) ✅ |
| OUT | `+1V8_A` (+ C336 1 µF + C337 0.1 µF) ✅ |
| EN | tie to IN (always-on with rail) or a gate ✅ |
| NR/SS | C338 10 nF noise-reduction cap ✅ (low-noise genlock rails) |
| GND | `GND` |

### 2.7 Clean-analog POL LDOs — ADP7142 ×3 (U307–U309)

❓ **Genuinely under-specified** ("sized at schematic," §1.3). These are point-of-load ultra-low-noise LDOs per ADC/decoder. **Proposed assignment (confirm, and consider relocating each to its load's sheet):**
- U307 → clean **AVDD for AD9204** genlock ADC (from `+3V3` via FB301) — the most noise-critical.
- U308 → clean analog for **ADV7280** decoder.
- U309 → clean **`+3V3_A`** (3.3 V) for ADV7393 VAA (**ADV7511 analog removed — 1.8 V, §0a-4**) (or this stays a passive ferrite tap FB302 + bulk per §1.3 — ❓ LDO vs ferrite-tap is the open call).
- ADP7142 = adjustable (AUJZ), V_REF = 1.2 V 🧮 → divider per target rail; CIN/COUT 2.2 µF + NR cap. Each: IN, OUT, ADJ(divider), EN, GND.

**Note:** the spec describes `+3V3_A` as a *ferrite tap* (FB + local bulk), while also listing ADP7142 POLs. Decide per rail whether it's a ferrite tap or a dedicated LDO. ❓

### 2.8 Ferrites (FB300–FB305)

| Ref | Branch | ✅/❓ |
|---|---|---|
| FB300 | 3.3 V → TPS7A2018 IN (1.8V-A branch) | ✅ |
| FB301 | 3.3 V → AD9204 clean branch | ✅ |
| FB302 | 3.3 V → `+3V3_A` (ADV7393 VAA / ADV7511 analog) | ✅ |
| FB303 | 3.3 V → **GS2962 cable driver own branch** (SDI edges off the DAC analog) | ✅ per §3.4 |
| FB304/FB305 | spare / per-decoder analog taps | ❓ assign at schematic |

🔧 Ferrite value: ~600 Ω @ 100 MHz, rated > branch current (e.g. BLM21/BLM18 series) — pick per branch current.

---

## 3. Net-name conventions (carry across sheets as global labels)

`+12V_RAW` · `+12V_PROT` · `+5V` · `+3V3` · `+1V2` · `+1V8_A` · `+3V3_A` · `GND` (already used on Sheet 3) — plus the hierarchical control nets: `PWR_BTN_N`, `EFUSE_EN`, `PWR_INT_N`, `PWR_KILL_N`, `EFUSE_FLT_N`, `I2C_HK_SDA/SCL`. Add a **PWR_FLAG** on each generated rail so ERC sees a driver (kills the `power_pin_not_driven` warnings).

---

## 4. Verify-before-fab checklist (the 🧮/🔧/❓ items)

1. ❓ Rail current budgets vs `pin-budget.md` (drives L + C_out selection).
2. 🧮 TPS26601: K_ILIM constant (→ R_ILIM for 2.5 A), V_OVP threshold (→ divider), dVdt cap for the 66 µF bulk. **Datasheet equations.**
3. ❓ eFuse EN vs UVLO-divider coexistence (gap #6a). **MODE resolved 2026-06-13b → TPS26601 chosen, `MODE` open = latch, no strap (§0a-1).**
4. 🧮 Buck V_REF: LMR33640 (assumed 1.0 V), TLV62568 (0.6 V), ADP7142 (1.2 V) — confirm, then the dividers above are correct.
5. 🔧 Inductors L300/L301/**L302** + output caps — bench/ripple verify; **L302 extends the refdes-map L-block (was L300/L301 only)**.
6. ❓ INA226 sense node (`+12V_PROT` proposed), VS rail, address 0x40, I²C master (PS vs RP2040) — gap #6b.
7. ❓ ADP7142 POL assignments (targets §0a: U307/U308 = 1.8 V, U309 = 3.3 V — **set each ADJ at its load sheet**) + ferrite-tap-vs-LDO for `+3V3_A` (§2.7); **ADV7511 analog off `+3V3_A` → 1.8 V, §0a-4**; and whether POLs relocate to their load sheets.
8. 🔧 LTC2954 **`PDT` = C-only ~0.82 µF for ~5 s (§0a-2); `ONT` = 0.1 µF or float (§0a-3)**; PB debounce cap.
9. Symbol: TPS26600 OUT pins → power_out + passive (see capture-log gap #3 fix) before this wires ERC-clean.
10. **B33 + B34 re-strap + `+1V8_D` (2026-06-13c / -13e):** add **U310** 1.8 V LDO (off `+3V3`) → VCCIO33 (JM2-5) **+ VCCIO34 (JM2-1/3) + AD9204 DRVDD**; B33 **and B34** I/O = LVCMOS18; AD9204 AVDD stays on U307 (`AVDD_GENADC`); LTC6912 PGA SPI is RP2040-mastered (not B33). **Resize U310 ~0.1 A → ~0.4–0.5 A** for the added B34 VCCIO load + the re-homed digital-1.8 V pins (ADV7280 DVDD, ADV7393 digital VDD, LT8619C VDD18 moved off `+1V8_A`; set the per-pin split at each load sheet). The **AD9742 SYNC-1 DAC moved B34→B35** (3.3 V-only part; no DAC rail change). AD9204 VREF bypass = 470 nF 6.3 V X5R; set the SENSE strap for internal-reference mode per the datasheet. See `sheet3-te0720-som-backbone.md` §2/§5/§6. **U310 part (MPN TBD, flagged 2026-06-13e):** the ~0.5 A `+1V8_D` load exceeds the 300 mA TPS7A2018 class — pick a **≥0.5 A 1.8 V LDO**; note 3.3→1.8 V @ 0.5 A ≈ **0.75 W dissipation**, so choose package/thermal accordingly, or use a **small buck** if the dissipation is unwelcome near the analog front-end.

Once Justin ratifies §2–§4, the agent can wire Sheet 3 fully from this doc and it should reach ERC-clean (rails driven, set components placed, control nets as hier labels).
