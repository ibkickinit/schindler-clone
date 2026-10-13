# 13 — v1 MVP Definition (first 4K unit)

> **Set by Justin 2026-10-13.** This is the target for the first shippable unit. Anything not listed
> here is out of v1. Supersedes the broader Tier-0 list in `01` where they differ.

## The unit

**One USB-C in → two independent channels, each = 12G-SDI out + HDMI out.**
No scaling, no frame-rate conversion, no frame buffer (source-locked, `02` Clocking).

```
Laptop USB-C ─► hub (MST: PS8650/VMM5330 · USB4: RTS5490 for Mac) ─► DP A ─► LT7911UXC #1 ─► FPGA ─► SDI TX ─► BNC 1
                                                                  └► DP B ─► LT7911UXC #2 ─► FPGA ─► SDI TX ─► BNC 2
                                                     each channel also ─► HDMI 2.0 TX ─► HDMI 1 / HDMI 2   (Q14)
MCU: reads the format selector, writes EDID to both RX chips, re-asserts HPD, drives status LEDs
USB-C power-in (aux) for when the host can't power the unit
```

## Must-have

| # | Feature | Notes |
|---|---|---|
| 1 | **Single USB-C video input** | DP Alt Mode / USB4; Mac support via USB4 hub (`06` Q-MAC) |
| 2 | **Two independent displays** to the OS | MST (Win/Linux) or USB4 (Mac + Win) |
| 3 | **2× 12G-SDI out** | Rate follows format: 1080p23.98–30 → **HD 1.5G** · 1080p50–60 → **3G** · 2160p23.98–30 → **6G** · 2160p50–60 → **12G**. So v1 needs **all four SDI TX stages** (`12`) |
| 4 | **2× HDMI 2.0 out** | Each mirrors its SDI channel (same video, 4K60 capable). Implementation = `06` **Q14** |
| 5 | **Format selector (hardware)** | Picks the EDID the PC sees → forces resolution + frame rate (below) |
| 6 | Embedded audio | 2–8 ch LPCM from DP → ST 299 (SDI) and HDMI audio |
| 7 | Status LEDs | Per channel: signal present / format matches selector / SDI rate |
| 8 | Non-HDCP | Unprotected content only (`06` Q11) |

## Format selector (the "tech switch")

Goal: a tech sets the format with a switch — no app, no OS display settings.

- **Resolution:** 3-position slide — **AUTO / HD (1080p) / 4K (2160p)**.
- **Frame rate:** 8-position rotary — **23.98 · 24 · 25 · 29.97 · 30 · 50 · 59.94 · 60**.
- **AUTO** = the broadcast-first multi-mode EDID from `03` (host picks; preferred 1080p59.94).
- HD/4K + a rate = a **single-mode "Lock" EDID** (`03`), the most reliable way to force the GPU.
- **Applies to both outputs** in v1 (simplest for a tech). Per-output selection = later option.
- On change: MCU writes the new EDID to both LT7911UXCs and **re-asserts HPD** so the host re-reads it.
- If the host ignores the EDID (some GPUs round 23.98/24 — `03` limits), the "format matches" LED
  shows it; the optional helper app (`03`) remains a later add-on, not v1.
- Depends on Lontium confirming **EDID is MCU-writable** (round-2 question, `05`).

## Explicitly NOT in v1

Scaling · frame-rate conversion · frame buffer / DDR population · genlock / REF-IN · multiview ·
color processing beyond RGB→YCbCr 4:2:2 + range · OLED/menu · config app · SDI/HDMI input · 1080i.
(Keep the DDR and REF-IN **footprints** on the PCB for Pro — `06` Q7.)

## Consequences for the plan

- **SDI TX:** v1 can't ship on HD alone — stages 1–4 (HD, 3G, 6G, 12G) are all v1 work (`12`).
- **HDMI out** adds two TX chips (or a TX core) + the **HDMI Adopter Agreement** (annual fee + per-unit
  royalty — check current terms; required for any HDMI-branded product regardless of chip vs core).
- **Power:** 2× RX + FPGA + 2× SDI drivers + 2× HDMI TX ≈ **8–12 W** (estimate) → keep the aux USB-C
  power-in; most laptops can't source that over the video port.
- **Bandwidth:** dual 2160p60 needs 4-lane HBR3 from the host (`02`, `06` Q2) — degradation ladder
  still applies.
