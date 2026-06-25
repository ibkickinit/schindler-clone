# 07 — MST Front-End Sourcing Playbook

> **Why this doc exists:** the MST options had piled up and *none of the discrete
> hub chips are actually small-shop-buyable* — they're NDA/design-win parts sold
> to dock/monitor OEMs. That frustration is correct and structural. This doc
> stops the option-sprawl and gives **one prototype path + one production track**,
> with concrete next actions. Distributor stock / prices / IP-tier costs marked
> *unverified* were search-snippet-derived (live pages 403-blocked) — confirm in
> a cart / with a rep before committing.

## The reframe that un-sticks it

**Don't shop for discrete MST silicon.** Split the problem:
- **Prototype (this week, ~$40 + a video kit):** a commodity USB-C→dual-HDMI MST
  adapter offloads the entire MST hub to a $40 part; feed its two HDMI streams
  into an FPGA HDMI-RX and build the *actual hard part* (HDMI/DP-RX → 12G-SDI-TX).
- **Production (parallel, weeks):** pursue **one** FPGA+IP silicon track. Don't
  chase NDA-gated hub chips.

## Ease-of-sourcing ranking (easiest first)

| Option | Ease | Fastest hands-on | ~Cost to first bench |
|---|---|---|---|
| **Off-the-shelf MST adapter → FPGA HDMI-RX** | **Easy** | StarTech MST14CD122HD / Plugable USBC-MSTH2 on Amazon | **~$40** + FPGA board |
| AMD Zynq US+ (ZCU102) + DP1.4 RX + UHD-SDI IP | Medium | Buy ZCU102 on DigiKey; eval IP in Vivado | ~$3.0–3.7k board |
| **Microchip PolarFire Video Kit + Parretto MST IP + free SDI IP** | Medium | Buy MPF300-VIDEO-KIT-NS on DigiKey; clone Parretto from GitHub | ~$1.0–1.5k board |
| Intel Cyclone 10 GX + DP IP + SDI II IP | Medium | C10GX dev kit via Altera eStore/DigiKey; OpenCore Plus eval | ~$3k+ board |
| Parade PS8650 (discrete) | Medium-Hard | Email Parade/Macnica for samples + EVB | samples free-ish; EVB *unverified* |
| Synaptics VMM6210/5330 (discrete) | Hard | FAE / design-win only; NDA datasheet | gated, no easy path |
| Realtek RTD2186 (discrete) | Hard | LCSC/broker for chip; config tooling NDA-gated | chip cheap but a brick w/o tooling |
| Analogix ANX6470 (discrete, DP1.2) | Very hard | vendor sales only; legacy | gated **+ DP1.2-marginal → drop** |

## ▶ The recommendation

### Prototype — do this now (~$40 + a video kit, zero NDA)
1. **Buy a Plugable USBC-MSTH2 (~$39.95, Amazon) today** + a StarTech MST14CD122HD
   as backup. Both are *true MST* hubs that present **two independent** 4K60
   displays (not mirrored) — provided the host does MST. **Test on a Windows/Linux
   laptop with DP1.4 + DSC + HBR3** (macOS mirrors only; weak hosts drop to 4K30).
2. Feed each HDMI output into an **FPGA HDMI2.0-RX**. Cheapest board that also has
   a 12G-SDI-TX path: **Microchip MPF300-VIDEO-KIT-NS** (HDMI2.0 + SDI on one
   PolarFire kit, DigiKey-stocked). If you're already an AMD shop, **ZCU102** is
   the most turnkey but ~$3.5k.
3. This proves the **HDMI/DP-RX → 12G-SDI-TX** core — the real engineering —
   with no MST silicon, no sample request, no IP license. The $40 adapter *is*
   your prototype front end.

### Production — the decided architecture (`02`, `04`, `06` Q0)
**Discrete DP-output hub + PolarFire conversion.** *Not* MST-in-FPGA — the hub
does the split; the FPGA does **DP-RX (SST) + free 12G-SDI IP**. This is simpler
and cheaper than the Parretto/AMD MST-in-FPGA routes.
- **Conversion: Microchip PolarFire MPF300** — 12G-SDI IP **free** (Libero), DP-RX
  IP (CoreDP/Bitec), dev kit + DG0889 reference. **Use the DP-RX path for 4K60**
  (HDMI-RX caps at 4K30). Confirm DP-RX IP license + 2-channel resource fit
  (`06` Q0b).
- **Front-end hub (DP output):** **Parade PS8650** (Avnet quote pending;
  support@paradetech.com / Macnica for samples+EVB) or **Synaptics VMM5330**; or
  **Realtek RTS5490 USB4 hub** if Mac independent-dual is a target (`06` Q-MAC).

**Note — the old "MST-in-FPGA" debate (Parretto/AMD/Intel) is superseded.** We use
a discrete hub, so we don't license DP-MST IP at all. AMD ZCU102 / Parretto-on-
PolarFire remain only as theoretical all-in-one-chip alternatives, not the plan.

**Discretes:** the only one worth an email is **Parade PS8650** (support@paradetech.com
+ Macnica) for samples + EVB — keep as a backup, but it's a DP-MST *hub* (DP/HDMI
out), so it still needs a downstream DP/HDMI-RX→SDI stage. **Drop Synaptics,
Realtek, Analogix** for a small shop (NDA/design-win gated, no buyable eval; ANX
also DP1.2).

### One-line decision
**Order a $40 Plugable MST adapter + the PolarFire Video Kit this week, clone
Parretto's GitHub DP IP, and email Parretto to confirm PolarFire MST dual-4K60
support** — that single sequence un-sticks both the prototype and the production
track for under ~$1.5k with zero NDAs.

## Concrete links / contacts
- Plugable USBC-MSTH2 — amazon.com (≈$39.95) / plugable.com
- StarTech MST14CD122HD — amazon.com (≈$60–90, *unverified*)
- Microchip **MPF300-VIDEO-KIT-NS** — DigiKey #10315239
- AMD **ZCU102** (EK-U1-ZCU102-G) — DigiKey #7035245 (≈$3.5k, *unverified*)
- Intel **Cyclone 10 GX** dev kit (DK-DEV-10CX220-A) — Altera eStore / DigiKey
- **Parretto** DP IP — github.com/Parretto/DisplayPort ; parretto.com/dp ; reseller Microtronix (sales@microtronix.com)
- **Bitec** DP1.4a IP (MST/HDCP on request) — bitec-dsp.com
- **Parade PS8650** (PS8650BGA274GTR-A0) — support@paradetech.com / Avnet Americas / Macnica
- Microchip 12G-SDI IP / demo **DG0889** — microchip.com (Jan-2026 SDI IP expansion)

## Open verifications (carry-forward)
- Live distributor stock for PS8650 (Avnet) and VMM-series.
- ZCU102 / C10GX current prices (DigiKey 403; figures approximate).
- Microchip 12G-SDI IP license *free at the 12G tier?*
- **Parretto on PolarFire: device support + MST dual-4K60 sink behavior** ← the
  primary-track gating assumption.
- StarTech current street price.
</content>
