# Schindler 2.0 — Component Datasheet Index

**Status:** Compiled 2026-05-20
**Purpose:** One place for datasheet links to every active/decision-driving BOM component. Companion to [`bom-v1.md`](bom-v1.md) (the authoritative BOM) and [`pin-budget.md`](pin-budget.md).

**Source-quality legend:**
- **[mfr]** — authoritative manufacturer-direct PDF. Trust and download these.
- **[brief]** — manufacturer product brief only; full datasheet is NDA-gated or login-walled. Scope from this, pull the real doc through proper channels before committing footprint/pinout.
- **[dist]** — distributor product page; datasheet downloads from there (usually the manufacturer's own PDF).
- **[verify]** — third-party aggregator mirror. Fine for a quick read; confirm against the manufacturer before committing to the schematic.

> **Three parts cannot be cleanly sourced without a login/NDA:** GS3470, GS2962 (Semtech, free-account-gated) and LT8619C (Lontium, signed-agreement-gated). Treat aggregator copies of these as scoping-only. This matters most for the **LT8619C**, whose I²C slave address is still an open-verify item (see `pin-budget.md` § 4).

---

## Video signal path

**LT8619C** — HDMI in (Lontium)
- [brief] https://www.lontiumsemi.com/UploadFiles/2022-07/LT8619C_Brief_R1.3.pdf
- Full register datasheet: request from Lontium / distributor under signed agreement. **I²C address still to verify against the full register manual.**

**ADV7280** — analog in / SDTV decoder (ADI)
- [mfr] https://www.analog.com/media/en/technical-documentation/data-sheets/ADV7280.PDF

**ADV7393** — analog out / SD-HD video encoder (ADI)
- [mfr] https://www.analog.com/en/products/adv7393.html (Rev. K datasheet + app notes linked from product page)

**ADV7511** — HDMI out / HDMI 1.4 TX (ADI)
- [mfr] https://www.analog.com/en/products/adv7511.html (Programming Guide + Hardware User's Guide PDFs linked here)
- [verify] https://www.farnell.com/datasheets/1537341.pdf (quick alternate)

**GS3470** — SDI in [Pro] (Semtech)
- [brief] https://www.semtech.com/products/broadcast-video/receivers-deserializers/gs3470 (full datasheet behind free Semtech account login)

**GS2962** — SDI out [Pro] (Semtech)
- [brief] product page via semtech.com (full datasheet login-gated)
- [verify] https://www.verical.com/datasheet/semtech-international-video-processor-GS2962-IBE3-745411.pdf

---

## Sync / genlock

**LTC6912** — dual programmable-gain amp / reference front-end (ADI)
- [mfr] https://www.analog.com/media/en/technical-documentation/data-sheets/6912fa.pdf

**AD9204** — dual 10-bit 20MSPS ADC / genlock+LTC digitizer (ADI)
- [mfr] https://www.analog.com/en/products/ad9204.html (datasheet PDF linked from product page)

**Si5351A** — clock generator (Skyworks) — covers BOTH the genlock chip (B-variant, 0x60) and the RF chip (A 16-QFN, A0→0x61)
- [mfr] https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/data-sheets/Si5351-B.pdf
- **Read closely** — this is the document confirming the A0-pin address-select detail behind the Si5351 collision fix (`pin-budget.md` § 4, changelog 2026-05-20).

---

## Power & protection

**INA226** — current/power monitor, I²C (TI)
- [mfr] https://www.ti.com/product/INA226

**DMP3098L-7** — P-channel reverse-polarity FET (Diodes Inc)
- [mfr] https://www.diodes.com/assets/Datasheets/ds31447.pdf

**SMBJ12A** — 600W unidirectional TVS (Littelfuse)
- [dist] https://www.digikey.com/en/products/detail/littelfuse-inc/SMBJ12A/285970 (SMBJ-series family datasheet)

**MF-MSMF200-2** — PTC resettable polyfuse (Bourns)
- [dist] Bourns product page, MF-MSMF series datasheet (cleanest source)
- [verify] https://www.alldatasheet.com/datasheet-pdf/pdf/619154/BOURNS/MF-MSMF200-2.html

**TPD12S016PWR** — HDMI ESD + level-shift companion, ×2 (TI)
- [mfr] https://www.ti.com/lit/ds/symlink/tpd12s016.pdf (Rev. F, confirmed active 2026-05-20)

---

## RF subsystem [Pro]

**ADL5391** — DC–2.0 GHz analog multiplier / AM modulator (ADI)
- [mfr] https://www.analog.com/media/en/technical-documentation/data-sheets/adl5391.pdf

**AD835** — 250 MHz multiplier (modulator fallback) (ADI)
- [mfr] https://www.analog.com/en/products/ad835.html (media-PDF linked from product page)

**ERA-3SM+** — MMIC RF amp, DC–3 GHz 50Ω (Mini-Circuits)
- [mfr] https://www.minicircuits.com/pdfs/ERA-3SM+.pdf

**ADG419** — SPDT analog switch / mode-mux (ADI)
- [mfr] https://www.analog.com/media/en/technical-documentation/data-sheets/adg419.pdf

---

## LEDs / UX / control

**TLC59116F** — 16-ch FM+ I²C LED driver, ×3 [Pro] (TI)
- [mfr] https://www.ti.com/product/TLC59116F

**RP2040** — MCU, ×2 (genlock slow-control + front-panel UI) (Raspberry Pi)
- [mfr] https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf

**NHD-2.9-376960AF-ASXP** — front TFT display (Newhaven)
- [mfr] newhavendisplay.com — enter part number for per-part datasheet PDF

**NHD-1.5-240240AF-CSXP** — rear status LCD [Pro] (Newhaven)
- [mfr] newhavendisplay.com — enter part number for per-part datasheet PDF

**BT817Q** — EVE graphics controller (Bridgetek)
- [mfr] brtchip.com — part page hosts datasheet

**LWB5+ (Sterling-LWB5+)** — WiFi/BT module (Ezurio, formerly Laird Connectivity)
- [mfr] ezurio.com — datasheet + regulatory/integration guide (pull both; the integration guide matters for the antenna/RF layout)

---

## Not indexed here (pull by exact value at schematic time)

Generic passives (R/C/L), the LC-filter inductors (Coilcraft 0805CS-class), op-amps (OPA2350, LMH6643 — real ICs, grab if wanted), connectors (BNC, F, HDMI, RJ45, Molex Mini-Fit Jr., Samtec LSHM SOM connectors), and mechanical/chassis parts. These are either family-datasheet/value-selected at capture or not datasheet-driven decisions.

---

## Cross-references
- BOM (authoritative): [`bom-v1.md`](bom-v1.md)
- Pin budget + I²C: [`pin-budget.md`](pin-budget.md)
- Decision log: [`01-spec-changelog.md`](01-spec-changelog.md)
- Architecture SSOT: [`01-spec.md`](01-spec.md)
