# 08 — Player Variant (mini PC + native SDI)

> **Status: CONCEPT — banked 2026-10-10, nothing decided.** Captures a discussion
> on pairing the Crossover conversion core with a mini PC (MeLE-class) so the
> product becomes a **player/PC with native SDI copies of its screens**, instead
> of a laptop accessory. Nothing here changes the v1 laptop design (`01`–`07`).

## The idea

Ship the host. A small fanless x86 PC (Intel N100/N150-class) drives the
PolarFire conversion core directly, so the box is a self-contained playback /
graphics / test-pattern machine whose screens come out as 12G-SDI.

## Why owning the host matters

Most of Crossover's open risk lives in the USB-C link to an **unknown laptop**.
Owning the PC removes most of it:

| Laptop-variant problem | With our own PC |
|---|---|
| macOS mirrors over MST (`06` Q-MAC — the defining fork) | **Gone** — we choose OS + GPU |
| GPU may ignore EDID-forced 23.98 / 59.94 → optional helper app (`03`, `06` Q4) | **Gone** — exact modes baked into the shipped OS image |
| Host may grant only 2-lane DP Alt Mode (`06` Q2) | **Gone** — fixed, known platform |
| MST / USB4 hub sourcing (`04` Block 2, `07`) | **Gone** in the integrated build (Option C) |
| Per-laptop support matrix | One platform |

**Unchanged:** genlock and true frame-rate conversion still need the Pro DDR
frame buffer + asynchronous output clock (`02` Future) — a PC iGPU cannot lock
to house reference. **New:** thermal — N100-class host ~6–10 W plus the FPGA
side ~6–10 W = **~12–20 W** in a small chassis.

## Three build options

### A. Piggyback — Crossover v1 bolted to a stock MeLE (demo / bench)
Bracket + one short USB-C jumper; zero new electronics.
- **Pros:** fastest path to a working demo; reuses v1 unchanged.
- **Cons:** consumer-PC SKU churn, no board docs or lifecycle guarantee; two
  boxes / two power paths; a hot box against a chassis-cooled fanless PC.
- **Verdict:** demo and bench proof, **not** a product.

### B. New chassis, PC's HDMI outputs → HDMI-input board variant
Short internal HDMI jumpers from the PC into a Crossover variant with HDMI inputs.
- ⚠️ PolarFire **HDMI-RX IP caps at 4K30** (`06` Q0a). 4K60 needs an external
  HDMI 2.0 receiver (Lontium **LT6911**-class → FPGA MIPI-RX, *unverified*) or an
  HDMI→DP stage.
- Still depends on a consumer PC. **Generally not recommended** — but see the
  Quieter 4C note below: it is the natural fit for that specific PC.

### C. Integrated — x86 compute module on our own carrier (recommended product path)
Use a **compute module** instead of a finished mini PC, with the FPGA on the same
carrier board.
- Candidates: **LattePanda Mu** (N100/N305, open carrier reference design,
  display interfaces on the edge connector) or **SMARC / COM Express Mini x86**
  (Kontron, congatec — industrial lifecycle, higher cost).
- iGPU DisplayPort lanes route **on-board** straight into the PolarFire DP-RX —
  no cables, **no MST/USB4 hub, no USB-C PD/Alt-Mode controller, no Mac fork**.
- EDID emulation can likely fold into the Mi-V soft core (we own both ends).
- N100-class iGPU drives **3 displays**, which maps cleanly to:
  - **Display 1** → rear-panel HDMI (operator UI).
  - **Displays 2 + 3** → FPGA → **2× 12G-SDI** program outputs.
- **Costs:** bigger board (host + FPGA + ~20 W power tree), a fan or
  heatsink-as-chassis, and an OS image to maintain.
- ⚠️ Verify per module: display count, which DDI ports reach the connector, and
  whether they come out as DP (needed for 4K60 into the DP-RX) or HDMI.

## Candidate MeLE hosts (for Option A / bench)

Specs are from third-party listings, which **disagree** in places — confirm
against the exact SKU/revision before buying.

