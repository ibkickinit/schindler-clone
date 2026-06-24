# 04 — Candidate Silicon & BOM

> Updated from the mid-2026 sourcing deep-dive. Parts below were screened for
> **obtainability** (active lifecycle + buyable in low volume, ideally stocked at
> DigiKey/Mouser, no NDA/ODM gate).
>
> **Data caveat (carried from the research):** semtech.com, ti.com, st.com,
> infineon.com, DigiKey, Mouser, Octopart and LCSC all returned **HTTP 403 to
> automated fetches**, so live stock counts and qty-1/10 prices come from search
> snapshots + manufacturer selector guides. **Verify in a live cart before
> committing.** Anything uncorroborated is marked *unverified*.

## The architecture-defining fork: how to do the MST split

Getting **two independent displays from one DP link requires MST**, and the
research went through two passes:

- **First pass:** concluded discrete MST-hub silicon was unbuyable, so MST had to
  be done inside an AMD FPGA (paid IP).
- **Follow-up pass (corrects it):** **Synaptics VMM6210 / VMM5330 are real,
  datasheet-published DP1.4 MST hubs** (dual-4K60) — the "totally unobtainable"
  claim was too strong. They aren't openly stocked at LCSC/DigiKey, but are
  reachable via **Synaptics design-win / distribution / FAE** (the cheap MST-hub
  dongles on Amazon are built on VMM silicon). **Live low-volume stock is
  unverified (distributor pages 403-blocked) — that is the gating unknown.**

So there are **two live paths** (full detail in Block 2):

| | **Path A — discrete VMM hub** | **Path B — MST in AMD FPGA** |
|---|---|---|
| Split done by | Synaptics VMM6210/VMM5330 | AMD DP1.4 RX Subsystem (PG300) |
| FPGA needed | simpler: **DP/HDMI SST RX + 12G TX** → PolarFire (free IP) | AMD Zynq US+ (DP-MST IP) |
| IP NRE | **none** (PolarFire 12G-SDI IP is free) | **~$11k AV + ~$5k DP** |
| Availability | **unverified** (VMM procurability) | high (AMD always available) |
| Vendor lock | two-vendor BOM | pinned to AMD |

⚠️ The buyable **Parade PS176/PS186 / ITE IT6563 / Algoltek / Realtek** parts are
**single-stream DP→HDMI converters, not MST splitters** — they cannot do the
split, on either path.

**Decision rule (`06` Q1):** chase a Synaptics VMM quote first. Procurable →
**Path A** (materially cheaper, no AMD IP). Not procurable → **Path B** as the
guaranteed-available fallback. HDCP IP is **not** needed on either path — we ship
as a non-HDCP sink (`06` Q11).

## Block-by-block

### Block 1 — 12G-SDI cable driver (+ reference clock)
Use a **reclocking** cable driver, one per BNC. The dominant 12G TX jitter
source is the **FPGA transceiver reference clock**, so a low-jitter reference is
mandatory — a plain (non-reclocking) buffer just passes jitter through and fails
SMPTE ST 2082.

| Part | Reclock | Lifecycle | Stock / ~price | Note |
|---|---|---|---|---|
| **Semtech GS12281-INE3** ★ | yes | Active (replaces GS12181/82) | DigiKey ~$31, stocked | recommended |
| TI LMH1297RTVR | yes (EQ-or-driver) | Active (*page unverified*) | DigiKey ~$37.50 | alt |
| Semtech GS12081-INE3 | no | Active | snippet showed **non-stocked, ~24-wk lead** | cost-down, risky |
| TI LMH1208RTVR | no | *NRND-vs-active unverified* | listed | avoid until confirmed |

- **No separate retimer IC needed** on a straight FPGA→BNC path — the reclocking
  driver covers it. A discrete retimer (LMH1219/LMH1239/GS12141) is only for
  RX/loop-through, which we don't have in v1.
- **Add a low-jitter reference clock** feeding the FPGA GTH: **Skyworks Si534x**
  (e.g. **Si5342/Si5344**). This is not optional for 12G compliance.
- ⚠️ **3G-only parts that look tempting but are disqualified:** GS3490, LMH0307,
  LMH0394 — cannot do 12G.

