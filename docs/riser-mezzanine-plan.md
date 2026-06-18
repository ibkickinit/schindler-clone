# Schindler 2.0 — Analog I/O Riser + Mezzanine Plan (PROPOSAL, rev 2)

**Created 2026-06-18, rev 2 2026-06-18 (Claude).** Staged plan implementing the two-row decision in [`connector-domain.md`](connector-domain.md). **STATUS: PROPOSAL — gated on Justin's approval of the plan + connector choice. No schematic edits, nothing pushed.** Do not start the riser or tear down sheets 5/6 until approved. **Sheet 8 is NOT torn down (see Genlock).**

## Scope recap
Top-row rear-panel **video** I/O moves off the carrier onto a new **analog I/O riser** (A4), connected to the carrier by **two G-S-G mezzanine headers** (IN + OUT). Genlock stays **coax** (not on the mezzanine). The analog PHYs (ADV7280/ADV7393) stay on the carrier → the FPGA PL pin-lock (the 116 nets) is **untouched**. SDI/HDMI/REF-OUT/RF stay carrier board-mount (bottom row, no change).

## 1. What crosses the mezzanine — 8 video signals + LED control
| # | Net | Dir | Header | Carrier dest (stays on carrier) |
|---|-----|-----|--------|----------------------------------|
| 1 | CVBS_IN | in | **IN** | ADV7280 U500 (sheet 5) |
| 2 | Y_IN | in | IN | ADV7280 U500 |
| 3 | PB_IN | in | IN | ADV7280 U500 |
| 4 | PR_IN | in | IN | ADV7280 U500 |
| 5 | CVBS_OUT | out | **OUT** | ADV7393 U600 (sheet 6) |
| 6 | Y_OUT | out | OUT | ADV7393 U600 |
| 7 | PB_OUT | out | OUT | ADV7393 U600 |
| 8 | PR_OUT | out | OUT | ADV7393 U600 |
| + | LED I²C block | — | OUT corner / 3rd hdr | TLC59116 on riser (see §4) |

**Genlock does NOT cross** (coax, §2). **8 video nets**, split IN vs OUT.

## 2. Genlock — STAYS COAX, sheet 8 unchanged
- **J802/J803 (sheet 8 U.FL) STAND** — not removed, sheet 8 **not torn down**.
- REF IN / REF LOOP reach the carrier by **coax pigtail → U.FL** (J802/J803); the **loop-through is carrier-side** (`REF_BUS`), as currently wired. The riser holds the 2 SYNC BNCs *mechanically*, but they connect by coax pigtail to the carrier U.FL — **not through the mezzanine.**
- Genlock front-end (U800 PGA / U801 ADC / U802 term-switch / U803 / `REF_BUS` term + AC-couple + ESD) **stays carrier-side, unchanged.** Sync ESD stays carrier-side (existing `REF_BUS` D801/D802); video ESD goes on the riser (§3).

## 3. Two mezzanine headers — separate inputs from outputs
- **IN header:** 4 video IN (CVBS/Y/Pb/Pr) → U500. G-S-G, ~2×6–2×8.
- **OUT header:** 4 video OUT (CVBS/Y/Pb/Pr) → U600. G-S-G, ~2×6–2×8. Carries the **LED I²C/power block in its own ground-barriered corner** — *or* a small dedicated **3rd control header** (2×3/2×4) (recommended, to keep the digital block fully off the analog headers).
- **Rationale:** separate full-swing DAC **outputs** from sensitive decoder **inputs** — no cross-coupling of a 1 Vpp DAC edge into a decoder front-end.

**Connector family (NOT QSH/QTH):** stack height must equal the **panel BNC row pitch (~18–22 mm)** to clear the carrier (bottom-row) BNCs. QSH/QTH 0.5 mm top out ~16 mm → **too short.** Propose **Samtec Q Strip QTE/QSE (0.8 mm)** for the small analog headers, or **SEARAY (SEAM/SEAF)** if a single denser connector with integral ground planes is preferred (SEARAY reaches tall stacks and gives the best G-S-G ground structure). Orientation (parallel vs right-angle) is a **mechanical** decision; support the riser with **standoffs**.

G-S-G target: a ground adjacent to every analog net + a ground return; >−50 dB channel separation at 30 MHz (component crosstalk spec).

## 4. LEDs — 5 per-SIGNAL bi-color, one driver, on the riser
- **5 bi-color LEDs, per SIGNAL (not per BNC):** Composite IN, Component IN, Composite OUT, Component OUT, **SYNC IN**. **SYNC LOOP = no LED.**
- The Y/Pb/Pr **component set shares ONE LED per direction** — the decoder locks on Y's sync; Pb/Pr have no independently-sensed status, so per-leg LEDs would show false state.
- **5 bi-color = 10 channels → ONE TLC59116** on the riser.
- **Crosses the mezzanine:** I²C SCL/SDA + LED supply + a **separate digital/LED ground** + optional `/RESET` (~5 pins), in a **ground-barriered corner** of the OUT header (or the 3rd control header). The **digital/LED ground joins analog ground only at the carrier star point** (no digital return through the analog ground on the riser).
- **SYNC IN LED is riser-local** (sync signals stay coax — the LED senses lock status delivered over the I²C block, not the sync net). Carrier bottom-row BNC LEDs stay on the **carrier** LED chain, unchanged.

