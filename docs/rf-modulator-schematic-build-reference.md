# RF Modulator Daughter Board — Schematic Build Reference (KiCad)

**Status:** Capture guide, 2026-06-07. Build the schematic in Eeschema, assign footprints, then **Update PCB from Schematic (F8)** — that is the live link the netlist-only path was missing. Net-level source of truth is the verified connection table in [`rf-modulator-schematic-skeleton.md`](rf-modulator-schematic-skeleton.md); this doc is the capture order + symbol/footprint sourcing.

---

## 0. Why schematic-first

A SKiDL/imported netlist is a one-shot seed with nothing behind it to re-sync. The schematic is KiCad's source of truth: assign footprints on the symbols, press F8, and the board stays in lockstep with the schematic forever after. The SKiDL netlist (`rf_mod_daughter.net`) is kept only as a **connectivity cross-check** (see §7).

---

## 1. Symbol + footprint sourcing (do this first)

The three RF ICs are **not** in stock KiCad — pull a matched symbol+footprint pair for each (SnapEDA / Component Search Engine / Ultra Librarian, search the exact P/N). That is the real fix for the "footprint not found" errors. Everything else is stock.

| Ref | Part | Symbol | Footprint |
|---|---|---|---|
| U1 | Si5351A-B-GT | **import** (SnapEDA P/N) | MSOP-10; matched, or stock `Package_SO:MSOP-10_3x3mm_P0.5mm` |
| U2 | ADL5391ACPZ | **import** | **LFCSP-16, 3×3 mm, 0.5 mm pitch, ~1.5 mm EP** (matched; *not* 4×4/0.65) |
| U3 | ERA-3SM+ | **import** / draw 4-pin | **Mini-Circuits WW107** land pattern (MCL supplies it) — do **not** substitute SOT-89 |
| U4 | 12→5 V LDO | `Regulator_Linear` generic | per chosen part (see §5 note on dissipation) |
| Y1 | 25 MHz xtal | `Device:Crystal` (2-pin) | per your crystal package |
| RV1 | 10k trim 3296W | `Device:R_Potentiometer` | `Potentiometer_THT:Potentiometer_Bourns_3296W_Vertical` |
| FL1 | BPF 56–73 MHz | *capture as discrete L/C* (§4) | none yet — topology TBD, leave unplaced |
| J1 | interconnect hdr | `Connector_Generic:Conn_01x06` | `Connector_PinHeader_2.54mm:PinHeader_1x06_P2.54mm_Vertical` |
| J2 | U.FL composite in | `Connector:Conn_Coaxial` | `Connector_Coaxial:U.FL_Hirose_U.FL-R-SMT-1_Vertical` |
| J3 | F-connector out | `Connector:Conn_Coaxial` | panel F-connector — custom/verify |
| D1 | PESD3V3L1BA TVS | `Device:D_TVS` | `Diode_SMD:D_SOD-323` |
| R1–R8 | resistors | `Device:R` | `Resistor_SMD:R_0805_2012Metric` |
| C1–C11 | caps | `Device:C` | `Capacitor_SMD:C_0805_2012Metric` (C10/C11 = 10 µF — 0805 OK or bump to 1206) |
| L1, L2 | inductors | `Device:L` | `Inductor_SMD:L_0805_2012Metric` (L2 = 0805CS-152, 0805 land) |

---

## 2. Sheet setup

Single sheet is fine (small board). Set the title block (project = Schindler 2.0, sheet = RF Modulator Daughter Board, rev/date). Add your imported libraries (Preferences → Manage Symbol/Footprint Libraries → project-specific).

---

## 3. Capture order, by block

Place symbols, then wire nets. Pin numbers are the verified datasheet pinouts. Use net labels (not long wires) for the rails and the carrier/video/output nets — it keeps the sheet readable.

### Block A — Power in & rails
- **J1**: 1 P12V · 2 P3V3 · 3 SDA · 4 SCL · 5 GND · 6 GND
- **U4 LDO**: VIN ← +12V · GND → GND · VOUT → +5V
- **+12V** = J1·1, U4·VIN, R4·1, C10·1
- **+3V3** = J1·2, U1·1 (VDD), U1·7 (VDDO), R7·1, R8·1, C7·1
- **+5V** = U4·VOUT, U2·2/3/4 (VPOS), U2·15 (ENBL), RV1·1, C8·1, C11·1
- **GND** = J1·5/6, U4·GND, all decap grounds, and the per-block grounds below
- Add **PWR_FLAG** to +12V, +5V, +3V3, GND (or ERC will flag "no driver").

