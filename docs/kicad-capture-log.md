# Schindler 2.0 Carrier — KiCad Capture Log

**Pass:** First pass (Phase 0 recon → Phase 1 skeleton → Phase 2 Sheet-3 pilot). **Date:** 2026-06-13.
**Project:** `KiCad/SchindlerCarrierBoard_V1/SchindlerCarrierBoard_V1/` · KiCad 10 (`kicad-cli 10.0.3`, format `version 20260306`).
**Method:** every refdes/value/footprint/sheet-assignment pulled from the SSOT only (`refdes-map.md`, `bom-v1.md`, `kicad-symbol-sourcing.md`, `sheet3-te0720-som-backbone.md`). **No values, nets, or pin assignments were invented.** Where the SSOT is silent, the pin/value is left blank/unconnected and listed below.
**Status:** ⏸ **Halted for review after the Sheet-3 pilot** (per the agent prompt's Phase-2 checkpoint). No `git commit`/`push` performed.

> `kicad-cli` is **not on `$PATH`**; it lives at `/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli`. All validation below was run with that full path.

---

## 0. Decisions taken (from Justin, 2026-06-13)

1. **Stale root content deleted.** The existing root sheet was *not* an empty starter — it held a partial 12 V-protection block (`Q1 = JustinLibrary:DMP3098L-7` P-MOS + `R1` 100k / `R2` / `C2` / `C3`, none wired). `DMP3098L-7` is the part `kicad-symbol-sourcing.md` flags as *legacy/unused, superseded by the TPS26600 eFuse — "Ignore; don't place."* It was removed and the root rebuilt as a clean 12-sheet hierarchy. **Backup:** `SchindlerCarrierBoard_V1.kicad_sch.bak-precapture-20260613` (in the project dir).
2. **Symbol library = `JustinLibrary` for all.** A new project-local `sym-lib-table` was created registering `JustinLibrary` (current format, `version 20251024`). All four "custom" symbols (`FN9260B-6-06`, `NHD-1.5…`, `NHD-2.9…`, `NFM21_Feedthrough`) exist in `JustinLibrary` in current format, so `lib_id`s use `JustinLibrary:…`. `_KiCad/Schindler.kicad_sym` (legacy format `20211014`, duplicate symbols) was **not** registered — see gap #8.
3. **Strict SSOT for Sheet 3.** Components placed with known refdes/value/footprint; only the explicitly-specified rail flow wired; everything else left unconnected and flagged here.

---

## 1. Phase 1 — Skeleton (built + validated)

Root (`SchindlerCarrierBoard_V1.kicad_sch`, paper A3, root uuid preserved `7e9730cc-…`) with 11 hierarchical sheet symbols → 11 child files:

| Page | Sheet | File |
|---|---|---|
| 1 | Root / hierarchy | `SchindlerCarrierBoard_V1.kicad_sch` |
| 2 | TE0720 SoM backbone | `02-te0720-som-backbone.kicad_sch` |
| 3 | Power tree | `03-power-tree.kicad_sch` ← pilot |
| 4 | HDMI in/out | `04-hdmi-in-out.kicad_sch` |
| 5 | Analog video in | `05-analog-in.kicad_sch` |
| 6 | Analog video out | `06-analog-out.kicad_sch` |
| 7 | SDI in/out | `07-sdi.kicad_sch` |
| 8 | Genlock front-end | `08-genlock.kicad_sch` |
| 9 | Clock + sync gen | `09-clock-sync.kicad_sch` |
| 10 | Control + networking | `10-control-net.kicad_sch` |
| 11 | Front-panel + LED | `11-panel-led.kicad_sch` |
| 12 | RF interface + debug | `12-rf-interface-debug.kicad_sch` |

**Validation:** `kicad-cli sch erc` → *0 violations* on the empty skeleton; `kicad-cli sch export netlist` → all 12 sheets recognized (`/` + 11 named children), 0 components. Loads clean.

---

## 2. Phase 2 — Sheet 3 (Power tree) pilot

**25 components placed** (rotation 0, on a rough 1.27 mm-snapped grid — placement is scaffolding; arrange visually later). All Sheet-3 parts the SSOT enumerates with specificity; no speculative passives added.

| Refdes | lib_id | Value | Footprint | on board | Wired pins (rail) |
|---|---|---|---|---|---|
| J300 | `JustinLibrary:FN9260B-6-06` | FN9260B-6-06 | — (none) | **no** (chassis IEC inlet) | none (chassis-wired) |
| F300 | `Device:Fuse` | 2A T (0213002.MXP) | — (TBD) | **no** (in IEC holder) | none |
| J301 | `Connector_Generic:Conn_01x02` | Molex 0039291028 | — (TBD) | yes | 1→+12V_RAW, 2→GND |
| U300 | `JustinLibrary:TPS26600PWPR` | TPS26600 | — (TBD) | yes | IN/IN-1→+12V_RAW, OUT/OUT-1→+12V_PROT, GND→GND |
| U301 | `JustinLibrary:INA226` | INA226AIDGSR | — (TBD) | yes | GND→GND only |
| R300 | `Device:R` | 5m 1% | — (TBD) | yes | none (shunt placement unspecified) |
| U302 | `JustinLibrary:LTC2954ITS8-2PBF` | LTC2954-1 ⚠ | — (TBD) | yes | VIN→+12V_RAW, GND→GND |
| U303 | `Regulator_Switching:LMR33640ADDA` | LMR33640 (5V) | — (TBD) | yes | VIN→+12V_PROT, GND→GND |
| U304 | `Regulator_Switching:LMR33640ADDA` | LMR33640 (3.3V) | — (TBD) | yes | VIN→+12V_PROT, GND→GND |
| U305 | `Regulator_Switching:TLV62568DBV` | TLV62568 (1.2V) | — (TBD) | yes | VIN→+5V, GND→GND |
| U306 | `Regulator_Linear:TPS7A20xxxDBV` | TPS7A2018PDBVR | — (TBD) | yes | VIN→+3V3, OUT→+1V8_A, GND→GND |
| U307–U309 | `Regulator_Linear:ADP7142AUJZ` | ADP7142 (adj) | — (TBD) | yes | GND→GND only |
| L300, L301 | `Device:L` | buck L 5V/3V3 (TBD) | — (TBD) | yes | none |
| C300–C302 | `Device:C` | 22uF 25V X7R | — (TBD) | yes | none (bulk node unspecified) |
| FB300–FB305 | `Device:FerriteBead` | ferrite (TBD) | — (TBD) | yes | none |

**Rails wired (global labels at pin endpoints — verified by netlist, no accidental merges):**
- `+12V_RAW` = J301.1, U300.IN, U300.IN-1, U302.VIN — *(eFuse + soft-power input, the always-on 12 V domain)*
- `+12V_PROT` = U300.OUT, U300.OUT-1, U303.VIN, U304.VIN — *(protected rail feeding the 5 V & 3.3 V bucks)*
- `+5V` = U305.VIN · `+3V3` = U306.VIN · `+1V8_A` = U306.OUT *(LDO clean output)*
- `GND` = all device ground pins incl. LMR33640 exposed-pad (pin 9).

**Validation:** netlist export OK; ERC loads the full hierarchy. ERC tally (all explained below): `pin_not_connected` 84 · `pin_not_driven` 29 · `power_pin_not_driven` 8 · `isolated_pin_label` 3 · `pin_to_pin` 1 · `lib_symbol_mismatch` 1 · `endpoint_off_grid` 0.

### 2a. Pins/nets intentionally left UNCONNECTED (the SSOT does not specify them)

- **All eFuse U300 set/monitor pins** — UVLO, OVP, ILIM, DVDT, MODE, SHDN, RTN, IMON, FLT. (Set-resistor values + EN source not in SSOT.)
- **INA226 U301** — Vbus, Vin+, Vin− (high-side sense across R300; *location before/after eFuse not specified*), VS (IC supply rail not specified), SDA/SCL/ALERT (housekeeping-I²C net name not defined), A0/A1 (address straps not specified).
- **LTC2954 U302** — PB (front-panel button via J1100, inter-sheet), EN/*EN (drives the eFuse enable — *which TPS26600 pin is not specified, see gap #6*), *INT/*KILL (↔ Zynq GPIO, inter-sheet), ONT/PDT (timing R-C not specified).
- **Bucks U303/U304/U305** — SW, FB, BOOT, VCC, EN, PG. (Output L + FB-divider network + EN logic not in SSOT → +5V/+3V3/+1V2 outputs are **not** sourced on this sheet yet.)
- **LDOs U306–U309** — U306 EN/NC; U307–U309 VIN, VOUT, EN, SENSE/ADJ (ADP7142 input rail + output voltages "set at schematic" — not in SSOT).
- **R300, L300/L301, C300–C302, FB300–FB305** — all pins (no values or topology specified).

### 2b. Footprints left TBD

**Every Sheet-3 footprint is blank.** `kicad-symbol-sourcing.md` records footprints only for the four custom symbols, and for the one used here (`FN9260B-6-06`) the recorded decision is **"No PCB footprint — chassis/panel-mount, exclude-from-board"** (applied: `on_board no`). `F300` likewise excluded (cartridge in the IEC holder). All other Sheet-3 footprints are unrecorded → blank, to be assigned in the dedicated footprint pass.

---

## 3. SSOT gaps & ambiguities found (most valuable output — what the spec is missing)

1. **No pin-level power-tree netlist, and no individual passive values.** `refdes-map.md` allocates the blocks (`R301–R330`, `C300–C349`, `L300/L301`, `FB300–FB305`) and `bom-v1.md` §3 gives block-level rail flow + the 3× GRM32 22 µF bulk + targets (I_LIM ≈ 2.5 A, PDT ~5 s) — but **no values** for the eFuse OVP/UVLO/ILIM/dVdt set resistors, LMR33640 feedback dividers, decoupling caps, inductors, ferrites, or LTC2954 timing/PB R-C, and **no pin-to-pin wiring** for the power tree. This is the single biggest blocker to a fully-wired Sheet 3. → *Decision needed: supply a power-tree detail doc, or authorize deriving standard values from the TI/ADI datasheets (currently disallowed by the "don't invent" rule).*
2. **LTC2954 variant mismatch.** BOM + refdes-map call for the **`-1`**; the only LTC2954 symbol in `JustinLibrary` is **`LTC2954ITS8-2PBF`** (the `-2`). Pin-identical TSOT-23-8, so the symbol is reusable, but the `-1`/`-2` differ in pushbutton turn-on behavior. Value field set to `LTC2954-1` per BOM intent; **confirm the variant** (and whether to rename/add the correct symbol). `kicad-symbol-sourcing.md` line claiming "LTC2954-1 (added)" is inaccurate.
3. **TPS26600PWPR symbol quality.** Output pins OUT (15) / OUT-1 (16) are typed **`Output`**, so tying them (they are the same physical node — paralleled eFuse outputs) raises a `pin_to_pin` ERC *error*. The connection is correct; the symbol's pin electrical type should be `power_out` (or `passive`). Recommend fixing in `JustinLibrary`.
4. **Regulator package/variants not locked in the SSOT.** Picked for the pilot (flag for confirmation): LMR33640 → `ADDA` (the `A`/`D` suffix = Fsw/FPWM option is unspecified; pinout identical); TLV62568 → `DBV` (SOT-23-6; bom doesn't fix the package — DDC/DRL/ADRL also exist); TPS7A2018 → `TPS7A20xxxDBV` (matches the BOM's `…PDBVR`); ADP7142 → `AUJZ` (TSOT-23-6 adjustable; `ARDZ` SOIC also valid).
5. **Footprints unrecorded** for all Sheet-3 parts except `FN9260B-6-06` (= none). Needs the footprint pass.
6. **Three under-specified connections** (left unwired, flagged): (a) which TPS26600 pin the LTC2954 EN output drives (SHDN vs UVLO); (b) INA226 high-side sense node (before/after the eFuse) + its supply rail + the housekeeping-I²C net identity; (c) the bulk-cap node (C300–C302 — input vs protected side).
7. **Doc → library symbol-name drift** (used the library names; library wins): `TPS26600`→`TPS26600PWPR`, `LMH6643`→`LMH6643MA`, `AD9742`→`AD9742ARUZ`, `BT817Q`→`BT817AQ-T`; ferrite is `Device:FerriteBead` (no underscore), not `Device:Ferrite_Bead` as `kicad-symbol-sourcing.md` states.
8. **`_KiCad/Schindler.kicad_sym` is legacy-format (`20211014`) and fully duplicated in `JustinLibrary`.** Not used. Recommend retiring it (or upgrading + de-duping) to avoid two sources of truth for the four custom symbols.
9. **`carrier-schematic-capture-plan.md` (2026-06-09) is superseded** by the newer SSOT (eFuse replaces the DMP3098L FET; 1.0 V/1.35 V rails moved on-module; OPA2350 dropped; ~13-sheet plan → the 12-sheet `refdes-map`). It targets the *other* project (`SchindlerSchematic_V1`). Consider marking it superseded to prevent confusion.
10. **`lib_symbol_mismatch` on U306** — benign artifact of embedding the flattened `extends` symbol (`TPS7A20xxxDBV` → `LP5907MFX-1.2`). Self-heals on first GUI save / "Update Symbol from Library." No connectivity impact.

---

## 4. Proposed Phase-3 rollout plan (after pilot approval)

**Per-sheet method** (repeat sheets 2, 4–12): place every component from `refdes-map.md` with explicit refdes + Value (`bom-v1.md`) + Footprint (where recorded); wire only SSOT-specified nets; flag the rest here; run `kicad-cli sch erc` before moving on.

**Inter-sheet connectivity:** use **hierarchical labels + sheet pins** for the PL bank buses per the `refdes-map` shared-bus maps, and FPGA-bank nets per `sheet3-te0720-som-backbone.md` §5. Global power-rail labels (`+12V_RAW`, `+12V_PROT`, `+5V`, `+3V3`, `+1V8_A`, `+3V3_A`, `+1V2`, `GND`) carry across sheets as already used on Sheet 3.

**Suggested order:** **(2) TE0720 SoM** first (defines the bank net targets every signal sheet terminates on) → **(4) HDMI** → **(5) Analog in** → **(6) Analog out** → **(7) SDI** → **(8) Genlock** → **(9) Clock/Sync** → **(10) Control/Net** → **(11) Panel/LED** → **(12) RF/Debug**. Sheet 1 mechanical (MP101–108, FID101–103, TP1xx) last.

**Blocked-pending items to resolve before/while rolling out:** gap #1 (power-tree values — to finish Sheet 3); the `sheet3-…md` §5 pin map permutability (the schematic becomes the XDC source of truth); confirm gaps #2–#4; the footprint pass (#5). After capture: export KiCad BOM and **diff against `bom-v1.md` pooled quantities** per `refdes-map.md` §"Using this against the netlist."

---

## 5. Phase 3 — Placement rollout (sheets 2, 4–12 + mechanical Sheet 1)

**Mode:** strict-SSOT **placement-only** — every named component from `refdes-map.md` with explicit refdes + Value (`bom-v1.md` MPN) + Footprint (blank; none recorded for these sheets) + embedded `lib_symbols`. **Nothing wired** (no rail/bus labels added — pure placement; wiring is the next pass). Aggregate passive blocks and ambiguous mixed ranges were **not** placed (would require inventing values/part-identity) — flagged below. Multi-unit symbols placed across all units sharing one refdes.

**Pre-roll updates picked up:** TPS26600 OUT-pin retype (Sheet-3 cache refreshed → `pin_to_pin` error cleared, `+12V_PROT` now has a `power_out` driver); JustinLibrary re-read; `power-tree-design.md` noted but **not acted on** (reserved for the wiring pass).

**Validation:** `kicad-cli sch export netlist` + `kicad-cli sch erc` on the full project → both **exit 0** (loads clean, all symbols resolve). **128 components** total. ERC profile (all expected for placement-only): `pin_not_connected` 1496 · `pin_not_driven` 161 · `power_pin_not_driven` 111 · `lib_symbol_mismatch` 3 · `isolated_pin_label` 3 (the last two carried from Sheet 3). No parse errors, no unresolved symbols, no off-grid.

| Sheet | Placed (component / lib_id / value) | Not placed — flagged |
|---|---|---|
| **2 SoM** | J200 `JustinLibrary:TE0720-03-61C33FAS` = `TE0720-04-62I33MA` (4 units); TP201–TP210 `Connector:TestPoint` | HS201 (heatsink, mechanical); C200–C239 (decoupling array, values TBD) |
| **4 HDMI** | J400/J401 `Connector:HDMI_A` = 10029449-001RLF; U400/U401 `…:TPD12S016PWR`; U402 `…:LT8619C`; U403 `…:ADV7511KSTZ` | R4xx/C4xx (I²C pulls, TMDS term, decoupling) |
| **5 Analog in** | J500–J503 `Connector:Conn_Coaxial` = 73101-0120; U500 `…:ADV7280AWBCPZ-M`; U501 `Analog_Switch:TS5A23159DGS` (3 units) | D500–D503 (BAV99/TVS split per-refdes unspecified); R5xx/C5xx |
| **6 Analog out** | J600–J603 `Conn_Coaxial`; U600 `…:ADV7393BCPZ`; U601/U602 `…:LMH6643MA` | R6xx/C6xx |
| **7 SDI** | J700/J701 `Conn_Coaxial`; U700 `…:GS3470-IBE3`; U701 `…:GS2962-IBE3` | R7xx/C7xx |
| **8 Genlock** | J800/J801 `Conn_Coaxial`; U800 `…:LTC6912CGN-2#PBF`; U801 `…:AD9204BCPZ-20`; U802 `TS5A23159DGS` (3 units); D800 `Diode:BAV99` | D800 TVS portion; R8xx/C8xx |
| **9 Clock/Sync** | U900 `…:RP2040`; U901 `Memory_Flash:W25Q128JVS`; Y900/Y901 `Device:Crystal_GND24` (12/25 MHz); U902 `…:SI5351A-B-GT`; U903 `…:AD9742ARUZ`; U904 `…:LMH6643MA`; J900/J901 `Conn_Coaxial` | R9xx/C9xx; xtal load caps |
| **10 Control/Net** | U1000 `…:Sterling LWB5+`; J1000 `Connector:RJ45` = JXD1-0001NL; J1001 `Connector:USB_C_Receptacle_USB2.0_16P`; U1001 `Power_Protection:TPD4S014`; J1002/J1003 `Conn_Coaxial` (RP-SMA) | R10xx/C10xx; magjack magnetics detail |
| **11 Panel/LED** | J1100 `Conn_01x06` (placeholder); J1101 `…:NHD-1.5-240240AF-CSXP`; U1100–U1102 `…:TLC59116FIPWR`; D1100–D1120 `Device:LED_Dual_KAK` (×21) | U1103 (backlight LDO, MPN TBD); R11xx |
| **12 RF/Debug** | J1200 `Conn_Coaxial` (u.FL); J1201 `Conn_01x06`; J1202 `Conn_02x05_Odd_Even` (JTAG); J1203 `Conn_01x04` (UART); J1204 `Conn_02x20_Odd_Even`; SW1200 `Switch:SW_DIP_x02`; SW1201/SW1202 `Switch:SW_Push`; D1200–D1204 `Device:LED` | — |
| **1 Root/mech** | MP101–MP108 `Mechanical:MountingHole`; FID101–FID103 `Mechanical:Fiducial` | TP1xx global test points (count unspecified) |

### New SSOT gaps / decisions found in Phase 3

11. **TE0720 symbol vs refdes-map structure.** `TE0720-03-61C33FAS` is one 4-unit / 270-pin symbol; `refdes-map` assigns three connectors **J200/J201/J202**. Placed as a single multi-unit part **J200** (units 1–4). **Decide:** keep one multi-unit SoM symbol (remap J201/J202 → units of J200) *or* model three separate Razor-Beam connector symbols. The **-03 vs -04 variant** flag persists — Value set to production `TE0720-04-62I33MA` but the symbol is `-03`; confirm the Razor-Beam pin map matches.
12. **Coax connector symbol.** No `Connector_Coaxial:BNC/SMA/U.FL` in installed KiCad 10 libs (the `kicad-symbol-sourcing.md` names don't exist). Used generic **`Connector:Conn_Coaxial`** for all BNC (J5xx–J9xx), RP-SMA (J1002/3), and u.FL (J1200); MPN in Value, footprint differentiates later.
13. **USB-C variant** — J1001 on `USB_C_Receptacle_USB2.0_16P`; confirm 14P vs 16P for USB4085-GF-A.
14. **Dual-anode LED** — `Device:LED_Dual_ACA` (sourcing doc) doesn't exist; used `Device:LED_Dual_KAK` (common-anode, K-A-K). **Confirm pin order** for L-3VEGW-CA.
15. **Mixed diode ranges not placed** — D500–D503 ("BAV99 + TVS") have no per-refdes type; left unplaced. D800 placed as BAV99 only; TVS portion not separately specified.
16. **Aggregate passives/decoupling not placed** (same rule as Sheet 3): C200–C239 + all R/C term/pull/decoupling groups have no per-part values in the SSOT. Refdes blocks reserved; values from the wiring-pass design docs.
17. **No symbol / MPN:** HS201 (heatsink — mechanical, skipped); U1103 (rear-LCD 3.0 V backlight LDO — MPN TBD in `bom-v1.md`, skipped).
18. **Unspecified connector pin counts:** J1100 (mezzanine→A2) placed as `Conn_01x06` **placeholder** (pin count TBD); J1203 (UART debug) `Conn_01x04` (3-vs-4-pin TBD); SW1200 `SW_DIP_x02` per the 2-strap MODE+JTAGMODE boot scheme (`sheet3-…md` §3) — confirm.
19. **Multi-unit parts** placed across all units under one refdes: TE0720 (J200 ×4), TS5A23159 (U501, U802 — 3 units each).
20. **3 benign `lib_symbol_mismatch`** (RJ45, TPS7A20xxxDBV, W25Q128JVS) — embedded-cache vs library normalization/flatten diffs; self-heal on GUI "Update Symbols from Library." No connectivity impact (all resolve in the netlist; pin counts verified).

### Status
**Full placement pass complete and validated; halted for review.** Next: the **wiring pass** (rails + inter-sheet bank buses via `power-tree-design.md` and `sheet3-…md` §5), the **footprint pass**, and resolution of gaps #11–#20. Nothing committed or pushed.

---

## 6. Structural revision pass (2026-06-13, pre-wiring)

Addressed the Phase-3 structural gaps before wiring (per Justin). Sheets 2 & 7 rebuilt; rest untouched. Validation: `kicad-cli sch erc` + netlist → **both exit 0**, no error-level violations (profile unchanged: `pin_not_connected`/`pin_not_driven` placement-only expected + 3 benign `lib_symbol_mismatch` + 3 `isolated_pin_label`). **132 components** total.

- **#11 TE0720 — RESOLVED as three connectors.** Removed the single 4-unit/270-pin `TE0720` symbol from Sheet 2. Re-placed the SoM mating interface as **three physical Razor Beam connectors** matching `refdes-map`: **J200 / J201 = Samtec LSHM-150 (2×50, 100-pin)** = TE0720 JM1 / JM2; **J202 = Samtec LSHM-130 (2×30, 60-pin)** = JM3. Confirmed against the old symbol's per-unit pin counts (100 / 100 / 60 — the 4th 10-pin unit, 270 vs the 260 connector pins, was extra/duplicate SoM pins; no impact). Value carries the production SoM MPN `-04-62I33MA`; -03/-04 bench-vs-production flag stays noted. The Odd/Even pin numbering (1,3,…/2,4,…) matches the `JM1-xx/JM2-xx/JM3-xx` scheme in `sheet3-…md` §5, so wiring net-mapping lands cleanly.
  - **New project library `CarrierGen.kicad_sym`** (registered in the project `sym-lib-table`): no stock 100-pin connector exists (installed `Connector_Generic` tops out at `02x40`), so `Conn_02x50_Odd_Even` was **synthesized** (100 pins, Odd/Even, parse-validated via `kicad-cli sym upgrade`) and housed here so it resolves cleanly. J202 uses stock `Connector_Generic:Conn_02x30_Odd_Even`. ⚠ The synthesized symbol is a generic 2×50 header — swap in a proper **Samtec LSHM-150** symbol (correct body/pin-1 marker) before layout if desired; pin numbering already matches the SSOT.
  - **SoM module as a BOM line:** the three connectors are the carrier-side sockets; the **TE0720 module itself** ($300 line item) now has no schematic symbol/refdes. Flag for BOM reconciliation — represent the module as a mechanical/board line (it has no carrier-side footprint of its own beyond these connectors).
- **SDI additions (Sheet 7) — placed.** Added **J702 = SDI IN LOOP** (reclocked loop-through via GS3470) and **J703 = SDI OUT mirror** (driven by GS2962 2nd SDO, pins C10/D10). Sheet 7 SDI is now **4 BNC** (J700 IN, J702 IN LOOP, J701 OUT, J703 OUT mirror) + GS3470/GS2962. ⚠ `refdes-map.md` doesn't yet list J702/J703 — **add them to the map** so the BOM reconciliation matches (these are banked decisions the doc predates).

### Status
**Structural revision complete and validated; halted for review** (wiring NOT started — held pending the rear-panel connector architecture decision, which affects analog-in/out + SDI connector placement). Nothing committed or pushed.

---

## 7. Wiring pass — Sheet 3 (Power tree) fully wired from `power-tree-design.md`

Panel layout locked (2026-06-13); wiring carrier-resident (carrier-vs-riser deferred to layout, no netlist impact). Sheet 3 wired from `power-tree-design.md` §2 + §0 locks. **64 components** (the 25 placed earlier + ~39 set/divider/decoupling parts the design doc specifies, with the doc's proposed values + verify-flags). Net connectivity via labels (global for rails + cross-sheet control; local for sheet-internal SW/FB/BOOT/VCC); PWR_FLAG on each undriven rail + each post-ferrite LDO input.

**Verified-correct nets** (netlist-checked): high-side shunt 2-node split — `+12V_EF` (U300 OUT/OUT-1, R300.1, INA226 Vin+) vs `+12V_PROT` (R300.2, INA226 Vin-/Vbus, both buck VIN+EN, bulk C300-302, buck input caps); `+12V_RAW` (J301.1, U300 IN/IN-1, U302 V+, OVP/UVLO divider tops, C303); the three buck output rails + FB dividers (R301/302 5V, R303/304 3V3, R305/306 1V2); `+1V8_A` (U306 OUT) via FB300; `+3V3_A` (U309 OUT); soft-power control nets as global/hier labels (`PWR_BTN_N`, `EFUSE_EN`→U300 SHDN, `PWR_INT_N`, `PWR_KILL_N`, `EFUSE_FLT_N`, `PDT_RC`); INA226 telemetry (`I2C_HK_SDA/SCL`, 0x40). eFuse set components: `ILIM_S` (R307), `OVP_DIV` (R308/309 from +12V_RAW), `UVLO_DIV` (R314/315), `DVDT_S` (C312). NC flags on genuine no-connects (J300/F300 chassis pins, U303/304 PG, U300 IMON, U306 pin-4, FB305 spare). RTN(U300.8)→GND.

**Validation:** netlist exit 0. Sheet-3 ERC: **11 error-severity violations remain**, all on **6 pins**, and every one is a doc-flagged-open item or a cross-sheet artifact (NOT a wiring error):

### Sheet-3 residual ERC — the genuine open items (need decisions / datasheets)
1. **U300 pin 6 `MODE`** — eFuse latch-off **strap level** not specified. §0 locked the *behavior* (latch-off) but the MODE pin resistor/level needs the **TPS26600 datasheet** (not in `KiCad/Reference Files/`). Left unconnected + flagged.
2. **U302 pin 3 `ONT`** — LTC2954 on-timer pin; not addressed in `power-tree-design.md`. Needs the LTC2954 datasheet (set cap/tie). Left unconnected + flagged.
3. **U307/U308/U309 pin 4 `SENSE/ADJ` (×3)** — ADP7142 feedback dividers. `power-tree-design.md` §2.7 marks these **"genuinely under-specified"** (output voltages "sized at schematic", ferrite-tap-vs-LDO for +3V3_A open). Outputs wired to their rails; ADJ dividers left unplaced + flagged — wiring them needs the per-rail target voltages locked.
4. **U301 pin 5 `SCL`** — not an error: `I2C_HK_SCL` is a cross-sheet net; the I²C master (Zynq PS, Sheet 2/10) isn't wired yet, so SCL reads "not driven." Resolves when the control-plane sheet is wired. (Artifact, not a defect.)

Symbol note carried forward: **TPS7A2018 (U306) pin 4** is labelled `NC` in the `JustinLibrary` symbol (inherited from the LP5907 base) but is physically **NR/SS** — so the noise-reduction cap (C338) could not be wired (NC-flagged instead). Fix the symbol (expose NR/SS at pin 4) to add C338.

### Wiring pass — remaining sheets: BLOCKED on a pin-assignment decision
The SoM PL parallel buses (HDMI/analog/SDI/genlock data buses on sheets 2,4–9) are **explicitly permutable** — `sheet3-…md` §5 + `pin-budget.md` give bank/lane allocations (B35/B13/B34/B33) and exact JM pins **only for the clock-capable pins**; the data-bus JM-pin assignments are left for "the schematic to finalize" (§5). Per the standing rule (**don't invent pin assignments — flag**), I did not fabricate ~100 JM-pin choices. **Decision needed:** either (a) authorize finalizing the PL data-bus pin assignments in-schematic (a design step — I'll assign within-bank per §5/§6 and you ratify), or (b) keep PL buses flagged and I wire only the unambiguous nets on the other sheets (IC power pins per the §1 rail tree, I²C/SPI buses per `sheet3-…md` §7, connector→front-end signal nets, the Sheet-8 Option-A genlock front-end incl. new J802/J803 U.FL receptacles).

### Status
**Sheet 3 wired & verified; halted for review** at the first genuine ambiguities (MODE/ONT/ADP-ADJ values + the permutable PL-bus assignment), per the wiring-pass process. Nothing committed or pushed.

---

## 8. Sheet-3 corrections applied (2026-06-13b dispositions) + symbol fix

Applied the other-agent dispositions / `power-tree-design.md` §0a corrections. **Sheet 3 now 87 components, ERC = 2 error pins only** (`MODE` pending the BOM decision below; `SCL` is the cross-sheet I²C artifact). All previously-open §2.7/timer items resolved:

- **PDT (LTC2954) corrected** — cap-only timer (6.4 s/µF, no series R): R316 removed; **C311 = 0.82 µF** (~5 s hard-off).
- **ONT (LTC2954) added** — **C312 = 0.1 µF** to GND (~0.64 s anti-accidental hold). dVdt cap renumbered → **C313** (10 nF).
- **ADP7142 dividers set** with the confirmed targets (no longer guessing): U307 = 1.8 V (`R317` 49.9k / `R318` 100k), U308 = 1.8 V (`R319`/`R320`), U309 = 3.3 V (`R321` 174k / `R322` 100k); output caps C340–C342, input caps C343–C345. `ADJ` pins now wired. 🧮 verify ADP7142 V_REF (1.2 V) before fab. POLs left on Sheet 3 (may relocate to load sheets at layout).
- **ADV7511 analog** noted off `+3V3_A` (it's 1.8 V) — resolve at the ADV7511 sheet (no Sheet-3 change).
- **TPS7A2018 NR/SS symbol fix** — could not edit JustinLibrary (per instruction); created corrected **`CarrierGen:TPS7A2018PDBVR`** (pin 4 `NC`→`NR/SS`, passive, unhidden), used for U306, wired **C338** (10 nF NR/SS cap). *(Recommend folding this into JustinLibrary when convenient.)*
- **INA226 I²C master** = Zynq PS (housekeeping bus) per §0a.

**Remaining Sheet-3 error — `MODE` (U300):** gated on **TPS26600 → TPS26601** (BOM line change, Justin's gate). On the '601, `MODE`-open defaults to latch-off → MODE becomes a clean NC (no strap); on the '600, a MODE latch strap is required (datasheet §9.3/§9.4). Symbol/pinout identical either way (reuse `TPS26600PWPR` symbol, Value field changes). Once dispositioned, Sheet 3 reaches true ERC-zero (modulo the cross-sheet SCL, which closes with the control-plane sheet).

### Next: wiring pass option (b)
Proceeding to wire the unambiguous nets on the remaining sheets — IC power pins (per §1 rail tree), I²C/SPI buses (§7), connector→front-end signal nets, and the Sheet-8 Option-A genlock front-end (incl. new J802/J803 U.FL receptacles) — leaving the permutable PL data buses flagged for a placement-context pass.

**TPS26600 → TPS26601 — DECIDED (Justin, 2026-06-13):** swapped. U300 Value → `TPS26601` (latch-off default; reuses the identical-pinout `TPS26600PWPR` symbol). `MODE` left open = latch (NC-flagged). **Sheet 3 is now ERC-clean** — the only remaining error is `U301 SCL` (cross-sheet I²C, resolves with the control-plane sheet). ⚠ `bom-v1.md` BOM line still to be updated to TPS26601 (Justin/other-agent).

**Sheet 3 wiring: COMPLETE & ERC-clean.** 87 components. Next session: wiring-pass option (b) on the remaining sheets.

---

## 9. Lumex SSF-LXH409 RA bi-color LED footprint (new task, before Sheet 11 wiring/layout)

Built per `docs/Hardware/LEDs/LUMXD00054-83.pdf` (SSF-LXH409SISUGW, T-3mm 3-lead RA bi-color **common-anode**, offset cathode lead). Project-local, mirroring the CarrierGen symbol approach — **no global/JustinLibrary edits**:
- **`CarrierGen.pretty/LED_Bicolor_Lumex_SSF-LXH409_RA_3pin.kicad_mod`** + new project **`fp-lib-table`** (registers `CarrierGen` → `${KIPRJMOD}/CarrierGen.pretty`). Parse-validated (`kicad-cli fp upgrade`).
- **Pads:** 3× THT, 2.54 mm pitch, **0.8 mm drill / 1.7 mm pad**; pad 1 (offset cathode) **rect + silk pin-1 dot**, offset 1.27 mm; pads 2/3 round. Silk body outline (7.0 mm housing + projected Ø4.0 dome), "A" polarity mark, courtyard = body+0.25, Fab outline.
- **Pin binding** (to `Device:LED_Dual_KAK`, already a valid 3-pin common-anode symbol): pad **1 = K1 (cathode)**, **2 = A (common anode, center)**, **3 = K2 (cathode)**. Anode→LED V+ rail; the two cathodes→TLC59116 sink channels (2 ch/LED, 42 of 48) — wired at Sheet 11.
- **Assigned to D1100–D1120** (21 LEDs) — netlist-verified all 21 carry the footprint. ERC unchanged (LEDs still placement-only on Sheet 11). Old Kingbright vertical-lamp footprint is **not** inherited (footprint was blank before).

**⚠ VERIFY-before-finalizing against the LUMXD00054-83 mechanical drawing (could not resolve from the OCR'd datasheet):**
- **(a) Offset lead identity + direction** — I offset **pad 1** (a cathode) by **−1.27 mm in Y**; confirm which physical lead is offset and the direction from the drawing.
- **(b) Anode/cathode pad order** — confirm datasheet pin-1/2/3 = K/A/K (center = common anode) and that pad 1 is a cathode (not the anode).
- **(c) Hole size** — used 0.8 mm drill from the 0.50 mm-sq lead; **use Lumex's recommended mounting-hole size if the datasheet states one**.
- **(d) Body standoff / RA dome offset from board edge** — silk body position relative to the leads is approximate; confirm housing depth + dome projection against the drawing before layout.
- Full **board DRC deferred** (no PCB layout yet); footprint validated at the file level only.
- Datasheet also lists internal-resistor + blinking variants — confirm the ordered MPN is the plain `SSF-LXH409SISUGW` (no internal resistor; external current set by TLC59116).

---

## 10. Proposed board-wide net conventions (for review BEFORE Sheet 8 / board-wide wiring)

Per the pacing directive — lock these, demonstrate on Sheet 8, then replicate on 2,4–7,9–12. **Flagged items = not explicitly in the SSOT rail tree / §7; need ratification.**

**Power rails (global labels, established on Sheet 3):**
`+12V_RAW` · `+12V_PROT` · `+5V` · `+3V3` · `+1V2` · `+1V8_A` · `+3V3_A` · `GND`
Clean POL outputs (Sheet 3): `AVDD_GENADC` (1.8 V → AD9204), `AVDD_DEC` (1.8 V → ADV7280), `+3V3_SDIDRV` (FB303 → GS2962 cable driver).

**Per-IC supply-pin → rail mapping (from §1 rail tree; ⚠ = not explicit, proposed):**
| Pin class | Rail |
|---|---|
| Digital core/IO (VDD/DVDD/VCCIO of LT8619C, ADV7280/7393/7511, GS3470/2962, TLC59116, RP2040, Si5351) | `+3V3` |
| SDI core (GS3470/GS2962 1.2 V core) | `+1V2` |
| ADC/decoder analog AVDD (AD9204, ADV7280) | `+1V8_A` *(or POL `AVDD_GENADC`/`AVDD_DEC`)* |
| DAC/encoder analog (ADV7393 VAA) | `+3V3_A` |
| ADV7511 analog/PLL | `+1V8_A` *(1.8 V — see §0a-4; ⚠ confirm at sheet)* |
| AD9204 `DRVDD` (output-driver supply) | ⚠ `+3V3` *(to match B33 VCCIO33 = 3.3 V LVCMOS output levels — confirm)* |
| LTC6912 PGA `V+` | ⚠ `+5V` *(single-supply, V−→GND — not in rail tree; confirm vs +3V3)* |
| Op-amp buffers LMH6643 (sheets 6/9) | ⚠ `+5V` single-supply (per bom §1) |

**I²C buses (§7):**
- `I2C_VID_SDA` / `I2C_VID_SCL` — video config: LT8619C, ADV7280, ADV7393, ADV7511, GS3470, GS2962, Si5351(genlock). ⚠ master = PS or PL EMIO (confirm).
- `I2C_HK_SDA` / `I2C_HK_SCL` — housekeeping: INA226 (Sheet 3), TLC59116 ×3, fan/front-panel GPIO. Master = **Zynq PS** (locked).

**SPI buses (§7):**
- Genlock: `GENLK_SPI_SCK` / `GENLK_SPI_MOSI` / `GENLK_SPI_MISO`, CS per device: `GENLK_PGA_CS` (LTC6912 CS/LD), `GENLK_ADC_CS` (AD9204 CSB). Master = **RP2040** (genlock MCU, Sheet 9). ⚠ AD9204 shares the genlock SPI (separate CS) — confirm vs a dedicated bus.
- SDI: `SDI_SPI_SCK/MOSI/MISO`, `SDI_GS3470_CS`, `SDI_GS2962_CS` (GSPI).
- Rear LCD (ST7789, PS-driven): `LCD_SPI_SCK` / `LCD_SPI_MOSI` / `LCD_CS` / `LCD_DC` / `LCD_RST`.

**Soft-power / control hier nets (Sheet 3 ↔ Sheet 2):** `PWR_BTN_N`, `EFUSE_EN`, `PWR_INT_N`, `PWR_KILL_N`, `EFUSE_FLT_N`, `INA_ALERT_N`.

**PL data buses (sheets 2,4–9):** stay **flagged/unwired** (permutable per `sheet3-…md` §5) until the placement-context pin-lock pass.

### Status
LED footprint complete (§9). **Conventions proposed above — halting for review before wiring Sheet 8 with them** (so the exemplar bakes in a ratified scheme, not a guessed one). On green-light I'll wire Sheet 8 (genlock Option-A front-end + J802/J803 U.FL + power/SPI per the above, PL bus flagged), then the straight-through run for 2,4–7,9–12. Nothing committed or pushed.

---

## 11. Sheet 8 (Genlock front-end) wired — conventions exemplar (supersedes §10 "halt-before")

Wired Sheet 8 as the board-wide exemplar for review (corrected course — wired it rather than halting before). 16 components incl. the new **J802/J803 Hirose U.FL-R-SMT-1** carrier receptacles (Option-A interconnect). Netlist-verified the convention threading:
- **Rails thread cross-sheet** (global labels): `+5V` (Sheet 3 → U800 V+), `+3V3` (→ TS5A23159 VCC + AD9204 DRVDD), `AVDD_GENADC` (U307 POL on Sheet 3 → AD9204 AVDD ×8). Confirmed the same net spans both sheets.
- **Genlock SPI bus**: `GENLK_SPI_SCK/MOSI/MISO` shared by LTC6912 + AD9204, per-device `GENLK_PGA_CS` / `GENLK_ADC_CS` (RP2040 master, Sheet 9).
- **Analog spine** (Option A): `REF_BUS` (J800 panel BNC + J802 U.FL + passive loop-through to J801/J803) → fixed 75 Ω term (R800→GND) → AC-couple (C800) → `PGA_IN` (LTC6912 INA) → `PGA_OUT` (OUT_A → AD9204 VIN+A); `ADC_VCM`/`ADC_VREF`/`ADC_RBIAS` reference nodes.
- TS5A23159 placed across all 3 units (unit 3 = VCC/GND power unit) — fixed an earlier `missing_power_pin`.

**Flagged on Sheet 8** (documented, not defects — consistent with the deferral rules):
- **AD9204 PL data/clock bus** (D0A–D9A, DCOA, ORA, + channel-B) → permutable PL (B33), left unwired per the PL-bus deferral.
- **ADC clock** (CLK+/CLK−) → source unresolved (`sheet3-…md` §8: Si5351 vs FPGA-derived) — flagged.
- **Channel B** (VIN±B, D*B) → unused (interleaved single-channel) — flagged.
- **Input conditioning detail** — D800 BAV99 clamp rails + U802 switchable-term sections/control → topology + values "set at schematic" — flagged.
- **ADC reference** (SENSE/VREF/VCM/RBIAS) values → datasheet, flagged.

Sheet 3 remains ERC-clean (only the cross-sheet `SCL`, which now... still pending the control-plane I²C master). Whole-project ERC errors are the expected placement-only/flagged set.

### CONVENTIONS LOCKED — awaiting green-light (HALT)
The board-wide net conventions (§10) are now demonstrated on Sheet 8. **Halting for review.** On green-light I'll run the straight-through pass for sheets 2, 4–7, 9–12 applying the same conventions (rails per the §10 table, I²C `I2C_VID`/`I2C_HK`, SPI `SDI_*`/`LCD_*`, PL buses flagged). Please confirm or correct: the ⚠ rail assignments (LTC6912→+5V, AD9204 DRVDD→+3V3, ADV7511 analog→+1V8_A), the I²C master split, and the SPI bus naming.

---

## 12. Straight-through wiring pass — sheets 2, 4–7, 9–12 (conventions replicated)

Wired the unambiguous nets board-wide per the locked conventions (§10–§11). **281 power/GND/I²C/SPI/SoM pins** threaded across the 9 sheets; PL data buses + analog signal paths flagged. Whole-project validation: netlist exit 0; ERC errors = **1218**, all expected/flagged (no `pin_to_pin`, lib, or Output-conflict errors):
- `pin_not_connected` 1097 — flagged PL data buses (parallel video/SDI/genlock/DAC), analog signal-path conditioning (values "set at schematic"), control/strap/clock pins.
- `pin_not_driven` 119 — cross-sheet buses whose **master isn't wired yet** (I²C_VID/HK master = PS-EMIO/MIO; GENLK_SPI = RP2040 GPIO; LCD_SPI = PS; SDI_SPI = GS-host) + divider-fed inputs. Resolve when the SoM MIO/EMIO + RP2040 GPIO pins are assigned.
- `power_pin_not_driven` 2 — HDMI cable +5V (J400/J401 pin 18), routed via the TPD12S016 switch (front-end), flagged.

**Verified threading (netlist):** `+3V3` (66 pins: all digital-IO ICs + SoM J200/J201 3.3VIN/VCCIO + TLC59116 ×3), `+5V` (SoM VIN J200/J201 + TPD + LMH6643 + USB), `+1V8_A` (U306 → LT8619C/ADV7511/ADV7280/ADV7393), `+1V2` (GS3470/GS2962 core), `+3V3_A` (ADV7393 VAA), `+3V3_SDIDRV` (FB303 → GS2962 cable driver), `AVDD_GENADC`/`AVDD_DEC` POLs. **I²C_VID** = LT8619C/ADV7511/ADV7280/ADV7393/Si5351 (PS-EMIO master). **I²C_HK** = INA226 + TLC59116 ×3 (PS master). **SDI_SPI** = GS3470 + GS2962. **LCD_SPI** = NHD-1.5. **SoM power** (Sheet 2) per `sheet3-…md` §2: VIN→+5V, 3.3VIN/VCCIO13/33/34/35→+3V3, NOSEQ→+3V3 on J200/J201 pads.

**Bug found & fixed mid-pass:** symbols with pins in the `_0_1` "common" sub-unit (e.g. TLC59116 — all 27 functional pins in unit 0) were initially placed as 2 units, landing ~72 labels off-pin (silently disconnecting them, since global labels merge by name regardless of position). Fixed `units()` to exclude unit 0 and remap common pins to the real unit; re-verified.

### CONFIRM items (per the review gate)
- **GS3470 / GS2962 host = SPI** (Semtech) — confirmed; placed on **SDI_SPI only**, dropped from I²C_VID. ✓
- **I²C address audit** (7-bit; ⚠ = confirm vs datasheet):
  - I²C_VID: ADV7280 **0x20**, ADV7393 **0x2A**, ADV7511 **0x39**, Si5351 **0x60**, LT8619C **⚠~0x56** (Lontium — confirm) → **no collisions**.
  - I²C_HK: INA226 **0x40**, TLC59116 ×3 = **0x60/0x61/0x62** (set via A0–A3 straps — must wire 3 distinct; strap wiring is a detail-pass item) → no collision with 0x40.
  - Note: Si5351 0x60 (I²C_VID) and TLC59116 0x60 (I²C_HK) share a value but are on **separate PS segments** → fine.

### Deferred (flagged, for later passes)
PL data/clock buses (permutable — placement-context pin-lock pass); analog signal-path conditioning (HDMI TMDS via TPD, analog video, SDI, sync — front-end values "set at schematic"); bus **masters** (SoM MIO/EMIO + RP2040 GPIO assignment); per-pin decoupling caps (detail/footprint pass); uncertain supplies flagged — **AD9204 DRVDD** (1.8 V-suspect, deferred per ruling), LT8619C/ADV7280 1.8 V digital on `+1V8_A` (⚠ budget), GS3470/GS2962 PLL/VCO/A_VDD, AD9742 AVDD clean-rail, LWB5+ VDDIO rails, RP2040 core loop.

### Status
**Straight-through pass complete & validated; halting for review.** All staged — nothing committed or pushed.

---

## 13. B33 re-strap → +1V8_D + U310 (review corrections, 2026-06-13c)

Applied the concrete unblocked correction from the review (B33 re-strapped to 1.8 V; AD9204 DRVDD confirmed 1.8 V). Re-read `power-tree-design.md` §0/§1 + `sheet3-…md` §2/§5/§6.
- **Sheet 3:** added **U310** = 1.8 V LDO off `+3V3` (reused `CarrierGen:TPS7A2018PDBVR`; ⚠ MPN per power-budget — a smaller 0.1 A LDO is fine) → new **`+1V8_D`** digital rail, with C346 (in) / C347 (out) / C348 (NR). Sheet 3 now 81 components, still ERC-clean (only cross-sheet SCL).
- **Sheet 2:** VCCIO33 (J201 / JM2-5) moved **+3V3 → +1V8_D** (B33 = LVCMOS18).
- **Sheet 8:** AD9204 **DRVDD** (pins 10/19/28/37) → **+1V8_D** (+ C806 decoupling); **SENSE** → GND (internal-reference mode, ⚠ confirm strap level); **VREF** bypass cap → 470 nF 6.3 V X5R. DRVDD/SENSE no longer flagged.
- **Verified:** `+1V8_D` = U310.5 → J201.5 (VCCIO33) → U801 DRVDD ×4 + caps. `+1V8_A` now carries the analog set (U306 + ADC/decoder/encoder AVDD/PLL) — *digital-1.8 loads (LT8619C VDD18, ADV7280/7393 digital) remain on +1V8_A pending the power-budget re-sort onto +1V8_D (deferred per review).*

### Review dispositions tracked
- **Confirmed:** LTC6912→+5V, ADV7511→+1V8_A, GS3470/2962 SDI_SPI-only, AD9204 on genlock SPI (RP2040 master), I²C addresses (ADV7280 0x20 / ADV7393 0x2A / ADV7511 0x39 / INA226 0x40 / TLC59116 0x60–62).
- **LT8619C I²C address** — left flagged (~0x56, in the R1.5 register map; confirm vs datasheet).
- **Si5351 (U902) bus** — ⚠ **held on I²C_VID pending your §3.7 confirmation.** Review says it likely belongs on the RP2040-local genlock I²C (not the PS video bus); `sheet3-…md` §7 currently lists it on bus A (suspected doc error). **Not moved** — awaiting confirm + the §7 doc fix, then I'll relocate U902 off I2C_VID.
- **Sheets 10 + 11 — HELD (wired to retired architecture).** Sheet 10 `U1000 = LWB5+` is being dropped (ESP32 radio); Sheet 11 `J1100` becomes an FFC (power+UART to a fabric bridge) and the A2 MCU → ESP32-S3. The power/I²C/SPI wiring already placed on 10/11 (straight-through pass) is to the **old** arch and will need rework once the Mini-silicon scope + control-plane redesign land. **Do not treat 10/11 as final.**
- **PL data-bus pin-lock** — not started (needs placement/layout context; stays flagged).
- **Analog signal-path conditioning** (term/AC-couple/anti-alias/clamp/TMDS values) — available as a **propose-and-ratify design pass** next (returns proposed values + flags, not silently filled).

### Status
B33/+1V8_D/U310 correction complete & validated. Halting. Everything staged — no commit/push.

---

## 14. Control-plane arch settled (2026-06-13d) — Si5351 bus move + LWB5+ drop

Control-plane locked: **PS thin-agent + ESP32-S3 UI head on A2** (LWB5+ retired; fabric-bridge dropped; rear USB-C on the PS). Applied the firm carrier-side changes:
- **Si5351 (U902) → genlock I²C** — moved off `I2C_VID` (PS video bus) onto **`I2C_GENLK`** (RP2040-mastered, 0x60), per spec §3.7. Verified: I2C_VID now = LT8619C/ADV7511/ADV7280/ADV7393 (4); I2C_GENLK = Si5351 (RP2040 master pins flagged until GPIO assignment).
- **U1000 (LWB5+) DROPPED** from Sheet 10 (radio → ESP32-S3 on A2). GbE (J1000), USB-C (J1001 → PS), USB-ESD (U1001) stay. Sheet 10 now 10 wired pins. Whole-project ERC errors 1213→1176.

### Flagged / pending (not wired — awaiting decisions)
- **J1002 / J1003 (rear RP-SMA)** — orphaned (fed the dropped LWB5+). Confirm removal vs repurpose for the ESP32 antenna path; left placed + flagged.
- **J1100 mezzanine FFC** — needs to grow 6 → **8 firm** (power + GND + UART×2 + PWR_BTN) or **10** if the **PS→ESP32 recovery path (EN + GPIO0)** is greenlit. Left at the `Conn_01x06` placeholder pending that call — **don't treat as final**.
- **RP2040 SWD/BOOTSEL service header (Sheet 9)** — proposed recovery insurance; **not added** (awaiting greenlight).
- **A2 mezzanine MCU → ESP32-S3** — A2 is its own board/namespace; no carrier-sheet action.

### Still open (tracked elsewhere)
- LT8619C I²C address (~0x56, confirm vs datasheet).
- +1V8_A digital-load re-sort (LT8619C VDD18 / ADV728x·7393 digital → +1V8_D) — power-budget pass.
- PL data-bus pin-lock — needs placement context.
- **Analog signal-path conditioning** — greenlit as a propose-and-ratify design pass (term / AC-couple / anti-alias / clamp / TMDS), to return as proposed values + flags.

### Status
Firm control-plane changes applied & validated. Halting. Everything staged — no commit/push.

---

## 15. Recovery path + SWD header + antenna (firm, 2026-06-13d) + refdes-map updates

All three greenlit items wired & verified:
- **J1100 → 10-pin mezzanine FFC** (`Conn_01x10`): 1=+5V, 2=+3V3, 3/9/10=GND, 4=`PS_ESP_UART_TX`, 5=`PS_ESP_UART_RX`, 6=`PWR_BTN_N`, 7=`ESP_EN`, 8=`ESP_GPIO0`. Verified `PWR_BTN_N` now spans A2 button → J1100.6 → Sheet-3 LTC2954 PB+debounce. EN/GPIO0/UART are PS-driven (Zynq MIO/EMIO) → ESP32 serial-boot recovery; PS side flagged until MIO assignment.
- **U900 RP2040 SWD service header** — added **J902** (`Conn_01x04`: 3V3 / SWDIO / SWCLK / GND). Verified `RP2040_SWDIO`=J902.2↔U900.25, `RP2040_SWCLK`=J902.3↔U900.24.
- **Rear RP-SMA** — **J1003 removed**; **J1002 repurposed** as the ESP32-S3 WiFi antenna bulkhead (`ESP_ANT` = J1002.1; A2 U.FL→coax→J1002).
- **refdes-map.md updated:** Sheet 9 (+J902, Si5351→RP2040 genlock I²C note), Sheet 10 (U1000 dropped, J1003 removed, J1002→ESP32 antenna), Sheet 11 (J1100→10-pin FFC), A2 (U1 → ESP32-S3).

Whole-project ERC errors now 1165 (all flagged/deferred categories). All staged.

---

## 16. Analog signal-path conditioning — PROPOSAL issued (propose-and-ratify)

Wrote **`docs/analog-signal-conditioning-proposal.md`** — per-path topology + proposed values + confidence flags (✅/🧮/🔧/❓) for sheets 4 (HDMI TMDS/DDC/5V), 5 (ADV7280 in: term/clamp/AC-couple/anti-alias), 6 (ADV7393+LMH6643 out: DAC load/buffer/back-term/AC-couple), 7 (SDI cable I/O), 8 (genlock front-end values), 9 (AD9742 sync out). **Nothing wired** — awaiting ratification. 5 open ❓ gate the wiring: AC-vs-DC couple at analog-out BNCs, buffer gain, TERM_EN line count, TVS-vs-BAV99 split, GS3470/GS2962 PLL/VCO/A_VDD rail voltages (need Semtech datasheet). PL data buses remain flagged for the placement pass.

---

## 17. B34=1.8V + digital-1.8V re-home + AD9742→B35 (A/B/C of the 2026-06-13e pass)

**A. B34 → 1.8 V (LVCMOS18):** GS3470 (U700) + GS2962 (U701) `IO_VDD` → **`+1V8_D`**; their parallel buses/PCLKs are LVCMOS18 (PL-flagged, no wiring change). VCCIO34 (J201/JM2-1,3) → **+1V8_D**.
**B. AD9742 (U903) B34 → B35** (stays 3.3 V LVCMOS33): SoM-side PL reassignment (SYNC1 clk→B35_L11_P/JM1-68, D[11:0]→B35_L18–23) — PL bus is flagged, so no carrier-wiring change; AD9742 supplies unchanged (+3V3). Freed B34 lanes released. (refdes-map AD9742 row already at B35 per -13e.)
**C. Power tree:** **digital-1.8 V re-homed off `+1V8_A` onto `+1V8_D`** — ADV7280 DVDD (U500), ADV7393 digital VDD (U600), LT8619C VDD18 (U402). Analog/PLL 1.8 V stays on +1V8_A / POLs (LT8619C VCCA18/PVCC18, ADV7511 analog, ADV7393 PVDD, ADV7280 AVDD/PVDD=U308, AD9204 AVDD=U307). **U310 resized → ~0.5 A** (⚠ TPS7A2018 = 300 mA; needs a ≥0.5 A 1.8 V LDO — MPN TBD, reconcile in bom-v1). GS analog rails per §7: CORE/PLL/VCO→+1V2, GS2962 AVDD→+3V3, CD→+3V3_SDIDRV (GS DDI/DDO analog 1.2/1.8 split ⚠ flag — Semtech datasheet).
**Verified:** +1V8_D = U310 + VCCIO33/34 (J201) + AD9204 DRVDD + ADV7280 DVDD + ADV7393 VDD + LT8619C VDD18 + GS3470/GS2962 IO. +1V8_A = clean analog set. ERC: 1156 errors (all flagged/deferred PL+signal; 2 = HDMI cable +5V), netlist exit 0, 197 components.

### D. Analog signal-path conditioning — PLAN (ratified §7; next, in progress)
Wiring the ratified §7 design — the new parts to add + reconcile into `bom-v1.md`:
- **Outputs (Sheet 6 ADV7393, Sheet 9 AD9742):** DAC load (37.5 Ω / 50 Ω) + RSET/FS_ADJ; LMH6643 buffers ×2 doubly-terminated; 75 Ω series back-term; **220 µF** AC-couple at BNC; full-scale set for 1.0 Vpp composite / 700 mV component (at load).
- **Inputs (Sheet 5 ADV7280, Sheet 8 genlock):** AC-couple + anti-alias; per-input switchable 75 Ω term via **I²C GPIO expander on I2C_HK** (new IC, e.g. PCA9555) switching the term-resistor **ground leg** — REF/SDI mandatory, composite/component fixed 75 Ω.
- **ESD:** <3 pF video TVS at every panel BNC + BAV99 IC-side; **ultra-low-cap (<0.5 pF) SDI ESD** (not BAV99) on GS3470 inputs.
- **SDI (Sheet 7):** AC-couple (4.7 µF/100 nF) GS I/O; GS analog RC filters; GS3470 external 27 MHz ref clock.
- **HDMI (Sheet 4):** I²C/DDC pull-ups 2.2 kΩ→+3V3; J400.+5V ← TPD `5V_OUT`.
All new parts → bom-v1.md reconciliation. PL data buses stay flagged.

### Status
A/B/C complete & validated. D (analog conditioning) is the next focused pass. All staged — no commit/push.

---

## 18. Sheet 6 (Analog video OUT) — conditioning wired (D, exemplar)

First analog-conditioning sheet wired (ratified §2/§7). **33 components.** Per-channel chain verified in netlist:
**ADV7393 DAC → 37.5 Ω load → LMH6643 ×2 (doubly-terminated) → 75 Ω back-term → 220 µF AC-couple → BNC + <3 pF video TVS.**
- DAC1 (CVBS/luma) feeds **two** buffers (U601A→J600 CVBS, U602A→J601 Y) — composite/component are mutually exclusive, so all 4 LMH6643 channels are used (refdes-map said "3 ch"; reconciled to 4). DAC2→U601B→J602 (Pb), DAC3→U602B→J603 (Pr).
- ×2 non-inverting buffers (Rf=Rg=1 k); RSET = 4.12 kΩ (set DAC full-scale for 1.0 Vpp composite / 700 mV component **at the load** — 🧮 verify vs ADV7393 datasheet under ×2 doubly-term).
- **CVBS→RF tap:** `CVBS_TO_RF` global label on the U601A output node → Sheet 12 J1200 (RF daughter board).
- Supplies thread correctly: VDD_IO→+3V3, VDD→+1V8_D, PVDD→+1V8_A, VAA→+3V3_A; LMH6643 V+→+5V/V-→GND + 0.1 µF decoupling. I²C → I2C_VID.
- New parts → bom-v1.md (video TVS <3 pF ×4, 220 µF AC-couple ×4, DAC-load/RSET/gain/back-term passives).

**ERC:** netlist exit 0; Sheet-6 errors = **23 pin_not_connected**, all deferred ADV7393 pins (P0–P15 data → PL bus; CLKIN/*RESET/*VSYNC/*HSYNC → PL/clock-gen; EXT_LF/COMP/SFL → datasheet loop-filter/compensation caps). **No conditioning/buffer/power errors.**

### Flagged on Sheet 6 (for later)
- ADV7393 **P0–P15 parallel bus** → B13 PL (placement-context pin-lock pass).
- **CLKIN** (← clock-gen, Sheet 9), **\*VSYNC/\*HSYNC** (← PL or external sync), **\*RESET** (← PS/control) — cross-sheet, flagged.
- **EXT_LF / COMP** (ADV7393 loop-filter + compensation caps) — values per datasheet, 🧮 flag.
- **CVBS/Y dual-buffer off DAC1** — confirm vs an analog-mux approach (uses 4 LMH6643 ch).

Sheet 6 done — ready for your review before replicating the conditioning across sheets 4/5/7/8/9.

---

## 19. Analog conditioning — Sheet 6 corrected + Sheet 5 wired (D, cont.)

**Sheet 6 correction:** ADV7393 DAC loads **37.5 Ω → 300 Ω** (low-drive, pairs with RSET 4.12 kΩ); flagged ADV7393 reg **0x0D = low-drive**. RSET/buffers/back-term/220 µF unchanged.

**Sheet 5 (Analog video IN) wired** (34 components). Per-input chain ×4 (J500 CVBS→AIN1, J501/2/3 component→AIN2/3/4):
**BNC → <3 pF bidirectional video TVS + 75 Ω fixed term → 0.1 µF AC-couple → 75 Ω anti-alias series + 220 pF → BAV99 GND-side clamp → ADV7280 AINx.**
- **Fixed 75 Ω term** (composite/component per §7-3) → **U501 (TS5A23159 switchable-term switch) DROPPED** from Sheet 5 (unused with fixed term). ⚠ **refdes-map Sheet 5: remove U501** (or revert to switchable if you want per-input mute).
- **BAV99 note:** KiCad `Diode:BAV99` is K-A-K (common-anode) — wired as a **parallel GND-side clamp** (both cathodes→signal, anode→GND) per the proposal's "BAV99 to GND"; the bidirectional TVS at the BNC is the 2-rail ESD. (A full 2-rail IC-side clamp would need a different part — flag.)
- **ADV7280 crystal added: Y500 (28.63636 MHz)** + 18 pF loads (the decoder needs it — wasn't in refdes-map). VREFP/VREFN decoupling caps. Supplies: DVDDIO→+3V3, DVDD→+1V8_D, AVDD/PVDD→AVDD_DEC; SDATA/SCLK→I2C_VID; ALSB→GND (0x20).
- New parts → bom-v1 (per-input: video TVS, BAV99, 75 Ω term/anti-alias, 0.1 µF AC-couple, 220 pF; Y500 crystal).

ERC: netlist exit 0; Sheet-5 = 14 pin_not_connected (deferred: ADV7280 P0–P7 data → B35 PL; VS/HS/INTRQ/*RESET/PWRDWN/LCC → PL/control). Sheet-6 = 23 (deferred ADV7393 PL/clk/sync + EXT_LF/COMP caps). No conditioning errors.

### Remaining D (next): sheets 4, 7, 8, 9 + I²C GPIO term-expander
- **Sheet 4 HDMI:** I²C/DDC pull-ups (2.2 kΩ→+3V3); J400.+5V ← TPD `5V_OUT`; TMDS internal-term (no parts).
- **Sheet 8 genlock:** add <3 pF TVS at J800/J801 + anti-alias; REF term **switchable** via the I²C GPIO expander.
- **Sheet 7 SDI:** AC-couple (4.7 µF/100 nF) GS I/O; **ultra-low-cap <0.5 pF SDI ESD** (not BAV99) on GS3470 inputs; GS PLL/VCO analog RC filters; **GS3470 external 27 MHz ref clock** (new oscillator).
- **Sheet 9 AD9742 sync out:** I-V load + **FS_ADJ computed vs AD9742 datasheet** (NOT 300 Ω — different DAC); LMH6643 ×2 → 75 Ω → 220 µF → BNC; SYNC2 slew-limited path.
- **I²C GPIO expander** (e.g., PCA9555 on I2C_HK) — drives the REF/SDI switchable-term ground-leg switches.

---

## 20. Sheet 5 BAV99 fix + Sheets 4 & 8 conditioning (D, cont. 2026-06-14)

**Sheet 5 BAV99 → 2-rail clamp:** replaced the 4× common-anode `Diode:BAV99` with **2× `Diode:BAV99S`** (series, 2 clamp sections each): per input, midpoint→AINx, cathode→**AVDD_DEC (1.8 V)**, anode→GND (AINx is AVDD-referenced). Front bidirectional <3 pF TVS kept. 32 components.

**Sheet 4 (HDMI) wired** (19 components) — full signal path through TPD12S016:
- **TMDS** (4 lanes ×2 ports): J400→U400(TPD ESD)→U402(LT8619C RX); U403(ADV7511 TX)→U401→J401.
- **DDC** (J↔TPD portA, TPD portB↔PHY) with 2.2 kΩ pull-ups; **HPD/CEC** through TPD; **5V** — IN: carrier→J400 via TPD `5V_OUT`; OUT: +5V from sink → TPD VCC5V (flagged direction).
- **I²C_VID** config (LT8619C/ADV7511) + bus pull-ups (R404/405); now threads sheets 4/5/6.
- TPD supplies/CT_HPD/decoupling. **113 deferred** = LT8619C 24-bit RGB + ADV7511 36-pin parallel → B35/B13 PL (placement pass) + audio/misc PHY pins.

**Sheet 8 (genlock) conditioning + expander** (22 components):
- **BAV99S 2-rail clamp** at PGA input (→ +5V_PGA/GND); **<3 pF TVS** at J800/J801; **anti-alias LPF** (R802/C807) before AD9204 VIN+A.
- **Switchable 75 Ω REF term** via **PCA9555 (U803)** I²C GPIO expander on **I2C_HK** → `TERM_EN_REF` → U802 term ground-leg switch. ⚠ **TS5A23159 switch pins are unnamed in the symbol** — wired COM=pin2/NO=pin9/IN=pin1; **confirm COM/NO/NC vs datasheet**.
- AD9204 ref values per §3 (VREF 470 nF, SENSE→GND internal, RBIAS). I2C_HK now = INA226 + TLC59116×3 + PCA9555.

**bom-v1 reconciled:** BAV99S, <3 pF video TVS, ADV7280 28.636 MHz crystal, PCA9555 expander, HDMI/output passives.

ERC: netlist exit 0 on all. Sheet-level errors all deferred PL-data/control (no conditioning errors). **Held: sheets 7 (SDI) + 9 (AD9742) for the focused pass** (7 shares the PCA9555 for SDI-loop term).

---

## 21. U802 pinout fix + Sheet 4 HDMI-input rework (2026-06-14)

**(1) U802 TS5A23159 pinout — FIXED.** The stock `Analog_Switch:TS5A23159DGS` symbol has GND=3/VCC=8, contradicting the TI datasheet (Rev. H). Built **`CarrierGen:TS5A23159_DUAL`** with the correct pinout (1=IN1, 2=NC1, 3=COM1, 4=NO1, 5=GND, 6=NO2, 7=COM2, 8=NC2, 9=IN2, 10=V+). Re-wired the REF term on **switch 1**: IN1(1)→`TERM_EN_REF` (PCA9555), COM1(3)→term ground-leg (R800), NO1(4)→GND, GND(5)→GND, V+(10)→+3V3. (Prior COM=2/NO=9 was invalid — pin 9 = IN2.) Switch 2 unused.

**(2) HDMI +5V direction — FIXED.** OUT (J401): carrier **sources** +5V to the downstream sink via U401 TPD `5V_OUT`. IN (J400): +5V is a **sense input** from the upstream source (`HDMI_IN_5V`, not carrier-driven; DDC pull-ups reference it).

**(3) HDMI IN companion — reworked to sink-side.** Removed the IN-side **U400 TPD12S016** (it's a source-side part). IN is now: J400 TMDS → **2× TPD4E05U06DQA** (ultra-low-cap ESD) → **LT8619C RX** directly (internal 50 Ω term to VTERM); DDC/HPD/EDID **native to the LT8619C** (+ `TPD3E001DRLR` ESD + 2.2 kΩ pulls to cable +5V). TPD12S016 kept **only on OUT** (U401, source-side). Verified: HIN TMDS = J400+ESD+LT8619C (no TPD); DDC native; HDMI_IN_5V sense; HOUT_5V carrier-sourced.

**bom-v1 reconciled:** HDMI IN ESD = 2× TPD4E05U06DQA + TPD3E001DRLR; TPD12S016 now OUT-only (qty 2→1).

ERC: netlist exit 0; Sheet-4 = 113 deferred (LT8619C/ADV7511 parallel → PL) + 2 (HDMI_IN_5V source-sense, expected). No conditioning errors.

### Sheet 7 SDI term — CONFIRMED: no external term switch
GS3470 has **internal 75 Ω input termination** (+ cable equalizer); GS2962 has an internal 75 Ω cable driver. So the SDI inputs/loop need **no external switchable term** (unlike the analog REF). The PCA9555 (Sheet 8) controls the REF term only. SDI conditioning (next pass) = AC-couple only + ultra-low-cap SDI ESD on GS3470 inputs + GS analog RC + 27 MHz ref clock.

### Status
U802 fix + Sheet 4 rework complete & validated. **Next: focused 7 + 9 pass** (SDI AC-couple/ESD/RC/27 MHz; AD9742 FS_ADJ/I-V + SYNC2). All staged — no commit/push.

---

## 22. Sheets 7 (SDI) + 9 (sync out) — conditioning wired (D, focused pass 2026-06-14)

**Sheet 9 (AD9742 SYNC OUT) — level math (verify vs datasheet):**
- `IOUTFS = 32·VREFIO/RSET`, VREFIO=1.2 V → **IOUTFS=10 mA → RSET=3.83 kΩ** (R900, FS_ADJ). ⚠ verify the **32** factor + VREFIO.
- **IOUTA → RL=100 Ω → 1.0 Vpp** DAC swing (R901; IOUTB→matched 100 Ω R902 balance). Compliance IOUTA·100 Ω=1.0 V < ~1.25 V ✓.
- **LMH6643 ×2** (Rf=Rg=1 k) → 2.0 Vpp → **75 Ω back-term + 75 Ω line ÷2 → 1.0 Vpp at load (black-burst)**; tri-level ±300 mV = 600 mVpp = 60% FS codes. **NOT the Sheet-6 300 Ω.**
- 220 µF AC-couple (C900), REFIO 0.1 µF (C901), REFLO→GND, <3 pF TVS (D900).
- **SYNC2 (1-bit LTC, B33 @1.8 V):** RC slew **R906=1 k + C902=1 nF** (τ≈1 µs, edge≈2.2 µs) → LMH6643 ch B → 75 Ω → 220 µF → J901. ⚠ buffer gain for LTC amplitude + slew RC bench-tune.
- Flagged: AD9742 DB0–11 → B35 PL; CLOCK → DAC sample clk; SYNC2_LTC_IN ← B33 PL.
- ERC: 64 pin_not_connected + 18 pin_not_driven, all deferred (PL/RP2040 GPIO/QSPI/Si5351 CLK). No conditioning errors.

**Sheet 7 (SDI) — values + §7-5 rails:**
- **No external term** — GS3470 internal 75 Ω (confirmed). SDI single-ended: **4.7 µF AC-couple** (C700–705), complement AC-grounded; **TPD1E05U06DPY (0.5 pF)** SDI ESD at IN/LOOP/OUT (⚠ 0.5 pF — consider <0.3 pF for 3G margin).
- Chains: J700→ESD+4.7µF→GS3470 DDI0; GS3470 DDO→4.7µF→J702 (reclocked loop); GS2962 SDO→4.7µF→J701.
- **Rails:** GS3470 CORE→+1V2, IO→+1V8_D (B34), **PLL/VCO→+1V2 via RC (10 Ω+1 µF)**, DDI/DDO_VDD→+1V8_D (⚠ equalizer/driver supply — verify 1.2/1.8 split). GS2962 CORE→+1V2, IO→+1V8_D, PLL/VCO→+1V2 RC, **AVDD→+3V3**, **CD_VDD→+3V3_SDIDRV** (FB303). RBIAS/RSET/LF/VBG passives per datasheet (flagged values).
- **27 MHz ref:** crystal Y700 across XTAL(A5)/~XTAL(A6) + 18 pF loads. ⚠ confirm crystal vs external XO (GS3470 datasheet).
- Host SPI: GS3470/GS2962 → SDI_SPI (SCK/MOSI/MISO + per-device CS).
- **⚠ J703 (SDI OUT 2 mirror) flagged unwired** — the GS2962 KiCad symbol exposes only one SDO (C10/D10); needs the 2nd-output pin or a reclocking fanout. Confirm vs datasheet.
- ERC: 109 pin_not_connected, all deferred (GS DOUT/DIN → B34 PL; PCLK/STAT/RESET/audio; J703).

**bom-v1 reconciled:** GS3470 27 MHz crystal, SDI 4.7 µF AC-couple, TPD1E05U06DPY SDI ESD, GS PLL/VCO RC, AD9742 sync passives.

### Status — analog conditioning pass (D) COMPLETE across sheets 4,5,6,7,8,9.
All staged — no commit/push.

---

## 23. Sheets 7 + 9 conditioning cleanup — closes D (2026-06-14)

**Sheet 7:**
- **J703 split:** GS2962 **SDO(C10)→J701**, **~SDO(D10)→J703** — each AC-coupled (4.7 µF) into its own 75 Ω, no fanout (~SDO was previously AC-grounded; now routed out). Both traces = 75 Ω controlled-imp, 3G (layout note).
- **SDI ESD → <0.3 pF** (SP3010-class) on all 4 BNCs (J700–703); replaced the 0.5 pF TPD1E05U06.
- **GS3470 DDI/DDO_VDD → filtered analog branch** `SDI_DDIVDD` = +1V8_D → FB700 ferrite → DDI/DDO_VDD + 1 µF bypass (was raw +1V8_D). ⚠ verify 1.2-vs-1.8 + filter per GS3470 datasheet.
- **J702 loop** — kept wired (GS3470 DDO → AC-couple → BNC). ⚠ **confirm GS3470 DDO drives 75 Ω directly; if logic-level, add a cable driver or drop J702.**
- **Y700 27 MHz** — 18 pF loads assume CL≈9 pF. ⚠ confirm crystal CL/ppm per GS3470 datasheet.

**Sheet 9:** SYNC2 slew **C902 1 nF → 18 nF** (R906=1 k → τ≈18 µs, ~40 µs SMPTE-12M LTC edge).

**refdes-map reconciled:** Sheet 7 (J703=~SDO split, Y700, <0.3 pF SDI ESD, FB700 DDI/DDO filter, no-external-term note); Sheet 8 (U802 CarrierGen/TI pinout, U803 PCA9555, D800 BAV99S 2-rail, D801/D802 REF TVS, ADC ref values). **bom-v1 reconciled.**

ERC: netlist exit 0; all sheet errors deferred PL/data (no conditioning errors).

### Analog-conditioning pass (D) — CLOSED across sheets 4, 5, 6, 7, 8, 9.
Remaining open items are higher-level (not schematic-blocking): spec §14/§15/§17 + packaging-skus propagation to ESP32-UI/PS-thin-agent; digital-1.8 V budget tally on the resized U310; pre-layout flags (2nd-GbE, riser partition, FCC class); + the per-sheet ⚠ verify flags logged above. All staged — no commit/push.

---

## 24. Sheet 7 SDI refinement (proposal §6 / Fig 5-1) — 2026-06-14b

- **TX return-loss networks** (GS2962, per leg): SDO(C10)→J701 and ~SDO(D10)→J703 each get **RSET 75 Ω→CD_VDD + 5.6 Ω series + 75 Ω/10 nF return-loss + 4.7 µF AC-couple** (was plain 4.7 µF). ⚠ verify exact values/topology vs GS2962 Fig 5-1.
- **J702 loop driver:** added **U702** (LMH0302-class 3G-SDI cable driver) — GS3470 DDO → U702 → 5.6 Ω/75 Ω/10 nF return-loss → 4.7 µF → J702; VCC+~SD from +3V3_SDIDRV (always-on). ⚠ symbol pinout is a placeholder — verify vs LMH0302 datasheet. (Resolves the earlier "DDO drives BNC directly?" flag.)
- **Analog supply partition (Fig 5-1):** **+1V2_A** = FB701 ferrite off +1V2 → GS3470 PLL/VCO **+ DDI equalizer (moved to 1.2 V)** + GS2962 PLL/VCO (per-rail RC dropped for the shared ferrite branch); **+3V3_A** ← GS2962 AVDD; **GND_A** = analog-ground partition bridged to GND at a single point via **FB702**. GS3470 **DDO_VDD** stays on the FB700 1.8 V branch — ⚠ confirm DDO rail vs Typical Application Circuit.
- **Y700:** 27 MHz **9 pF-CL** crystal + **8 pF** loads (was 18 pF). ⚠ confirm ppm.
- **10-bit straps:** GS3470 BIT20/~BIT10 (H6) + GS2962 20bit/~10bit (G4) → GND (10-bit). ODDR(TX)/IDDR(RX) on the FPGA buses = HDL note.
- **bom-v1 + refdes-map reconciled.** ERC: netlist exit 0; Sheet-7 errors = deferred PL/data + 2 benign ferrite-isolated-rail power flags (+1V2_A, DDO branch).

---

## 25. Sheet 7 SDI TX return-loss correction (GS2962 datasheet — Justin-confirmed) — 2026-06-14

Per the GS2962 datasheet the series element in each TX return-loss leg is a **5.6 nH inductor, not a 5.6 Ω resistor**. Corrected both GS2962 output legs (SDO→J701, ~SDO→J703) to the exact datasheet topology:
- Output pin (C10=SDO / D10=~SDO) → **5.6 nH (L700/L701) ∥ 75 Ω (R722/R725)** → 4.7 µF (4.6 µF nom) AC-couple → BNC center.
- Same output pin → 75 Ω (R720/R723) → **common CD_VDD** (=+3V3_SDIDRV/E10); 10 nF (C720/C721) bypass CD_VDD→GND_A.
- Output BNC shells **J701/J703 → GND_A** (moved off GND per topology spec; J700/J702 shells remain on GND).
- **Refdes reclass R→L:** R721→**L700**, R724→**L701** (Device:L, 5.6 nH).
- Loop-driver (LMH0302, U702) output network **unchanged** (5.6 Ω + 75 Ω + 10 nF) per instruction; DDO_VDD/+1V2_A/+3V3_A/GND_A partition, Y700 (9 pF-CL, ±100 ppm, ≤50 Ω ESR), 10-bit straps all confirmed and untouched.
- **MPN (flag):** L700/L701 = 2× 5.6 nH RF/wideband 0402, SRF>3G — suggested **Murata LQW15AN5N6G00D**; higher-SRF alt **Coilcraft 0402HP-5N6XJTW**. ⚠ confirm.
- ERC: netlist exit 0; Sheet-7 profile unchanged (107 pin_not_connected deferred PL/control + 2 pin_not_driven + 2 power_pin_not_driven ferrite-rail flags); 0 real errors. Project: 44 comps on Sheet 7. bom-v1 + refdes-map reconciled.
