# Schindler 2.0 — Reset Strategy (carrier A1, `SchindlerCarrierBoard_V1`)

**Date:** 2026-06-17 (datasheet-verified 2026-06-17) · **Status:** PLAN / RATIFIED — all reset-pin polarities, levels, and the power-up-reset requirement confirmed against datasheets (see Per-pin table + Power-up reset requirement). No `.kicad_sch`, bom-v1, or refdes-map changes yet. Wiring happens at the PS-EMIO/PL pin-lock pass (see Sequencing).

## Problem

The reset audit (live netlist) found **no reset infrastructure on the carrier** — every reset / power-down / standby / TRST / RUN pin on every resettable chip floats, with no reset net and no supervisor (Case 3, board-wide). Floating active-low resets leave parts in an indeterminate state, and there is **no way to recover a wedged I²C device under firmware without power-cycling the box.**

This doc defines a two-domain, PS-EMIO-driven, active-low reset scheme. Each net is **pulled to the asserted (reset) state** so parts power up **held in reset** and are released only when the PS drives the line high — required because the ADV7280 / ADV7393 / GS parts **mandate a hardware reset after power-up** (a static pull-up-to-release never delivers one). See *Power-up reset requirement* below.

## Key correction to the initial grouping — split by I/O voltage, not by interface

The initial proposal was `VIDEO_RESET_N = U403/U500/U600` and `SDI_RESET_N = GS3470/GS2962 + LT8619C`. The netlist shows that won't work electrically:

- **ADV7280 RESET\*, ADV7393 \*RESET, LT8619C RESET_N** are all **3.3 V** logic (DVDDIO / VDD_IO / VCC33_TTL = +3V3).
- **GS3470 / GS2962 ~RESET** are **1.8 V** logic (IO_VDD = +1V8_D).
- A single net + single pull-up can't serve both 1.8 V and 3.3 V inputs (a 3.3 V pulled net over-drives 1.8 V inputs; a 1.8 V net may not reach a valid logic-high at 3.3 V inputs).
- **ADV7511 has no hardware reset pin** — only **PD** (power-down), and its control level is **1.8 V** (DVDD). It is handled separately (see Oddballs).

**Therefore the domains are grouped by I/O voltage:**

| Domain | Logic level | Pull (idle) | Release | Members |
|--------|-------------|-------------|---------|---------|
| **VIDEO_RESET_N** | 3.3 V | 10 kΩ → **GND** | PS-EMIO drives **HIGH** | ADV7280 RESET* (U500.25), ADV7393 *RESET (U600.20), LT8619C RESET_N (U402.24) |
| **SDI_RESET_N** | 1.8 V | 10 kΩ → **GND** | PS-EMIO drives **HIGH** | GS3470 ~RESET (U700.H5), GS2962 ~RESET (U701.G8) |

Both are **active-low, default = ASSERTED (held in reset)** — the pull-down holds the line low (in reset) at power-up and through PS boot (EMIO is Hi-Z then), and the PS drives the line **high to release** when it's ready to configure the parts over I²C. The EMIO bank VCCO still must match the domain voltage (3.3 V driver for VIDEO, 1.8 V for SDI) because the EMIO's *high* level has to clear the part's V_IH to register as released — so the by-voltage grouping still holds. LT8619C (HDMI RX) rides the **VIDEO** domain because it's 3.3 V, not because it's "video vs SDI" — what matters is the voltage match.

## Power-up reset requirement (why pull-DOWN, not pull-up)

Datasheet-confirmed — this is the crux of the topology:
- **ADV7280** RESET* — active-low, **≥5 ms** min low pulse to reset.
- **ADV7393** *RESET — active-low; *"a hardware reset is necessary after power-up for correct device operation"* (datasheet offers an RC network as a self-reset alternative).
- **GS2962** ~RESET — active-low; *"the device must be reset to operate correctly"*, hold LOW **≥1 ms** after supplies stable.
- **GS3470** ~RESET (H5) — active-low; LOW → default conditions.
- **LT8619C** RESET_N — active-low hardware reset (MCU/SoC-driven or I²C).

Because these parts **mandate** a power-up reset, a static pull-up-to-release is wrong (it never asserts one). Holding the nets **low via pull-down** keeps every part safely in reset from power-up through PS boot; the PS then drives the line **high to release** when ready. This satisfies the min pulse widths *by construction* (the line is held low far longer than 5 ms during boot) and doesn't depend on firmware remembering a pulse. Bonus: a PS reboot tri-states the EMIO → pull-down re-asserts reset → the parts reset with the PS. **RC-network alternative:** if a firmware-independent power-up reset is wanted, an RC on each net (or OR'd with the EMIO) self-generates the pulse (ADV7393-endorsed) — optional belt-and-suspenders, not needed with the PS as deliberate reset master.

## Per-pin table

