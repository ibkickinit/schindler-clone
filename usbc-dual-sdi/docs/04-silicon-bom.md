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

## The architecture-defining finding: MST split must live in the FPGA

The deep-dive's most important result: **you cannot buy a DP 1.4 MST hub chip as
a small shop.**

- **Synaptics VMM-series** (VMM5320/5330/6210/7100 — the real DP1.4/2.1 MST
  hubs): **NDA / design-win / ODM-only.** No buy button, no distributor, no
  public datasheet. Used captively inside docks. **Not BOM-able.**
- **Parade PS176/PS186/PS196** and **ITE IT6563** *are* buyable in low volume —
  but they are **single-stream DP→HDMI converters, not MST splitters** (wrong
  function). The real Parade MST hubs are NDA/ODM, same as Synaptics.

**Resolution (answers `06` Q1): do DP 1.4 MST RX inside the FPGA.**
- **AMD DisplayPort 1.4 RX Subsystem (LogiCORE, PG300)** — **MST sink confirmed**,
  supports up to 4 native streams (we need 2), up to HBR3 8.1 Gb/s, dynamic
  1/2/4-lane.
- **Must use PL GTH (≤16.3G) or GTY** transceivers for HBR3 MST. The Zynq US+
  **PS hard-DP block (PS-GTR) only reaches HBR2/5.4G** (~4K30 SST) — **not**
  enough; instantiate the *soft* RX subsystem in PL fed by GTH.
- **The DP IP is a PAID license** (SKU `EF-DI-DISPLAYPORT-SITE`), not free with
  Vivado. Order-of-magnitude ~$5k, "contact sales" (*unverified*). Budget
  **HDCP 2.3** entitlement separately if protected content must pass.

This trades the *availability* risk of MST silicon for a *cost/NRE* risk
(AMD FPGA + paid IP). That is the right trade for a buildable product, but it
**pins the FPGA vendor to AMD** (see Block 3) and adds meaningful NRE.

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

### Block 2 — DP MST split → **in the FPGA** (see finding above)
No discrete part. Cost item = AMD DP1.4 RX Subsystem license (+ HDCP if needed).
Freely-buyable Parade/ITE converters are only useful on an *output* (DP-out →
HDMI) path, never for the split.

### Block 3 — FPGA
The MST-in-FPGA decision **pins the vendor to AMD** — it is the only vendor with
a proven one-toolchain stack of **4K60 HDMI 2.0 RX + DP 1.4 MST RX + 12G-SDI TX**.

| Family | SerDes max | 12G-SDI | DP/HDMI RX | IP cost | Obtainable |
|---|---|---|---|---|---|
| **AMD Zynq US+ XCZU4EV / ZU3EG** ★ | PL GTH **12.5G** | yes (via GTH) | **DP1.4 MST + HDMI2.0 4K60 RX** | paid (~$11k AV bundle) | yes, stocked (~$150–400) |
| AMD Artix US+ AU25P | GTH 12.5G (pkg-dependent!) | yes (SFVB784 pkg) | DP + HDMI2.0 | paid ~$11k | yes |
| Microchip PolarFire MPF300T | 12.7G | yes (**free** 12G IP, Jan-2026) | DP1.4 RX **SST only (no MST)**; HDMI RX **only 4K30** | free | yes — but doesn't fit MST design |
| Lattice CertusPro-NX | **10.3G** | **NO — disqualified** | — | — | — |
| Lattice Avant-G | 12.5G | electrically yes, **no turnkey 12G-SDI IP** | DP IP; HDMI bridging | mixed | eval only |

- **Recommendation: AMD Zynq UltraScale+ XCZU4EV (or ZU3EG)** in a **12.5G-GTH
  package** — confirm the package exposes **≥4 GTH at 12.5G**. The integrated ARM
  PS can also absorb the USB-C control plane (possibly folding in Block 5).
- **Downside:** ~$11k AV IP site license + the ~$5k DP IP (Block 2) — a real NRE
  that amortizes only at volume.
- **PolarFire is disqualified for *this* design** despite free 12G-SDI IP: its DP
  RX is **SST-only (no MST)** and stock HDMI RX caps at **4K30** — it can't do the
  dual-4K60 MST architecture. (It *would* suit a DP-only or HD-class variant.)
- **CertusPro-NX disqualified:** SerDes hard-capped at 10.3G < 12G.

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
| DP MST split | **AMD DP1.4 RX Subsystem (FPGA IP)** | yes (IP, paid) | license ~$5k *(unverified)* | dedicated MST-hub silicon unobtainable |
| FPGA | AMD **Zynq US+ XCZU4EV** (12.5G-GTH pkg) | yes, stocked | ~$150–400 | ~$11k AV IP bundle; verify GTH count |
| USB-C PD/DP | TI **TPS65987DDHRSHR** + CCG3PA (port 2) | yes (*stock unverified*) | ~$5–8 | EEPROM config; 4-lane via multifn bit |
| MCU | ST **STM32H723ZGT6** | yes, in stock | ~$12 | USB-HS needs ext ULPI (FS fine for HID) |
| Ref clock | Skyworks **Si5342/Si5344** | yes | — | mandatory for 12G jitter |
| Power | PD ≥27–45 W (+ 2nd USB-C port) | — | — | default 15 W bus insufficient for dual-4K |

## Top sourcing risks (ranked)

1. **DP MST split — HIGHEST.** No buyable MST-hub silicon (Synaptics/Parade MST
   = NDA/ODM). Mitigation = MST RX in FPGA, which forces **AMD FPGA + paid DP IP
   (+ HDCP)**. Risk shifts from *availability* to *cost/NRE*.
2. **FPGA + IP licensing — HIGH cost.** Silicon stockable; the **~$11k AV bundle
   + ~$5k DP IP + HDCP** is a large, partly-opaque ("contact sales") NRE that
   gates the whole architecture.
3. **12G driver lifecycle/stock — MODERATE.** GS12281 looks well-stocked; the
   cost-down GS12081 showed non-stocked / 24-wk lead, and TI LMH1208/1297
   active-vs-NRND couldn't be confirmed (403). Stick with GS12281.
4. **PD controller config/stock — LOW-MODERATE.** Active + listed, but live
   stock/price unverified, and all need a firmware/EEPROM config flow. Avoid
   NRND TPS65988.
5. **MCU — LOWEST.** STM32H723/H743 Active, four-figure same-day stock; shortage
   recovered. Only watch-item (USB-HS PHY) is a non-issue for HID.

## Make-vs-buy note (unchanged thesis, now cost-quantified)
The FPGA path is non-negotiable for the managed-EDID / frame-rate / color thesis
**and** is now also the only obtainable way to do the MST split. The cost of that
is the AMD AV/DP IP NRE above. A future **HD-class / DP-only budget variant**
could escape both the 12G-SDI and the AMD-IP costs (e.g. PolarFire with its free
SDI IP for a 3G/6G product), but cannot serve the dual-4K60 MST design.
</content>