| | **Quieter 4C** | **PCG02** (stick) |
|---|---|---|
| CPU | N100 (later refresh: N150) | N100 (older: J4125) |
| Video | **2× HDMI 2.0 (4K60) + DP 1.4 via USB-C** — up to 3 displays | Sources conflict: 1× HDMI 2.0 + USB-C w/ DP Alt, **or** 2× HDMI with data-only USB-C |
| USB-C | One "full-function" port: data 10 Gb/s + **display + PD power input** | Separate PD power-in USB-C |
| Size | 131 × 81 × 18.3 mm, fanless | stick form factor, fanless |

**Gotchas found:**
1. **Quieter 4C — power and video share one USB-C port** (per listings). If we
   take DP from it for a piggyback, Crossover must also *supply* PD power to the
   PC through that port (power-source role, not just sink). Changes the PD
   controller design. **Verify** whether a separate power input exists.
2. **USB-C on both is 10 Gb/s USB 3.2 Gen 2** — with USB 3 active, DP Alt Mode is
   very likely **2-lane** (~12.96 Gb/s usable), enough for one 4K60 4:2:2 *or*
   two 1080p59.94 via MST, **not** dual-4K60. **Measure.**
3. **Quieter 4C's two HDMI 2.0 outputs are its best video path** — 4K60 each,
   no USB-C involvement. That makes **Option B** (HDMI-input board) the natural
   match for *this* PC, subject to the 4K30 HDMI-RX cap above.
4. **PCG02 port layout is ambiguous** across sources (and the PCG02 Pro is a
   different model: 2× HDMI 2.1 + 10 Gb/s USB-C). Pin the exact SKU first.

## Product positioning (to validate)

A laptop accessory competes on price with ~$1,100–1,200 Blackmagic/AJA boxes. A
**player with native SDI** is a different category — playback, show clocks,
test patterns, graphics — and the show-app.com tools (videoloop, showclock,
testpattern, colorbars) are ready-made software for it. **Market check needed**
against HyperDeck-class SDI players and Mac + UltraStudio + QLab/Millumin rigs
before assuming white space.

## Suggested sequencing

1. **Bench:** Quieter 4C (or any mini PC with DP out) → PolarFire video kit
   (`05` Phases 1–2). Proves the PC side with no new hardware.
2. **Demo:** Option A piggyback (or B with the Quieter 4C's HDMI outs).
3. **Product:** Option C as its own SKU in the family ("Crossover Player",
   placeholder), sharing the FPGA conversion core with the laptop variant.

## Open questions

- **P1** — Which host: stock MeLE (A/B) for demos only, or commit to a compute
  module (C)? Which module?
- **P2** — Quieter 4C: separate power input, or USB-C only? DP Alt lane count
  with USB 3 active?
- **P3** — PCG02: exact SKU and port layout.
- **P4** — OS image: Windows IoT vs Linux; who owns updates.
- **P5** — Thermal: fanless heatsink chassis at ~20 W, or accept a fan?
- **P6** — Is the player a separate SKU or the Pro model of Crossover?

## Sources (MeLE specs)

- [CNX Software — MeLE Quieter4C](https://www.cnx-software.com/2023/12/05/mele-quieter4c-ultrathin-fanless-intel-n100-mini-pc-supports-up-to-three-displays/)
- [Starry Hope — MeLE Quieter 4C](https://www.starryhope.com/minipcs/models/mele-quieter-4c/)
- [Liliputing — MeLE Quieter 4C review](https://liliputing.com/mele-quieter-4c-review/)
- [YPC — Quieter 4C listing](https://www.ypc.co.uk/product/mele-fanless-mini-pc-quieter-4c-n100-8gb-128gb-no-os-inside-support-multi-os-linux-ubuntu-win11-pro-home-micro-computer-hdmi-full-functioned-usb-c-pd3-0-for-iot-office-industrial-business/)
- [Starry Hope — MeLE PCG02](https://www.starryhope.com/minipcs/models/mele-pcg02/)
- [Starry Hope — MeLE PCG02 Pro](https://www.starryhope.com/minipcs/models/mele-pcg02-pro)
- [Liliputing — PCG02](https://liliputing.com/?p=175031)
