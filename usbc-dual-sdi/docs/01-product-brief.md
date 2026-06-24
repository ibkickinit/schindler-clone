# 01 — Product Brief

**Working name:** Crossover (placeholder)
**Category:** USB-C-native dual-channel 12G-SDI display adapter / converter
**Form factor:** compact palm-sized box with a captive (or detachable) USB-C
cable and two BNC outputs. **Not** a thumb-stick dongle — dual 12G-SDI plus an
FPGA and cable drivers dissipates several watts and needs real BNC connectors,
so the realistic envelope is "Blackmagic Micro Converter" sized, not "HDMI
dongle" sized. We keep the *user mental model* of a dongle ("plug in, get two
displays") while being honest about the physical size.

## The core promise

> Plug one USB-C cable into a laptop. The OS sees two new displays. Two BNCs on
> the box emit two independent, broadcast-legal 12G-SDI signals — and you can
> dictate exactly what resolution / frame rate each one runs at.

## Feature tiers

### Tier 0 — must-ship (v1 MVP)
- USB-C **DisplayPort Alt Mode** input (DP 1.4, 4-lane HBR3).
- Presents as **two independent displays** to host (via DP MST).
- **Two 12G-SDI outputs**, each auto-negotiating 12G / 6G / 3G / HD / SD.
- Per-output formats up to **2160p59.94 4:2:2 10-bit** (4K UHD).
- **Embedded audio** (LPCM from the DP stream → SMPTE ST 299 audio groups).
- **Managed EDID** per output with selectable profiles.
- **EDID-forced frame-rate management** (true fractional rates 23.98 / 29.97 /
  59.94 advertised so the GPU emits broadcast cadence).
- **Plug-and-play video** — no host driver required for the SDI to work.
- **Graceful degradation ladder** — when the host link or power can't sustain
  dual-4K, drop predictably (single-4K twin output → dual-HD → single-HD twin)
  instead of failing to black. See `02`.
- **Flexible power** — bus/PD power from the host when sufficient, with a
  secondary USB-C power-in (another port or a standard USB-C PD PSU) for dual-4K.
- Status LEDs per output (lock / format / active degradation rung).

### Tier 1 — fast-follow (v1.x)
- Optional **USB HID config app** (Win/Mac) for picking EDID profiles,
  resolution/frame-rate locks, color range (full/limited), and viewing link +
  lock status. Communicates over USB 2.0 sideband on the same USB-C cable —
  optional, the device works without it.
- Small on-device **OLED + button** for standalone status / profile cycling.
- SDI **payload ID (ST 352)** and **format flip** confidence on the OLED.

### Tier 2 — Pro / v2 (architecturally reserved, not v1)
- **Genlock / reference input** (tri-level or black-burst REF IN BNC) so both
  outputs lock to house sync.
- **Active frame-rate conversion** with a DDR frame buffer (e.g. host 60.00 →
  SDI 59.94, or 50↔60 region conversion) instead of relying on EDID coaxing.
- **SDI loop / second source** or HDMI confidence out.
- These require DDR + a genlock PLL on the carrier; v1 PCB should leave
  footprints / FPGA banks for them but not stuff them.

## Explicit non-goals (v1)
- **Not a capture device.** This is SDI *out* from the laptop, not SDI *in*. (A
  capture variant is a plausible v2 sibling but is a different data path —
  SDI→USB UVC — and is out of scope here.)
- **Not DisplayLink.** We do not push compressed video over USB bulk and
  decompress in the box; that path needs a host driver, adds latency, and is
  unsuited to broadcast. We use native DP Alt Mode.
- **Not 12G dual-link / quad-link 8K.** Single-link 12G per output is the cap.
- **Not an HDCP stripper.** SDI has no HDCP, so the box ships as a **non-HDCP
  sink** (like Blackmagic/AJA): unprotected sources convert; protected sources
  blank at the source. No "override" toggle — stripping is illegal (`06` Q11).

## Competitive landscape

| Product | Host I/F | Channels | Direction | Notes |
|---|---|---|---|---|
| Blackmagic UltraStudio Monitor 3G | Thunderbolt/USB-C | 1 | out | desktop box, 3G only |
| Blackmagic Micro Converter HDMI→SDI | HDMI | 1 | out | needs an HDMI dongle to reach USB-C; 3G/6G |
| AJA U-TAP SDI | USB 3 | 1 | **in** (capture) | opposite direction |
| Magewell Pro Convert | network/HDMI | 1 | varies | not USB-C display-native |
| **Crossover (this)** | **USB-C DP Alt Mode** | **2** | **out** | **dual 12G, presents as two displays, managed EDID/FRC** |

The gap we fill: **dual-channel, USB-C-display-native, broadcast-legal SDI out
with deliberate EDID/frame-rate control.** Nobody is sitting exactly here.

## Key risks (see `06-open-questions.md`)
1. **DP-MST path / Synaptics VMM procurability** — the cheap path (discrete VMM
   hub + PolarFire, no AMD IP) hinges on whether VMM6210/VMM5330 is buyable in
   our volume (*unverified*). Fallback is AMD FPGA MST RX (~$16k IP). Top
   architecture decision to close (`06` Q1).
2. **2-lane vs 4-lane DP Alt Mode** on the host — dual 4K needs 4 lanes;
   *mitigated* by the degradation ladder, but the host-lane behavior still needs
   measurement.
3. **GPU honoring fractional-rate EDID** — 23.98/24 from laptops is historically
   flaky; *mitigated* by the optional host-side helper (`03`), with active FRC
   (Tier 2) as the heavier fallback.

(Power form is now decided — secondary USB-C power-in; only the per-rung wattage
thresholds remain open. See `06` Q3.)
