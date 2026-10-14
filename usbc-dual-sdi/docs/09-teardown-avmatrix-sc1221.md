# 09 — Teardown: AVMATRIX SC1221-12G (HDMI 2.0 → 12G-SDI)

> **Status: reference teardown, banked 2026-10-13.** Chip IDs are from Justin's
> board photos (markings legible); block *roles* are inferred from layout and
> are **not** verified against schematics or datasheets. Top side only — the
> underside has not been photographed.

## The product

- **AVMATRIX SC1221-12G** — HDMI 2.0 → 12G-SDI 4K60 mini converter.
- I/O: **HDMI 2.0 IN** + **HDMI 2.0 LOOPOUT** (one end); **USB-C POWER** +
  **2× 12G-SDI OUT** (other end). Status LED light-pipes at both ends.
- **USB-C is power only (5 V)** — no DP Alt Mode; video enters on HDMI only.
- The two SDI outs are **copies of the one HDMI input**, not independent channels.
- SDI out: HD / 3G / 6G / 12G, YCbCr 4:2:2 10-bit, up to 2160p60.
- Street price **~€199 ex-VAT to ~$337** (2026 listings). 3-yr warranty.
- Board silkscreen: **`SC1221-12G-V1.5  2024-12-10`**.

## Bill of materials (top side)

| Ref | Part | Role (inferred) |
|---|---|---|
| U14 | **GSCoolink GSV2011** (BGA, ~10×10 mm) | HDMI 2.0 RX + loop-out TX; parallel video bus to FPGA (long series-resistor arrays around it). HDMI-2.0 sibling of the GSV1011. **No public datasheet found** — Chinese vendor, likely NDA/direct sales. |
| U8 | **Xilinx/AMD Artix UltraScale+** (small lidless chip-scale pkg) | SDI framing + 12G serializer via on-chip GTH transceivers. Exact part hidden by label; package size suggests the **11×11 mm UBVA368** (AU10P/AU15P) — *unverified*. |
| U20 | **Skyworks Si5392B-A-GM** | Low-jitter clock / jitter attenuator for the GTH reference (SDI line rates). |
| U13 | **ST STM32F103CBT6** (LQFP-48) | Control MCU: EDID, config, status; UART header J2 (GND/TX/RX). |
| U9 | **Macronix MX25U-series** SPI NOR (8-pin) | FPGA configuration flash (1.8 V family). |
| U12 | Small QFN marked **"6731 / 2230 / 528C"** — *unidentified* | Between the two BNCs: likely SDI cable driver or 1→2 fan-out buffer. |
| Y1 | 27.000 MHz crystal | Video reference clock. |
| Y2/Y3 | crystal + oscillator near FPGA | FPGA / clock references. |
| U2–U7, U16 + 4R7 inductors | Small SOT-23-5 bucks ("KVG1A" marking) | Rails from USB-C 5 V. |
| JP2 | 6-pin header | Likely FPGA JTAG. |
| CON1 | 2-pin header | Unknown (aux power / fan / LED). |

**Not present (top side):** no DDR → almost certainly **no frame buffer**;
conversion is source-locked, same philosophy as Crossover v1 (`02` Clocking).

## What it means for Crossover

1. **Architecture validated.** External HDMI 2.0 RX chip → small FPGA with
   multi-gigabit transceivers → jitter cleaner → (driver) → BNC, MCU on the side
   is the commodity recipe. The external-RX approach is exactly the fix for
   PolarFire's 4K30 HDMI-RX cap noted in `08` Option B.
2. **⚠️ Cost pressure.** Our plan-of-record FPGA (**MPF200T, $286 qty-1**, `04`)
   costs more than this entire retail product. AVMATRIX gets there with a small
   Artix US+ (DigiKey qty-1: AU10P ~€108–152, AU15P ~$182), volume pricing, and
   probably in-house or licensed SDI IP. → **New open question Q12** (`06`).
3. **The "DIY" competitor is now concrete.** `01` lists "USB-C MST hub + 2×
   HDMI→SDI" at ~$380–450. With this unit it's ~$40 MST adapter + 2× SC1221-12G ≈
   **$440–700**, shipping today, Windows-only, no unified EDID/format control.
   Crossover's $600–900 target must beat that on *integration* (one box,
   presents-as-displays, Mac via USB4, frame-rate control), not on SDI quality.
4. **Player variant demo (`08`).** MeLE Quieter 4C (2× HDMI 2.0) + 2× SC1221-12G
   = working player with **two independent 12G-SDI outs** today, zero dev.
5. **Bench reference.** A known-good 12G-SDI source for the analyzer, to
   compare against our PolarFire bench output (`05` Phase 2).
6. **Clocking choice.** A shipping product uses **Si5392** for the transceiver
   reference — add as a candidate next to Si534x in `04`.
