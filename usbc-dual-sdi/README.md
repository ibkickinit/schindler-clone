# USB-C → Dual 12G-SDI Converter (working name: **Crossover**)

> **Sequestered project.** This folder is a **separate, unrelated product** that
> happens to be parked inside the `schindler-clone` repo during incubation. It
> shares **no code, hardware, or roadmap** with Schindler 2.0. The folder is
> self-contained so it can be lifted into its own repository later with a single
> `git mv` / subtree split. Nothing here should be cross-referenced from the
> Schindler docs, and nothing in the Schindler tree should depend on it.
>
> Working product name **"Crossover"** is a placeholder — rename freely.

## One-liner

A pocket-box that turns a laptop's single USB-C port into **two independent
12G-SDI outputs**. To the operating system it looks like **two ordinary
external displays** (like plugging in two HDMI dongles); on the back it has
**two BNC connectors** carrying broadcast-grade SDI up to **2160p59.94 (4K UHD)
per output**. EDID and frame-rate behavior is fully managed, so the SDI you get
out is broadcast-legal (true 23.98 / 59.94 cadence, correct color range), not
whatever the GPU felt like emitting.

## Why this exists

Today, getting clean SDI out of a laptop means a desktop Thunderbolt I/O box
(Blackmagic UltraStudio), a single-channel HDMI→SDI mini converter plus an HDMI
dongle, or a PCIe card in a tower. There is **no small, bus-friendly, USB-C-
native device that presents as two displays and emits two channels of 12G-SDI**
with deliberate EDID / frame-rate control.

Target users:

- **Live events / corporate AV** — drive two SDI monitors, a switcher input,
  and a confidence feed straight from a presenter's laptop.
- **On-set / playback** — feed SDI client monitors and a recorder at true
  23.98/24 cadence from an editor's laptop.
- **Broadcast playout & signage** — a laptop becomes a two-output SDI source
  with frame rates that legalize cleanly downstream.

## What makes it different

| | Typical HDMI→SDI mini | This product |
|---|---|---|
| Host interface | HDMI (needs a separate dongle) | **USB-C DP Alt Mode, native** |
| Channels | 1 | **2 independent** |
| Appears to OS as | a display (via the dongle) | **two displays** |
| EDID control | fixed EEPROM | **managed, profile-selectable** |
| Frame-rate intent | passthrough | **EDID-forced broadcast rates** |
| Max per channel | usually 3G/6G | **12G (2160p59.94)** |

## Status

Concept / paper design. See [`docs/`](docs/) for the full design package.

## Document map

- [`docs/01-product-brief.md`](docs/01-product-brief.md) — positioning, target users, feature tiers, competitive landscape.
- [`docs/02-architecture.md`](docs/02-architecture.md) — system block diagram, signal path, link-bandwidth budget, power.
- [`docs/03-edid-framerate.md`](docs/03-edid-framerate.md) — the EDID + frame-rate management design (the core differentiator).
- [`docs/04-silicon-bom.md`](docs/04-silicon-bom.md) — candidate silicon for each block, with open sourcing risks.
- [`docs/05-roadmap.md`](docs/05-roadmap.md) — phased bring-up plan and prototype platform.
- [`docs/06-open-questions.md`](docs/06-open-questions.md) — unresolved decisions that gate the design.
</content>
</invoke>