### Block 2 — DP MST split → **two families + a decoupled dev path**
Repeated research has widened this considerably from the early "must be AMD"
conclusion. Two architectural families, each now with several options, plus a
prototyping path that **decouples MST-hub sourcing from development**.

**Family A — discrete MST hub chip + a simple FPGA.** The hub splits in silicon;
the FPGA then only needs **HDMI/DP SST RX + 12G-SDI TX** (no DP-MST IP → cheaper
FPGA, Block 3). Hub options, best first:
- **Synaptics VMM6210** (USB-C/DP-Alt in → 1× HDMI 2.1 + 1× DP 1.4, dual-4K60) /
  **VMM5330** (DP1.4 MST hub, ≤3 TX). VMM6210 **integrates the USB-C input** —
  fewest parts. **Datasheet obtained (2026-06-24, vault `_Projects/USB_DualSDI`)**
  — spec review unblocked; procurement quote still pending (stock 403-blocked).
- **Parade PS8650** — DP2.1a→DP1.4 **MST hub, 1 in → 4 out**, 4K60+HDR/stream.
  Orderable MPN **PS8650BGA274GTR-A0** (BGA-274), US distributor **Avnet** —
  **quote requested 2026-06-24, pending**. Needs a separate USB-C DP-Alt/PD front
  stage (takes a DP input).
- **Realtek RTD2186** *(new find)* — DP1.4 RX **SST/MST (≤7 in, out to 4
  displays)**, **HDMI 2.0b 4K60** per output (no DSC). Single-chip DP-MST-RX →
  4× HDMI 2.0; Chinese reference designs (schematic + PCB) exist. Low-volume
  obtainability **unverified** — but a credible 3rd discrete hub.
- **Analogix ANX6470** *(new find, marginal)* — real MST hub but **DP1.2/HBR2
  only** (1 in → 3 streams, 21.6 Gb/s total), so dual-4K60 is tight/not
  guaranteed. Listed for completeness; lower priority.

**Family B — DP MST RX inside the FPGA.** No scarce hub chip; the cost is IP.
Now three IP routes, not just AMD:
- **AMD DP1.4 RX Subsystem (PG300)** on Zynq/Artix US+ — MST sink, proven, but
  **paid IP** (~$5k DP + ~$11k AV bundle) and **pins to AMD**.
- **Intel/Altera DisplayPort FPGA IP** *(new find)* — has a true **MST sink (up
  to 4 streams, HBR3)**, and Intel FPGAs with ≥12.5G transceivers
  (**Arria 10 GX, Cyclone 10 GX, Agilex 7 F-Tile**) also have first-party **12G-
  SDI II IP** → a **complete non-AMD single-chip** equivalent of the AMD path.
  Intel IP pricing not public (*"cheaper than AMD" unverified*).
- **Third-party MST IP on a cheap FPGA** *(new find — softens the cost wall)* —
  **Parretto** (vendor-neutral MST IP: AMD/Intel/Lattice/Microchip; on GitHub +
  commercial) or **Bitec DP1.4a** (MST "on request"). These let us run **MST sink
  on a low-cost Microchip PolarFire** (whose own DP RX is SST-only) **alongside
  PolarFire's FREE 12G-SDI IP** — i.e. MST-in-FPGA **without** AMD's ~$16k NRE.
  Stream-count/HBR3 details need confirming (vendor pages 403).

**Development path — decouple sourcing from progress (do this regardless).** A
commercial **USB-C → dual-HDMI-2.0 MST adapter** (StarTech **MST14CD122HD**,
Plugable **USBC-MSTH2**) outputs two independent 4K60 HDMI streams *today* → feed
the FPGA HDMI RX and bring up the **whole SDI chain** now. Caveats: dual-4K60
needs a **host with DP1.4 + DSC + HBR3** (else it drops to 4K30); **macOS mirrors
only — use Windows/Linux**; **don't** accidentally buy a DisplayLink dock
(compressed, driver-based). This *bypasses* (doesn't *validate*) our own MST
sink — but it unblocks all the SDI-TX work. Eval boards for the real MST sink:
**AMD ZCU102** ships a 4-stream-over-one-DP MST example; Intel dev kits
(Cyclone 10 GX) have DP + 12G-SDI examples; PS8650 EVB via Macnica.

**Thunderbolt / USB4 — evaluated, no Asian single-chip.** Only **Intel Goshen
Ridge JHL8440** receives both tunneled DP streams → dual independent DP
(dual-4K60), but it's Intel and **TB-cert/firmware-gated**. Asian USB4 parts
don't replace the splitter (ASMedia ASM2464PD = storage-only; ASM4242 =
host-side; VIA VL830/VL832 = single-DP-out). Not for v1 unless TB-only host
support is required.

