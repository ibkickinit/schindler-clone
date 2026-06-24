# 05 — Roadmap & Bring-Up Plan

Top-down de-risking: prove the **hardest, highest-uncertainty** links first
(DP-Alt-Mode-to-two-streams, and clean 12G out), then integrate.

## Phase 0 — Paper design & sourcing de-risk
- **Resolve the MST option (`06` Q1) — but it no longer blocks dev (see Phase 1).**
  Price the cheapest-first options in parallel: discrete hubs **Parade
  PS8650BGA274GTR-A0** (Avnet quote **requested 2026-06-24, pending**), **Synaptics
  VMM6210/5330** (datasheet in hand), **Realtek RTD2186**; and the in-FPGA IP
  routes **Intel** DP-MST + SDI II and **Parretto/Bitec MST IP on PolarFire**.
  Default to **discrete hub + PolarFire (no IP NRE)**; AMD only as last resort.
- **Only if forced to Family B:** quote **Intel** and **Parretto/Bitec** before
  AMD; if AMD, confirm **eval/timeout licenses** carry Phases 1–4 (`06` Q10).
  **HDCP entitlement is not needed** on any route — non-HDCP-sink (`06` Q11).
- **HDCP:** confirm the chosen DP/HDMI RX silicon (incl. VMM6210, which has
  HDCP 2.3) can be **provably unprovisioned** so the box is not an HDCP sink.
- Confirm **DP Alt Mode 4-lane** behavior on the target laptop classes
  (MacBook, Dell/Lenovo USB-C, etc.) and whether each gives 4 lanes (`06` Q2).
- Confirm the chosen **Zynq US+ package exposes ≥4 GTH at 12.5G** (package
  selection is the gotcha).
- Validate the **power budget** (~10–15 W) against Xilinx Power Estimator →
  confirms PD is required and sizes the secondary power port (`04` Block 6).
- **Live-verify distributor stock/price** for GS12281, TPS65987D, STM32H723,
  Si534x (the research was 403-blocked from live carts).

## Phase 1 — One channel, SDI-first (decoupled from MST sourcing)
**Key insight: MST is the *last* thing you need.** The "twin output" rung needs
no MST, so bring up the hard part (the SDI chain) from a single ordinary display
first, using an off-the-shelf front end — the MST-hub sourcing thread (`06` Q1)
runs in parallel and blocks nothing here.
- **Front end = a commercial USB-C→dual-HDMI MST adapter** (StarTech
  **MST14CD122HD** or Plugable **USBC-MSTH2**) tapped into the FPGA HDMI RX —
  gives two clean independent 4K60 HDMI streams *today*, no bare MST silicon
  needed. Caveats: drive it from a **Windows/Linux** laptop with **DP1.4 + DSC +
  HBR3** (macOS mirrors only; non-DSC hosts drop to 4K30); **don't** buy a
  DisplayLink dock by mistake.
- Bench: that adapter → **FPGA dev board** (PolarFire eval, or **AMD ZCU102** if
  validating a real DP-MST sink) → **SDI driver eval board** → scope / SDI
  analyzer on the BNC.
- Goal: **one clean 3G-SDI output** (1080p59.94) from a laptop, lock verified on
  an SDI analyzer / real SDI monitor.
- Validate **embedded audio** (ST 299) and **ST 352 payload ID**.
- Note: the off-the-shelf adapter *bypasses* (doesn't validate) our own MST sink —
  that validation comes in Phase 3 on the real front end (ZCU102 ships a
  4-stream-over-one-DP MST example for exactly this).

## Phase 2 — One channel at 12G
- Push the same path to **2160p59.94 4:2:2 10-bit / 12G-SDI**.
- Add **reclocker** if the 12G eye fails compliance.
- Validate over real 12G coax lengths.

## Phase 3 — Two channels
- Bring up **both** DP streams (MST) and **both** SDI pipelines on the FPGA
  simultaneously. This is where the **link-bandwidth budget** (`02`) gets
  stress-tested — confirm dual-4K60 4:2:2 holds on 4-lane HBR3.
- Validate independent formats per output (e.g. ch1 2160p23.98, ch2 1080p59.94).

## Phase 4 — EDID & frame-rate management
- Bring up **EDID emulation** + profile store on the MCU.
- Validate **profile switching** with HPD re-assert across Win / macOS / Linux.
- Characterize **fractional-rate reliability** (23.98 / 59.94) per OS — this
  measurement decides how badly Tier-2 active FRC is needed.
- Ship the **config app** (HID) as a fast-follow.

## Phase 5 — Integrated prototype PCB
- Single carrier: PD/Alt-Mode ctrl + MST/DP-RX + FPGA + 2× SDI driver + MCU.
- Thermal + power validation under dual-4K60 load.
- Mechanical: compact box, 2× BNC, USB-C, status LEDs/OLED.

## Phase 6 — Tier-2 reserve (Pro / v2)
- Stuff **DDR + REF-IN**; bring up **active FRC** + genlock.
- Only after v1 ships and demand for true 60.00→59.94 / cross-region conversion
  is confirmed.

## Suggested prototype platforms
- **DP source / MST:** USB-C → dual-HDMI MST dock as a behavioral reference;
  MST-hub or DP-RX eval board for the real path.
- **FPGA:** an Artix/Zynq UltraScale+ board with **GTH/GTY at ≥12G** and SDI FMC
  (e.g. an SDI FMC mezzanine) — the SDI subsystem IP + DP/HDMI IP run here.
- **SDI:** vendor **12G-SDI driver/equalizer eval boards** (Semtech / TI) on the
  BNC side.
- **Analyzer:** an SDI signal analyzer (or a known-good 12G SDI monitor) for
  lock/format/eye validation — non-negotiable for SDI compliance work.

## Definition of done (v1)
- Two BNCs, two independent broadcast-legal SDI outputs up to 2160p59.94 4:2:2
  10-bit, from one USB-C cable, presenting as two displays, with selectable EDID
  profiles that reliably force the advertised resolution/frame rate on the major
  OSes — verified on an SDI analyzer and real downstream gear.
