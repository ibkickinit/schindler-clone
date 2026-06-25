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

## Architecture baseline: FPGA (Microchip PolarFire) — decided

The fixed-function GS12170 design is **dead** (EOL Feb 2025, no replacement — `06`
Q0). Conversion moves into a **PolarFire FPGA** with Microchip's **free 12G-SDI
IP** — how the industry already builds these. V1 is **conversion-only**
(source-locked); the FPGA makes the smart features a later unlock.

**V1 BOM (per box):**

| Block | Part | Role |
|---|---|---|
| Front-end hub | Parade **PS8650** / Synaptics **VMM5330** (DP out) · or **RTS5490** (USB4, Mac) | 1 USB-C → 2× **DP 1.4** (DP, not HDMI — see Block 1) |
| FPGA | Microchip **PolarFire MPF300** + DDR4 + SPI flash | 2× DP-RX + SDI map + 2× 12G-SDI TX (free IP) + Mi-V |
| Cable driver ×2 | Semtech **GS12281** | 12G reclocking driver → 75 Ω BNC |
| USB-C PD/DP | TI **TPS65987D** (+ CCG3PA on port 2) | DP Alt / USB4 + PD sink |
| MCU | ST **STM32** *or* soft **Mi-V** in the FPGA | EDID emulation, USB HID, status |

## Block-by-block

### Block 1 — Conversion: PolarFire FPGA (DP-RX → 12G-SDI)
Per channel, inside one PolarFire MPF300:
- **DisplayPort RX IP** — DP 1.4, **HBR3 8.1 Gb/s/lane, SST**, carries **4K60
  4:2:2**. ⚠️ **Feed it DP, not HDMI:** Microchip's **HDMI RX IP caps at 4K30**
  (1080p60 1-pixel / 4K30 4-pixel) — confirmed; the DP-RX path is how we reach
  4K60. (So the hub must output DP — Block 2.)
- **video → SDI mapping** + **ST 299 audio embed** + **ST 352 payload ID** in
  fabric.
- **12G-SDI TX IP** — Microchip, **FREE** (1.5G/3G/6G/12G, ST 2082-1; Jan-2026
  release; demo **DG0889**). Drives the transceiver → GS12281.
- **One MPF300 (300K LE)** targets **both** channels (2× DP-RX + 2× SDI-TX) + soft
  **Mi-V**. ⚠️ **Resource/timing fit at 2 channels is a diligence item** (`06`
  Q0b) — the DG0889 demo is single-channel; budget LE/transceiver/DDR for two.
- **HDCP:** configure DP-RX to **not authenticate** → non-HDCP sink (`06` Q11).
- **IP cost:** SDI IP free; **DP-RX IP** is Microchip CoreDP (SST) or **Bitec** —
  confirm license cost (`06` Q0b). No AMD-style ~$16k AV/DP bundle here.

