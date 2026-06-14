# Schindler 2.0 — FPGA Pin & Clock Budget

**Status:** created 2026-06-05; **reconciled to the locked carrier architecture 2026-06-11.**
**Authoritative pin map:** [`sheet3-te0720-som-backbone.md`](sheet3-te0720-som-backbone.md) §5–6 is the source of truth for the live per-bank PL assignment (119/152). This doc is retained as the *rationale* layer — how each PHY/interface-width choice spends budget, plus the MMCM analysis — kept consistent with the backbone rather than as a competing count.
**Purpose:** answer "are we tight on pins?" definitively. Two independent ceilings matter: **PL I/O pins** and **clock-management tiles (MMCM/PLL)**. After the all-external-PHY architecture was locked, **pins land at 119/152 (comfortable) and the MMCM ceiling — once the tighter of the two — is no longer tight.**

---

## 1. The ceiling

**Production carrier: Trenz TE0720-04 = 152 FPGA (PL) I/O**, via 2× Samtec LSHM-150 + 1× LSHM-130
Razor Beam connectors (`01-spec.md`, `bom-v1.md`). DDR3L, eMMC, QSPI, and GbE PHY are on the SOM
and consume **PS/MIO** pins that do **not** count against the 152. (Caveat: the 152 are grouped into
voltage banks and a few are best reserved for clock-capable / diff-pair use, so treat ~152 as the
working number with ~5–10 pins of practical bank/placement slack.)

---

## 2. Per-interface pin tally — locked

Every video/sync/genlock fast bus is **parallel** between the FPGA and an external PHY/converter; every
high-speed serial lane (HDMI TMDS, 3G-SDI, ADC/DAC sample) lives in the external chip, not in FPGA
fabric. Pins are single-ended unless noted. "Embedded sync" = SAV/EAV in-stream (no separate HS/VS/DE).

| Interface | Direction | PHY / converter | PL pins | Bank |
|---|---|---|---:|---|
| **HDMI IN** | chip→PL | LT8619C — HDMI RX → 16-bit YCbCr 4:2:2 + clk + sync | **20** | B35 |
| **ADV7280 analog IN** | chip→PL | ADV7280 — 8-bit BT.656 + LLC, embedded sync | **9** | B35 |
| **HDMI OUT** | PL→chip | ADV7511 — 16-bit YCbCr + clk + HS/VS/DE | **20** | B13 |
| **Analog OUT** | PL→chip | ADV7393 — 16-bit component + clk + sync/control | **20** | B13 |
| **SDI IN** *(Pro)* | chip→PL | GS3470 — deserializes to parallel (FPGA side parallel, not GTX) | **11** | B34 |
| **SDI OUT** *(Pro)* | PL→chip | GS2962 — parallel in, serializes in-chip | **11** | B34 |
| **SYNC OUT 1** | PL→chip | AD9742 — 12-bit DAC (data + clk) | **13** | **B35** |
| **SYNC OUT 2** | PL→buf | 1-bit FPGA biphase → slew-limited op-amp (LTC only) | **1** | B33 |
| **Genlock ADC** | chip→PL | AD9204 — dual-10-bit, interleaved capture + DCO | **11** | B33 |
| **LTC6912 PGA** | PL→chip | SPI to genlock front-end PGA | **3** | B33 |

### Totals (matches backbone §5)

| Bank | Used | Available |
|---|---:|---:|
| B35 (JM1, input + SYNC-1 DAC) | **42** | 48 |
| B13 (JM2, output) | 40 | 50 |
| B34 (JM3, Pro SDI, 1.8 V) | **22** | 36 |
| B33 (JM2, genlock + sync 2) | 15 | 18 |
| **Total PL** | **119** | **152** |

**78% of PL, ~33 free.** Mini SKU drops B34 entirely (no Pro silicon) and doesn't populate the B35 SYNC-1 DAC → ~84/152. **Update 2026-06-13e (B34 = 1.8 V SDI re-strap, Option A):** the SYNC-1 DAC (AD9742, 3.3 V-only) moved B34→B35, so **B34 relaxes to 22/36** and **B35 rises to 42/48** (the 24-bit-HDMI-in reserve is spent). B35 is now the fullest bank; none is tight.

Control-plane, housekeeping, and status I/O ride **PS MIO/EMIO + I²C**, largely off the 152 PL: the
front panel is now an RP2040 + BT817Q mezzanine (off FPGA pins entirely), the rear status LCD hangs off
the PS, and per-connector LEDs use an I²C driver. The PL count above is the video/sync/genlock fast-bus total.

---

## 3. The ADV7280 (composite input) verdict

**It fits trivially. It is not where the pin pressure is.**
- **~9 pins** (8-bit BT.656 + LLC clock, embedded sync; I²C shared). +3 only if you break out
  HS/VS/FIELD instead of embedded sync.
