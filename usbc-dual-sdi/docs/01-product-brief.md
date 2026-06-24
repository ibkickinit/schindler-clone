# 01 — Product Brief

**Working name:** Crossover (placeholder)
**Category:** USB-C-native dual-channel 12G-SDI display adapter / converter
**Form factor:** compact palm-sized box with a captive (or detachable) USB-C
cable and two BNC outputs — "Blackmagic Micro Converter" sized, not "HDMI
dongle." We keep the *user mental model* of a dongle ("plug in, get two
displays") while being honest about the physical size.
**Architecture (decided):** the **fixed-function "dumb" design** — USB-C MST hub
+ two **Semtech GS12170 HDMI→SDI bridge ASICs** + a small MCU for EDID. **No
FPGA, no DDR, no SOM** (see `02`, `04`). This is literally "a USB-C MST dongle +
two HDMI→SDI micro-converters, integrated into one box." An FPGA-based **smart
variant** (active frame-rate conversion, color, genlock) is a documented future
**Pro** option, not v1.

## The core promise

> Plug one USB-C cable into a laptop. The OS sees two new displays. Two BNCs on
> the box emit two independent, broadcast-legal 12G-SDI signals — and you can
> dictate exactly what resolution / frame rate each one runs at.

## Feature tiers

> **⚠️ Platform caveat (defining, `06` Q-MAC):** with an **MST** front end, "two
> independent displays" is true on **Windows/Linux** but **Mac mirrors** (macOS
> has no MST extended; hardware-locked on Apple Silicon). Independent-dual on Mac
> requires a **USB4 front end (Realtek RTS5490 — still no FPGA)**. The choice is a
> who's-the-customer decision; see `02` §2.

### Tier 0 — must-ship (v1 MVP)
- USB-C input (DP 1.4 / 4-lane HBR3 for MST, **or USB4** for the Mac-independent
  variant — see platform caveat).
- Presents as **two independent displays** (Windows/Linux via MST; Mac via USB4 —
  MST mirrors on Mac).
- **Two 12G-SDI outputs**, each auto-negotiating 12G / 6G / 3G / HD / SD.
- Per-output formats up to **2160p59.94 4:2:2 10-bit** (4K UHD).
- **Embedded audio** (HDMI LPCM → SMPTE-embedded SDI audio, up to 16 ch — done
  in the GS12170 bridge).
- **Managed EDID** per output with selectable profiles (in the MCU).
- **EDID-forced frame-rate management** (true fractional rates 23.98 / 29.97 /
  59.94 advertised so the GPU emits broadcast cadence). *Passive* (EDID-nudged,
  source-locked) — this is also **required** to keep the laptop emitting
  SDI-legal SMPTE rasters the bridge can convert (`02` §5). *Active* rate
  conversion is a Pro feature.
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

### Tier 2 — Pro / v2 (FPGA-based "smart" variant — NOT v1)
This is the **only** thing that justifies adding an FPGA + DDR, and it mirrors
Schindler's Mini/Pro split (same front end, different conversion core):
- **Active frame-rate conversion** with a DDR frame buffer (host 60.00 → SDI
  59.94, 50↔60 region conversion) instead of EDID coaxing.
- **Color / range processing** and **genlock to house reference** (tri-level /
  black-burst REF IN BNC).
- **SDI loop / second source** or HDMI confidence out.
- Replaces the two GS12170 bridges with one FPGA + DDR. Out of scope for v1; the
  v1 PCB need not pre-stuff it.

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
1. **MST vs USB4 front end / Mac support (DEFINING — `06` Q-MAC)** — MST gives
   independent-dual on Windows but **mirror-only on Mac**; a Mac-heavy target
   forces the **USB4 (RTS5490)** front end. Still no FPGA either way, but it
   reshapes the front-end BOM and host compatibility. **Verify RTS5490 macOS
   independent-dual on a real M4 Mac.**
2. **DP MST / USB4 hub sourcing** — the front-end hub (VMM6210 / PS8650 /
   RTD2186 / RTS5490) is a design-win-channel part. *Mitigated* for development
   by an off-the-shelf adapter (`07`).
2. **GS12170 lifecycle** — the bridge ASIC that removes the FPGA may be EOL/NRND
   (still stocked; conflicting signals). **Confirm with Semtech before designing
   in.** Fallback = small-FPGA conversion recipe (`06`, `04`).
3. **2-lane vs 4-lane DP Alt Mode** on the host — dual 4K needs 4 lanes;
   *mitigated* by the degradation ladder; host-lane behavior needs measurement.
4. **GPU honoring fractional-rate EDID** — 23.98/24 from laptops is historically
   flaky; *mitigated* by the optional host-side helper (`03`).

(Decided: fixed-function/no-FPGA architecture; secondary USB-C power-in;
non-HDCP-sink. Per-rung wattage still open — `06` Q3.)
