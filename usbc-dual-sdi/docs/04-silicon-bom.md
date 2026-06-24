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

## Architecture baseline: fixed-function, NO FPGA (decided)

v1 is the **"dumb" design** — pure HDMI→SDI format passthrough, no frame buffer,
no FPGA, no SOM, no DDR. The conversion is done by a **fixed-function bridge
ASIC** per channel. An FPGA only ever returns for the **smart/Pro variant**
(active frame-rate conversion / color / genlock — Blocks 2-Family-B & 3 below are
*Pro-only*).

**v1 dumb BOM (per box):**

| Block | Part | Role |
|---|---|---|
| MST hub | VMM6210 / PS8650 / RTD2186 | 1 USB-C DP → 2× HDMI 2.0 (still required; the hard-to-source block) |
| Conversion ×2 | **Semtech GS12170** | HDMI 2.0 → 12G-SDI bridge ASIC, audio embed, ST 352 — **no FPGA** |
| Cable driver ×2 | Semtech **GS12281** | 12G reclocking driver → 75 Ω BNC |
| HDMI redriver ×2 | TI/Diodes/Parade HDMI 2.0 redriver | clean TMDS into the GS12170 |
| USB-C PD/DP | TI **TPS65987D** (+ CCG3PA on port 2) | 4-lane DP Alt negotiate + PD sink |
| MCU | ST **STM32H723** | EDID emulation, USB HID, status, I²C config |

Getting two displays from one USB-C **still requires the MST hub** — going
FPGA-less does not remove that (see Block 2 / `07`). What it removes is the
entire FPGA + DP-MST-IP + 12G-SDI-IP problem on the *conversion* side.

## Block-by-block

### Block 1 — Conversion: Semtech GS12170 HDMI→SDI bridge (the FPGA-killer)
- **One chip per channel:** HDMI 2.0 in (≤4Kp60 4:2:2 10-bit) → **12G-SDI out**,
  auto HD/3G/6G/12G; **embeds up to 16-ch audio** and builds the **ST 352
  payload ID**; carries HDR InfoFrames. 196-ball BGA, 12×12 mm, **<2 W**.
- **~$73 qty 1** (GS12170-IBE3); stocked DigiKey/Mouser/Arrow/LCSC (*unverified*).
- **HDMI port is chip-to-chip TMDS** → needs an **HDMI redriver** on the cable
  input. Expects **unencrypted** TMDS, no HDCP — aligns with non-HDCP-sink (`06`
  Q11); ensure the MST hub upstream doesn't authenticate HDCP.
- ⚠️ **TOP RISK — lifecycle:** one source flags GS12170 EOL/NRND while it remains
  stocked. **Confirm with Semtech before designing in.** Fallback if EOL = small-
  FPGA recipe (HDMI RX + Lattice ECP5/Artix + SDI IP + GS12281) — more work, the
  thing the bridge was built to avoid.
- Only the **GS12170** does HDMI 2.0 → 12G-SDI single-chip; older Gennum SDI
  parts (GS2972/GS2971A) are SDI-only and cap at 3G.

### Block 1b — 12G-SDI cable driver
Use a **reclocking** cable driver, one per BNC, after the GS12170 SDI output.

| Part | Reclock | Lifecycle | Stock / ~price | Note |
|---|---|---|---|---|
| **Semtech GS12281-INE3** ★ | yes | Active (replaces GS12181/82) | DigiKey ~$31, stocked | recommended |
| TI LMH1297RTVR | yes (EQ-or-driver) | Active (*page unverified*) | DigiKey ~$37.50 | alt |
| Semtech GS12081-INE3 | no | Active | snippet showed **non-stocked, ~24-wk lead** | cost-down, risky |
| TI LMH1208RTVR | no | *NRND-vs-active unverified* | listed | avoid until confirmed |

- The **GS12281 reclocking** driver after the GS12170 covers SDI output jitter —
  **no separate retimer and no external Si534x reference clock needed in the dumb
  design** (the GS12170 generates the SDI bitstream; there's no FPGA GTH to
  feed). *(The Si534x reference is only relevant to the Pro/FPGA variant, where
  the transceiver reference is the dominant jitter source.)*
