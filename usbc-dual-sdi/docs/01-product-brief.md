# 01 — Product Brief

**Working name:** Crossover (placeholder)
**Category:** USB-C-native dual-channel 12G-SDI display adapter / converter
**Form factor:** compact palm-sized box with a captive (or detachable) USB-C
cable and two BNC outputs — "Blackmagic Micro Converter" sized, not "HDMI
dongle." We keep the *user mental model* of a dongle ("plug in, get two
displays") while being honest about the physical size.
**Architecture (decided):** **FPGA-based (Microchip PolarFire).** USB-C →
DP-output hub → 2× DP-RX in a **PolarFire MPF300** (free 12G-SDI IP) → 2× BNC,
with an MCU for EDID. The fixed-function bridge plan died with the **Semtech
GS12170 (EOL Feb 2025, no replacement)** — conversion now lives in the FPGA, as it
does across the industry (Blackmagic = Spartan/Artix). V1 is **conversion-only**
(source-locked, no frame manipulation); the same FPGA unlocks the smart features
(active FRC, color, genlock) later. **Raw FPGA on a 6–8 layer board, no SOM** (no
DDR-heavy frame buffer in V1). See `02`, `04`, `06` Q0.

## The core promise

> Plug one USB-C cable into a laptop. The OS sees two new displays. Two BNCs on
> the box emit two independent, broadcast-legal 12G-SDI signals — and you can
> dictate exactly what resolution / frame rate each one runs at.

## Feature tiers

> **⚠️ Platform caveat (defining, `06` Q-MAC):** with an **MST** front end, "two
> independent displays" is true on **Windows/Linux** but **Mac mirrors** (macOS
> has no MST extended; hardware-locked on Apple Silicon). Independent-dual on Mac
> requires a **USB4 front end (Realtek RTS5490)**. The choice is a
> who's-the-customer decision; see `02` §2.

### Tier 0 — must-ship (v1 MVP)
- USB-C input (DP 1.4 / 4-lane HBR3 for MST, **or USB4** for the Mac-independent
  variant — see platform caveat).
- Presents as **two independent displays** (Windows/Linux via MST; Mac via USB4 —
  MST mirrors on Mac).
- **Two 12G-SDI outputs**, each auto-negotiating 12G / 6G / 3G / HD / SD.
- Per-output formats up to **2160p59.94 4:2:2 10-bit** (4K UHD).
- **Embedded audio** (DP/HDMI LPCM → SMPTE ST 299 embedded SDI audio — done in
  the FPGA).
- **Managed EDID** per output with selectable profiles (in the MCU).
- **EDID-forced frame-rate management** (true fractional rates 23.98 / 29.97 /
  59.94 advertised so the GPU emits broadcast cadence). *Passive* (EDID-nudged,
  source-locked) — this is also **required** to keep the laptop emitting
  SDI-legal SMPTE rasters the FPGA can convert (`02` §5). *Active* rate
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

### Tier 2 — Pro / v2 ("smart" features — NOT v1)
V1 already uses the FPGA for conversion (source-locked); the Pro variant adds a
**DDR frame buffer + asynchronous output clock** on the *same* FPGA to unlock:
- **Active frame-rate conversion** (host 60.00 → SDI 59.94, 50↔60) instead of
  EDID coaxing.
- **Color / range processing** and **genlock to house reference** (tri-level /
  black-burst REF IN BNC).
- **SDI loop / second source** or HDMI confidence out.
- A firmware/stuffing upgrade on the same silicon — mirrors Schindler's Mini/Pro
  split. Out of scope for v1.

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

## Competitive landscape & white space *(market check, 2026)*

**Verified: no shipping product is simultaneously (a) USB-C/Thunderbolt-native,
(b) two *independent* SDI out, and (c) presents as plain OS displays.** The market
splits into two camps that each miss the key bit (HIGH confidence among the
majors; MEDIUM on "zero competitors worldwide" — not every regional/Chinese brand
was exhaustively checked).

