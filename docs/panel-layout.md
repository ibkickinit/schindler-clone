# Schindler 2.0 — Panel Layout

**Status:** Draft 2026-05-11
**Scope:** rear-panel connector arrangement for V1 Pro Full / Broadcast Digital.
**Form factor:** 1RU full-rack 19" — usable panel area ≈ 432 mm × 44 mm.

This doc holds the spatial arrangement. The connector inventory and electrical spec live in [`01-spec.md`](01-spec.md).

---

## Organising principles

1. **IN on the left, OUT on the right.** Signal flow runs left to right, matching every Tek / AJA / Evertz / BMD reference unit in the market.
2. **Sync zone follows the IN/OUT discipline.** Sync IN BNCs live inside the input section; SYNC OUT BNCs live inside the output section. No standalone "sync island" — the sync zone is partitioned by direction like the rest of the panel.
3. **Power + control cluster on the far left.** AC mains entry, USB service, network, wireless antennas — grouped at the corner farthest from the analog signal path.
4. **Rear status LCD in the centre.** Read-only status display for at-rack patching from behind. Visible from any working angle.
5. **Per-connector LED next to each connector.** R/A/G status, ~10 % default brightness, drives off the same I/O state the rear LCD reads.
6. **Spare panel area on the far right.** Reserved for V1.x expansion (XLR LTC return, 10 MHz reference, future I/O).

---

## Connector inventory (post-2026-05-11 decisions)

| Section | Connector | Qty | Notes |
|---|---|---|---|
| Power + control | IEC C14 | 1 | AC mains in |
| Power + control | USB-C | 1 | Service / firmware / debug |
| Power + control | RJ45 | 1 | GbE on TE0720 PHY |
| Power + control | SMA | 2 | RP-SMA WiFi antennas |
| Video IN | HDMI | 1 | Via LT8619C HDMI RX |
| Video IN | BNC SDI | 1 | Via Semtech GS3470 |
| Video IN | BNC composite | 1 | CVBS, ADV7280 decoder |
| Video IN | BNC component | 3 | Y / Pb / Pr, ADV7280 decoder |
| Sync IN | BNC | 2 | REF IN + REF LOOP (passive loop-through) |
| Status | LCD | 1 | 2.4" 16:9 SPI, rear-only, read-only |
| Sync OUT | BNC | 2 | SYNC OUT 1 + SYNC OUT 2, format-selectable |
| Video OUT | BNC component | 3 | Y / Pb / Pr, ADV7393 DAC |
| Video OUT | BNC composite | 1 | CVBS, ADV7393 DAC |
| Video OUT | BNC SDI | 1 | Via Semtech GS2962 (broadcast tier — populated or unpopulated per SKU) |
| Video OUT | HDMI | 1 | Direct FPGA TX |

**Totals:** 1× IEC, 1× USB-C, 1× RJ45, 2× SMA, 2× HDMI, 2× SDI BNC, 12× video/sync BNC, 1× LCD, plus per-connector LEDs (~21 LEDs × R+G).

---

## ASCII rear-panel sketch

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

- **LCD horizontal position:** centred between IN and OUT zones (current sketch) vs offset right (closer to where the operator usually stands when patching). Default = centred; revisit if there's a strong ergonomic preference.
- **Spare panel area allocation:** ~67 mm at the right reserved for future expansion. Candidates: XLR LTC IN/OUT return (52 mm — close to filling it), 10 MHz reference IN/OUT (2× BNC = 18 mm — leaves slack), or simply a vented airflow grille. No commitment for V1.
- **Per-connector LED placement:** above-right of each connector (current convention in most pro gear), above-left, or directly below. Decide during mechanical design — affects screen-print layout and PCB LED placement only.
- **Power button on rear:** none in current design. Front-panel soft power button is the only switch; rear has IEC inlet only. Some gear adds a hard rocker switch behind the IEC for service. **Pending Justin's call** — common pattern, ~$2 BOM.

---

## Mechanical TODO (for chassis design phase)

- Front Panel Express style milled aluminium panel; same vendor as planned for front panel in `schindler-playbook.md` Ch. 10.
- LCD bezel: recessed cutout with anti-glare film, ~52 × 32 mm aperture for the 2.4" 16:9 module.
- BNC mounting: front-mount nut + lockwasher, panel cutout ø10 mm, ~5 mm thread length needed behind panel.
- XLR mounting (reserved, V1 dropped): D-shape Neutrik-style cutout, ~24 × 19 mm, in case panel space lets the XLR pair return.
- SMA: panel-mount RP-SMA bulkhead, ø6.35 mm cutout + flats.
- Engraving / silkscreen: white on black anodised, group labels in larger font (INPUT / OUTPUT / SYNC IN / SYNC OUT / etc.), connector labels smaller below each ●LED.
