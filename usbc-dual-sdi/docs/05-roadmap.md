# 05 — Roadmap & Bring-Up Plan

> **Re-baselined 2026-10-13.** Bench platform is now the **Avnet AUBoard 15P**
> (AMD Artix UltraScale+ AU15P) — **ordered**. It matches the leading production
> FPGA family (`06` Q12) and lets us reuse Schindler's Vivado pipeline (`10`). The
> earlier PolarFire bench plan is kept at the bottom as the **fallback path** if
> Q12 swings back to PolarFire.

Baseline: hub → 2× video RX in the FPGA → SDI map + 12G-SDI TX (GTH) → driver →
2× BNC + MCU. **V1 is source-locked conversion — no frame buffer** (`02`
Clocking; `10` "v1 vs Pro"). De-risk the FPGA conversion and 12G output stage
first; hub sourcing runs in parallel.

## Bench platform

| Item | Role | Status |
|---|---|---|
| **Avnet AUBoard 15P** (`AES-AUB-15P-DK-G`, ~$699) | AU15P, 12× GTH, HDMI 2.0 RX+TX on GTH, 2 GB DDR4 (PL), SFP+ cage, FMC LPC (4 GTH), QSPI | **Ordered** |
| 12G-SDI egress — **SFP 12G-SDI TX module** (SFP+ cage) *or* **Nextera VIDIO 12G-X** FMC (~$1,495) | The board has no BNC. SFP module = likely cheapest; VIDIO is HPC-designed → **confirm lane map on AUBoard's LPC FMC with Nextera before buying** | **To decide** |
| AVMATRIX SC1221-12G (`09`) | Known-good 12G-SDI reference | On hand |
| 12G-SDI analyzer / monitor | Compliance + format/lock verification — non-negotiable | Rent / borrow |
| MeLE Quieter 4C or any 4K60 HDMI PC | HDMI 2.0 source | — |
| Zybo Z7-20 | Keeps Schindler 1080p pipeline work going | On hand |

## Phase 0 — Tooling, licenses, decisions (while the board ships)
- **Vivado:** install; **confirm the free edition covers AU15P**. Pull Avnet's
  AUBoard board files + reference designs.
- **AMD IP:** request **evaluation licenses** (hardware-timeout) for the **HDMI 2.0
  RX/TX Subsystem** and **SMPTE UHD-SDI**; ask for **production quotes** on both
  (+ DP-RX for the laptop variant) — feeds `06` Q12.
- **SDI egress:** price an SFP 12G-SDI TX module; ask Nextera about VIDIO 12G-X on
  the AUBoard FMC.
- **Schindler source branch:** confirm `v1-tsg` as the HDL port source (`10`).
- **Hub sourcing (parallel, `07`):** PS8650 / VMM5330 (DP out) or RTS5490 (USB4,
  Mac — `06` Q-MAC). Confirm **4-lane DP Alt Mode** on target laptops (`06` Q2).

## Phase 1 — Board bring-up (AUBoard)
1. Avnet reference design: board, JTAG, clocks, DDR4 alive.
2. **HDMI 2.0 in → HDMI out passthrough at 4K60** using AMD's HDMI subsystem
   example design (eval license).
3. Port Schindler **`pg_tsg`** (test-signal generator, `10`) as an internal source
   — widen to 2160p / 4 px/clk.

## Phase 2 — 12G-SDI TX on test patterns
- AMD **UHD-SDI TX** (eval license) on a GTH lane → SFP module (or VIDIO FMC) → BNC.
- Step up **3G → 6G → 12G** from the TSG; verify **ST 352**, format/lock, and the
  **12G eye/jitter** on the analyzer, side by side with the SC1221-12G.