- ⚠️ **3G-only parts that look tempting but are disqualified:** GS3490, LMH0307,
  LMH0394 — cannot do 12G.

### Block 2 — Front-end hub: split one USB-C into two displays (still required)
Unchanged by the FPGA-less decision — you still need a hub to get two displays
from one USB-C, feeding the two **GS12170 bridges** (HDMI 2.0). **Two hub
technologies, and the choice decides Mac support** (`06` Q-MAC, `02` §2):

**Option 1 — DP MST hub (Windows-independent / Mac-mirror).** Cheapest; works on
any DP-Alt host; but **macOS mirrors** (no MST extended). Discrete options, best
first:
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
- ⚠️ Parade PS176-class / ITE / Algoltek / Realtek **RTD2173**-class are
  single-stream converters, **not** MST splitters.

**Option 2 — USB4 hub (Mac AND Windows independent-dual; still no FPGA).** Uses
Thunderbolt/USB4 DP tunneling instead of MST, so **macOS extends** (not mirrors).
Replaces the MST hub, feeds the same GS12170 chain — *fixed-function, not an
FPGA.*
- **Realtek RTS5490** — **USB4 hub** (DP2.1 tunneling, multi-display, PD), **not**
  Thunderbolt-cert-gated, non-Intel; shipping in the 2025 MS Surface USB4 Dock.
  The cost-down vs Intel **Barlow Ridge JHL9480** (TB5, premium, cert-gated) or
  **Goshen Ridge JHL8440** (TB4, DP1.4, mature). ⚠️ **Verify it presents two
  *fully independent* tunneled DP outs that macOS extends — test on a real M4/M5
  Mac**; confirm low-volume sourcing; and check whether it requires a **USB4/TB
  host** (may not work on plain DP-Alt-only PCs — could narrow PC support).
- Caveat: base **M1/M2/M3 Macs cap at 1 external** regardless; only M4+/Pro/Max
  do independent dual.

**Family B — DP MST RX inside the FPGA (PRO/SMART VARIANT ONLY — not v1).** Only
relevant if you build the FPGA-based smart variant (active FRC/color/genlock),
where the FPGA does both the MST split and the conversion. No scarce hub chip;
the cost is IP. Three IP routes, not just AMD:
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

### Block 3 — FPGA *(NOT IN v1 — Pro/smart variant only)*
**v1 has no FPGA** (the GS12170 bridges do the conversion). This block applies
only if/when the **smart variant** is built (active FRC / color / genlock), where
one FPGA replaces both bridges and does the MST split too. Options, if that day
comes:
- **Discrete hub + cheap FPGA:** **Microchip PolarFire** (free 12G-SDI IP) doing
  DP/HDMI SST RX + 12G-SDI TX after a hub split — plus DDR for the frame buffer.
- **MST-in-FPGA:** **no longer AMD-only** — AMD first-party, **Intel/Altera**
  first-party (DP-MST sink + 12G-SDI II on Arria 10 / Cyclone 10 GX / Agilex 7),
  or **third-party MST IP (Parretto/Bitec) on PolarFire** (MST-in-FPGA without
  AMD's ~$16k NRE, pairs with PolarFire's free SDI IP).

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
- The dumb design has light MCU duties, so it can be **smaller/cheaper than the
  H723**. **ST STM32H723ZGT6** is fine and over-provisioned; an **STM32G0/G4 or
  L4** class part with **≥3 I²C** (two DDC/EDID slave channels + bridge/hub
  config) and **USB-FS device** (HID) would do and cut cost. Pick in layout.
- Duties: **EDID emulation** on the two MST-hub DDC channels, **USB HID** config,
  **status LEDs/OLED**, **GS12170 + hub config** over I²C. No bitstream staging
  (no FPGA), so no large flash / OCTOSPI needed.
- **USB-FS (12 Mbps) is plenty** for HID — no external HS PHY.

### Block 6 — Power budget (dumb design, dual-4K60 worst case)

