 # Schindler 2.0 — RF Modulator Daughter Board: Schematic Skeleton

**Status:** Pin-level connection skeleton, 2026-06-07. All three IC pinouts **verified against datasheets**. This is the electrical net-list for the panel-mount RF modulator daughter board ([`rf-modulator-daughter-board-option.md`](rf-modulator-daughter-board-option.md)) — the source to draw the KiCad schematic from, plus a runnable SKiDL generator that emits a KiCad-importable `.net`.

**What's locked vs open:** Connectivity and all IC pin numbers are confirmed. The genuine open items are circuit-design choices (modulation method, BPF topology, input matching) flagged in §4 — not connectivity.

Companion artifacts (Claude container outputs, drop into the repo): `rf_mod_daughter.py` (SKiDL source) and `rf_mod_daughter.net` (generated KiCad netlist).

---

## 1. Refdes legend

| Ref | Part | Ref | Part |
|---|---|---|---|
| U1 | Si5351A-B-GT clock gen (10-MSOP) | C1 | Cin — composite coupling |
| U2 | ADL5391 multiplier (16-LFCSP) | R1 | Y-bias series |
| U3 | ERA-3SM+ MMIC amp (WW107) | L1/C2/C3 | LPF1 (recover sinusoid) |
| U4 | 12→5 V LDO (part TBD) | R2/R3 | resistive combiner |
| Y1 | 25 MHz crystal | C4/C5/C6 | Ca/Cb/Cc — 1 nF C0G DC blocks |
| FL1 | BPF 5th-order LC 56–73 MHz (TBD) | R4 | 240 Ω amp bias |
| RV1 | 10k trim (mod-depth) | L2 | 1.5 µH bias choke (RFC) |
| J1 | interconnect header | R5/R6 | 43 Ω / 82 Ω MLP |
| J2 | U.FL composite-in | D1 | PESD3V3L1BA TVS |
| J3 | F-connector RF out | R7/R8 | I²C pull-ups (~2k2) |
| | | C7–C11 | decoupling |

---

## 2. Verified IC pinouts (number ↔ name)

**U1 Si5351A-B-GT, 10-MSOP** (Rev 1.3, Table 20). No A0 pin → I²C address fixed **0x60**. No exposed pad.

| 1 VDD | 2 XA | 3 XB | 4 SCL | 5 SDA | 6 CLK2 | 7 VDDO | 8 GND | 9 CLK1 | 10 CLK0 |
|---|---|---|---|---|---|---|---|---|---|

**U2 ADL5391, 16-LFCSP CP-16-27** (Rev A, Table 3). Exposed pad → GND (mandatory).

| 1 COMM | 2 VPOS | 3 VPOS | 4 VPOS | 5 WPLS | 6 WMNS | 7 COMM | 8 GADJ |
|---|---|---|---|---|---|---|---|
| **9 ZMNS** | **10 ZPLS** | **11 YPLS** | **12 YMNS** | **13 XPLS** | **14 XMNS** | **15 ENBL** | **16 VMID** |

**U3 ERA-3SM+, WW107 Micro-X**: 1 = RF-IN, 2 = GND, 3 = RF-OUT + DC-IN, 4 = GND.

---

## 3. Connection table (by net)

