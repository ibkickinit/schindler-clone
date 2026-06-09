# Schindler 2.0 — FPGA Pin & Clock Budget

**Status:** created 2026-06-05. Consolidates numbers previously scattered across `01-spec.md`,
`bom-v1.md`, `format-support-matrix.md`, and `wiki/PHASE-G-ANALOG.md`.
**Purpose:** answer "are we tight on pins?" definitively, and show how much budget each
interface-width decision spends. Two ceilings matter and they're independent: **PL I/O pins** and
**clock-management tiles (MMCM/PLL)**. The MMCM ceiling is the *tighter* of the two.

> **How to read this:** every video interface has a **narrow** form (8-bit BT.656 / multiplexed
> YCbCr) and a **wide** form (full parallel RGB). The budget is comfortable in all-narrow and
> *over* in all-wide — so the design is a set of narrow/wide choices, not a fixed number. Rows
> marked **🔓 open** are not yet locked and are where the budget is actually decided.

---

## 1. The ceiling

**Production carrier: Trenz TE0720-04 = 152 FPGA (PL) I/O**, via 2× Samtec LSHM-150 + 1× LSHM-130
Razor Beam connectors (`01-spec.md` §, `bom-v1.md`). DDR3L, eMMC, QSPI, and GbE PHY are on the SOM
and consume **PS/MIO** pins that do **not** count against the 152. (Caveat: the 152 are grouped into
voltage banks and a few are best reserved for clock-capable / diff-pair use, so treat ~152 as the
working number with ~5–10 pins of practical bank/placement slack.)

---

## 2. Per-interface pin tally

Pins are single-ended unless noted. "Embedded sync" = SAV/EAV codes in the data stream (no separate
HS/VS/DE wires).

| Interface | Narrow form | Narrow pins | Wide form | Wide pins | Status |
|---|---|---:|---|---:|---|
| **HDMI IN** (LT8619C → PL) | 16-bit YCbCr 4:2:2 + clk + sync | **~17** | 24-bit RGB888 + clk + HS/VS/DE | ~28 | 🔓 open |
| **HDMI OUT** | FPGA TMDS, 4 diff pairs | **~8** | external PHY (TFP410/IT6802) parallel RGB | ~28 | 🔓 open (PHY needed for 1080p60 on -1; -2 may do FPGA TMDS) |
| **ADV7393** analog out (PL → chip) | 8-bit BT.656 + clk | **~9** | 16-bit (≈17) / 30-bit RGB (≈33) | 17–33 | 🔓 open — `format-support-matrix.md` flags "switch to 4:2:2 if pin count is an issue" |
| **ADV7280** analog **in** (chip → PL) | 8-bit BT.656 + LLC clk (embedded sync) | **~9** | +HS/VS/FIELD broken out | ~12 | spec'd narrow in BOM (`BT.656 4:2:2`) |
| **SDI** (GS3470, broadcast SKU) | GTX serial (MGT pins, off-budget) | **0** | 20-bit parallel + clk | ~22 | 🔓 SKU-gated; off base SKU |
| **Sync / ref out** (BB / tri-level / LTC) | ride ADV7393 spare DAC channels | **0** | dedicated R2R DAC, 2–3× 8–10-bit | 16–30 | 🔓 open — biggest swing |
| **TFT LCD** | SPI (ILI9341 / ST7789) | **~6** | LTDC parallel RGB565/888 + sync | 20–28 | BOM says SPI proto → LTDC "production" 🔓 |
| **Front-panel controls** (D-pad ×5, buttons ×4, encoder) | I²C GPIO expander (MCP23017) | **0** (+I²C) | direct EMIO GPIO | ~12 | 🔓 open |
| **Status LEDs** (per-connector R/A/G) | TLC59116 I²C LED driver | **0** (+I²C) | direct PWM | ~16 | narrow locked (BOM lists driver) |
| **I²C buses** (×2: video / housekeeping) | shared | **4** | — | 4 | locked |
| **Housekeeping** (INA226 alert, fan PWM+tach, reset, misc) | — | **~6** | — | ~6 | locked |
| **UART debug** | — | **~2** | — | ~2 | locked |

### Totals

| Scenario | Pins | of 152 | Headroom |
|---|---:|---:|---|
| **All-narrow** (BT.656 video, SPI LCD, I²C controls/LEDs, sync on ADV7393 DACs) | **~61** | 40% | **~91 free** |
| **All-narrow + dedicated R2R sync** (sync not on ADV7393) | ~77–85 | ~53% | ~67–75 free |
| **Mixed-realistic** (16-bit HDMI-in, FPGA-TMDS out, BT.656 analog, SPI LCD, R2R sync, ADV7280 **in**) | **~89** | 59% | **~63 free** |
| **All-wide** (24-bit HDMI in, external PHY out, 16-bit ADV7393, LTDC LCD, R2R sync, SDI, direct controls/LEDs) | **~197** | **130%** | **−45 OVER** |