### Block B — Clock generator (U1 + Y1 + I²C)
- **Y1**: across U1·2 (XA) and U1·3 (XB)
- **SDA** = J1·3, U1·5, R7·2 (pull-up to +3V3)
- **SCL** = J1·4, U1·4, R8·2
- U1·1/7 → +3V3, U1·8 → GND, C7 decoupling
- **CLK0 (U1·10)** → CARRIER_SQ · **CLK1 (U1·9)** → PILOT
- **U1·6 (CLK2)** → place a **no-connect** flag (unused)
- Note: 10-MSOP has no A0 → I²C addr fixed **0x60**; this must be its own I²C segment vs the genlock Si5351.

### Block C — Carrier LPF + modulator (U2)
- **CARRIER_SQ** = U1·10, L1·1, C2·1  *(L1/C2/C3 = LPF1, recover sinusoid from the square clock)*
- **CARRIER_SIN** = L1·2, C3·1, U2·13 (XPLS)
- **COMP_IN** = J2·1 (SIG), C1·1     **VIDEO_Y** = C1·2, R1·2, U2·11 (YPLS)
- **RV1** wiper (pin 2) → R1·1 (sets Y DC-bias / mod depth); RV1·1 → +5V, RV1·3 → GND
- **VMID** = U2·16 (VMID), U2·12 (YMNS), U2·14 (XMNS), U2·9/10 (Z), U2·6 (WMNS), C9·1; C9·2 → GND
- U2·2/3/4 → +5V · U2·1/7 (COMM) + EPAD → GND · U2·15 (ENBL) → +5V
- **U2·8 (GADJ)** → **no-connect** flag (open = α 1, unity gain)
- **MOD_OUT** = U2·5 (WPLS), R2·1
- (Bench item, not wiring: 56.2 Ω input match on the X carrier input; AM-with-carrier method — DC-bias Y vs inject via Z. See skeleton §4.)

### Block D — Combiner + BPF
- **PILOT** = U1·9, R3·1
- **COMB_NODE** = R2·2, R3·2, FL1·IN
- **FL1 (BPF)**: topology TBD until harmonics measured — capture as a labeled 2-port stub or a small hierarchical sheet and **leave it without a footprint** for now. It won't block the rest of the board from pushing to PCB; you backfill the discrete L/C once measured.
- **BPF_OUT** = FL1·OUT, C4·1 (Ca)

### Block E — Amplifier + 75 Ω output
- **AMP_IN** = C4·2, U3·1 (RF-IN)
- ERA-3 bias: +12V → **R4 (240 Ω)** → **BIAS_MID** → **L2 (1.5 µH choke)** → AMP_OUT
- **AMP_OUT** = U3·3 (RF-OUT+DC), L2·2, C5·1 (Cb)
- U3·2/4 → GND
- **MLP_IN** = C5·2, R5·1 (43 Ω) · **MLP_OUT** = R5·2, R6·1 (82 Ω), C6·1 (Cc); R6·2 → GND
- **RF_OUT** = C6·2, D1·1 (TVS), J3·1 (SIG); D1·2 → GND; J3 shell → GND

---

## 4. ERC checklist
- PWR_FLAG on every rail (+12V, +5V, +3V3, GND).
- No-connect flags on **U1·6 (CLK2)** and **U2·8 (GADJ)**.
- U2 exposed pad → GND (the imported symbol should expose an EP/pin 17; if not, tie the pad in the footprint).
- Run ERC clean before assigning footprints.

## 5. Footprints + push to PCB
- Assign footprints (Tools → Assign Footprints / they come pre-bound on the imported IC symbols).
- **U4 dissipation note:** ADL5391 draws ~130 mA at 5 V; a linear 12→5 V drop burns ~0.9 W. Size the LDO package (SOT-223/DPAK + copper) accordingly — or, if you'd rather, add a 5 V wire to the J1 interconnect and delete U4 + its heat entirely (one extra conductor vs. a hot regulator on a small board). Bench call.
- **Tools → Update PCB from Schematic (F8)** to push to the board. This is the sync that was missing.

## 6. Cross-check against the SKiDL netlist
After capture, Eeschema → export netlist, and diff against `rf_mod_daughter.net` (the verified skeleton) to catch any transcription miswires before you route.

## 7. Cross-references
- Verified pinouts + full net table + SKiDL source: [`rf-modulator-schematic-skeleton.md`](rf-modulator-schematic-skeleton.md)
- Partition / interconnect rationale: [`rf-modulator-daughter-board-option.md`](rf-modulator-daughter-board-option.md)
- Parts spec + BOM: [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md)
