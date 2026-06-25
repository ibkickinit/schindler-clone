# 05 — Roadmap & Bring-Up Plan

Baseline = the **dumb/fixed-function design** (`02`, `04`): MST hub → 2× GS12170
HDMI→SDI bridge → 2× BNC + MCU. No FPGA, no Vivado/Quartus, no IP licensing.
De-risk the two real unknowns first: **the GS12170 conversion block** and **MST
hub sourcing** (decoupled — see Phase 1).

## Phase 0 — Paper design & sourcing de-risk
- **GS12170 — order the HDMI→SDI RDK + confirm lifecycle.** The right eval/
  reference vehicle is **`RDK-GS12170-H2S00`** (HDMI→SDI flavor; Newark #90AJ5039,
  Symmetry, Utmel) — a **complete reference design** containing the HDMI redriver
  + GS12170 + external PLL + GS12281 cable driver + BNC. Order **two** (one per
  channel). Its **schematic + BOM is the gen-1 conversion-subsystem reference** —
  it specifies the exact PLL/redriver/driver parts, so the real PCB is "adapt the
  RDK + add MST hub + MCU," not design SDI from scratch. (Other flavors: `-S2H00`
  SDI→HDMI, `-S2S00` gearbox — not ours.) Separately ask Semtech the **EOL/NRND**
  question (`06` Q0); if EOL, pivot to the small-FPGA fallback.
- **MST sourcing — follow `07-sourcing-playbook.md`.** Buy a **Plugable
  USBC-MSTH2 (~$40, Amazon)** now as the prototype front end; chase a production
  hub in parallel (**Parade PS8650** Avnet quote pending; **VMM6210** datasheet in
  hand; **RTD2186**). HDCP not needed (`06` Q11).
- **HDCP:** confirm the MST hub (incl. VMM6210, which has HDCP 2.3) can be
  **provably unprovisioned** so the chain passes unencrypted TMDS into the
  GS12170 (which has no HDCP).
- Confirm **DP Alt Mode 4-lane** behavior across target laptops (`06` Q2).
- **Live-verify distributor stock/price** for GS12170, GS12281, HDMI redriver,
  TPS65987D, STM32 (403-blocked in research).

## Phase 1 — One channel, SDI-first (decoupled from MST sourcing)
**MST is the *last* thing you need.** Bring up the conversion from a single
ordinary display first; MST-hub sourcing runs in parallel and blocks nothing.
- **Front end = a $40 commercial USB-C→dual-HDMI MST adapter** (Plugable
  USBC-MSTH2 / StarTech MST14CD122HD) — two clean independent 4K60 HDMI streams
  today, no bare MST silicon. Drive from a **Windows/Linux** laptop with **DP1.4 +
  DSC + HBR3** (macOS mirrors only; non-DSC hosts drop to 4K30); **don't** buy a
  DisplayLink dock.
- Bench: adapter HDMI out → **`RDK-GS12170-H2S00`** (the RDK already *is* the
  redriver → GS12170 → PLL → GS12281 → BNC chain) → scope / SDI analyzer (or a
  known-good 12G SDI monitor). One RDK per channel.
- Goal: **one clean SDI output** (start at 1080p59.94 / 3G) from a laptop, lock +
  format verified, **embedded audio + ST 352 payload** confirmed — all from the
  GS12170, no FPGA.

## Phase 2 — One channel at 12G
- Push the same path to **2160p59.94 4:2:2 10-bit / 12G-SDI** through the GS12170.
- Validate the **12G eye / jitter** out of the GS12281 over real coax lengths.

## Phase 3 — Two channels + the real front-end hub (+ the MST-vs-USB4 decision)
- Add the **second GS12170 channel**, and swap the off-the-shelf adapter for the
  **chosen production hub**.
- **Resolve `06` Q-MAC (defining):** MST hub (VMM6210/PS8650/RTD2186 — Windows-
  independent, Mac-mirror) **vs USB4 hub (Realtek RTS5490 — Mac+Windows
  independent, still no FPGA).** If Mac broadcast is a target, **get an RTS5490
  dev/dock and verify two-independent extended displays on a real M4/M5 Mac**, and
  check USB4-hub behavior on a plain DP-Alt-only PC.
- Stress the **link-bandwidth budget** (`02`); validate independent formats per
  output.

## Phase 4 — EDID & frame-rate management (MCU)
- Bring up **EDID emulation** + profile store on the MCU; validate **profile
  switching** with HPD re-assert across Win / macOS / Linux.
- Confirm the EDID profiles reliably force **SDI-legal SMPTE rasters** (incl.
  fractional 23.98 / 59.94) so the GS12170 always sees convertible timing.
- Ship the optional **config app** (HID).

## Phase 5 — Integrated prototype PCB
- Single 4–6 layer board: USB-C PD/Alt-Mode ctrl + MST hub + 2× (redriver +
  GS12170 + GS12281) + MCU. **No FPGA, no DDR, no SOM.**
- Thermal + power validation (~6–9 W); mechanical: compact box, 2× BNC, USB-C,
  status LEDs.

## Phase 6 — Pro / smart variant (only if demand appears)
- Replace the two GS12170 bridges with an **FPGA + DDR** for **active frame-rate
  conversion**, color processing, and **genlock to house reference** (REF-IN
  BNC). Same front end (USB-C + MST hub + MCU). Mirrors Schindler's Mini/Pro
  split. Only after v1 ships and the demand for true 60.00→59.94 / cross-region
  conversion is real.

## Suggested prototype platforms
- **MST front end:** off-the-shelf USB-C→dual-HDMI MST adapter (Plugable/StarTech).
- **Conversion:** **GS12170 + GS12281 eval boards** (Semtech) — the core bench.
- **HDMI redriver:** vendor eval/redriver breakout.
- **Analyzer:** an SDI signal analyzer or known-good 12G SDI monitor — non-
  negotiable for SDI compliance.

## Definition of done (v1)
Two BNCs, two independent broadcast-legal SDI outputs up to 2160p59.94 4:2:2
10-bit, from one USB-C cable, presenting as two displays, with selectable EDID
profiles that reliably force broadcast-legal resolution/frame rate on the major
OSes — verified on an SDI analyzer and real downstream gear. **All fixed-function
— no FPGA.**
</content>