**Conclusion:** with disciplined narrow buses you sit around **60–90 / 152 — comfortable.** You only
go "tight" (the feeling you had) when you stack the wide options. You **cannot** have all-wide.

---

## 3. The ADV7280 (composite input) verdict

**It fits trivially. It is not where the pin pressure is.**
- **~9 pins** (8-bit BT.656 + LLC clock, embedded sync; I²C shared). +3 only if you break out
  HS/VS/FIELD instead of embedded sync.
- **~0 MMCMs** — the ADV7280 brings its own 28.6 MHz reference (its crystal) and emits the LLC
  clock; the PL receives BT.656 on a BUFG/BUFR and CDCs into the AXIS pixel domain. No clock-tile
  spend (see §4).
- Already in **BOM v1** (`ADV7280AWBCPZ-M-RL`, ~$19, ✅), already spec'd to the narrow interface.

Adding composite input costs ~9 of your ~63 free pins. The budget is decided by **the LCD bus, the
HDMI-out PHY choice, the ADV7393 width, and SDI** — not by analog input.

---

## 4. The *tighter* ceiling: clock-management tiles (MMCM/PLL)

The Zynq-7020 has **4 Clock Management Tiles** = **4 MMCM + 4 PLL**. This is the constraint that's
actually near its limit (`wiki/PHASE-G-ANALOG.md`, memory `zynq7020_mmcm_budget`).

| Clock consumer | Tile | Notes |
|---|---|---|
| `dvi2rgb` / HDMI-in pixel clock recovery | MMCM | input pixel domain |
| Output pixel `clk_wiz` | MMCM | drives VTC + rgb2dvi |
| Reference / system PLL | PLL | |
| `clk_wiz_adv7393` (27 MHz analog-out CLKIN) | MMCM | Phase-G; "load-bearing" |
| `clk_wiz_si5351` (Phase E2 sync) | MMCM | **puts the count at the 4-MMCM ceiling** |

**So with both analog-out and Si5351 active, you're at 4/4 MMCMs.** Mitigations already on record:
- A 5th clock must use **PLLE2_ADV** (not clk_wiz/MMCM). PLLE2_ADV needs ≥19 MHz input
  (memory `zynq7020_mmcm_budget`).
- Or **offload pixel generation to the external Si5351 clocks** (the dual-engine architecture) — this
  is the strategic reason Si5351 exists: it frees FPGA MMCMs by generating pixel/27 MHz externally.
- Or route 27 MHz from PS **FCLK_CLK1** (more jitter; acceptable for CVBS rate).

**ADV7280 impact on this ceiling: none** — it self-clocks (§3). So composite input does not worsen
the tight ceiling; the analog **output** + sync clocks are what crowd it.

---

## 5. What this means for decisions

**Locked-narrow (good — keep them):** ADV7280 in (BT.656), status LEDs (I²C driver), I²C controls
option.

**🔓 Open decisions, ranked by how much budget they spend:**
1. **TFT LCD bus** — SPI (~6) vs LTDC parallel (~20–28). **Biggest single swing.** Stay SPI unless a
   UI requirement forces LTDC.
2. **HDMI-out PHY** — FPGA TMDS (~8) vs external parallel PHY (~28). The 1080p60-on-Zybo-1 limit
   pushed toward an external PHY; on **-2 production silicon** FPGA TMDS may close timing and save
   ~20 pins. Decide per production-silicon bring-up.
3. **Sync/ref generation** — ride ADV7393 spare DACs (0 pins) vs dedicated R2R (~16–24). Confirm how
   many spare DAC channels the ADV7393 leaves after composite + component.
4. **ADV7393 bus width** — 8-bit BT.656 (9) vs 16-bit (17). Default to 8-bit per the format-matrix
   note.
5. **HDMI-in width** — 16-bit YCbCr (17) vs 24-bit RGB (28). 16-bit is the natural pin-saver.
6. **SDI** — only on the broadcast SKU; prefer GTX serial (off the 152) over parallel.

**Bottom line:** pins are **not** the binding constraint for adding composite input — the **MMCM
budget** is the one to watch, and the analog **output + sync** path (not input) is what spends it.
If you keep the LCD on SPI and one video path narrow, you have ~60 pins of headroom and the ADV7280
drops in unnoticed.

---

## Cross-references
- Carrier I/O figure: `01-spec.md`, `bom-v1.md` (TE0720-04, 152 I/O)
- Pin-saving precedent: `format-support-matrix.md` (ADV7393 → 4:2:2)
- MMCM ceiling: `wiki/PHASE-G-ANALOG.md`, memories `zynq7020_mmcm_budget`, `schindler_phase_g_clkwiz_zombie`
- Analog input hypothetical: `mvphd-gap-implementation.md` Appendix A
- ADV7393 header wiring (bench): `adv7393-breakout-header-pinout.md`