- Work out **GTH reference clocking** for both 1.000 and 1.001 families (two refs or
  fractional — on the custom board this is the Si5392's job).

## Phase 3 — HDMI in → 12G-SDI out, source-locked (v1 core on the bench)
- HDMI RX → RGB→YCbCr, 4:4:4→4:2:2 10-bit, range (Schindler `color_matrix` /
  `color_correct`, widened) → SDI TX. **No frame buffer.**
- Lock the SDI TX clock to the **recovered source pixel clock** through a jitter
  cleaner (bench: board clocking / external Si539x EVB; product: Si5392). Verify
  zero frame drop/repeat across 23.98 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60.
- Embedded audio (ST 299).
- **This is the "smart SC1221" stepping stone (`10`)** — an HDMI→12G-SDI product
  path in its own right.

## Phase 4 — DP-RX + two channels + the real front-end hub (+ MST-vs-USB4)
- Replace HDMI RX with **DP-RX** (AMD DP RX Subsystem, license per Q12) fed from a
  DP source / hub. **Bench gap:** AUBoard has no DP connector — needs a DP FMC card
  or move to the custom board; *to resolve*.
- Instantiate the **second channel** (2× RX + 2× SDI TX); confirm **resource +
  timing fit** (AU10P vs AU15P — `10` follow-ups).
- Swap in the **production hub** (PS8650 / VMM5330, or RTS5490 for Mac).
- **Resolve `06` Q-MAC:** RTS5490 dock → two independent extended displays on a real
  M4/M5 Mac; check USB4-hub behavior on a plain DP-Alt-only PC.

## Phase 5 — EDID & frame-rate management (MCU)
- **EDID emulation** + profile store; **profile switching** with HPD re-assert across
  Win / macOS / Linux.
- Confirm profiles force **SDI-legal SMPTE rasters** (incl. 23.98 / 59.94) so the FPGA
  always sees convertible timing (source-locked — `02` Clocking).
- Optional **config app** (HID).

## Phase 6 — Integrated prototype PCB
- Single **6–8 layer** board: USB-C PD/Alt-Mode ctrl + DP-output hub + **FPGA per Q12**
  (Artix US+ AU10P/AU15P leading) + SPI flash + **Si5392** + 2× 12G driver + MCU.
  **DDR4 footprint reserved** (populated for Pro), REF-IN footprint reserved (`06` Q7).
- 12G layout to BNC simulated (return loss / ST 2082); power-sequencing per FPGA.
- Thermal + power validation (~6–10 W, confirm with the vendor power estimator);
  compact box, 2× BNC, USB-C, status LEDs.

## Phase 7 — Smart / Pro variant
- Same FPGA + **DDR4 frame buffer + asynchronous output clock** → **active FRC**
  (60.00→59.94, 50↔60), **color/range**, **genlock to house reference**, and
  **multiview** — **ported from Schindler** (`pg_cadence`, `pg_genlock`, scaler,
  `pg_compose`, `pg_osd`; `10`), widened to 4 px/clk 10-bit 4:2:2. Needs MIG DDR4 +
  MicroBlaze(-V) on Artix US+. Firmware/stuffing upgrade, not a redesign.

## Fallback: PolarFire bench path *(only if `06` Q12 picks PolarFire)*
- `MPF300-VIDEO-KIT-NS` (Newark #66AH4313) + `VIDEO-DC-SDI` (12G FMC) + `VIDEO-DC-DP`
  (DP FMC). ⚠️ One HPC FMC slot — the two FMCs swap, not coexist, so DP-4K60-in →
  12G-out is not benchable end-to-end on one kit.
- Free 12G-SDI IP + **DG0889** reference design; Phase-1 HDMI→3G via the kit's HDMI 2.0
  input (HDMI-RX caps at **4K30**); $40 Plugable USBC-MSTH2 MST adapter for early
  dual-display tests.
- Schindler modules would need re-porting to Libero (`10`).

## Definition of done (v1)
Two BNCs, two independent broadcast-legal SDI outputs up to 2160p59.94 4:2:2
10-bit, from one USB-C cable, presenting as two displays (Windows via MST / Mac
via USB4), with EDID profiles that reliably force broadcast-legal resolution/
frame rate — verified on an SDI analyzer and real downstream gear. Conversion in
the FPGA chosen by `06` Q12, **source-locked (no frame drop)**.