#### Eval / bench (what to order)
- **`MPF300-VIDEO-KIT-NS`** (Newark #66AH4313) — MPF300T + DDR4 + SPI flash, HDMI
  2.0 (RX ≤4K30) + **HD/3G-SDI on-board**. Validates the chain at **1080p59.94 /
  3G** with *just the kit*.
- **`VIDEO-DC-SDI`** (SDI FMC daughtercard) — **required to reach 12G-SDI** (the
  kit's on-board SDI is HD/3G only; 12G goes over the FMC). Order alongside.
- Phased: kit (HDMI→3G) → add SDI FMC (→12G) → DP-RX input (→4K60). See `05`.

### Block 1b — 12G-SDI cable driver
Use a **reclocking** cable driver, one per BNC, after the FPGA SDI transceiver
output (this SDI-PHY part survives the GS12170 EOL).

| Part | Reclock | Lifecycle | Stock / ~price | Note |
|---|---|---|---|---|
| **Semtech GS12281-INE3** ★ | yes | Active (replaces GS12181/82) | DigiKey ~$31, stocked | recommended |
| TI LMH1297RTVR | yes (EQ-or-driver) | Active (*page unverified*) | DigiKey ~$37.50 | alt |
| Semtech GS12081-INE3 | no | Active | snippet showed **non-stocked, ~24-wk lead** | cost-down, risky |
| TI LMH1208RTVR | no | *NRND-vs-active unverified* | listed | avoid until confirmed |

- The **GS12281 reclocking** driver after the FPGA covers SDI output jitter on the
  line side; **no separate retimer IC** is needed.
- **Low-jitter reference clock (Skyworks Si534x) required** to feed the PolarFire
  **transceiver reference** — the SDI TX serial jitter is dominated by the
  transceiver refclk, so a clean reference is mandatory for ST 2082 compliance.
  (This is the original FPGA-path reasoning, back in force now that conversion is
  in the FPGA.)
- ⚠️ **3G-only parts that look tempting but are disqualified:** GS3490, LMH0307,
  LMH0394 — cannot do 12G.

### Block 2 — Front-end hub: split one USB-C into two displays (still required)
Still required — and now it should output **DP** (to feed the PolarFire **DP-RX**,
which reaches **4K60**; the HDMI-RX path caps at 4K30, Block 1). **Two hub
technologies, and the choice decides Mac support** (`06` Q-MAC, `02` §2):

**Option 1 — DP MST hub (Windows-independent / Mac-mirror).** Cheapest; works on
any DP-Alt host; but **macOS mirrors** (no MST extended). **Prefer DP-output
hubs.** Discrete options, best first:
- **Parade PS8650** ★ — DP2.1a→DP1.4 **MST hub, 1 in → 4 DP out**, 4K60+HDR/stream.
  **DP outputs feed the DP-RX directly** — best fit. Orderable MPN
  **PS8650BGA274GTR-A0** (BGA-274), **Avnet** quote pending. Needs a USB-C
  DP-Alt/PD front stage.
- **Synaptics VMM5330** — DP1.4 MST hub, ≤3 **DP** TX. Also DP-out → good fit.
  (VMM6210 gives 1× HDMI 2.1 + only 1× DP — fewer DP outs; less ideal now.)
  Datasheet in hand (vault `_Projects/USB_DualSDI`); quote pending.
- **Realtek RTD2186** — DP1.4 MST → **4× HDMI 2.0** out. ⚠️ **HDMI output now
  disfavored** (would hit the FPGA's 4K30 HDMI-RX cap, or need an HDMI→DP stage).
  Keep only if a 4K30 ceiling is acceptable. Low-volume sourcing unverified.
- **Analogix ANX6470** — real MST hub but **DP1.2/HBR2 only**, so dual-4K60 is
  tight. Lower priority.
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

> **We do the MST split in a *discrete hub*, NOT in the FPGA.** The FPGA does
> **DP-RX (SST) + SDI**, not MST sink — so the AMD/Intel/Parretto MST-IP debate is
> moot for our architecture. (MST-in-FPGA stays a theoretical alternative for an
> all-in-one-chip Pro variant: AMD DP RX Subsystem ~$16k, Intel DP-MST, or
> Parretto/Bitec MST IP on PolarFire. Not pursued — the discrete hub is cheaper
> and simpler.)

**Prototyping note (still valid):** a commercial **USB-C→dual-HDMI MST adapter**
(Plugable **USBC-MSTH2**) can feed the bench *today* — but our FPGA input is
**DP**, and the adapter outputs **HDMI** (→ 4K30 cap on PolarFire HDMI-RX), so the
adapter is only good for the **initial 3G / ≤4K30 chain bring-up** on the video
kit's HDMI input. Full 4K60 needs a **DP source** into the DP-RX (the real hub, or
a DP test source). See `05`.

**Thunderbolt / USB4:** the **RTS5490** USB4 hub (Block 2 Option 2) is the Mac
path; it outputs DP-tunneled → feeds the DP-RX. Intel Goshen Ridge JHL8440 is the
only other dual-DP-tunnel breakout (cert-gated). ⚠️ Parade PS176-class / ITE /
Algoltek / RTD2173-class are single-stream converters, **not** MST splitters.

### Block 3 — FPGA: Microchip PolarFire (the V1 conversion core)
The GS12170 EOL makes the FPGA the V1 conversion engine. **PolarFire MPF300** is
the choice: **free 12G-SDI IP**, 12.7G transceivers, DP-RX IP (SST/HBR3/4K60), and
a complete dev kit (`MPF300-VIDEO-KIT-NS` + `VIDEO-DC-SDI` FMC for 12G).

**What PolarFire gives us:**
- **12G-SDI RX/TX IP — FREE** (1.5G/3G/6G/12G, ST 2082-1; demo DG0889).
- **DisplayPort RX IP** — DP 1.4 **HBR3/SST → 4K60** (Microchip CoreDP or Bitec).
- 12.7G transceivers; MPF300T (300K LE) + DDR4 + SPI flash; stocked.

**Part selection — MPF300 is overkill/too costly; size down.** The die (logic) is
the cost driver; all PolarFire have the same 12.7G transceivers (12G is fine on
any). DigiKey qty-1 prices:

| Part | Logic | Xcvr lanes | Qty-1 | Fit for dual-4K60 (2× DP-RX + 2× SDI-TX) |
|---|---|---|---|---|
| MPF300T-FCG1152I | 300K | 16 | **~$600** | overkill (kit part) |
| **MPF200T-FCG484I** | 192K | 16 | **$345** | comfortable — safe choice |
| **MPF100T-FCG484I** | 109K | 8 | **$174** | cheapest viable; **logic TIGHT** (~110–130K needed) — may not fit two full channels |
| MPF050T | 50K | few | less | too small for two 4K60 channels |

- **PLAN OF RECORD: `MPF200T-FCG484I` ($345)** — 192K LE / 16 xcvr, comfortable
  for two 4K60 channels. **Cost-down target: `MPF100T-FCG484I` ($174)** if the
  design fits its 109K LE (transceivers already fine — 6 of 8). The MPF100T fit is
  a **Phase-3 bench item** (`06` Q0b); design to MPF200T, port down if it fits.
- Volume pricing drops ~30–50%; verify live qty/price on the cart (403 remotely).
- Scope **decided**: dual-4K60/12G retained (not scoped down) — `06` Q0c.

**Diligence items before committing (`06` Q0b):**
- ⚠️ **HDMI-RX caps at 4K30** — must use the **DP-RX** path for 4K60 (drives the
  DP-output-hub choice, Block 2).
- ⚠️ **Resource/timing fit for 2 channels** — DG0889 is single-channel; confirm
  2× DP-RX + 2× SDI-TX + Mi-V fit in MPF300 (300K LE) with timing closure.
- ⚠️ **DP-RX IP license cost** — confirm Microchip CoreDP-RX (or Bitec) terms; SDI
  IP is free, DP-RX may not be.

**Alternatives (only if PolarFire doesn't fit):** AMD Zynq US+ (DP+SDI IP, but
~$16k AV/DP NRE) or Intel Arria10/Cyclone10 GX (DP + free-eval SDI II IP). Both
do everything PolarFire does at higher IP cost — fallbacks, not the plan.
**Lattice CertusPro-NX disqualified** (SerDes 10.3G < 12G).

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

### Block 6 — Power budget (FPGA design, dual-4K60 worst case)

| Block | Typical | Note |
|---|---|---|
| PolarFire MPF300 (2 pipes + 4 transceivers) | ~3–6 W | confirm via Libero power estimator |
| PLL / clock (Si534x) | ~0.3–0.5 W | transceiver reference |
| 2× GS12281 cable drivers | ~0.7 W | ~0.34 W ea |
| MST/USB4 hub | ~1–2 W | |
| DDR4 + USB-C PD + MCU/LEDs | ~1–2 W | |
| **Total realistic** | **~6–10 W** | FPGA is the dominant load |

- **Verdict: still above bare bus power — PD recommended.** A single PD contract
  at **9 V/2 A (18 W)** covers it comfortably.
- **Validates the secondary-power-port decision** (`02`): negotiate PD on the
  video port, or feed Port 2 from a USB-C charger; **degrade** rather than brown
  out on a stingy host.

## Summary recommendation table (V1 FPGA design)

| Block | Recommended | Obtainable? | ~Price (1–10) | Caveat |
|---|---|---|---|---|
| **FPGA (conversion)** | Microchip **PolarFire MPF300** + DDR4 | yes, stocked | ~$150–300 | **free 12G-SDI IP**; DP-RX via DP (HDMI-RX caps 4K30) |
| SDI IP / DP-RX IP | Microchip 12G-SDI (free) + CoreDP-RX / Bitec | — | SDI free; DP-RX *TBD* | confirm DP-RX license cost (`06` Q0b) |
| PLL / clock | Skyworks **Si534x** | yes | ~$3–8 | transceiver reference clock |
| 12G cable driver ×2 | Semtech **GS12281-INE3** | yes, stocked | ~$31 ea | reclocking; after FPGA TX |
| Front-end hub (DP out) | **PS8650** (Avnet, pending) / **VMM5330** / **RTS5490** (USB4/Mac) | design-win channel | hub chip cost | DP output (feeds DP-RX); `07` |
| USB-C PD/DP | TI **TPS65987D** + CCG3PA (port 2) | yes (*stock unverified*) | ~$5–8 | DP Alt / USB4 + PD sink |
| MCU | ST **STM32** *or* soft **Mi-V** | yes / in-fabric | ~$3–12 | EDID + HID; or fold into FPGA |
| Power | PD ~18 W (+ 2nd USB-C port) | — | — | ~6–10 W load |
| Bench | `MPF300-VIDEO-KIT-NS` + `VIDEO-DC-SDI` (12G FMC) | yes | kit ~$1–1.5k | kit alone = HDMI≤4K30 + HD/3G; FMC for 12G |

## Top diligence / sourcing items (ranked)

1. **HDMI-RX 4K30 cap → use DP-RX — HIGHEST design item.** PolarFire HDMI RX IP
   tops out at 4K30; 4K60 requires the **DP-RX** path → **DP-output hub** (PS8650/
   VMM5330). Validate 4K60 over DP-RX on the bench. (`06` Q0b)
2. **FPGA resource/timing fit for 2 channels.** DG0889 is single-channel; confirm
   2× DP-RX + 2× SDI-TX + Mi-V close timing in MPF300 (300K LE). May push to a
   larger PolarFire if tight.
3. **DP-RX IP license cost.** SDI IP free; confirm Microchip CoreDP-RX or Bitec
   DP-RX terms.
4. **Front-end hub sourcing.** DP-output hub (PS8650 Avnet quote pending / VMM5330
   / RTS5490 for Mac). Design-win channel parts.
5. **PD controller** config/stock (avoid NRND TPS65988); **MCU** lowest risk.

## Make-vs-buy note (FPGA forced by GS12170 EOL)
We briefly had a true fixed-function path (the GS12170 bridge) that needed **no
FPGA** — but it's **EOL with no replacement** (`06` Q0), so an FPGA is now
unavoidable for 12G conversion (as it is for the whole industry). The mitigations:
**PolarFire's 12G-SDI IP is free**, the dev kit + reference design exist, and the
*same* FPGA that does V1 conversion also unlocks the smart features (FRC/color/
genlock) later — so the FPGA is a foundation, not a detour. The real cost is
**HDL development effort + the DP-RX IP license**, not silicon or SDI IP.