| Chip | Pin | Function | Polarity (confirmed) | Domain / net | Idle pull | Suggested refdes |
|------|-----|----------|----------|--------------|----------|------------------|
| ADV7280 (U500) | RESET* p25 | chip reset | active-low, ≥5 ms pulse | **VIDEO_RESET_N** | net pull-**down** | shared net PD (below) |
| ADV7393 (U600) | *RESET p20 | chip reset | active-low, power-up reset mandatory | **VIDEO_RESET_N** | net pull-**down** | shared net PD |
| LT8619C (U402) | RESET_N p24 | chip reset | active-low (HW reset pin) | **VIDEO_RESET_N** | net pull-**down** | shared net PD |
| GS3470 (U700) | ~RESET H5 | chip reset | active-low (LOW→defaults) | **SDI_RESET_N** | net pull-**down** | shared net PD |
| GS2962 (U701) | ~RESET G8 | chip reset | active-low, ≥1 ms after supplies | **SDI_RESET_N** | net pull-**down** | shared net PD |
| **VIDEO_RESET_N net** | — | PS-EMIO drive, 3.3 V | active-low, PS drives HIGH to release | (this net) | **R_PDv 10 kΩ → GND** | at EMIO entry — refdes at pin-lock (sheet 2/10) |
| **SDI_RESET_N net** | — | PS-EMIO drive, 1.8 V | active-low, PS drives HIGH to release | (this net) | **R_PDs 10 kΩ → GND** | at EMIO entry — refdes at pin-lock |
| ADV7511 (U403) | PD/AD p38 | **power-down + I²C-addr select** (no reset pin) | active-low PD *when tied high* | **static tie** (no net, no EMIO) | **2 kΩ → +1V8_A** | **R406** 2 kΩ ±10% → +1V8_A |
| GS2962 (U701) | STANDBY D3 | standby | **active-high** (STBY=1 → standby) | standalone | pull-**down** GND | **R728** 10 kΩ → GND |
| GS3470 (U700) | ~TRST D7 | **JTAG TAP reset** (not chip reset) | active-low, internal pull-down | **leave unconnected** | none (internal PD) | — (optional R729 → GND) |
| RP2040 (U900) | RUN p26 | global reset | **active-low**, internal PU present | standalone | pull-**up** +3V3 + POR cap | **R910** 10 kΩ → +3V3, **C926** 100 nF → GND |

One pull-down per **net** is the minimum (it holds the whole net asserted/in-reset until the PS releases). The 5 ms / 1 ms minimum pulse widths are satisfied for free — the PS holds the line low through its entire boot, far longer than either minimum.

## The four oddballs — resolved (with basis)