- **~0 MMCMs** — the ADV7280 brings its own 28.6 MHz reference (its crystal) and emits the LLC
  clock; the PL receives BT.656 on a BUFG/BUFR and CDCs into the AXIS pixel domain. No clock-tile
  spend (see §4).
- Already in **BOM v1** (`ADV7280AWBCPZ-M-RL`, ~$19, ✅), locked to the narrow interface.

It sits in bank B35 next to HDMI-in (**now 42/48** after the SYNC-1 DAC moved in — see §2). Composite input is not where budget is spent.

---

## 4. Clock-management tiles — no longer the tight ceiling

The Zynq-7020 has **4 CMTs = 4 MMCM + 4 PLL.** Under the old FPGA-TMDS-out plan this was the binding
constraint. The locked all-external-PHY architecture **relieved it**: because every serializer/
deserializer is in an external chip (ADV7511, GS2962, GS3470, LT8619C) and every ADC/DAC self-clocks,
the FPGA only ever synthesizes or captures **parallel-rate clocks (≤148.5 MHz)** — no fabric SerDes clocking.

**Inputs cost zero MMCM** — each arrives with a recovered clock from its external chip, captured on a
BUFR/BUFIO/BUFG: HDMI-in pixel clock (LT8619C), SDI-in recovered clock (GS3470), ADV7280 LLC, AD9204 DCO.

**Synthesized clocks (the only MMCM consumers):**

| Clock | Tile | Notes |
|---|---|---|
| HDMI-out + SDI-out **shared** pixel clock | MMCM #1 | one clock → ADV7511 + GS2962 word clock + VTC; both carry the same master image at the same rate |
| Analog-out 27 MHz (`clk_wiz_adv7393`) | MMCM #2 | ADV7393 CLKIN |
| Genlock/sync reference | PLL #1 | loop NCO domain + AD9742 sample clock |
| HDMI-in capture deskew | MMCM #3 | optional — collapses to a plain BUFR if a 5th synth clock is ever needed |

**That's 2–3 MMCM + 1 PLL of 4 + 4 — comfortable.** Two documented reserves free a tile on demand:
(a) drop HDMI-in to BUFR capture, (b) offload the 27 MHz to the external Si5351 (its strategic purpose).
The four PLLs are otherwise unused and absorb any 5th clock via PLLE2_ADV (≥19 MHz input).

**Decision (2026-06-11):** keep the conservative map above; hold both reserves + PLL overflow; do not
pre-optimize. Si5351 stays as FPGA master source + reserve for ever running HDMI/SDI at independent rates.

---

## 5. Decisions — now locked

The interface-width / PHY choices this budget used to leave open are resolved:

1. **HDMI-out PHY** → dedicated **ADV7511** (LQFP-100), 20 PL. External PHY does the TMDS serialization,
   keeping fabric clean. (Not FPGA-TMDS.)
2. **Sync generation** → dedicated **AD9742** 12-bit DAC (SYNC 1, 13 PL, **in B35** — moved from B34 2026-06-13e since the AD9742 is 3.3 V-only and B34 went 1.8 V for SDI) + 1-bit LTC biphase (SYNC 2, 1 PL, B33).
   (Not riding ADV7393 spare DACs.)
3. **ADV7393 width** → **16-bit** component, 20 PL.
4. **HDMI-in width** → **16-bit** YCbCr 4:2:2, 20 PL.
5. **SDI** → **GS3470 / GS2962 parallel** (11 + 11 PL), Pro SKU only. FPGA side parallel, not GTX serial —
   this is the bulk of the rise from the old ~89 estimate to 119.
6. **Front-panel LCD** → off the FPGA entirely (RP2040 + BT817Q EVE mezzanine driving NHD-2.9).
   **Rear status LCD** → PS-driven NHD-1.5; SPI-vs-parallel interface pending the control-plane dive.

**Bottom line:** pins land at **119/152 (comfortable; no tight bank after the 2026-06-13e B34→B35 sync-DAC move — B35 fullest at 42/48)** and the **MMCM ceiling is
no longer the constraint** — the external-PHY architecture chosen for HDCP, timing closure, and output
independence also minimized FPGA clock-management load.

---

## Cross-references
- **Authoritative PL pin map:** `sheet3-te0720-som-backbone.md` §5–6
- Carrier I/O figure: `01-spec.md`, `bom-v1.md` (TE0720-04, 152 I/O)
- MMCM ceiling history: `wiki/PHASE-G-ANALOG.md`, memories `zynq7020_mmcm_budget`, `schindler_phase_g_clkwiz_zombie`
- ADV7393 header wiring (bench): `adv7393-breakout-header-pinout.md`
