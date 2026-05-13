# Schindler 2.0 — SKU Packaging Variants

**Status:** Draft 2026-05-13
**Scope:** packaging differences between Mini v1 and Pro v2 SKUs. Internal electronics architecture is shared — see [`01-spec.md`](01-spec.md).

This doc captures everything that differs between the two SKUs: chassis form factor, front-panel hardware, rear-panel I/O complement, carrier stuffing variant, BOM impact. The electronics architecture itself is one design, documented in `01-spec.md`.

---

## 1. SKU strategy

| | **Mini v1** | **Pro v2** |
|---|---|---|
| **Status** | First shipping SKU | Gated on Mini selling |
| **Positioning** | Lean entry — NTSC/film cadence, on-set CRT driver | Full broadcast — adds SDI, RF modulator, sync conversion, fuller UI |
| **Chassis** | Half-rack 1RU aluminum | Full-rack 1RU 19" aluminum |
| **Front-panel UI** | Mono OLED + tactile switches, driven by Zynq PS | NHD-2.9 color TFT + mezzanine board (RP2040 + BT817Q EVE) + dual encoders + LED column |
| **Rear status LCD** | None | NHD-1.5 240×240 SPI |
| **Per-connector status LEDs** | None | Tricolor R/A/G on every rear connector (TLC59116F drivers) |
| **Indicative retail** | $1,500–2,500 | $2,500+ |
| **Indicative parts cost** | ~$572 | ~$816 |

Both SKUs use the **same carrier PCB design** with different factory stuffing. HDL is identical (one bitstream powers both). PetaLinux control-plane firmware is shared. Mini's smaller front panel runs a simpler `schindler-ui` user-space app that talks to mono OLED + switches; Pro's mezzanine runs additional firmware on its dedicated RP2040 + BT817Q.

**Field upgrade Mini → Pro** is theoretically possible (factory retrofit of stuffing-variant silicon), but treat as a defer-until-Mini-ships question.

---

## 2. Carrier stuffing matrix

The carrier PCB has footprints for every subsystem. Stuffing varies per SKU at assembly.

| Subsystem | Mini | Pro |
|---|---|---|
| TE0720 SOM + Razor Beam sockets | ✅ | ✅ |
| HDMI in (LT8619C + TPD12S016) | ✅ | ✅ |
| HDMI out (ADV7511 + TPD12S016) | ✅ | ✅ |
| Composite + component input (ADV7280) | ✅ | ✅ |
| Composite + component output (ADV7393 + OPA2350 + LMH6643) | ✅ | ✅ |
| Genlock front-end (LTC6912 + AD9204 + RP2040 + Si5351) | ✅ | ✅ |
| WiFi module | ESP32-WROOM (cost-down) OR LWB5+ — *pending decision* | LWB5+ |
| Ethernet RJ45 magjack | ✅ | ✅ |
| USB-C | ✅ | ✅ |
| IEC inlet + LRS-50 PSU module (internal) | *pending decision* — internal OR external 12V brick | ✅ |
| Power protection chain (DMP3098L + polyfuse + TVS + INA226 + MLCC bulk) | ✅ | ✅ |
| SDI in (GS3470) | ❌ | ✅ |
| SDI out (GS2962) | ❌ | ✅ |
| RF modulator chain (ADL5391 + dedicated Si5351 + ERA-3 + bandpass + shield can) | ❌ | ✅ |
| Dual SYNC OUT driver chain (per-OUT DAC + 75 Ω cable driver) | ❌ | ✅ |
| Per-connector status LED drivers (3× TLC59116F) | ❌ | ✅ |
| Rear LCD driver wiring (Zynq PS dedicated SPI port + 3.0 V backlight LDO) | ❌ | ✅ |
| Expansion header (40-pin 2.54 mm) | ✅ | ✅ |
| JTAG + UART debug headers | ✅ | ✅ |

**Differential BOM (Pro stuffing adds vs Mini stuffing):**

| Subsystem | BOM |
|---|---|
| SDI in + out (GS3470 + GS2962 + 2× BNCs + passives) | ~$36 |
| RF modulator chain | ~$32 |
| Dual SYNC OUT driver chain (2× DAC + 2× driver + 2× BNC + passives) | ~$22 |
| Per-connector LED drivers (3× TLC59116F + ~21 LEDs) | ~$9 |
| Rear LCD module (NHD-1.5) + LDO | ~$15 |
| Pro front-panel mezzanine (NHD-2.9 + BT817Q + mezzanine RP2040 + encoders + buttons + LEDs + boost reg + PCB) | ~$150 |
| **Pro stuffing premium** | **~$264** |