7. **Form factor.** Micro-converter size (`01` target) is achievable with RX
   chip + FPGA + clock + regulators. Crossover's harder constraint is **power**
   (~6–10 W, PD ≥18 W, aux port) → thermal, not board area.

## Follow-ups

- [ ] Photograph the **board underside** (DDR? second driver? more regulators?).
- [ ] Close-up of **U12** to identify the SDI driver / fan-out.
- [ ] Read the **FPGA part number** (package edge, or JTAG via JP2).
- [ ] Measure **USB-C current draw** at 2160p60 → real power data point for an
      FPGA 12G converter (vs our ~6–10 W estimate).
- [ ] Request **GSV2011 datasheet** + EVB from GSCoolink sales.
- [ ] Cost comparison — see `06` Q12.

## Sources

- [Markertek — SC1221-12G](https://markertek.com/product/avmx-sc1221-12g/avmatrix-sc1221-12g-hdmi-2-0-to-12g-sdi-4k60-broadcast-converter)
- [AVMATRIX SC1221-12G user manual (240906)](https://syntex.cz/media/document/37488/avmatrix-sc1221-12g-user-manual-240906.pdf)
- [Syntex — SC1221-12G](https://syntex.tv/avmatrix-sc1221-12g-hdmi-2-0-to-12g-sdi-4k-converter)
- [B&H — SC1221-12G](https://www.bhphotovideo.com/c/product/1858634-REG/avmatrix_sc1221_12g_hdmi2_0_to_12g_sdi_4k.html)
- [Newegg listing](https://www.newegg.com/p/3C6-01SG-00096)
- [CSDN — GSV2011 positioning vs GSV1011](https://damodev.csdn.net/6a4365a6662f9a54cb868968.html)
- [DigiKey — XCAU15P-1FFVB676E](https://www.digikey.com/en/products/detail/amd/XCAU15P-1FFVB676E/16720162)
- [DigiKey — XCAU10P-1SBVB484I](https://www.digikey.be/en/products/detail/amd/XCAU10P-1SBVB484I/16720068)
- [AMD — SMPTE UHD-SDI IP (PG205)](https://docs.amd.com/r/en-US/pg205-v-smpte-uhdsdi)

---

## Addendum (2026-10-14): AVMATRIX **Mini SC1221** — HDMI → 3G-SDI (the non-12G sibling)

Board silkscreen **`Mini_SC1221 Ver1.8 20231111`**. Top side, from Justin's photos.

| Ref | Part | Role (inferred) |
|---|---|---|
| U3 | **Analog Devices ADV7611BSWZ** (LQFP-64) | HDMI 1.4 RX → parallel video (≤1080p60). Has HDCP keys. **NRND/EOL-track** (Schindler ruled it out on that basis) |
| U6 | **Gennum/Semtech GS2972** | **3G/HD/SD-SDI serializer with integrated cable driver** — takes parallel video and does TRS/LN/CRC/ST 352/scrambling itself |
| U1 | **ST STM32F042F6P6** (TSSOP-20) | Control MCU (configures ADV7611 + GS2972 over I²C/SPI); JP1 = programming header |
| Y3 | 27.000 MHz crystal | Video reference |
| U8 | APL5934D | LDO; plus a small buck (4R7) from USB-C 5 V |
| BNC1/2 | 2× SDI OUT | Likely driven from the GS2972's **SDO and SDO-bar** (complementary outputs — NRZI is polarity-insensitive, so both are valid SDI). *Verify* |

**No FPGA, no HDMI loop-out, no clock cleaner.** It's the "fixed-function, chip-to-chip" architecture
(HDMI RX chip → SDI serializer chip) that Crossover originally planned around the GS12170 — viable at
3G because single-chip 3G serializers still exist.

**What it tells us**
1. **The FPGA is what 12G costs.** Same brand: the 3G unit is two chips + an MCU; the 12G unit needs
   an Artix US+ + Si5392 because there's no current single-chip 12G serializer we know of (GS12170 EOL —
   `06` Q0). Confirms our architecture for v1's 12G requirement.
2. **Reference for our own framer.** The **GS2972 datasheet is public** (Semtech) and documents how it
   inserts TRS, line numbers, CRC and the ST 352 packet — use it to cross-check our CRC bit order and
   line-number convention (`12` "still to confirm") before the analyzer session.
3. **Bench:** a second known-good source — the right reference for our **HD and 3G-A stages** (1–2),
   while the 12G SC1221 covers 6G/12G.
4. **Cheap dual-output trick:** complementary serializer outputs give two BNCs for free. Not needed for
   v1 (each channel is independent), but worth remembering for a loop/second copy.

**Follow-ups:** confirm the BNC2 drive (SDO-bar?) with a meter/scope; pull the GS2972 datasheet and
compare its framing description with `hdl/sdi_tx/`.
