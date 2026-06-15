# Schindler 2.0 — Panel Layout

**Status:** Draft 2026-05-13
**SKU scope:** this doc describes the **Pro v2** panel layout (full-rack 1RU 19" × 44 mm, full I/O complement, full mezzanine front panel). **Mini v1** has its own panel layout (half-rack 1RU, smaller I/O complement, mono OLED + tactile buttons front panel) — documented in [`packaging-skus.md`](packaging-skus.md).

This doc holds the spatial arrangement. The connector inventory and electrical spec live in [`01-spec.md`](01-spec.md); the menu hierarchy displayed on the front TFT lives in [`ui-menu.md`](ui-menu.md); SKU packaging variants in [`packaging-skus.md`](packaging-skus.md).

---

## Organising principles

> **Revised 2026-06-13** — backplane order reworked, the old "sync follows IN/OUT direction" rule retired (see #2), and the sync zone relabeled **SYNC** (was REF). The ASCII sketch below was **redrawn 2026-06-13** to match this order + the backplane render. *(Naming note: `01-spec.md` §3.7 + refdes-map + BOM still carry the genlock inputs as `REF IN` / `REF LOOP`; the panel/silkscreen uses SYNC throughout — propagate to those docs on request.)*

1. **Left-to-right backplane order:** `PWR → WiFi / Net / USB → Display (LCD) → INPUTS → OUTPUTS → SYNC (all 4 sync BNCs) → RF (far-right, isolated)`. Signal flow still runs input-before-output; the change is that the sync BNCs are now a single grouped zone to the right of the outputs rather than split by direction.
2. **SYNC is one grouped zone, not split by direction (replaces the old rule).** The prior principle — "sync IN lives in the input section, SYNC OUT in the output section" — is **retired**. All four sync BNCs (SYNC IN, SYNC LOOP, SYNC OUT 1, SYNC OUT 2) now sit together in a dedicated SYNC zone between OUTPUTS and RF. Rationale: keeps the genlock front-end interconnect short and grouped, and isolates it from the RF connector.
3. **Analog-top / digital-bottom row rule (two-row BNC stacks).** **Row 2 (top) = analog** (composite + component, in & out); **Row 1 (bottom) = digital** (SDI + HDMI). The top analog rows are the SI-tolerant lines that ride the **riser** sub-board; the bottom digital rows stay carrier-rooted. Within the SYNC zone: SYNC IN/LOOP on the top row, both SYNC OUT on the bottom row. (SYNC IN/LOOP reach the carrier front-end by Option-A pigtail → u.FL regardless of which board the BNC mounts on — see `01-spec.md` §3.7.)
4. **Power + control cluster on the far left.** AC mains entry, USB service, network, wireless antennas — grouped at the corner farthest from the analog signal path.
5. **Rear status LCD left-of-inputs.** Moved from centre (old sketch) to sit just right of the PWR/Net/USB cluster, ahead of the INPUTS zone, per the new order. Read-only status display for at-rack patching from behind.
6. **Per-connector LED next to each connector.** R/A/G status, ~10 % default brightness, drives off the same I/O state the rear LCD reads. **Part (banked 2026-06-13c): Lumex SSF-LXH409SISUGW** — one-piece 3 mm **right-angle** bi-color CBI (common-anode), emits parallel to the board so it faces the rear panel with no holder or light pipe. Sits low at the carrier's rear edge, dome at panel-hole height, beside each connector at ~BNC-center height. Balance R/G in TLC59116 PWM (red 350 mcd is brighter than green 130 mcd at equal current).
7. **RF + spare on the far right.** The RF daughter-board F-connector occupies the isolated far-right edge; any remaining spare panel width (V1.x expansion: XLR LTC return, 10 MHz reference, future I/O) sits adjacent.

---

## Connector inventory (post-2026-05-11 decisions)

| Section | Connector | Qty | Notes |
|---|---|---|---|
| Power + control | IEC C14 | 1 | AC mains in |
| Power + control | USB-C | 1 | Service / firmware / debug |
| Power + control | RJ45 | 1 | GbE on TE0720 PHY |
| Power + control | SMA | 2 | RP-SMA WiFi antennas |
| Video IN | HDMI | 1 | Via LT8619C HDMI RX |
| Video IN | BNC SDI | 2 | IN + IN LOOP (reclocked loop-through), via Semtech GS3470 |
| Video IN | BNC composite | 1 | CVBS, ADV7280 decoder |
| Video IN | BNC component | 3 | Y / Pb / Pr, ADV7280 decoder |
| Sync IN | BNC | 2 | SYNC IN + SYNC LOOP (passive loop-through; genlock reference input). **Option A interconnect:** panel BNC → 75 Ω pigtail → U.FL-R-SMT-1 on carrier (no riser hop on phase-critical sync). |
| Status | **Newhaven NHD-1.5-240240AF-CSXP** LCD | 1 | 1.5" 240×240 IPS square, ST7789VI, 8-bit 8080-II parallel OR 3/4-wire SPI. Module outline 32.52 × 35.32 mm; active-area cutout **~28 × 28 mm**; recessed pocket ~33 × 36 × ~3 mm. Rear-only, read-only, paginated summary view. |
| Sync OUT | BNC | 2 | SYNC OUT 1 + SYNC OUT 2, format-selectable |
| Video OUT | BNC component | 3 | Y / Pb / Pr, ADV7393 DAC |
| Video OUT | BNC composite | 1 | CVBS, ADV7393 DAC |
| Video OUT | BNC SDI | 2 | OUT + **OUT MIRROR** (GS2962 C10/D10, buffered duplicate), broadcast tier — populated/unpopulated per SKU |
| Video OUT | HDMI | 1 | Direct FPGA TX |

**Totals:** 1× IEC, 1× USB-C, 1× RJ45, 2× SMA, 2× HDMI, 4× SDI BNC, 12× video/sync BNC, 1× LCD, plus per-connector LEDs (~21 LEDs × R+G). *(SDI **IN LOOP** + **OUT MIRROR** both added 2026-06-13 → **16** video/sync+SDI BNC total; both extra SDI BNCs are carrier-mounted / Row 1, next to the GS3470/GS2962.)*

---

## ASCII rear-panel sketch

Glyphs: `◯` BNC 75 Ω · `▭` HDMI Type A · `◎` F-connector (RF) · `◦` RP-SMA · `●` per-connector tricolor R/A/G status LED (Lumex SSF-LXH409SISUGW right-angle CBI; silkscreen position beside each connector — see Open questions).

```
REAR PANEL — 1RU full-rack 19"  (432 mm × 44 mm)        — redrawn 2026-06-13 to match the backplane render

Zone order (L→R):   PWR / CTRL  │  LCD  │  INPUTS  │  OUTPUTS  │  SYNC  │  RF
Row rule:           TOP row = analog (composite + component)      BOTTOM row = digital (SDI + HDMI)

              ┌─ INPUTS ────────────┐      ┌─ OUTPUTS ──────────┐      ┌─ SYNC ──────┐
TOP   ►       COMPOSITE  Y In  Pb In  Pr In    COMPOSITE  Y Out Pb Out Pr Out    SYNC IN   SYNC LOOP
(analog)       IN ◯●    ◯●    ◯●    ◯●          OUT ◯●    ◯●    ◯●    ◯●          ◯●        ◯●

BOT   ►       SDI IN  SDI LOOP  HDMI IN        SDI OUT 1  SDI OUT 2  HDMI OUT     SYNC OUT 1  SYNC OUT 2
(digital)      ◯●     ◯●        ▭●              ◯●         ◯●         ▭●           ◯●          ◯●

PWR / CTRL (far left):   [IEC C14]    ◦ SMA1  ◦ SMA2  (top)    [RJ45]  [USB-C]  (bottom)
LCD:                     NHD-1.5 240×240 rear-status square, between the control cluster and INPUTS
RF (far right):          ◎ RF OUT — F-connector on the RF daughter-board's own panel edge, isolated

Approx panel budget:  PWR/CTRL ~89 + LCD ~38 + INPUTS ~94 + OUTPUTS ~94 + SYNC ~50 + RF ~25
                      ≈ 390 mm of 432 mm → ~42 mm slack for spacing, mounting screws, LED gaps.

BNC count: 8 analog video (4 in / 4 out) + 4 SDI (IN/LOOP/OUT1/OUT2) + 4 SYNC (IN/LOOP/OUT1/OUT2)
           = 16 BNC.  Plus 1 RF F-connector, 2 HDMI, RJ45, USB-C, 2 SMA, IEC, rear LCD.
```

<details>
<summary>Prior boxed sketch (pre-2026-06-13 — superseded by the layout above)</summary>

Each character cell ≈ 5 mm wide for spatial reference. `●` denotes a per-connector R/A/G status LED.

```
REAR PANEL — 1RU full-rack 19"   (432 mm × 44 mm)

← INPUT SIDE ─────────────────────────────[ STATUS ]───────────────────────── OUTPUT SIDE →

┌── PWR + CTRL ──────────┐ ┌───── VIDEO IN ─────┐ ┌SYNC IN┐ ┌── LCD ──┐ ┌SYNC OUT┐ ┌───── VIDEO OUT ────┐ ┌──spare──┐
│                        │ │                    │ │       │ │         │ │        │ │                    │ │         │
│ [IEC●] [USB●] [RJ45●]  │ │ [HDMI●]   [SDI●]   │ │ ●REF  │ │  Rear   │ │ ●OUT1  │ │   [SDI●]   [HDMI●] │ │         │
│                        │ │                    │ │  IN   │ │ Status  │ │        │ │                    │ │  V1.x   │
│                        │ │  ●Y    ●Pb   ●Pr   │ │       │ │  2.4"   │ │        │ │  ●Pr   ●Pb   ●Y    │ │  expan- │
│                        │ │                    │ │ ●REF  │ │  16:9   │ │ ●OUT2  │ │                    │ │  sion   │
│                        │ │  ●CVBS             │ │ LOOP  │ │         │ │        │ │             ●CVBS  │ │         │
│ [SMA1●]      [SMA2●]   │ │                    │ │       │ │         │ │        │ │                    │ │         │
│                        │ │                    │ │       │ │         │ │        │ │                    │ │         │
└────────────────────────┘ └────────────────────┘ └───────┘ └─────────┘ └────────┘ └────────────────────┘ └─────────┘
  ~89 mm                     ~94 mm                ~18 mm    ~52 mm      ~18 mm     ~94 mm                  ~67 mm

Two-row BNC stacking:
  composite/component IN/OUT — 4 BNCs in 2x2 grid, ~36 mm column width
  sync IN BNCs              — 2 BNCs vertical stack, ~18 mm column width
  sync OUT BNCs             — 2 BNCs vertical stack, ~18 mm column width
```

</details>

---

## Front-panel inventory

| Section | Element | Qty | Notes |
|---|---|---|---|
| Power | Lighted soft pushbutton | 1 | ~15 mm dia, illuminates on power |
| **microSD slot** | Push-push panel-mount socket | 1 | **Confirmed 2026-05-11.** Front-accessible. Dual purpose: (a) firmware updates without rear-panel access, (b) extended still-image library load for the 4 still buffers. ~$2 BOM (Hirose DM3 class or similar) |
| Status LEDs | Tricolor R/A/G LED column | ~6 | Mirrors rear per-connector LED state (genlock / signal / link / fault / IN / OUT roll-ups) |
| Branding | Silkscreen / etched logo | — | "Schindler 2.0" or similar |
| Display | **Newhaven NHD-2.9-376960AF-ASXP** front TFT, 2.9" mounted landscape | 1 | 376×960 native, **rotated to 960 × 376 landscape**, IPS, ST7701SN driver, 190 PPI. Driven over 24-bit parallel RGB by the BT817Q EVE controller on the front-panel mezzanine. Module outline 78.7 × 32.6 mm; bezel-opening cutout **~69 × 28 mm**; recessed pocket ~80 × 33 × ~3 mm. Drives the main menu (`ui-menu.md`) and the 4-wide horizontal strip of still-buffer thumbnails. |
| Front-panel UI controller | **RP2040** (front mezzanine) + **BridgeTek BT817Q EVE 4** graphics controller | 1 each | Front panel is its own mezzanine board. RP2040 reads inputs + sends draw commands to EVE over SPI; EVE drives the NHD-2.9 over 24-bit parallel RGB. Front mezzanine ↔ main carrier = UART + power only over a small cable. Replaces the prior STM32H735IGT6 UI MCU (retired from V1 production spec 2026-05-11). |
| Encoders | ALPS EC11E18244AU rotary, 11 mm metal D-shaft | 2 | Encoder A (navigate), Encoder B (adjust); each with integrated push-switch and **knob shroud / guard** (HARD REQUIREMENT — must survive face-down drop in road case) |
| Fixed buttons | Tactile illuminated | 4 | Home / Back / Menu / Confirm |
| Quick-select buttons | Tactile illuminated, user-bindable | 2–3 | **Defaults (post MVPHD review):** Q1 = `BLACK` (fade-to-black), Q2 = `MONO`, Q3 = `Proc Amp bypass`. Operator can rebind. |
| Cooling vents | Side intake slots | — | For the Noctua NF-A4x20 fan behind |

**Front panel total:** 1 power button + 6 status LEDs + 1 TFT + 2 encoders + 4 fixed + 3 quick-select buttons = clean minimal pro-broadcast aesthetic. No unlabeled buttons, no buttons that do nothing in a context.

---

## ASCII front-panel sketch

```
FRONT PANEL — 1RU full-rack 19"   (432 mm × 44 mm)

┌──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                                          │
│  ┌─PWR+SD+LEDs─┐  ┌── BRANDING ──┐  ┌──── FRONT TFT ────┐  ┌─ ENCODERS ─┐  ┌─ FIXED ──┐  ┌─ QUICK ──┐  │
│  │  [⏻ PWR]    │  │              │  │                   │  │            │  │          │  │          │  │
│  │  [▭ SD]    │  │              │  │ 2.8" 16:9 LTDC    │  │   ⊙    ⊙    │  │ ⌂   ⮜    │  │ BLK MONO │  │
│  │  ● GENLOCK │  │ SCHINDLER 2.0│  │ 480×272 WQVGA     │  │  ENC A ENC B│  │ ≡   ✓    │  │  BYP     │  │
│  │  ● SIGNAL  │  │              │  │ menu + status +   │  │             │  │          │  │          │  │
│  │  ● LINK    │  │              │  │ buffer thumbnails │  │  [shroud]  │  │          │  │          │  │
│  │  ● ALARM   │  │              │  │ (2×2 grid)        │  │             │  │          │  │          │  │
│  │  ● IN      │  │              │  │                   │  │             │  │          │  │          │  │
│  │  ● OUT     │  │              │  │                   │  │             │  │          │  │          │  │
│  └─────────────┘  └──────────────┘  └───────────────────┘  └────────────┘  └──────────┘  └──────────┘  │
│                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘
   ~40 mm            ~70 mm              ~75 mm               ~60 mm         ~55 mm       ~50 mm

  Width budget:
    PWR + LED column         ~35 mm
    Branding / logo zone     ~80 mm   (or replace with cooling vents / SD-card slot — see open questions)
    Front TFT (2.8" 16:9)    ~75 mm   (62 mm active + ~13 mm bezel)
    Encoder pair             ~60 mm   (2x knob ~20 mm + shroud bars + spacing)
    Fixed buttons (4)        ~55 mm   (2x2 grid, ~25 mm each + spacing)
    Quick-select buttons     ~45 mm   (3 stacked or single row)
    Subtotal                 ~350 mm  of 432 mm
    Slack                    ~82 mm   for spacing + corner mounting screws + adjustments
```

**Notes:**

- The persistent status bar from `ui-menu.md` (sync source + rate + lock state) renders at the top of the front TFT continuously, so the front-panel TFT mirrors that bar plus shows the current menu screen below it.
- Front-panel LED column shows roll-up state: `GENLOCK` (combined ref source lock), `SIGNAL` (any input present), `LINK` (network/WiFi), `ALARM` (any fault), `IN` and `OUT` (rolled-up state of all active inputs / outputs respectively). Detailed per-connector state lives on the rear LCD.
- Encoders use ALPS EC11E18244AU — 36 detents / 18 PPR half-step quadrature. Decoder must count edges, not full cycles. Software acceleration on long scrolls advised given fine 10° click pitch.
- Both encoders are **shrouded** — recessed pocket, side rail bars, or equivalent. Must survive being dropped face-down in a road case. Confirmed HARD REQUIREMENT.
- Power button is a soft button — pressing initiates graceful Linux shutdown, then powers down. Mains kill is via the rear IEC cord (no rocker on rear per current spec).

---

## LED conventions (recap, full detail in `01-spec.md`)

| Connector type | Red | Amber | Green | Off |
|---|---|---|---|---|
| Video IN | Expected, not present | Present, not in use | Present and in use | Port disabled |
| Sync IN | Invalid signal | Locked, not selected as ref | Locked, selected as ref | Nothing connected |
| Video / Sync OUT | (rare — fault state) | Configured, no source | Configured and outputting | Port disabled |
| Control (USB / RJ45 / SMA) | Hardware fault | Link present, no traffic | Link + traffic | Port disabled |
| Power (IEC) | Fault / overcurrent | Standby | Powered, normal | Off |

---

## Open questions

**Rear panel:**
- **LCD horizontal position:** centred between IN and OUT zones (current sketch) vs offset right (closer to where the operator usually stands when patching). Default = centred; revisit if there's a strong ergonomic preference.
- **Spare panel area allocation:** ~67 mm at the right reserved for future expansion. Candidates: XLR LTC IN/OUT return (52 mm — close to filling it), 10 MHz reference IN/OUT (2× BNC = 18 mm — leaves slack), or simply a vented airflow grille. No commitment for V1.
- **Per-connector LED placement:** part **resolved 2026-06-13c → Lumex SSF-LXH409SISUGW** one-piece right-angle CBI (common-anode, faces the rear panel, no holder/light-pipe). Remaining detail is only the silkscreen/PCB position relative to each connector — above-right (most pro gear), above-left, or directly below; decide at mechanical design (screen-print + PCB placement only, not the part).
- **Power button on rear:** none in current design. Front-panel soft power button is the only switch; rear has IEC inlet only. Some gear adds a hard rocker switch behind the IEC for service. **Pending Justin's call** — common pattern, ~$2 BOM.

**Front panel:**
- ~~**Front SD card slot:**~~ **RESOLVED 2026-05-11 — added as front-panel microSD.** Confirmed as part of the still-image-buffers banking. Uses: firmware updates (no rear access needed) + extended buffer image library load. ~$2 BOM. See inventory table above.
- **Branding zone width:** ~80 mm allocated to logo / silkscreen. Could be tighter to free up panel space for a front-panel USB-C service port (alongside rear USB-C, or instead of it) or for additional quick-select buttons. **Pending mechanical mock review.**
- **TFT size confirmation:** spec mentions 2.8" or 3.5". A 2.8" 16:9 (62 × 35 mm) just fits 1RU height with bezel margin; a 3.5" 4:3 (71 × 53 mm) would not fit a 44 mm panel. Recommend confirming 2.8" 16:9 as the V1 commitment before carrier traces go to the LTDC parallel bus.
- **Quick-select count: 2 or 3?** Spec says 2–3 buttons. With Output Mode + Profile + Genlock source as defaults, 3 is the natural number. Confirm.
- **Front-panel speaker / beeper:** none currently. Some pro gear includes a small beeper for confirmation tones / fault alarms (which the user can mute). Worth deciding.

---

## Mechanical TODO (for chassis design phase)

- Front Panel Express style milled aluminium panel; same vendor as planned for front panel in `schindler-playbook.md` Ch. 10.
- **Front TFT bezel (NHD-2.9-376960AF-ASXP):** ~69 × 28 mm bezel-opening cutout, recessed pocket ~80 × 33 × 3 mm deep, foam-gasket seat, anti-glare film optional
- **Rear LCD bezel (NHD-1.5-240240AF-CSXP):** ~28 × 28 mm active-area cutout, recessed pocket ~33 × 36 × 3 mm deep, foam gasket
- BNC mounting: front-mount nut + lockwasher, panel cutout ø10 mm, ~5 mm thread length needed behind panel.
- XLR mounting (reserved, V1 dropped): D-shape Neutrik-style cutout, ~24 × 19 mm, in case panel space lets the XLR pair return.
- SMA: panel-mount RP-SMA bulkhead, ø6.35 mm cutout + flats.
- Engraving / silkscreen: white on black anodised, group labels in larger font (INPUT / OUTPUT / SYNC IN / SYNC OUT / etc.), connector labels smaller below each ●LED.