| Product | Host I/F | Dir. | SDI out | Presents as a **display**? | Price | The gap |
|---|---|---|---|---|---|---|
| BMD **UltraStudio 4K Mini** | TB3 | out+capture | **2× 12G** | **No** — DeckLink, app-driven; dual is fill+key | ~$1,199 | not a display; needs NLE/Resolve |
| AJA **T-TAP Pro** | TB3 | out | 1× 12G (+HDMI) | **No** — "not like another monitor" | ~$1,145 | single; not a display |
| BMD **UltraStudio Monitor 3G** | TB3 | out | 1× 3G | **No** — app-driven | ~$500–600 | single, 3G, not a display |
| AJA **U-TAP / Magewell** | USB | **in** (capture) | — | — | ~$300+ | wrong direction |
| **DIY: USB-C MST hub + 2× HDMI→SDI** | USB-C DP-Alt | out | 2 indep | **Yes** | ~$380–450 | 3 boxes; **Windows-only**; no unified EDID/format mgmt |
| **This product** | **USB-C / USB4** | **out** | **2× 12G** | **Yes** | target **$600–900** | — |

**The moat is "presents as displays," not "dual 12G SDI."** Dual-12G-out already
exists (UltraStudio 4K Mini). What nobody ships is a box that **behaves like two
ordinary monitors from any app / the desktop** *and* outputs SDI. Every pro
SDI-out box is **app-driven** (needs Premiere/Resolve/Control Room; AJA documents
T-TAP Pro is "not like another monitor"). The only "acts-as-a-display" path today
is the **3-box DIY chain — and it's Windows-only** (no Mac MST). **Demand is
proven** by the NDI/Syphon/BetterDisplay "virtual-display → mirror-to-DeckLink"
hacks people use to fake exactly this.

**Positioning consequences:**
- Lead with **"two SDI outputs that just work as displays, from any app, on Mac
  and PC"** — not "dual 12G-SDI out" (table stakes).
- **Mac support is a competitive weapon**, not just a risk: the DIY status quo is
  Windows-only, so "works on Mac too" (the USB4/RTS5490 path, `06` Q-MAC) is a
  differentiator nobody offers.
- **Target:** live events / playout / signage / feeding switchers — buyers who
  want display-like SDI. **Not** color-critical finishing (that crowd wants the
  NLE/Mercury-Transmit path, so generic-display behavior is a non-feature).
- **Pricing room:** ~$600–900 integrated undercuts the ~$1,200 pro boxes and
  beats the DIY chain on platform support, cable count, and EDID/format mgmt.

*Caveat: aja.com 403'd (specs via resellers); regional/Chinese brands not
exhaustively checked — treat as "white space among the majors."*

## Key risks (see `06-open-questions.md`)
1. **MST vs USB4 front end / Mac support (DEFINING — `06` Q-MAC)** — MST gives
   independent-dual on Windows but **mirror-only on Mac**; a Mac-heavy target
   forces the **USB4 (RTS5490)** front end. Reshapes the front-end BOM and host
   compatibility. **Verify RTS5490 macOS independent-dual on a real M4 Mac.**
2. **FPGA fit / IP cost** — design to **MPF200T** ($286); confirm 2-channel logic
   fit (port down to MPF100T if it fits) and the **DP-RX IP license** cost (SDI IP
   is free). `06` Q0b.
3. **DP-output hub sourcing** — the front-end hub (PS8650 / VMM5330 / RTS5490) is
   a design-win-channel part. *Mitigated* for development by an off-the-shelf
   adapter (`07`).
4. **2-lane vs 4-lane DP Alt Mode** on the host — dual 4K needs 4 lanes;
   *mitigated* by the degradation ladder; host-lane behavior needs measurement.
5. **GPU honoring fractional-rate EDID** — 23.98/24 from laptops is historically
   flaky; *mitigated* by the optional host-side helper (`03`).

(Decided: **PolarFire FPGA** conversion (GS12170 EOL); dual-4K60/12G scope;
secondary USB-C power-in; non-HDCP-sink. Per-rung wattage open — `06` Q3.)