1. **ADV7511 PD/AD (p38) — dual-function power-down + I²C-address select; NO reset pin (datasheet-confirmed).** Reset is I²C register script or power cycle only. The PD/AD pin is **latched at supply power-up** and sets BOTH the I²C address AND the PD polarity: tied **HIGH via 2 kΩ to AVDD** → address **0x7A** + PD **active-low** + powered-on; tied **LOW** → 0x72 + PD active-high. The datasheet mandates a **2 kΩ ±10%** resistor (not 10 k). **Decision: static 2 kΩ → +1V8_A** (= AVDD), locking **address 0x7A** + active-low PD + on. **No EMIO, no reset net** — this **frees an EMIO** vs the earlier plan. Power-down, if ever needed, is available via the I²C PD register bit (OR'd with the pin). The PD pin is **not a reset and cannot recover a wedged I²C** (it only gates the device) — the ADV7511's real recovery is the **I²C reset script** or a **box power cycle** (eFuse/soft-power), which ADI confirms is normal. **Lock 0x7A into the I²C map** — collision-free vs ADV7280 (0x20 / 7-bit 0x10) and ADV7393 (0x54 / 7-bit 0x2A).
2. **GS2962 STANDBY (D3) — active-high.** STANDBY = 1 puts the device in low-power standby; it must be held **low** for normal operation. **Pull-down to GND** (opposite direction from the active-low resets — do not place on SDI_RESET_N). Optionally a dedicated EMIO if firmware standby control is wanted (default-low pull-down keeps it operational regardless).
3. **GS3470 ~TRST (D7) — JTAG test-reset, not chip reset (datasheet-confirmed).** Active-low, **internal pull-down**, and the datasheet explicitly states it **can be left unconnected when JTAG is unused**. **Decision: leave unconnected** (the internal pull-down holds the TAP in reset) — no external part required. An optional external pull-down (R729 → GND) adds margin but isn't needed. **Does NOT belong on SDI_RESET_N.** If a JTAG header is ever added, route TRST there instead.
4. **RP2040 RUN (p26) — active-low global reset, has an internal pull-up** (~50 kΩ) so it boots without external help. Best practice per the RP2040 Hardware Design guide: external **10 kΩ pull-up → +3V3** (IOVDD) + **100 nF to GND** for a clean power-on reset, and a **test point** (or reset button) for bench recovery. **Standalone** — the RP2040 is the genlock MCU and resets independently of the video/SDI domains.

**Active-low reset confirmation (datasheet-verified; all idle LOW/in-reset on their domain pull-downs, released by the PS driving high):** ADV7280 RESET* (≥5 ms pulse), ADV7393 *RESET (power-up reset mandatory), LT8619C RESET_N (HW reset pin), GS3470 ~RESET (H5, LOW→defaults), GS2962 ~RESET (≥1 ms after supplies). ✅ All confirmed against datasheets — no convention assumptions remain.

## Pin-budget / EMIO check

Per `pin-budget.md`: control-plane I/O rides **PS MIO/EMIO + I²C, largely off the 152 PL**, and the PL is ~78 % used (**~33 free**). EMIO GPIO from the PS is 64-bit-wide (ample) — the cost is one **PL package pin per EMIO line**, in a bank whose VCCO matches the domain voltage.

**Requirement: 2 reset lines = 2 EMIO/PL pins** (HDMI_TX_PD_N dropped — ADV7511 PD is now a static tie, freeing that EMIO). Verdict: **available — but conditionally.**
- **VIDEO_RESET_N** → a **3.3 V** PL bank EMIO. A 3.3 V VCCO bank already exists (ADV7280 BT.656 / HDMI-in ride 3.3 V I/O).
- **SDI_RESET_N** → **1.8 V** PL bank EMIO (B34/B35 are 1.8 V per the SDI re-strap; B34 = 22/36, 14 free → room).

> ⚠ **"≥2 available" must hold AFTER the data buses are allocated, not before.** These 2 control lines, the BT.656 egress from U500, and every other front-end's PL egress all draw from the **same SoM pin pool**. The free-pin counts above are pre-data-bus-allocation. So this is a **pin-lock-pass accounting item**: scope the fast parallel buses first, then confirm 2 voltage-matched control pins still remain. See [`pin-lock-todo.md`](pin-lock-todo.md) for the full SoM-interface allocation list this competes within.

**Proposed nominal assignment** (exact EMIO bit index + PL pin location set at pin-lock):
- `EMIO_GPIO[a]` → VIDEO_RESET_N (3.3 V bank)
- `EMIO_GPIO[b]` → SDI_RESET_N (1.8 V bank, B34)
- *(HDMI_TX_PD_N eliminated — ADV7511 PD is a static 2 kΩ tie, no EMIO.)*

⚠ *The specific EMIO indices are not in the repo (they live in the Vivado PS block design); assigned at pin-lock. This doc reserves the requirement, not the numbers.*

### U803 PCA9555 fallback (if EMIO is too tight)
U803 (PCA9555 on **I2C_HK** — off the video **I2C_VID** bus, so it can still recover an I2C_VID wedge) has 16 GPIO, only a few used for term-enable → spare bits available (confirm exact count at wiring). **Caveat: U803 outputs are 3.3 V** (its VCC), so it's a clean fallback for **VIDEO_RESET_N (3.3 V)** but would **over-drive the 1.8 V SDI_RESET_N** — that domain would need a level shift or a 1.8 V expander.
**Recommendation:** PS-EMIO for both reset lines (native per-bank voltage, no level issues). Use U803 only as a fallback for the 3.3 V VIDEO_RESET_N if an EMIO can't be spared.

## Sequencing — this is a pin-lock dependency

VIDEO_RESET_N and SDI_RESET_N **must be allocated in the same pass that locks the PS-EMIO / PL bus assignments.** Reasons: (a) each consumes a PL package pin in a voltage-matched bank, so it competes with the parallel video/SDI buses for bank pins; (b) wiring resets before the EMIO map is fixed means re-wiring them when the map changes. **Do not wire reset in isolation** — fold it into the EMIO/PL pin-lock, then the standalone pulls (ADV7511 PD, GS STANDBY/TRST, RP2040 RUN) can be placed at the same time.

## Open items

**Reset polarities/levels — ALL CONFIRMED (datasheets, 2026-06-17):** ADV7511 PD/AD (no reset pin; latches addr + PD polarity; 2 kΩ tie → 0x7A), ADV7280 RESET* (active-low, ≥5 ms), ADV7393 *RESET (active-low, power-up reset mandatory), GS2962 ~RESET (active-low, ≥1 ms) + STANDBY (active-high), GS3470 ~RESET (H5, active-low) + ~TRST (internal PD, leave NC), LT8619C RESET_N (active-low HW reset), RP2040 RUN (active-low, internal PU). No convention assumptions remain.

**Still open:**
- **ADV7511 separate 3.3 V I/O supply** — confirm whether the part has a 3.3 V digital-I/O supply distinct from the 1.8 V AVDD/DVDD (decoupling-pass item, not reset).
- **U803 spare-bit count** — confirm at wiring (only matters if the U803 fallback is used; PS-EMIO is the primary plan).
- **Exact EMIO bit indices / PL pin locations** — assigned at pin-lock (live in the Vivado PS block design, not the repo).
