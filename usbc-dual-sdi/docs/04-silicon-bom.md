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

### Block 2 — DP MST split → **two live paths** (this is the key open fork)
Follow-up research refined the earlier "MST silicon is unobtainable" conclusion.
There are **two real ways** to split one DP link into two displays, and the
choice has large cost/lock-in consequences. **Which one wins is gated on whether
Synaptics VMM parts are procurable in our volume** (see Q-block risk + `06` Q1).

- **Path A — discrete MST hub chip (avoids AMD DP IP).** The hub does the split
  in silicon; the FPGA then only needs **HDMI/DP SST RX + 12G-SDI TX** (no DP-MST
  IP). Two hub sources:
  - **Synaptics VMM6210** (USB-C/DP-Alt in → 1× HDMI 2.1 + 1× DP 1.4, dual-4K60)
    / **VMM5330** (DP1.4 MST hub, up to 3 TX). VMM6210 **integrates the USB-C
    input** — fewest parts. **Datasheet obtained (2026-06-24, in project vault
    `_Projects/USB_DualSDI`)** — de-risks the spec/feasibility review; still need
    a procurement quote (stock was 403-blocked). Cheap MST-hub dongles
    (StarTech/Club3D/Cable Matters) run on VMM silicon — circumstantial evidence
    it's buildable.
  - **Parade PS8650** (Taiwan) — genuine DP2.1a→DP1.4 **MST hub, 1 in → 4 out**,
    4K60+HDR/stream; the one credible *non-Synaptics* MST-hub alternative.
    Orderable MPN **PS8650BGA274GTR-A0** (BGA-274, tape-&-reel, rev A0),
    distributed in the US by **Avnet** — **quote/details requested 2026-06-24,
    pending** (this is now a tracked sourcing thread, not a dead-end). Takes a
    **DP input**, so it needs a separate USB-C DP-Alt-Mode/PD front stage (unlike
    the VMM6210). New part (sampling 2024); confirm datasheet access + config/
    firmware tooling with Avnet/Macnica when they respond.
- **Path B — DP MST RX inside an AMD FPGA (no scarce hub chip).**
  **AMD DP1.4 RX Subsystem (PG300)**, MST sink, 2 streams, fed by PL GTH. Robust
  and self-contained, but **paid IP** (~$5k DP + ~$11k AV bundle) and **pins the
  FPGA to AMD**.

**Thunderbolt / USB4 front end — evaluated, no Asian single-chip win.** TB/USB4
natively tunnels two DP streams, but the only silicon that *receives* both and
breaks them out as two independent DP outputs is **Intel's Goshen Ridge JHL8440**
(dual-4K60) — Intel, not Asian, and **TB-cert/firmware-gated** (hard for a small
shop). Asian USB4 parts don't replace the splitter: **ASMedia ASM2464PD** is
storage-only, **ASM4242** is host-side (wrong direction), and **VIA Labs
VL830/VL832** (Taiwan) are device-side but **single-DP-out** — they'd still need
an MST hub bolted after them. So TB/USB4 buys broader Thunderbolt-only-laptop
support and guaranteed dual-DP bandwidth, but **adds cost/cert friction and no
Asian one-chip path** — not worth it for v1 unless Thunderbolt-only host support
becomes a requirement.