---

## 3. Mini chassis + front panel

### 3.1 Mini chassis

- **Form factor:** half-rack 1RU aluminum
- **Dimensions:** ~217 mm wide × 44 mm tall × ~250 mm deep
- **Material:** anodized aluminum extruded body, milled aluminum front + rear panels
- **Vendor:** TBD (likely Chinese OEM aluminum chassis at qty-100; see chassis-vendor discussion in earlier project notes)
- **Power:** *pending decision* — internal LRS-50-12 + IEC inlet (matches Pro) OR external 12 V brick + DC barrel jack

### 3.2 Mini front panel

| Component | Notes |
|---|---|
| Power button | Lighted soft pushbutton |
| **Mono OLED display** | 1.3" mono OLED, I²C (SH1106 or SSD1306 driver), ~$7 |
| **5-way navigation switch** | D-pad + center enter, GPIO via EMIO to Zynq PS |
| **4× tactile preset buttons** | P1 / P2 / P3 / P4, GPIO via EMIO to Zynq PS |
| **Tri-color status LED** | Green = locked/ready, Amber = input issue, Red = sync loss/error |
| **microSD card slot** | Push-push panel-mount, front-accessible |

**No dedicated UI MCU on Mini.** All Mini front-panel I/O wires back to Zynq PS via I²C (OLED) and GPIO (buttons, LED). PetaLinux user-space app `schindler-ui` handles event detection, menu state, preset save/recall (to filesystem), LED color/blink patterns.

### 3.3 Mini rear panel

| Connector | Qty | Notes |
|---|---|---|
| HDMI Type A | 2 | IN + OUT |
| BNC 75 Ω | 6 | 1× CVBS IN + 1× CVBS OUT + 3× component (YPbPr) OUT + 1× genlock REF IN |
| Mini-DIN 4-pin | 0 or 1 | S-Video silicon-capable; connector pending decision |
| RJ45 magjack | 1 | GbE |
| USB-C | 1 | Service / firmware update |
| Power | 1 | DC barrel jack (external brick) OR IEC C14 (internal PSU) — pending |
| RP-SMA WiFi | 0 or 2 | Internal chip antenna or external |

**Rear panel total ~215 mm wide** — fits half-rack budget with margin.

### 3.4 Mini BOM rollup

| Category | Cost |
|---|---|
| Active silicon (carrier) | ~$361 (no SDI / no RF / no SYNC OUT amp / no LED drivers / no rear-LCD circuitry) |
| Samtec mating connectors | $30 |
| Rear-panel connectors | ~$30 |
| Front-panel components (OLED + 9 switches + LED + microSD + harness) | ~$15 |
| Headers (JTAG, UART, expansion) | $7 |
| 4-layer carrier PCB (50-unit qty) | $25 |
| Misc passives | $30 |
| **Carrier subtotal** | **~$498** |
| Half-rack chassis | $40–60 |
| Power (external brick OR internal PSU + IEC inlet) | $15 OR ~$33 |
| Mounting hardware | $10 |
| Misc | $5 |
| **Mini per-unit total** | **~$580** |

Mini retail target $1,500–2,500 → 23–38 % BOM-to-retail ratio. Healthy.

---

## 4. Pro chassis + front panel

### 4.1 Pro chassis

- **Form factor:** full-rack 1RU 19" aluminum
- **Dimensions:** ~482 mm wide × 44 mm tall × ~250 mm deep
- **Material:** anodized aluminum
- **Rear panel:** populated with full Pro I/O complement (see § 4.3)
- **Internal layout:** carrier PCB + Mini PCB (same board) + Pro front-panel mezzanine PCB + internal Mean Well LRS-50-12 PSU

### 4.2 Pro front panel

Mezzanine board mounted behind the front-panel aluminum, connected to main carrier via UART + power cable.