| Net | Pins (refdes · pin name) |
|---|---|
| **+12V** | J1·1 (P12V), R4·1, U4·1 (VIN), C10·1 |
| **+5V** | U4·3 (VOUT), U2·2/3/4 (VPOS), U2·15 (ENBL = enabled), RV1·1, C8·1, C11·1 |
| **+3V3** | J1·2 (P3V3), U1·1 (VDD), U1·7 (VDDO), R7·1, R8·1, C7·1 |
| **GND** | J1·5/6, J2·2 (shield), J3·2 (shell), U1·8, U2·1/7 (COMM) + EPAD, U3·2/4, U4·2, FL1·3, RV1·3, R6·2, D1·2, C2/C3/C7/C8/C9/C10/C11 grounds |
| **SDA** | J1·3, U1·5, R7·2 |
| **SCL** | J1·4, U1·4, R8·2 |
| **XA** | Y1·1, U1·2 |
| **XB** | Y1·2, U1·3 |
| **COMP_IN** | J2·1 (SIG), C1·1 |
| **VIDEO_Y** | C1·2, R1·2, U2·11 (YPLS) |
| *(Y-bias)* | RV1·2 (wiper) → R1·1 |
| **VMID** | U2·16 (VMID ref), U2·12 (YMNS), U2·14 (XMNS), U2·9/10 (Z), U2·6 (WMNS), C9·1 |
| **CARRIER_SQ** | U1·10 (CLK0), L1·1, C2·1 |
| **CARRIER_SIN** | L1·2, C3·1, U2·13 (XPLS) |
| **PILOT** | U1·9 (CLK1), R3·1 |
| **MOD_OUT** | U2·5 (WPLS), R2·1 |
| **COMB_NODE** | R2·2, R3·2, FL1·1 (IN) |
| **BPF_OUT** | FL1·2 (OUT), C4·1 (Ca) |
| **AMP_IN** | C4·2, U3·1 (RF-IN) |
| **BIAS_MID** | R4·2, L2·1 |
| **AMP_OUT** | U3·3 (RF-OUT+DC), L2·2, C5·1 (Cb) |
| **MLP_IN** | C5·2, R5·1 |
| **MLP_OUT** | R5·2, R6·1, C6·1 (Cc) |
| **RF_OUT** | C6·2, D1·1, J3·1 (SIG) |
| *(unused)* | U1·6 (CLK2) float · U2·8 (GADJ) open = α 1 |

---

## 4. Design items to settle on the bench (not connectivity)

1. **Modulation method (the one real modulator decision).** ADL5391 datasheet: feed CW carrier into X, AM (video) into Y; the **Z input adds directly to the output** "to cancel a carrier or apply a static offset." NTSC needs AM-*with*-carrier (negative mod), so either (a) DC-bias the Y input to create the carrier pedestal, or (b) inject scaled carrier via Z. RV1 is reserved for whichever path wins. Inputs self-bias to VPOS/2 (2.5 V); single-ended drive uses the PLS input with the MNS half referenced/terminated.
2. **Input matching.** ADL5391 inputs are ~500 Ω diff up to ~100 MHz; eval board uses 56.2 Ω input matching resistors. Carry that over for the X (carrier, 56–73 MHz) input.
3. **BPF topology (FL1).** Placeholder block; synthesize the 5th-order LC after measuring harmonic content on the bench.
4. **Decoupling.** Per datasheet, one 0.1 µF at *each* supply pin: U1 VDD (1) and VDDO (7); U2 VPOS (2/3/4) wants the eval-board set (100 pF + 0.1 µF + 4.7 µF). VMID (U2·16) decouple to GND.
5. **ERA-3 bias.** Rbias from +12 V: datasheet optimum ≈ 251 Ω for 35 mA; ordered 240 Ω → ~37 mA, fine. RFC (L2, 1.5 µH) feeds bias into pin 3; DC blocks on pins 1 and 3 (Ca, Cb).
6. **I²C address.** 10-MSOP Si5351A is fixed 0x60 — collides with the genlock Si5351; this RF one must be on its own I²C segment (the interconnect SDA/SCL = dedicated segment) or behind a mux.
7. **ENBL** = high to enable (tied to +5 V). **GADJ** open = unity gain; drive 0–2 V to trim.

---

## 5. SKiDL generator

Defines every part ad-hoc with named pins (no KiCad symbol libraries needed), wires by net, emits a KiCad netlist. `pip install skidl --break-system-packages` then `python3 rf_mod_daughter.py` → `rf_mod_daughter.net` (import via KiCad PCB editor → Import Netlist). The "no footprint" messages on generation are expected; footprints are assigned in KiCad.

