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
| 4 | **2× HDMI 2.0 out** | Each **mirrors its own SDI channel**. **Q14 decided: Option A** — LT7911UXC duplicates its output to a MIPI→HDMI 2.0 TX chip; FPGA not in the HDMI path |
| 5 | **Format selector (hardware)** | Picks the EDID the PC sees → forces resolution + frame rate (below) |
| 6 | Embedded audio | 2–8 ch LPCM from DP → ST 299 (SDI) and HDMI audio |
| 7 | Status LEDs | Per channel: signal present / format matches selector / SDI rate |
| 8 | Non-HDCP | Unprotected content only (`06` Q11) |

## Format selector (the "tech switch")

Goal: a tech sets the format with a switch — no app, no OS display settings.

- **Resolution:** 5-position rotary (or 3-position slide if mixed modes are dropped):
  **AUTO · HD both · 4K both · HD(1)+4K(2) · 4K(1)+HD(2)**. Mixed modes are *to explore* — if they
  complicate EDID/HPD handling or bandwidth, ship **AUTO / HD both / 4K both** only (Justin: fine either way).
- **Frame rate:** 8-position rotary — **23.98 · 24 · 25 · 29.97 · 30 · 50 · 59.94 · 60**.
- **AUTO** = the broadcast-first multi-mode EDID from `03` (host picks; preferred 1080p59.94).
- HD/4K + a rate = a **single-mode "Lock" EDID** (`03`), the most reliable way to force the GPU.
- **One selector for the unit** (Justin). Frame rate is shared by both outputs; resolution per the modes above.
- On change: MCU writes the new EDID to both LT7911UXCs and **re-asserts HPD** so the host re-reads it.
- If the host ignores the EDID (some GPUs round 23.98/24 — `03` limits), the "format matches" LED
  shows it; the optional helper app (`03`) remains a later add-on, not v1.
- **Assumed: EDID is MCU-writable** in the LT7911UXC (by necessity — Justin). Still confirm in Lontium round 2 (`05`).

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

## Power architecture (two USB-C ports)

No "load balancing" — use **priority selection**: run from the aux port when it's present, otherwise
from the host. Sharing load between two sources is unusual and fragile; a priority power mux is the norm.

| Block | Job | Candidate parts (verify) |
|---|---|---|
| **Video port PD/Alt-Mode controller** | Negotiate DP Alt Mode + sink whatever VBUS the host offers | TI **TPS65987D** (already in `04`); the USB4 hub (RTS5490) or the LT7911UXC's built-in CC/PD may cover part of this — decide with the hub choice |
| **Aux port PD sink** | Request e.g. 9–15 V from a USB-C PSU, no firmware | Infineon **CYPD3177** (EZ-PD BCR, resistor-configured) or TI **TPS25750** (PD + integrated power path) |
| **Power mux / ideal-diode OR** | Pick aux when present, else host; no back-feed between sources | TI **TPS2121** (2-input priority mux) · ADI **LTC4417** (prioritized 3-input) · TI **LM66200** (dual ideal diode) |
| Downstream | One wide-input buck front end → FPGA/RX/TX rails | — |

- **Host budget:** most laptops source only **5 V at 1.5–3 A (≤ 7.5–15 W)** on a DP-Alt port — not
  enough for the ~8–12 W v1 estimate on many hosts. The MCU reads the negotiated host contract; if it's
  short and no aux is present, light a **"connect power"** LED and/or hold a lower ladder rung (`02`).
- **Not v1:** pass-through charging (feeding aux power back to the laptop like a dock) — needs a PD
  *source* role and a bigger supply. Possible later.