| Component | Part | Notes |
|---|---|---|
| Power button | Lighted soft pushbutton | |
| microSD card slot | Push-push | Front-accessible |
| **Front TFT** | Newhaven **NHD-2.9-376960AF-ASXP** | 2.9" 376×960 IPS landscape (960×376), ST7701SN driver, 24-bit parallel RGB, ~$30–45 |
| **Graphics controller** | BridgeTek **BT817Q EVE 4** | Holds frame in 1 MB RAM_G, renders from command lists, ~$10–13 |
| **Mezzanine UI MCU** | RP2040 (dedicated, separate from genlock RP2040) + QSPI boot flash + 12 MHz crystal | ~$3 |
| **Rotary encoders** | 2× ALPS EC11E18244AU | 36 detents / 18 PPR, push-switch, **knob shroud / guard mandatory** |
| **Fixed buttons** | 4× tactile | Home / Back / Menu / Confirm |
| **Quick-select buttons** | 2–3× tactile | Defaults: BLACK / MONO / Proc Amp bypass; user-rebindable |
| **Front status LED column** | ~6 tricolor LEDs | Mirrors rear per-connector LED state |
| Backlight boost regulator | TI TPS61040 class | 6.0 V boost for NHD-2.9 backlight (~$0.50) |

**Mezzanine ↔ main carrier link:** UART + power only. No high-speed buses cross the connector.

### 4.3 Pro rear panel

| Connector | Qty | Notes |
|---|---|---|
| IEC C14 (FN9260B-6-06) | 1 | Mains + integrated fuse + EMI filter |
| HDMI Type A | 2 | IN + OUT |
| BNC 75 Ω (analog video) | 8 | 1× CVBS IN + 1× CVBS OUT + 3× component IN + 3× component OUT |
| BNC 75 Ω (sync) | 4 | REF IN + REF LOOP + SYNC OUT 1 + SYNC OUT 2 |
| BNC 75 Ω (SDI) | 2 | SDI IN + SDI OUT |
| F-connector | 1 | RF modulator output |
| Mini-DIN 4-pin | 0 or 1 | S-Video pending |
| RJ45 magjack | 1 | GbE |
| USB-C | 1 | Service / firmware update |
| RP-SMA WiFi | 2 | Dual antennas for AP+STA |
| **Rear status LCD (NHD-1.5)** | 1 | Recessed bezel cutout |

**Rear panel total ~253 mm width** of available 432 mm. ~179 mm of unused panel slack for future I/O.

### 4.4 Pro BOM rollup

| Category | Cost |
|---|---|
| Active silicon (carrier, full stuffing) | ~$361 + Pro silicon premium ~$110 (SDI + RF + SYNC drivers + LED drivers + rear LCD circuitry, not counting mezzanine) = ~$471 |
| Samtec mating connectors | $30 |
| Rear-panel connectors (full Pro complement) | ~$55 |
| Front-panel mezzanine PCB + components | ~$150 |
| Front status LED + harness | ~$5 |
| Headers (JTAG, UART, expansion) | $7 |
| 4-layer carrier PCB | $25 |
| Misc passives | $30 |
| **Carrier + mezzanine subtotal** | **~$773** |
| Full-rack 1RU chassis | $50–80 |
| Internal LRS-50-12 + IEC inlet | $33 |
| Mounting hardware | $10 |
| Misc | $5 |
| **Pro per-unit total** | **~$885** |

Pro retail target $2,500+ → ~35 % BOM-to-retail ratio. Healthy.

---

## 5. Open packaging decisions

- **Mini WiFi:** LWB5+ (~$30, matches Pro, dual-band + BT) vs ESP32-WROOM (~$5, 2.4 GHz only). Default: same-as-Pro for assembly simplicity unless Mini cost-down is critical.
- **Mini PSU:** internal LRS-50-12 + IEC (matches Pro, same carrier wiring, ~$33) vs external 12 V brick + DC jack on carrier (cheaper, looser positioning, ~$15 + brick).
- **Mini S-Video out connector:** include mini-DIN or not. Silicon already supports.
- **Mini WiFi antenna:** internal chip antenna or external RP-SMA stubs.
- **Pro field-upgrade path:** support Mini → Pro factory retrofit kits as a product line, or treat SKUs as one-way commitments at purchase. Defer until Mini ships.

---

## 6. Cross-references

- Internal electronics architecture: [`01-spec.md`](01-spec.md)
- Bill of materials (silicon-level): [`bom-v1.md`](bom-v1.md)
- Active dev arc + deferred work: [`dev-roadmap.md`](dev-roadmap.md)
- Front + rear panel layout (both SKUs): [`panel-layout.md`](panel-layout.md)
- Signal flow + per-SKU control plane variants: [`signal-flow.md`](signal-flow.md)
- UI menu hierarchy (Pro detailed; Mini deferred): [`ui-menu.md`](ui-menu.md)
- RF modulator subsystem detail: [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md)