⚠️ The buyable **Parade PS176 / ITE / Algoltek / Realtek** *converter* parts are
**single-stream, not MST splitters** — they cannot do the split. (Parade's
splitter is the PS8650 above; don't confuse it with their PS176-class converters.)

**Why Path A matters:** it can **eliminate the AMD IP NRE entirely** and unlock a
much cheaper FPGA (Block 3) — *if* the VMM is procurable. **Verify VMM
obtainability in our volume before locking the architecture.**

### Block 3 — FPGA (depends on the Block-2 path)
**Path B (MST-in-FPGA) pins the vendor to AMD** — the only proven one-toolchain
stack of **4K60 HDMI 2.0 RX + DP 1.4 MST RX + 12G-SDI TX**. **Path A (discrete
VMM hub) relaxes this**: the FPGA only needs **DP/HDMI SST RX + 12G-SDI TX**,
which opens cheaper, non-AMD options — notably **Microchip PolarFire** with its
**free** 12G-SDI IP (its DP RX is SST-only, which is now *fine* because the VMM
already split the link, and at 4K60 per SST stream; feed it the VMM's **DP**
output, not HDMI, to dodge PolarFire's 4K30 HDMI-RX cap). An even more extreme
cost-down on Path A is the **Semtech GS12170 HDMI→SDI bridge ASIC** (HDMI in →
12G-SDI out, 4Kp60 4:2:2, *no FPGA*) — but that **sacrifices the managed-EDID /
frame-rate / color thesis**, so it's only for a dumb-converter variant.

| Family | SerDes max | 12G-SDI | DP/HDMI RX | IP cost | Obtainable |
|---|---|---|---|---|---|
| **AMD Zynq US+ XCZU4EV / ZU3EG** ★ | PL GTH **12.5G** | yes (via GTH) | **DP1.4 MST + HDMI2.0 4K60 RX** | paid (~$11k AV bundle) | yes, stocked (~$150–400) |
| AMD Artix US+ AU25P | GTH 12.5G (pkg-dependent!) | yes (SFVB784 pkg) | DP + HDMI2.0 | paid ~$11k | yes |
| Microchip PolarFire MPF300T | 12.7G | yes (**free** 12G IP, Jan-2026) | DP1.4 RX **SST only**; HDMI RX **only 4K30** | free | **fits Path A** (VMM DP-out → SST RX); not Path B |
| Lattice CertusPro-NX | **10.3G** | **NO — disqualified** | — | — | — |
| Lattice Avant-G | 12.5G | electrically yes, **no turnkey 12G-SDI IP** | DP IP; HDMI bridging | mixed | eval only |

- **Path B recommendation: AMD Zynq UltraScale+ XCZU4EV (or ZU3EG)** in a
  **12.5G-GTH package** — confirm the package exposes **≥4 GTH at 12.5G**. The
  integrated ARM PS can also absorb the USB-C control plane (folding in Block 5).
  **Downside:** ~$11k AV IP + ~$5k DP IP (Block 2) NRE; amortizes only at volume.
- **Path A recommendation: Microchip PolarFire MPF300T** — free 12G-SDI IP +
  free/SST DP RX is sufficient once a VMM hub has done the split, **eliminating
  the AMD IP NRE**. Gated entirely on **VMM procurability** (Block 2 / `06` Q1).
- **CertusPro-NX disqualified** (SerDes capped at 10.3G < 12G) on either path.
- **Net:** if the VMM is procurable, **Path A (VMM + PolarFire) is materially
  cheaper** (no ~$16k AMD IP, cheaper FPGA) at the cost of an extra hub chip and
  a two-chip-vendor BOM. If the VMM can't be sourced in our volume, **Path B
  (AMD)** is the fallback. **This is the top architecture decision to close.**

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
| DP MST split | **Path A:** Synaptics **VMM6210/5330** *or* Parade **PS8650BGA274GTR-A0** (Avnet, quote pending) · **Path B:** AMD DP1.4 RX IP | A: PS8650 via Avnet *(in progress)* · B: yes (paid IP ~$5k) | A: hub chip cost · B: license ~$5k | **gating fork** — Path A avoids AMD IP; PS8650 needs a USB-C front stage |
| FPGA | **Path A:** Microchip **PolarFire MPF300T** (free IP) · **Path B:** AMD **Zynq US+ XCZU4EV** | yes, stocked | ~$150–400 | A: free 12G IP, no AMD NRE · B: ~$11k AV IP, verify GTH count |
| USB-C PD/DP | TI **TPS65987DDHRSHR** + CCG3PA (port 2) | yes (*stock unverified*) | ~$5–8 | EEPROM config; 4-lane via multifn bit |
| MCU | ST **STM32H723ZGT6** | yes, in stock | ~$12 | USB-HS needs ext ULPI (FS fine for HID) |
| Ref clock | Skyworks **Si5342/Si5344** | yes | — | mandatory for 12G jitter |
| Power | PD ≥27–45 W (+ 2nd USB-C port) | — | — | default 15 W bus insufficient for dual-4K |

## Top sourcing risks (ranked)

1. **DP MST split / hub procurability — HIGHEST (now actively de-risking).** The
   Path-A-vs-Path-B fork hinges on whether a discrete MST hub is buyable in our
   volume.
   - **Parade PS8650BGA274GTR-A0** has an orderable MPN with **Avnet (US)** —
     **quote/details requested 2026-06-24, pending.** This is the live thread.
   - Synaptics VMM6210/VMM5330 remain a parallel option (stock was 403-blocked,
     *unverified*).
   - Any hub procurable → **Path A** (hub + PolarFire), **no AMD IP NRE**.
   - None procurable → **Path B** (AMD FPGA + ~$16k IP). Always available, so
     this is a true fallback — the risk is *cost*, not *can-we-ship*.
   **Action:** track the Avnet PS8650 response (datasheet access, MOQ, lead time,
   config/firmware tooling); price a Synaptics VMM quote in parallel.
2. **AMD IP licensing (Path B only) — HIGH cost.** ~$11k AV bundle + ~$5k DP IP
   — large, partly-opaque ("contact sales") NRE. Path A avoids it. (No HDCP
   entitlement on either path — non-HDCP sink, `06` Q11.)
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
