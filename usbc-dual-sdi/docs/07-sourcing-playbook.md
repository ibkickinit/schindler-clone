# 07 — Sourcing & Bench Playbook

> Concrete "what to order and how to get it" for the **decided architecture**
> (`02`/`04`/`06` Q0): **discrete DP-output hub → PolarFire FPGA (DP-RX + free
> 12G-SDI IP) → GS12281 → BNC.** Prices/stock marked *unverified* were
> search-snippet-derived (distributor pages 403 the crawler) — confirm on the cart.

## What's easy vs hard to source

- **Easy (off-the-shelf, stocked):** the **PolarFire FPGA** and its **dev kit +
  FMCs**, the **GS12281** SDI driver, the **TPS65987D** PD/Alt-Mode controller,
  the **STM32** MCU, and a **$40 MST adapter** for early bring-up.
- **Hard (design-win channel):** the **DP-output hub** (Parade PS8650, Synaptics
  VMM5330, Realtek RTS5490) — all sold to dock/monitor OEMs, not openly stocked.
  This is the one sourcing thread that needs a vendor conversation. Mitigated for
  *development* by the off-the-shelf adapter (you don't need the production hub to
  start).

## Bench shopping list (order to start)

| Item | Part | Where | ~Cost | Purpose |
|---|---|---|---|---|
| FPGA dev kit | `MPF300-VIDEO-KIT-NS` | Newark #66AH4313 | ~$1–1.5k | MPF300T + DDR4; HDMI 2.0 + HD/3G SDI on-board |
| SDI FMC | `VIDEO-DC-SDI` | Microchip | — | adds **12G-SDI** (kit on-board SDI is HD/3G) |
| DP FMC | `VIDEO-DC-DP` | Microchip (Bitec) | — | **DP-RX 4K60 input** (kit has no DP jack) |
| MST adapter | Plugable **USBC-MSTH2** | Amazon | ~$40 | early HDMI-in bring-up (≤4K30) |
| Analyzer | 12G SDI analyzer / known-good monitor | — | — | SDI compliance — non-negotiable |

⚠️ The kit has **one** HPC FMC slot → the SDI and DP FMCs **swap, not coexist**;
validate the 12G-TX and DP-RX halves separately, integrate on the custom board
(`05` Phase 2).

> Note: the dev kit uses the 300K-LE MPF300T; **production uses the cheaper
> MPF200T-FCG484I ($286)** — see below. The kit is for bring-up + the free
> reference design (DG0889), not the production part.

## Production silicon

| Block | Part | Obtainable | ~Price | Note |
|---|---|---|---|---|
| FPGA | **MPF200T-FCG484I** (MPF100T cost-down if it fits) | DigiKey, stocked | **$286** / $174 | free 12G-SDI IP; DP-RX IP TBD (`06` Q0b) |
| Front-end hub (DP out) | **Parade PS8650** / Synaptics VMM5330 / **RTS5490** (USB4/Mac) | design-win channel | hub cost | the one hard part — see below |
| SDI driver ×2 | Semtech **GS12281-INE3** | DigiKey, stocked | ~$31 ea | reclocking; after FPGA TX |
| Ref clock | Skyworks **Si534x** | stocked | ~$3–8 | transceiver reference |
| USB-C PD/DP | TI **TPS65987D** (+ CCG3PA port 2) | stocked (*unverified*) | ~$5–8 | DP Alt / USB4 + PD sink |
| MCU | ST **STM32** (or soft Mi-V) | stocked | ~$3–12 | EDID + HID |

## The hub — the one design-win conversation

DP-output MST/USB4 hubs are sold to dock OEMs, not on DigiKey. Chase in parallel
with the build (the adapter unblocks development):
- **Parade PS8650** (`PS8650BGA274GTR-A0`) — **Avnet (US) quote requested
  2026-06-24, pending**; samples/EVB via support@paradetech.com / Macnica.
- **Synaptics VMM5330** — datasheet in hand (vault); quote via Synaptics FAE.
- **Realtek RTS5490** (USB4) — only if Mac independent-dual is a target (`06`
  Q-MAC); verify on a real M4/M5 Mac before committing.

## Concrete links / contacts
- Microchip **MPF300-VIDEO-KIT-NS** (Newark #66AH4313); FMCs **VIDEO-DC-SDI**,
  **VIDEO-DC-DP**; 12G-SDI IP + demo **DG0889** — microchip.com.
- FPGA **MPF200T-FCG484I** / **MPF100T-FCG484I** — DigiKey.
- **Bitec** DP IP / DP FMC — bitec-dsp.com.
- **Parade PS8650** — support@paradetech.com / Avnet Americas / Macnica.
- Plugable **USBC-MSTH2** — amazon.com (~$40).

## Open verifications (carry-forward)
- **DP-RX IP license** cost (Microchip CoreDP-RX or Bitec); 12G-SDI IP confirmed
  free.
- **2-channel logic fit** in MPF200T (port-down to MPF100T) — `06` Q0b.
- **DP-output hub** live stock/quote (PS8650 via Avnet; VMM5330).
- **RTS5490 + macOS** two-independent on a real M4/M5 Mac — `06` Q-MAC.
- Live distributor stock/qty for the FPGA, GS12281, TPS65987D.

## One-line next action
**Order `MPF300-VIDEO-KIT-NS` + `VIDEO-DC-SDI` + `VIDEO-DC-DP` + a $40 Plugable
adapter; in Libero pull the free 12G-SDI IP + DG0889 and price the DP-RX IP** —
that gets the whole conversion bench running while the hub quote (Avnet/PS8650)
proceeds in parallel.
</content>