## 5. Riser board (A4) — contents
- **10 board-mount BNCs:** 4 video IN + 4 video OUT (→ IN/OUT mezzanine headers) + SYNC IN + SYNC LOOP (→ coax pigtail to carrier U.FL, **not** mezzanine).
- **Panel-entry ESD on the 8 video BNCs** (low-cap video TVS <3 pF, TPD1E10B06-class). *(Sync ESD stays carrier-side.)*
- **TLC59116 + 5 bi-color LEDs** (§4) + the LED I²C/power block.
- **IN + OUT mezzanine sockets** (+ optional 3rd control header).
- 75 Ω term + AC-couple **stay on the carrier** at each PHY (unchanged) — riser carries BNC + ESD + LED only.
- New project `schindler-riser` (A4), own refdes namespace.

## 6. Riser mechanical
- Riser holds all 10 top-row BNCs.
- The **8 video BNCs** use the IN/OUT mezzanine headers — **tall stack (~18–22 mm)** to clear the carrier BNCs below.
- The **SYNC IN/LOOP region carries NO mezzanine connector** — just the 2 BNC mounts + the SYNC IN LED — so it can be **shallow / cut-back** and slip past the carrier BNCs below; sync exits by **coax pigtail to the carrier U.FL**.

## 7. Carrier changes (A1)
- **Remove:** J500–J503 (sheet 5 video-in BNCs), J600–J603 (sheet 6 video-out BNCs).
- **Keep (NO change):** J802/J803 (sheet 8 genlock U.FL), the genlock front-end, sheet 9 REF OUT, the 116 PL nets.
- **Add:** IN + OUT mezzanine headers (+ optional 3rd control header) — propose refdes in the 200-block or on sheets 5/6; nets are global so sheet placement is cosmetic.
- **Reroute:** 8 video nets from the IN/OUT headers to U500 / U600 inputs/outputs; LED I²C block to the carrier I²C + a PS/EMIO `/RESET` if used. Per-PHY conditioning stays.

## 8. PL pin-lock — CONFIRMED untouched
The 8 video nets are PHY-side analog I/O (connector → PHY), not FPGA PL nets. PHYs stay carrier-side; the 116 nets to J200/J201/J202 are unaffected. **No pin-lock change.**

## 9. BOM / refdes domain split
| Domain | Gets | Loses |
|--------|------|-------|
| **Riser (A4, new)** | 10 BNCs, 8× video panel ESD, TLC59116 + 5 bi-color LEDs, IN+OUT (+3rd) mezzanine sockets, riser passives | — |
| **Carrier (A1)** | 2 (or 3) mezzanine headers | J500–503, J600–603 (8 connectors) |
| **Chassis/panel** | panel + cutouts; **SYNC IN/LOOP coax pigtails STAND** (genlock unchanged) | — |

## 10. Staged execution sequence (AFTER approval)
1. Approve connector family (QTE/QSE vs SEARAY) + stack height + orientation; approve LED scheme.
2. Create `schindler-riser` (A4): 10 BNCs + 8× ESD + TLC59116/5 LEDs + IN/OUT(/3rd) sockets + sync coax landings. ERC standalone.
3. Carrier sheets 5/6: remove J500–503 / J600–603, route 8 video nets from the mezzanine headers to U500/U600; add LED I²C block. Re-ERC. **(Sheet 8 untouched.)**
4. Reconcile bom-v1 / refdes-map (3-domain split), update connector-domain.md status.
5. Hold for Justin's push.

## 11. Open items
- Connector family/stack/orientation (QTE/QSE vs SEARAY; ~18–22 mm; parallel vs R/A) — mechanical.
- 3rd control header vs LED-block-in-OUT-corner.
- LED `/RESET` source (PS-EMIO vs tie-off) + I²C address for the riser TLC59116 (vs the carrier LED driver chain).
- Final crosstalk validation at layout (component channels, 30 MHz).
- **Fallback (recorded, not chosen):** 10× MCX (75 Ω) on the carrier + panel BNC pigtails — no new board.
- Not in scope (ignore per Justin): 2× top-left SMA/MCX, white-square panel feature.

---
*Genlock-on-mezzanine (rev 1) was dropped: genlock stays coax, J802/J803 + sheet 8 stand. ESD-on-riser (video), term+AC-couple-on-carrier, riser refdes A4, PL pin-lock untouched, 3-domain BOM split, and the MCX fallback all carry forward from rev 1.*
