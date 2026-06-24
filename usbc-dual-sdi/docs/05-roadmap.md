# 05 — Roadmap & Bring-Up Plan

Top-down de-risking: prove the **hardest, highest-uncertainty** links first
(DP-Alt-Mode-to-two-streams, and clean 12G out), then integrate.

## Phase 0 — Paper design & sourcing de-risk
- Lock the **MST-hub-vs-FPGA-DP-RX** decision (`06` Q1) — this gates the whole
  topology.
- Confirm **DP Alt Mode 4-lane** behavior on the target laptop classes
  (MacBook, Dell/Lenovo USB-C, etc.) and whether each gives 4 lanes.
- Confirm **12G SERDES** availability/margin on the chosen FPGA.
- Power budget first-pass from real datasheet currents → decide bus-power vs
  aux-power-in.

## Phase 1 — One channel, eval boards
- Bench: USB-C → DP source into an **eval MST hub** (or FPGA DP-RX eval) →
  one HDMI/DP stream into an **FPGA dev board** → **SDI driver eval board** →
  scope / SDI analyzer on the BNC.
- Goal: **one clean 3G-SDI output** (1080p59.94) from a laptop, lock verified on
  an SDI analyzer / a real SDI monitor.
- Validate **embedded audio** (ST 299) and **ST 352 payload ID**.

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
</content>
