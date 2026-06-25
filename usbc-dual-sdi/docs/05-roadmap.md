# 05 — Roadmap & Bring-Up Plan

Baseline = the **PolarFire FPGA design** (`02`, `04`): DP-output hub → 2× DP-RX in
a PolarFire MPF300 → SDI map + free 12G-SDI IP → GS12281 drivers → 2× BNC + MCU.
This is real FPGA/HDL work, but the IP is free and there's a reference design.
De-risk the FPGA conversion first (it has the new unknowns); hub sourcing runs in
parallel.

## Phase 0 — Tooling, IP, and the bench
- **Order the kit:** `MPF300-VIDEO-KIT-NS` (Newark #66AH4313) **+ `VIDEO-DC-SDI`
  SDI FMC** (12G; kit's on-board SDI is HD/3G only) **+ `VIDEO-DC-DP` DisplayPort
  FMC** (DP-in for 4K60; the kit has no DP connector). ⚠️ The kit has **one** HPC
  FMC slot — the two FMCs swap, not coexist (see Phase 2).
- **Install Libero**; pull the **free 12G-SDI IP** + **DG0889** 12G-SDI reference
  design; identify the **DP-RX IP** (Microchip CoreDP-RX or Bitec) and **confirm
  its license cost** (`06` Q0b).
- **Hub sourcing (parallel, `07`):** chase a **DP-output** hub — **Parade PS8650**
  (Avnet quote pending) / **VMM5330**; **RTS5490** USB4 hub if Mac independent-dual
  is a target (`06` Q-MAC). HDCP not needed — configure DP-RX as non-HDCP sink
  (`06` Q11).
- Confirm **DP Alt Mode 4-lane** behavior across target laptops (`06` Q2).

## Phase 1 — Single-channel conversion on the video kit (HDMI → 3G first)
Prove the SDI chain cheaply before touching DP-RX or 12G.
- Bench: a **$40 USB-C→dual-HDMI MST adapter** (Plugable USBC-MSTH2) → the video
  kit's **HDMI 2.0 input** → PolarFire (HDMI-RX IP) → SDI map → on-board **3G-SDI**
  out → SDI analyzer / known-good monitor. (HDMI-RX caps at 4K30, fine for now.)
- Goal: **one clean 1080p59.94 / 3G-SDI** output, lock + format verified,
  **embedded audio (ST 299) + ST 352 payload** confirmed — the whole pipeline in
  FPGA fabric.

## Phase 2 — 12G + break the 4K30 cap (move input to DP-RX)
- Add the **`VIDEO-DC-SDI` FMC** → push the SDI TX to **2160p / 12G** via the free
  SDI IP; validate the **12G eye/jitter** out of the GS12281 over real coax. Drive
  it from an **internal 2160p60 test-pattern generator** so the 12G-TX half is
  provable **without** a 4K60 input.
- **Bring up the DP-RX path** with the **`VIDEO-DC-DP` DisplayPort FMC** (Microchip,
  Bitec-based): plug a DP cable into the FMC → DP lanes → PolarFire transceivers
  (DisplayPort RX IP, HBR3/SST) → **4K60** capture; verify via frame readback or
  the on-board HDMI TX.
- ⚠️ **One HPC FMC slot:** `VIDEO-DC-DP` and `VIDEO-DC-SDI` **can't co-reside**, so
  the full **DP-4K60-in → 12G-SDI-out** chain is **not** benchable on the single
  kit — validate the two **halves separately** (above), then integrate on the
  custom board (Phase 5). Production has no FMC: hub DP → transceiver pins
  directly; transceivers → GS12281 → BNC.

## Phase 3 — Two channels + the real front-end hub (+ MST-vs-USB4)
- Instantiate the **second channel** (2× DP-RX + 2× SDI-TX); confirm **resource +
  timing fit** in MPF300 (300K LE) — the diligence gate (`06` Q0b).
- Swap the adapter for the **chosen production hub** (DP-output: PS8650/VMM5330; or
  RTS5490 for Mac).
- **Resolve `06` Q-MAC (defining):** if Mac broadcast is a target, get an
  **RTS5490 dock and verify two-independent extended displays on a real M4/M5
  Mac**; check USB4-hub behavior on a plain DP-Alt-only PC.

## Phase 4 — EDID & frame-rate management (MCU / Mi-V)
- Bring up **EDID emulation** + profile store; validate **profile switching** with
  HPD re-assert across Win / macOS / Linux.
- Confirm EDID profiles force **SDI-legal SMPTE rasters** (incl. fractional
  23.98 / 59.94) so the FPGA always sees convertible timing (source-locked, no
  frame drop — `02` Clocking).
- Ship the optional **config app** (HID).

## Phase 5 — Integrated prototype PCB
- Single **6–8 layer** board: USB-C PD/Alt-Mode ctrl + DP-output hub + **PolarFire
  MPF300 + DDR4 + SPI flash** + Si534x + 2× GS12281 + MCU (or Mi-V). No SOM.
- Thermal + power validation (~6–10 W, confirm via Libero power estimator);
  compact box, 2× BNC, USB-C, status LEDs.

## Phase 6 — Smart / Pro variant (later)
- Same FPGA. Add a **DDR frame buffer + asynchronous output clock** for **active
  frame-rate conversion** (60.00→59.94, 50↔60), **color/range processing**, and
  **genlock to house reference** (REF-IN BNC). Firmware/stuffing upgrade, not a
  redesign — Schindler's Mini/Pro split.

## Suggested prototype platforms
- **Conversion:** **MPF300-VIDEO-KIT-NS + VIDEO-DC-SDI FMC** (Microchip) — the
  core bench; free 12G-SDI IP + DG0889 reference.
- **Front end:** $40 USB-C→dual-HDMI MST adapter (HDMI, for Phase-1 ≤4K30); real
  DP-output hub / DP source for 4K60.
- **Analyzer:** SDI signal analyzer or known-good 12G SDI monitor — non-negotiable.

## Definition of done (v1)
Two BNCs, two independent broadcast-legal SDI outputs up to 2160p59.94 4:2:2
10-bit, from one USB-C cable, presenting as two displays (Windows via MST / Mac
via USB4), with EDID profiles that reliably force broadcast-legal resolution/
frame rate — verified on an SDI analyzer and real downstream gear. Conversion in
a **PolarFire FPGA** (free SDI IP), source-locked (no frame drop).
</content>