```python
from skidl import Part, Pin, Net, generate_netlist, SKIDL, TEMPLATE

PASSIVE = Pin.types.PASSIVE

def mkpart(name, ref_prefix, value, pin_specs):
    t = Part(name=name, ref_prefix=ref_prefix, tool=SKIDL, dest=TEMPLATE)
    t.value = value
    for num, nm in pin_specs:
        t.add_pins(Pin(num=num, name=nm, func=PASSIVE))
    return t

# U1 Si5351A-B-GT 10-MSOP (Rev 1.3 Table 20). No A0 -> addr 0x60. No EPAD.
SI5351 = mkpart("Si5351A-B-GT", "U", "Si5351A-B-GT", [
    ("1","VDD"),("2","XA"),("3","XB"),("4","SCL"),("5","SDA"),
    ("6","CLK2"),("7","VDDO"),("8","GND"),("9","CLK1"),("10","CLK0")])

# U2 ADL5391 16-LFCSP CP-16-27 (Rev A Table 3). EPAD -> GND.
ADL5391 = mkpart("ADL5391ACPZ", "U", "ADL5391ACPZ", [
    ("1","COMM"),("2","VPOS"),("3","VPOS"),("4","VPOS"),("5","WPLS"),
    ("6","WMNS"),("7","COMM"),("8","GADJ"),("9","ZMNS"),("10","ZPLS"),
    ("11","YPLS"),("12","YMNS"),("13","XPLS"),("14","XMNS"),
    ("15","ENBL"),("16","VMID"),("17","EPAD")])

# U3 ERA-3SM+ WW107: 1=RFIN 2/4=GND 3=RFOUT+DCIN
ERA3 = mkpart("ERA-3SM+", "U", "ERA-3SM+",
    [("1","RFIN"),("2","GND"),("3","RFOUT"),("4","GND")])

LDO  = mkpart("LDO_12to5","U","LDO 12V->5V",[("1","VIN"),("2","GND"),("3","VOUT")])
XTAL = mkpart("XTAL_25M","Y","25MHz",[("1","1"),("2","2")])
TRIM = mkpart("TRIM_10k","RV","10k",[("1","1"),("2","W"),("3","3")])
BPF  = mkpart("BPF_56_73MHz","FL","5th-order LC (TBD)",[("1","IN"),("2","OUT"),("3","GND")])

def two(name, ref, value): return mkpart(name, ref, value, [("1","1"),("2","2")])
R=two("R","R",""); C=two("C","C",""); L=two("L","L","")
TVS=two("TVS_PESD3V3L1BA","D","PESD3V3L1BA")
UFL=mkpart("U.FL","J","U.FL composite in",[("1","SIG"),("2","GND")])
FCONN=mkpart("F_75ohm","J","F-conn RF out",[("1","SIG"),("2","SHELL")])
J1t=mkpart("HDR_Interconnect","J","I2C+PWR+GND",
    [("1","P12V"),("2","P3V3"),("3","SDA"),("4","SCL"),("5","GND"),("6","GND")])

u1=SI5351(ref="U1"); u2=ADL5391(ref="U2"); u3=ERA3(ref="U3"); u4=LDO(ref="U4")
y1=XTAL(ref="Y1"); rv1=TRIM(ref="RV1"); bpf=BPF(ref="FL1")
j1=J1t(ref="J1"); j2=UFL(ref="J2"); j3=FCONN(ref="J3")

cin=C(ref="C1"); rby=R(ref="R1"); llpf=L(ref="L1"); clpf1=C(ref="C2"); clpf2=C(ref="C3")
rc1=R(ref="R2"); rc2=R(ref="R3"); ca=C(ref="C4"); cb=C(ref="C5"); cc=C(ref="C6")
rbias=R(ref="R4"); lchk=L(ref="L2"); rser=R(ref="R5"); rsh=R(ref="R6"); tvs=TVS(ref="D1")
rpu_s=R(ref="R7"); rpu_c=R(ref="R8")
cd1=C(ref="C7"); cd2=C(ref="C8"); cd3=C(ref="C9"); cd4i=C(ref="C10"); cd4o=C(ref="C11")

GND=Net("GND"); P12V=Net("+12V"); P5V=Net("+5V"); P3V3=Net("+3V3")
SDA=Net("SDA"); SCL=Net("SCL"); XA=Net("XA"); XB=Net("XB")
COMP_IN=Net("COMP_IN"); VIDEO_Y=Net("VIDEO_Y"); VMID=Net("VMID")
CAR_SQ=Net("CARRIER_SQ"); CAR_SIN=Net("CARRIER_SIN"); PILOT=Net("PILOT")
MOD_OUT=Net("MOD_OUT"); COMB_NODE=Net("COMB_NODE"); BPF_OUT=Net("BPF_OUT")
AMP_IN=Net("AMP_IN"); AMP_OUT=Net("AMP_OUT"); BIAS_MID=Net("BIAS_MID")
MLP_IN=Net("MLP_IN"); MLP_OUT=Net("MLP_OUT"); RF_OUT=Net("RF_OUT")

P12V += j1["P12V"], rbias["1"], u4["VIN"], cd4i["1"]
P3V3 += j1["P3V3"], u1["VDD"], u1["VDDO"], rpu_s["1"], rpu_c["1"], cd1["1"]
P5V  += u4["VOUT"], u2["VPOS"], rv1["1"], cd2["1"], cd4o["1"]
GND  += (j1["GND"], j2["GND"], j3["SHELL"], u1["GND"], u4["GND"], u3["GND"],
         bpf["GND"], rv1["3"], rsh["2"], tvs["2"],
         cd1["2"], cd2["2"], cd3["2"], cd4i["2"], cd4o["2"], clpf1["2"], clpf2["2"])
GND += u3["4"]
GND += u2["COMM"], u2["EPAD"]

SDA += j1["SDA"], u1["SDA"], rpu_s["2"]
SCL += j1["SCL"], u1["SCL"], rpu_c["2"]
XA  += y1["1"], u1["XA"]
XB  += y1["2"], u1["XB"]
# U1 CLK2 (pin 6) unused -> float

COMP_IN += j2["SIG"], cin["1"]
VIDEO_Y += cin["2"], rby["2"], u2["YPLS"]
rv1["W"] += rby["1"]
VMID += (u2["VMID"], u2["YMNS"], u2["XMNS"], u2["ZPLS"], u2["ZMNS"], u2["WMNS"], cd3["1"])
u2["ENBL"] += P5V          # high = enable
# GADJ (pin 8) left OPEN => alpha = 1

CAR_SQ  += u1["CLK0"], clpf1["1"], llpf["1"]
CAR_SIN += llpf["2"], clpf2["1"], u2["XPLS"]
PILOT     += u1["CLK1"], rc2["1"]
MOD_OUT   += u2["WPLS"], rc1["1"]
COMB_NODE += rc1["2"], rc2["2"], bpf["IN"]
BPF_OUT  += bpf["OUT"], ca["1"]
AMP_IN   += ca["2"], u3["RFIN"]
BIAS_MID += rbias["2"], lchk["1"]
AMP_OUT  += u3["RFOUT"], lchk["2"], cb["1"]
MLP_IN   += cb["2"], rser["1"]
MLP_OUT  += rser["2"], rsh["1"], cc["1"]
RF_OUT   += cc["2"], tvs["1"], j3["SIG"]

generate_netlist(file_="rf_mod_daughter.net")
```

---

## 6. Cross-references

- Daughter-board partition + interconnect: [`rf-modulator-daughter-board-option.md`](rf-modulator-daughter-board-option.md)
- Baked-in design + parts spec + BOM: [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md)
- Datasheets: ADL5391 Rev A · Si5351A/B/C-B Rev 1.3 · ERA-3SM+ Rev R