⚠️ **Not** MST splitters (single-stream converters — can't do the split):
Parade **PS176**-class, ITE, Algoltek, and Realtek's **RTD2173**-class converters.
Don't confuse them with the real MST hubs above (PS8650, RTD2186).

### Block 3 — FPGA (depends on the Block-2 family)
The FPGA need depends on the Family-A-vs-B choice:
- **Family A (discrete hub did the split):** FPGA only needs **DP/HDMI SST RX +
  12G-SDI TX** → cheapest is **Microchip PolarFire** (free 12G-SDI IP; its
  SST-only DP RX is fine post-split; feed it the hub's **DP** output to dodge
  PolarFire's 4K30 HDMI-RX cap). Extreme cost-down: **Semtech GS12170 HDMI→SDI
  bridge ASIC** (no FPGA) — but it sacrifices the managed-EDID/FRC/color thesis,
  so dumb-converter variant only.
- **Family B (MST in FPGA):** **no longer AMD-only.** Three IP routes (Block 2):
  AMD first-party; **Intel/Altera** first-party (DP-MST sink + 12G-SDI II on
  Arria 10 / Cyclone 10 GX / Agilex 7); or **third-party MST IP (Parretto/Bitec)
  on a cheap PolarFire** — which gives MST-in-FPGA **without AMD's ~$16k NRE**
  (pairs with PolarFire's free SDI IP).

| Family/role | SerDes max | 12G-SDI | DP/HDMI RX MST | IP cost | Obtainable |
|---|---|---|---|---|---|
| **AMD Zynq US+ XCZU4EV/ZU3EG** ★(B) | PL GTH **12.5G** | yes (GTH) | **DP1.4 MST + HDMI2.0 4K60** (1st-party) | ~$11k AV +$5k DP | yes, stocked (~$150–400) |
| **Intel Arria10/Cyclone10 GX**(B) | **12.5G** | yes (SDI II IP) | **DP MST sink (≤4, HBR3)** 1st-party | paid (*unverified*) | yes |
| **Microchip PolarFire MPF300T** ★(A, or B via 3rd-party IP) | 12.7G | **free** 12G IP | native SST only; **MST via Parretto/Bitec** | free / 3rd-party IP | yes |
| Lattice CertusPro-NX | **10.3G** | **NO — disqualified** | — | — | — |
| Lattice Avant | 12.5G | no turnkey 12G IP | MST via Parretto (prelim) | mixed | eval only |

- **Cheapest overall: Family A + PolarFire** — discrete hub (VMM/PS8650/RTD2186)
  + PolarFire (free 12G-SDI IP), **no MST IP NRE at all**. Gated on hub
  procurability (Block 2 / `06` Q1).
- **If no hub sources out: Family B no longer means a forced ~$16k AMD bill.**
  Two cheaper-than-AMD routes now exist: **Intel** first-party DP-MST + SDI II,
  or **Parretto/Bitec MST IP on PolarFire** (keeps the free SDI IP). AMD remains
  the most-proven but most-expensive Family-B option.
- **CertusPro-NX disqualified** (SerDes capped at 10.3G < 12G) everywhere.
- **Net:** the architecture is **no longer a binary "cheap-but-gated vs
  expensive-AMD."** Best case = discrete hub + PolarFire (no IP NRE); if hubs
  fall through, MST-in-PolarFire via Parretto/Bitec, or an Intel FPGA, both beat
  the AMD NRE. AMD is now the *fallback-of-last-resort*, not the default.
  **Decision still gated on the Block-2 sourcing/quote results.**

### Block 4 — USB-C PD + DP Alt-Mode controller
The box is a **DP Alt-Mode sink (UFP_D)** wanting **4-lane DP (pin assignment
C/E)**. The controller negotiates UFP + DP Alt Mode and sinks power; a separate
DP mux/redriver routes the lanes.

| Part | Ports | 4-lane DP sink | Lifecycle | Config |
|---|---|---|---|---|
| **TI TPS65987DDHRSHR** ★ | 1 | yes (explicit 4-lane bit, SLVA844) | Active | register/EEPROM (easiest) |
| Infineon CYPD6227 (CCG6DF, dual) | 2 | yes (UFP) | Active | MCU fw + EZ-PD tool |
| Infineon CYPD6127 (CCG6SF) | 1 | yes (UFP) | Active | MCU fw + EZ-PD tool |
| TI TPS65988 | 2 | yes | **NRND — avoid** | register/EEPROM |

- **Second-port power (your decision, confirmed buildable):** **Port 1 = DP video
  sink** (+ optional bus power); **Port 2 = dedicated power-only PD sink** from
  another USB-C port or a USB-C PD PSU. Cleanest discrete arrangement:
  **TPS65987D on Port 1 + a cheap sink-only Infineon CCG3PA on Port 2**, with
  VBUS ORing (ideal-diode FETs). Single-chip alternative: **CCG6DF (CYPD6227)**
  dual-port (Active).
- None of these are PD 3.1/EPR; for ≤100 W (20 V/5 A SPR) sink that's fine.
- Live stock/price *unverified (403)* — confirm TPS65987DDHRSHR and CYPD6227 on
  DigiKey before committing.

### Block 5 — Management MCU
- **Recommendation: ST STM32H723ZGT6** (LQFP-144, Cortex-M7 550 MHz). **4× I²C**
  (two for DDC/EDID slave emulation + OLED + spare), 6× SPI, 2× OCTOSPI (share
  FPGA flash), 1 MB flash / 564 KB RAM, USB-FS device. **Active** (DS13313 Rev 5,
  May 2025). Mouser ~1,362 in stock; DigiKey ~$12, ships today.
- Alt: **STM32H743ZIT6** (2 MB/1 MB, ~$16) for more bitstream-staging headroom.
- ⚠️ **No on-chip USB High-Speed PHY** (Full-Speed only). For a HID config port,
  **FS (12 Mbps) is plenty** — non-issue. HS would need an external ULPI PHY.
- **Could be folded into the Zynq US+ PS** instead of a discrete MCU — decide in
  layout (discrete MCU = simpler bring-up + isolation; PS = fewer parts).

### Block 6 — Power budget (dual-4K60 worst case)

| Block | Typical | Note |
|---|---|---|
| FPGA (ZU4EV, dual-4K + 4 GTH) | ~6–10 W | dominant; confirm via Xilinx Power Estimator |
| 2× 12G reclocking drivers | ~0.7 W | GS12281 ~0.34 W ea |
| Si534x reference clock | ~0.3–0.5 W | |
| USB-C PD + DP mux/redriver | ~0.5–1 W | |
| MCU + OLED/LEDs | ~0.5 W | |
| DC-DC losses (~85%) | +~1.5–2 W | |
| **Total realistic** | **~10–15 W** | push to 15–18 W if run hot |

- **Verdict: bus power is insufficient — PD is required.** Default non-PD bus
  (≤15 W, 5 V/3 A) won't cover FPGA peaks + conversion loss for dual-4K. A single
  PD contract at **9 V/2 A (18 W)** or **15 V/3 A (45 W)** covers it comfortably.
- This **validates the secondary-power-port decision** (`02`): negotiate
  ≥27–45 W PD on the video port, or feed the dedicated Port 2 from a charger, so
  the design never depends on a host's stingy port budget. The **degradation
  ladder** handles the bus-power-only case by dropping to dual-HD / single-4K.

## Summary recommendation table

| Block | Recommended | Obtainable? | ~Price (1–10) | Caveat |
|---|---|---|---|---|
| 12G-SDI driver | Semtech **GS12281-INE3** (reclocking) ×2 | yes, stocked | ~$31 ea | + Si534x ref clock; no separate retimer |
| DP MST split | **Fam A (hub):** VMM6210/5330 · Parade **PS8650** (Avnet, quote pending) · Realtek **RTD2186** — **Fam B (in-FPGA IP):** AMD · Intel · Parretto/Bitec-on-PolarFire | A: PS8650 via Avnet *(in progress)* · B: yes | A: hub chip cost · B: IP NRE | **no longer AMD-or-bust** — many routes; gated on Block-2 quotes (`06` Q1) |
| FPGA | **Fam A:** Microchip **PolarFire MPF300T** (free 12G IP) · **Fam B:** AMD **Zynq US+ XCZU4EV** *or* Intel **Cyclone 10 GX** *or* PolarFire + 3rd-party MST IP | yes, stocked | ~$150–400 | A: no IP NRE · B: Intel/3rd-party-IP both beat AMD's ~$16k |
| USB-C PD/DP | TI **TPS65987DDHRSHR** + CCG3PA (port 2) | yes (*stock unverified*) | ~$5–8 | EEPROM config; 4-lane via multifn bit |
| MCU | ST **STM32H723ZGT6** | yes, in stock | ~$12 | USB-HS needs ext ULPI (FS fine for HID) |
| Ref clock | Skyworks **Si5342/Si5344** | yes | — | mandatory for 12G jitter |
| Power | PD ≥27–45 W (+ 2nd USB-C port) | — | — | default 15 W bus insufficient for dual-4K |

## Top sourcing risks (ranked)

1. **DP MST split — MODERATE (downgraded; many routes now).** No longer a single
   gating chip — there are multiple discrete hubs *and* multiple in-FPGA IP
   routes (Block 2). Cheapest = a discrete hub + PolarFire (no IP NRE).
   - **Parade PS8650BGA274GTR-A0** — orderable MPN, **Avnet (US)**, quote
     **requested 2026-06-24, pending** (live thread).
   - **Synaptics VMM6210/5330** (datasheet in hand; quote pending) and **Realtek
     RTD2186** are parallel hub options.
   - Even if *no* hub sources out, MST-in-FPGA via **Intel** or **Parretto/Bitec
     IP on PolarFire** avoids AMD's NRE; **AMD is the last-resort fallback**.
   **Action:** track Avnet PS8650 (datasheet/MOQ/lead/tooling); price VMM in
   parallel; keep Parretto/Bitec + Intel as IP fallbacks.
2. **IP licensing (only if forced into Family B) — was HIGH, now bounded.** AMD
   ~$11k AV + ~$5k DP is the *expensive* route; **Intel first-party** and
   **Parretto/Bitec MST IP on PolarFire** are cheaper Family-B options to price
   before defaulting to AMD. (No HDCP entitlement anywhere — non-HDCP sink,
   `06` Q11.)
3. **12G driver lifecycle/stock — MODERATE.** GS12281 looks well-stocked; the
   cost-down GS12081 showed non-stocked / 24-wk lead, and TI LMH1208/1297
   active-vs-NRND couldn't be confirmed (403). Stick with GS12281.
4. **PD controller config/stock — LOW-MODERATE.** Active + listed, but live
   stock/price unverified, and all need a firmware/EEPROM config flow. Avoid
   NRND TPS65988.
5. **MCU — LOWEST.** STM32H723/H743 Active, four-figure same-day stock; shortage
   recovered. Only watch-item (USB-HS PHY) is a non-issue for HID.

## Make-vs-buy note
An **FPGA is non-negotiable for the managed-EDID / frame-rate / color thesis** —
fixed-function bridge silicon (e.g. the **Semtech GS12170 HDMI→SDI bridge ASIC**,
which does HDMI→12G-SDI at 4Kp60 4:2:2 with no FPGA) is cheaper but exposes none
of the EDID/FRC/color control that is the whole product. Reserve GS12170 only for
a hypothetical dumb-converter variant. Within the FPGA approach, **Path A (VMM +
PolarFire) avoids the AMD IP NRE** while keeping full FPGA flexibility — so the
make-vs-buy tension is now mostly resolved *in favor of Path A, contingent on VMM
procurability.*