| Block | Typical | Note |
|---|---|---|
| 2× GS12170 bridge | ~3–4 W | <2 W ea |
| 2× GS12281 cable drivers | ~0.7 W | ~0.34 W ea |
| 2× HDMI redrivers | ~0.4 W | |
| MST hub | ~1–2 W | |
| USB-C PD + MCU + LEDs | ~1 W | |
| DC-DC losses (~85%) | +~1 W | |
| **Total realistic** | **~6–9 W** | lower than the FPGA design — no big-FPGA load |

- **Verdict: still above bare bus power — PD recommended.** A single PD contract
  at **9 V/2 A (18 W)** covers it comfortably.
- **Validates the secondary-power-port decision** (`02`): negotiate PD on the
  video port, or feed Port 2 from a USB-C charger; **degrade** rather than brown
  out on a stingy host.

## Summary recommendation table

**v1 dumb design** (FPGA/IP rows are Pro-variant only):

| Block | Recommended | Obtainable? | ~Price (1–10) | Caveat |
|---|---|---|---|---|
| **Conversion ×2** | Semtech **GS12170** bridge ASIC | stocked (*lifecycle unverified*) | ~$73 ea | **the FPGA-killer; confirm EOL status w/ Semtech** |
| 12G cable driver ×2 | Semtech **GS12281-INE3** | yes, stocked | ~$31 ea | reclocking; after each GS12170 |
| HDMI redriver ×2 | TI/Diodes/Parade HDMI 2.0 redriver | yes | ~$2–6 ea | clean TMDS into the bridge |
| DP MST hub | VMM6210 · PS8650 (Avnet, quote pending) · RTD2186 | design-win channel | hub chip cost | still required; `07` for sourcing |
| USB-C PD/DP | TI **TPS65987D** + CCG3PA (port 2) | yes (*stock unverified*) | ~$5–8 | 4-lane DP + PD sink |
| MCU | ST **STM32H723** (or smaller G0/G4/L4) | yes, in stock | ~$3–12 | EDID + HID + config; FS USB fine |
| Power | PD ~18 W (+ 2nd USB-C port) | — | — | ~6–9 W load; bus power marginal |
| *FPGA + DP/SDI IP* | *Pro/smart variant only — see Block 3* | — | — | *not in v1* |

## Top sourcing risks (ranked)

1. **GS12170 lifecycle — HIGHEST.** The single chip that removes the FPGA may be
   **EOL/NRND** (one source) while still **stocked** at DigiKey/Mouser/Arrow/LCSC
   (~$73). **Confirm status directly with Semtech before designing it in.**
   Fallback if truly EOL = the small-FPGA conversion recipe (HDMI RX +
   ECP5/Artix + SDI IP + GS12281) — more engineering, the thing the bridge
   avoided. **Action:** Semtech lifecycle inquiry; identify a second-source
   bridge or commit to the FPGA-recipe fallback early.
2. **DP MST hub sourcing — MODERATE.** Still required; all hubs are design-win-
   channel parts. *Decoupled from development* by an off-the-shelf MST adapter
   (`07`). **Parade PS8650** (Avnet quote pending), **VMM6210** (datasheet in
   hand), **RTD2186** are the candidates.
3. **PD controller config/stock — LOW-MODERATE.** Active + listed; needs a
   firmware/EEPROM config flow. Avoid NRND TPS65988.
4. **MCU — LOWEST.** STM32 family, in stock; FS-USB is fine for HID.

## Make-vs-buy note (decided: buy fixed-function)
Earlier drafts argued an FPGA was "non-negotiable for the managed-EDID/FRC/color
thesis." **That was scope creep.** The features the product actually needs —
EDID-driven resolution/frame-rate management + format conversion + embedded audio
— are delivered by the **MCU (EDID) + the GS12170 bridge (conversion/audio)**
with **no FPGA**. Only *active* frame-rate conversion, color processing, and
genlock genuinely need an FPGA + DDR, and those are deferred to the **Pro
variant**. So v1 = **buy fixed-function** (GS12170), keep the FPGA design
documented as the Pro upgrade path (Blocks 2-Family-B & 3).
