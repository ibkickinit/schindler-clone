# Schindler 2.0 — Spec & Backlog

**Status:** Draft 2026-05-13 (post-merge unification)
**Working principle:** Stay Schindler-shaped. Width dilutes the product.

**SSOT** for the internal electronics architecture and feature set. SKU-specific packaging detail lives in [`packaging-skus.md`](packaging-skus.md). Active dev arc + deferred work in [`dev-roadmap.md`](dev-roadmap.md). Dated decision history in [`01-spec-changelog.md`](01-spec-changelog.md). Items marked **[PROPOSED]** are awaiting confirmation; everything else is confirmed.

---

## 0. Product structure

Schindler 2.0 ships in two SKUs that share **one internal electronics design** — same carrier PCB, same TE0720 SOM, same FPGA HDL, same control-plane firmware. The SKUs differ only in:

- **Chassis form factor** (Mini: half-rack 1RU / Pro: full-rack 1RU)
- **Front panel hardware** (Mini: mono OLED + tactile switches; Pro: NHD-2.9 TFT + mezzanine board + dual encoders + per-connector LEDs + rear status LCD)
- **Rear panel I/O complement** (Mini exposes the subset; Pro exposes everything)
- **Carrier stuffing variant** (Mini omits Pro-tier silicon: SDI chips, dual SYNC OUT driver chain, per-connector LED drivers, rear-LCD driver)

*(The **RF modulator** is **not** part of this stuffing-variant split — it's a truly optional standalone daughter-board module; see the note after the SKU table and §3.9.)*

| SKU | Positioning | Indicative retail |
|---|---|---|
| **Mini (v1)** | Lean entry. NTSC/film cadence workflows. HDMI + composite + component + genlock + Ethernet/WiFi. Half-rack chassis. | $1,500–2,500 |
| **Pro (v2)** | Full broadcast-grade. Adds SDI in/out, dual SYNC OUT with cross-rate conversion, rear status LCD, per-connector LEDs, full TFT + mezzanine UI. Full-rack 1RU chassis. RF modulator (period CRT support) available as an optional add-on module — see note below. | $2,500+ |

Pro v2 is gated on Mini v1 selling. **Engineering work targets the unified electronics design** — Mini and Pro are packaging + stuffing variants of one carrier, not two separate hardware development tracks.

**RF modulator (Period CRT support) — truly optional module (2026-06-12).** RF is a self-contained shielded daughter board, **orthogonal to the stuffing variant**: never fitted by default, added only when ordered. The carrier (common to both SKUs) always carries the u.FL + 6-pin interface footprints (~$1.70), so RF is a clean populate/omit on any build with no respin. Offered as a Pro-tier option; **Mini-eligibility is an open product/commercial call** (technically supported on any carrier). See §3.9 + [`rf-modulator-daughter-board-option.md`](rf-modulator-daughter-board-option.md).

See [`packaging-skus.md`](packaging-skus.md) for SKU-by-SKU stuffing tables and chassis detail.

---

## 1. Hardware foundation

### 1.1 SoC module

- **Trenz TE0720 SOM** — Xilinx Zynq-7020. **Production target: TE0720-04-62I33MA** (XC7Z020-2I speed grade, industrial -40 to +85°C, 1 GB DDR3L, 32 MB QSPI flash, 8 GB eMMC, GbE PHY on-module). 152 FPGA I/O via Samtec Razor Beam connectors. Module-level cost ~$300 at qty 100.
- Bench evaluation runs on a TE0720-04-31C33MA SOM (commercial -1 speed grade, same memory config, identical pinout) when available; primary bench dev platform is the Digilent Zybo Z7-20 which shares the same Z-7020 silicon family — HDL ports 1:1.
- **Explicitly ruled out:** -61C530A and similar 256 MB / no-eMMC TE0720 variants — insufficient memory for the Linux-hosted video pipeline (need 1 GB DDR3 for frame buffers + PetaLinux + Node.js + working memory; need eMMC for Linux rootfs).

### 1.2 Carrier PCB

- **Custom 4-layer FR-4 board, ENIG finish**, ~150 × 120 mm estimated, accepts the TE0720 SOM via 2× Samtec LSHM-150 100-pin + 1× Samtec LSHM-130 60-pin Razor Beam connectors (8 mm mating height, ~$30 connector set per unit).
- **What the carrier does NOT need:** BGA layout, DDR3 routing, HDMI differential routing, USB/Ethernet PHY layout. All of that's on the TE0720 SOM. The carrier is conventional mixed-signal PCB work — analog video chains, panel I/O, genlock front-end, WiFi module footprint, power tree, front-panel connector. Layout effort estimate: 3–5 weeks focused work.
- **One PCB design, two stuffing variants** (Mini / Pro). All silicon footprints exist on every carrier; stuffing differs at assembly.
- **Design rule:** unused TE0720 PL pins route to a 2× 20-pin (or 1× 40-pin) 2.54 mm expansion header. Preserves field-upgrade and prototype-extension paths.

### 1.3 Power & safety

- **Power budget:** ~10–14 W typical (Mini), ~14–18 W typical (Pro), ~22 W peak (Pro).
- **AC entry — pre-certified module path.** Custom AC-DC design intentionally avoided (would add ~$15–25K and 3–6 months of NRTL certification for negligible benefit at ~75 unit lifetime volume). All AC-side components carry their own certifications.
- **IEC inlet:** Schaffner **FN9260B-6-06** — C14 + 6 A + integrated fuse holder + 1-stage EMI filter. ~$18 BOM.
- **Mains fuse:** 2 A T (time-lag), 5×20 mm cartridge. Sized for 120 VAC worst-case (steady state ~0.21 A RMS, 7–10× headroom; comfortably absorbs ~25 A / 5 ms cold-start inrush).
- **No rocker switch.** IEC cord = service disconnect; front-panel soft power button handles daily on/off.
- **PSU module — primary:** Mean Well **LRS-50-12** — 50 W / 12 V single output, 85–264 VAC universal, enclosed aluminum case, convection-cooled, UL 62368-1, EN 55032 Class B. ~$15–20.
- **PSU module — alternate:** TDK-Lambda **HWS50A-12/A** — same form factor, lower switching noise. ~$50. Swap-in if Mean Well noise shows up as audible artifact during bench characterization.
- **Mains wiring inside chassis:** UL 1015 stranded, 18–20 AWG, three-conductor, short captive run from IEC inlet to PSU module screw terminals.
- **Earth bonding:** chassis ground stud as the single bond point. IEC earth + PSU earth + chassis enclosure all bonded to stud. Carrier digital ground tied to chassis earth at one point only (single-point earth, prevents ground loops through the analog signal chain).

**Carrier-side 12 V protection chain:**

| Function | Part | Notes |
|---|---|---|
| Protection eFuse | TI **TPS26601** | 60 V integrated FET: reverse-polarity + reverse-current, adjustable OVP, adjustable OCP (precise limit, no polyfuse thermal-derate), controlled inrush slew. EN = front-panel soft-power gate; I<sub>LIM</sub> ≈ 2.5 A. **Latch-off is the '601's MODE-open default (MODE left open, no strap)** — swapped from TPS26600 2026-06-13b (the '600 defaults to auto-retry). Replaces the prior reverse-FET + polyfuse + TVS chain. |
| Power monitor | TI **INA226** + 5 mΩ shunt | I²C 16-bit current+voltage on 12 V rail (telemetry alongside the eFuse). PSU-healthy proxy (LRS-50 has no DC-OK pin). |
| Bulk cap | 3× Murata GRM32 22 µF 25 V X7R MLCC | ~66 µF nominal (~35 µF effective at 12 V DC bias); MLCC over electrolytic for 10+ year service life. |
| PSU→carrier connector | Molex **Mini-Fit Jr.** 2-pin locking | 9 A rated. |
| Soft-power controller | ADI **LTC2954-1** | Pushbutton on/off controller in the always-on 12 V domain (2.7–26.4 V, 6 µA standby — no standby LDO needed). Debounced front-panel button → drives eFuse EN. **INT** → Zynq GPIO (orderly-shutdown request); **KILL** ← Zynq GPIO (clean power-down once Linux has synced); **PDT** watchdog (~5 s) force-off if the PS hangs; turn-on KILL-blank 512 ms lets the system raise KILL during boot. Resolves the chicken-and-egg where the RP2040 sits downstream of the rails it would switch. Button LED off EN state, with an RP2040 leg for status patterns once booted. |

**Per-rail regulators (downstream of protected 12 V) — committed 2026-06-11.** All bucks/LDOs with built-in OCP + thermal shutdown. The TE0720's Vccint 1.0 V, 1.8 V, and DDR3L 1.35 V are generated **on-module** (from VIN) — the carrier does NOT supply them. VIN is fed from the 5 V rail (see `sheet3-te0720-som-backbone.md` §2).
- **5 V (~3 A) — TI LMR33640 (4 A)** buck (12→5 V). Feeds module VIN, USB host, analog op-amps (single +5 V, AC-coupled at the BNCs — no negative rail).
- **3.3 V (~2.5 A) — TI LMR33640 (4 A)** buck (12→3.3 V), same part, 2nd instance. Feeds module 3.3VIN, all four VCCIO banks (3.3 V), carrier digital.
- **1.2 V (~0.4 A) — TI TLV62568** buck (5→1.2 V) [Pro]. GS3470 (~0.15 A) + GS2962 (~0.25 A) on 1.2 V core+analog — verified ~0.3–0.4 A total (GS2962 cable driver sits on 3.3 V analog, not here), so the 1 A part has ample margin.
- **1.8 V analog (~0.4 A) — per-chip low-noise LDOs (TI TPS7A20 / ADI ADP7142 class)** from 3.3 V via ferrite: AD9204 AVDD (dedicated POL), ADV7280 analog, ADV7393 VDD/PVDD (digital + PLL on a clean tap), and **ADV7511 analog/PLL (AVDD/PVDD = 1.8 V)**. Isolated from buck switching for precision genlock.
- **1.8 V digital (~0.1 A) — small LDO off 3.3 V (`+1V8_D`):** VCCIO33 (PL bank 33) + AD9204 DRVDD. Added 2026-06-13 when B33 was re-strapped to 1.8 V to match the AD9204's 1.8 V CMOS data outputs (the module allows 1.2–3.3 V on B33). Kept separate from the analog 1.8 V so ADC output-driver switching stays off the AVDD.
- **3.3 V analog branch — clean tap off the 3.3 V rail** (ferrite + local bulk): ADV7393 VAA (~0.15–0.2 A) only — **ADV7511 analog is 1.8 V, moved to the 1.8 V analog domain (corrected 2026-06-13)**; the **GS2962 cable driver gets its own ferrite branch** (SDI-rate transients kept off the DAC analog).
- **Clean analog rails — point-of-load ultra-low-noise LDOs** (ADP7142 class) per ADC/decoder, sized at schematic.

### 1.4 Resolution ceiling

- **1080p60 max** input + output for V1. HDMI 1.4 input handled by **Lontium LT8619C** RX (Z-7020 has no MGTs, no direct TMDS deserialize).
- 4K deferred to v2 / Schindler 3.0 — requires SoC upgrade (Zynq UltraScale+ ZU3EG/ZU4EV via TE0820/TE0822), DDR4, HDMI 2.0/2.1 silicon, HDCP 2.2/2.3 licensing. Treated as a separate product, not a V1 stretch goal.

---

## 2. HD pipeline architecture

### 2.1 Pipeline carries HD-bandwidth video throughout

RGB or YCbCr 4:2:2 at up to 1080p60 (148.5 MHz pixel clock) flows from input decoder through scaler / color / geometry to a shared HD signal bus. Downconversion to SD and rate-conversion happen **only inside per-output terminal encoders** that need it (composite, S-Video, SD component).

### 2.2 Outputs are independent and concurrent

The HD signal bus fans out to one terminal encoder per output. All terminals can run simultaneously at their own format and rate. Example: 1080p60 HDMI source can drive 1080p60 HDMI OUT + NTSC composite OUT (downconvert + 5:2 cadence + composite encode) + HD component OUT (YPbPr) all live from the same source.

### 2.3 Terminal encoders (independent FPGA blocks)

- **HDMI passthrough terminal** [All SKUs] — format-match or rate-convert, then HDMI 1.4 TX. Drives the external ADV7511 HDMI TX chip on the carrier. HDCP-protected content gated by UI consent dialog (§ 3.5).
- **NTSC/PAL composite encoder terminal** [All SKUs] — HD-to-SD downconvert + cadence convert + luma+chroma encode + sync gen. Drives ADV7393 in composite mode. HDL: `hdl/vid_timing.v` + `hdl/vbi_gen.v` + `hdl/chroma_gen.v` + `hdl/sample_gen.v` (Phase 2 first-light validated on Zybo + R2R DAC; chroma burst verification deferred per `dev-roadmap.md`).
- **Component YPbPr encoder terminal** [All SKUs] — HD passthrough or SD downconvert, drives ADV7393 in component mode.
- **SDI passthrough terminal** [Pro only] — HD re-serialize, drives GS2962.

### 2.4 Test pattern generator + still buffers as source

TPG + 4 still image buffers selectable as input source via the source mux (alongside HDMI / SDI / composite / component inputs), default at power-on. See `signal-flow.md` diagram 1.

---

## 3. Per-subsystem detail

### 3.1 HDMI input [All SKUs]

- **TPD12S016PWR** (TI) — HDMI ESD clamps + DDC/HPD level shift + 5V cable-power switch. ~$1.50.
- **LT8619C** (Lontium) — HDMI 1.4 RX, parallel RGB output to FPGA, embedded HDCP 1.4 keys (Lontium holds DCP Adopter Agreement). ~$2.
- Parallel RGB bus (24-bit + HSYNC + VSYNC + DE + pixel clock, ~28 lines) to TE0720 PL.
- I²C control from TE0720 PS — input mode, EDID (advertise V1's supported rates: 720p / 1080p / 1080i at 24/30/60 Hz; explicit reject of 25/50 Hz unless international firmware enables them).

### 3.2 HDMI output [All SKUs]

- **ADV7511KSTZ** (Analog Devices, LQFP-100) — HDMI 1.4 TX. Parallel RGB or YCbCr 4:2:2 input from FPGA on **its own dedicated 16-bit bus** (no longer shared with ADV7393); TMDS output. **Utility/monitoring output — no HDCP asserted on the TMDS output** (avoids the Xilinx HDCP-TX IP + DCP adopter license); a UI toggle disables the default HDCP block so protected content passes unencrypted per § 3.5. ~$7.
- **TPD12S016PWR** — second instance on output side for ESD/level shift.
- HDMI Type A panel-mount connector.
- I²C control from TE0720 PS.
- **Independent output buses (2026-06-11):** HDMI OUT, SDI OUT, and analog OUT each have their own FPGA read engine and parallel bus — no sharing. (Supersedes the earlier ADV7511/ADV7393 shared-bus optimization: the pin budget fits at ~119/152 PL without it, and sharing forced HDMI-out to track analog-out's format/rate — which broke concurrent 1080p60-HDMI + SD-composite, the headline §2.2 use case.)

### 3.3 Composite / component / S-Video input [All SKUs]

- **ADV7280AWBCPZ-M-RL** (ADI, AEC-Q100 grade, MIPI-capable variant) — multi-format decoder. CVBS + YPbPr + S-Video → BT.656 YCbCr 4:2:2 parallel bus to FPGA. ~$19.
- **SD-only input** — the ADV7280 decodes standard-definition only (480i/576i): CVBS, S-Video, and **SD component** YPbPr. **HD analog component (1080i/p) is not an input path** — HD enters via HDMI/SDI and the box upconverts SD analog → HD. (HD analog in would need an ADV7842-class decoder — out of V1 scope.)
- BNC 75 Ω panel-mount: 1× CVBS in + 3× YPbPr (component in). S-Video silicon-capable; no V1 mini-DIN connector (dropped 2026-05-11).
- I²C control from TE0720 PS.
- Passive front-end: input clamp diodes, switchable 75 Ω termination, AC-coupling, anti-alias LPF — schematic-phase.

### 3.4 Composite / component / S-Video output [All SKUs]

- **ADV7393BCPZ-REEL** (ADI) — triple 10-bit DAC with composite/S-Video/component encoding. I²C-switched runtime mode: composite/S-Video (DAC_A=CVBS, DAC_B=Y, DAC_C=C) OR component (DAC_A=Y, DAC_B=Pb, DAC_C=Pr). ~$16. Fed from the FPGA on **its own dedicated 16-bit parallel bus** (independent read engine; 16-bit carries SD composite/S-Video plus SD/ED/HD component per §2.2).
- **Output buffers (consolidated 2026-06-11):** 2× **LMH6643MAX/NOPB** dual op-amps (4 ch, 3 used) — one 130 MHz HD-capable channel per DAC output, serving both composite and component modes (single +5 V, AC-coupled at the BNCs). Replaces the prior OPA2350 SDTV-tier + single LMH6643: the 3-channel HD component path needs 3 HD buffers, so the two-tier split under-counted; all-LMH6643 is one part type, HD on every channel. ~$3 total. **One channel (4th of the 4) is spare.**
- **Optional second composite output [pre-layout decision, 2026-06-12]:** the spare LMH6643 channel can drive a second buffered CVBS output (its own 75 Ω back-term) to a rear BNC. Two ways to expose it: (a) an always-present second composite out — a composite mult/loop, useful for feeding a local monitor + a record path at once; or (b) in the **no-RF stuffing variant**, repurpose the rear F-connector position as this second composite BNC (RF fitted → F-connector; RF omitted → 2nd composite). Either way the footprint + back-term + panel position must be fixed **before carrier layout** (a respin to add later — same class as the 2nd-GbE-jack flag). The RF baseband tap is unaffected: it's a high-Z bridge off the *first* composite channel, not this spare one. Panel position tracked in `panel-layout.md`.
- **Rails:** ADV7393 draws 1.8 V (VDD digital + PVDD PLL) + 3.3 V VAA (analog, ~0.15–0.2 A). VAA sits on a clean 3.3 V branch (ferrite + local bulk); **the ADV7511 analog/PLL is 1.8 V — not on this 3.3 V branch (corrected 2026-06-13, see §1.3)**; the GS2962 cable driver gets its own ferrite branch so SDI-rate edges don't couple into the DAC analog. See §1.3.
- 4× BNC 75 Ω panel-mount (1× CVBS out + 3× YPbPr) with SMPTE-compliant back-termination.
- S-Video silicon-capable from ADV7393 in composite mode (Y + C on two DAC channels); no V1 mini-DIN connector.
- Modes: NTSC / NTSC-J / PAL / PAL-M (composite); SMPTE / Beta / Wide levels (component).

### 3.5 HDCP architecture [All SKUs]

- **Default-safe behavior:** HDCP-protected content (detected via LT8619C / GS3470 authentication state) is **blocked from HDMI OUT** by the HDMI passthrough terminal. Protected content can still flow to analog outputs (composite/component/S-Video don't carry HDCP) and to SDI OUT (broadcast workflow assumption).
- **UI consent gate (operator override):** unlocked via a UI dialog requiring explicit attestation ("I attest this is a non-violating use"). Once attested, HDMI passthrough permits HDCP-protected content through unencrypted. Attorney-advised posture.
- Non-protected content flows through HDMI OUT with no gate.
- **No HDCP encryption on HDMI OUT** — avoids the Xilinx HDCP IP license + DCP Adopter Agreement cost path.

### 3.6 SDI input/output [Pro only — carrier stuffing variant]

- **GS3470** (Semtech) — SDI 1.485/2.97 Gb/s RX. Recovers clock + VITC; feeds video pipeline AND genlock subsystem as a reference source. ~$15.
- **GS2962** (Semtech) — SDI TX. ~$17.
- 4× BNC 75 Ω panel-mount (Pro only): 1× IN + 1× **IN LOOP** (reclocked loop-through of the SDI input, for daisy-chaining the source downstream) + 1× processed OUT + 1× **OUT MIRROR** (buffered duplicate of the processed OUT).
- **SPI (GSPI) control from TE0720 PS** — GS3470/GS2962 use a 4-wire SPI host interface (CS/SCLK/SDIN/SDOUT), not I²C (confirmed 2026-06-13); shares the SDI SPI bus, separate CS each.
- Mini SKU: GS3470/GS2962 footprints on the carrier are unpopulated; Pro stuffing populates them. No daughter card; single PCB, factory-stuffed per SKU.
- **SDI IN LOOP [added 2026-06-13]:** an SDI input loop-through output, re-instating the GS3470 loop/mux path parked 2026-05-11. Implement as a **reclocked/buffered** loop — *not* the original passive tee (a passive 3G-SDI loop degrades the signal); confirm the exact GS3470 loop mechanism + any external reclocker/buffer at schematic. It is an **active** loop (drops on power loss), not a passive DA-style loop. SI-critical 3G serial → carrier-side, rear-panel **Row 1** next to the GS3470. *(HDMI IN loop was evaluated and **rejected** — no passive HDMI loop exists; it would need a TMDS splitter/redriver + HDCP-repeater handling, out of proportion for V1, and concurrent outputs per §2.2 already cover the downstream-monitor use case.)*
- **SDI OUT MIRROR [added 2026-06-13]:** the GS2962 exposes two serial-digital outputs (**C10 / D10**); the second SDO drives a buffered duplicate of the same processed SDI stream to a fourth SDI BNC. **Active** (drops on power loss), SI-critical 3G serial → carrier-side, rear-panel **Row 1** next to the GS2962. KiCad: placed as **J703** on Sheet 7. Use case: feed two downstream SDI destinations from one processed output without an external DA.

### 3.7 Genlock subsystem [All SKUs]

Auto-sensing reference input across LTC / black burst / tri-level sync.

**Front-end:**
- BNC 75 Ω panel-mount: **REF IN** + **REF LOOP** (passive loop-through for daisy-chaining).
- **REF interconnect — Option A pigtail (banked 2026-06-13):** the REF panel BNCs connect to the carrier genlock front-end by a short **75 Ω coax pigtail → Hirose U.FL-R-SMT-1** receptacle on the carrier — continuous coax from panel to silicon, no board-to-board mezzanine hop on the phase-critical sync lines (this is what lets the BNCs mount on the riser while the genlock front-end stays carrier-rooted). u.FL is 50 Ω / 6 GHz; the few-cm 50 Ω segment is an electrically negligible reflection at genlock/tri-level edge rates. **Upgrade path** (impedance-exact + serviceable, if ever needed on these 2 lines): swap to a 75 Ω MMCX PCB jack (~500 mating cycles, ~$3–6 ea). A 75 Ω blind-mate float-bullet was evaluated and rejected — effectively a custom part (the SMP/SMPM/AFI float catalogs are all 50 Ω). See `bom-v1.md` §2 and the 2026-06-13 changelog entry.
- Clamp diodes, switchable 75 Ω termination, AC-coupled buffer.
- **LTC6912CGN-2#PBF** (ADI/LTC) — 2-channel programmable gain amplifier. ~$8.
- **AD9204BCPZ-20** (ADI) — dual-channel 10-bit 20 MSPS ADC. ~$16. Pin-compatible upgrade path to AD9231/9251/9258/9268 if higher resolution becomes necessary.

**Signal classification + clock generation:**
- **RP2040** (carrier, dedicated to genlock) — owns slow-control: autosense decision, PGA gain commands, Si5351 register writes, status reporting to Zynq PS over UART. ~$1.
- **Si5351A-B-GT** (Skyworks/Silicon Labs) — programmable clock generator. ch0 → FPGA master clock; ch1/ch2 reserved for future GPSDO 10 MHz distribution. ~$2.

**FPGA-side logic (all SKUs):**
- Autosense classifier (LTC biphase mark / BB 15.734 kHz / tri-level pulse signature) running on the 20 MSPS ADC stream.
- Per-format decoders: LTC frame decoder + TC parser, BB sync separator + colorburst phase extract, tri-level decoder, SDI recovered clock + VITC from GS3470 (Pro only).
- Reference selector mux (operator override + autosense priority: LTC > tri-level > BB > SDI > free-run).
- Digital PLL: phase/frequency detector → loop filter (default ~0.5 Hz bandwidth, configurable) → NCO/integrator (holds last value on ref loss → free-run hold) → lock detector (Acquiring / Locked / Lost state + phase-error magnitude + 1 s stddev quality metric). Integrator's correction pushed to Si5351 via RP2040 over I²C.

**VITC:** extracted from SDI video input (Pro only) when SDI is selected as reference — removes need for separate LTC cable when SDI video is already connected.

### 3.8 Reference outputs — dual SYNC OUT [Pro only]

- 2× BNC 75 Ω panel-mount (SYNC OUT 1 + SYNC OUT 2).
- **SYNC OUT 1** — runtime format select: black burst / tri-level / LTC unbalanced (also DARS AES3id 48 kHz + Word Clock 48/96 kHz as firmware-only future). **SYNC OUT 2 — LTC only.** Driver bandwidth DC–10 MHz, output swing ≥2 Vpp into 75 Ω.
- Each OUT targets its own frame rate, locked to the input reference via rational ratios. Cross-rate sync conversion absorbed into V1 Pro (originally scoped as V1.5).
- **SYNC OUT 1 chain:** FPGA phase accumulator → waveform gen → **AD9742** (12-bit, 210 MSPS TxDAC, current-output; pin-compatible to AD9744 if 14-bit ever needed) → I-to-V + **LMH6643** 75 Ω cable driver. 13 PL pins (12 data + sample clock). **SYNC OUT 2 chain:** FPGA biphase-mark generator → 1 PL pin → slew-limited **LMH6643** (2nd channel of the same dual, SMPTE 12M ~25 µs edges) → 75 Ω BNC. **PWM dropped** — it cannot reproduce black-burst colorburst (3.58/4.43 MHz) or tri-level edges (~4 ns) at usable resolution; viable for LTC only.
- Mini SKU: unpopulated; the SYNC OUT 1 DAC + shared LMH6643 driver + SYNC OUT 2 LTC chain are omitted at assembly. REF LOOP BNC + REF IN BNC remain on Mini for genlock input.

### 3.9 RF modulator output [Optional module — Period CRT support]

Adds an RF modulated output on NTSC Ch3 or Ch4 (operator-selectable) for 1970s consumer CRTs with antenna-only inputs.

**Operator model:** picks one of three analog output modes via UI. F-connector lives beside the composite BNC; both physically present, only one electrically live per mode.

| Mode | Live connector | ADV7393 state | RF chain |
|---|---|---|---|
| Composite | composite BNC | composite mode | disabled |
| RF Ch3 | F-connector (+ composite BNC) | composite mode | enabled, Si5351 ch1 → 61.25 MHz |
| RF Ch4 | F-connector (+ composite BNC) | composite mode | enabled, Si5351 ch1 → 67.25 MHz |
| Component | 3× component BNC | component mode | disabled |

HDMI and SDI remain independently live; not part of the analog-output mode mux. The composite BNC stays live in RF mode (the RF chain taps the same buffered signal; the ADG419 series switch was dropped 2026-06-11 — a ~25 Ω switch in a 75 Ω video line degraded the composite output for no benefit).

**Architecture (separate daughter board — committed 2026-06-11):** the whole RF chain — ADL5391 analog multiplier (DSB-AM) + dedicated Si5351 RF carrier gen + silent CW audio pilot at video_carrier + 4.5 MHz + 5th-order LC bandpass (56–73 MHz, covers Ch3 + Ch4) + ERA-3SM+ MMIC amp + 50→75 Ω minimum-loss pad + ESD + F-connector — lives on a **standalone shielded, panel-mounted daughter board** (Masach MS643 two-piece can, 4-layer PCB), not on the carrier. The carrier feeds it baseband composite over **1× u.FL** + a **6-pin header** (12 V, 3.3 V, GND×2, I²C); no VHF crosses the interconnect (RF Si5351 + crystal are on the board). RF mute = disable the daughter-board Si5351 output over I²C. Cleanest FCC partition — all RF in one Faraday box — and makes the Mini-omit a populate/omit choice with no carrier respin.

**Truly optional (2026-06-12):** never fitted by default — added only when ordered. The carrier (both SKUs) always carries the unpopulated u.FL pad + 6-pin header, so RF is a clean populate/omit on any build with no respin. Offered as a Pro-tier option; Mini-eligibility is an open product/commercial call (technically fittable on any carrier).

Full spec: [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md) (chain) + [`rf-modulator-daughter-board-option.md`](rf-modulator-daughter-board-option.md) (partition + build). BOM contribution (Pro): ~$40 daughter-board assembly + ~$1 carrier interface.

---

## 4. Frame rates

### 4.1 Pipeline throughput rates (HD path)

1080p23.98 / 1080p24 / 1080p25 / 1080p29.97 / 1080p30 / 1080p50 / 1080p59.94 / 1080p60 / 1080i50 / 1080i59.94 / 720p50 / 720p59.94 / 720p60.

### 4.2 Output rates per terminal encoder

- **Composite / component encoder (analog outputs):** 23.976 / 24.000 / 25.000 / 29.97 / 30.000 fps.
- **HDMI / SDI passthrough:** matches selected output rate (full pipeline rate matrix).

### 4.3 Cadence convert per output

- **3:2 auto-detect** (default Auto): when source is 30/60 fps with 3:2 cadence in the data (telecined 24p material), detects the cadence and extracts the original 24p sequence without motion filtering. Cleaner than blind frame-rate conversion. Auto-falls-back to motion filtering when 3:2 cadence isn't detected.
- Manual cadence ratios: 5:2 (60→24), 6:5 (60→25), 4:5 (24→30), 2:1 (60→30), 1:2 (24→48), Slip (23.98↔24 drift comp).
- **Motion filter selection:** Quadratic (default, 3-frame) / Linear (2-frame, lighter DSP) / Off (drop or repeat frames, produces judder).

---

## 5. Color pipeline (port from Screenie)

- 1D LUT per channel (gamma, 1024 entries × 12-bit)
- 3×3 color matrix (color space + white point)
- Per-channel gain/offset (fine trim)
- RGB white/black point controls
- Color temperature presets: 3200 K / 4800 K / 5600 K / 6500 K / 9300 K / Custom
- **YUV color-circle adjust** (X/Y axes on chroma plane) in addition to RGB controls. Preserves luminance + saturation when shifting color temp (vs RGB subtraction which darkens and desaturates). Inherited from MVPHD-24's approach; preferred by video colorists familiar with vectorscope X/Y.
- Saturation, hue, black level
- **Proc Amp Enable bypass toggle** — single per-input toggle disables all proc-amp adjustments (unity gain). Used for raw-vs-adjusted quick compare. Bindable to a front-panel quick-select button (default Q3).

---

## 6. Geometry

- Anamorphic / Letterbox / Pillarbox / 14:9 Letter / 14:9 Pillar / Cut-Crop / Custom — explicit ARC modes with both-direction labeling (16:9→4:3 + 4:3→16:9).
- Pincushion / keystone / 4-corner warp.
- Polyphase scaler (8-tap H / 4-tap V).
- Active window position trim (X/Y pixel offset).
- Overscan compensation modes: safe-area-only vs fill-with-overscan.

---

## 7. Effects library

13-effect EFX menu. Effects can be temporarily toggled OR saved into a per-CRT profile for permanent operation. Profile-persistent enables the "make this LCD look like a CRT in-shot" workflow (scanlines + slight blur + warm tint saved as a profile).

**Effects:**
- Freeze frame
- Random noise (snow)
- Block artifacts (intensity-configurable)
- CRT power-off (collapse + flash + black, ~1.5 s)
- CRT power-on (flash + scan-in)
- Vertical hold loss (rolling)
- Snow burst (channel change)
- Color rolling (chroma desync)
- VHS tracking error (drifting noise bars)
- Hum bars (slow horizontal dim bars)
- Burn-in ghost overlay (source from still buffer)
- Scanline emphasis (CRT look on downstream LCD)
- Blur (Gaussian — Tier 3 HDL cost, may land later in V1)
- Solarize
- Posterize

**Modifiers:** blend/mixer (0–100 % wet/dry), transition time (0–240 frames fade in/out), per-effect intensity params.

**HDL effort:** ~2–3 weeks for MVPHD-set + Tier 1 CRT effects post-pipeline-validation; blur deferred if needed.

---

## 8. Per-CRT calibration profiles

- JSON profiles in the NovaTool tile-profile pattern.
- Import / export via web UI; recall by name from front panel or web.
- Snapshots: color + geometry + sync structure + behavior + effects.
- 4× front-panel quick-recall buttons (Mini: P1–P4; Pro: bindable quick-selects).

---

## 9. CRT-specific signal controls

- Sync structure parameters (per profile): front porch, back porch, equalizing pulse count, serration pulse width.
  - **Wide-back-porch default for 24p camera shoots** — back porch ≈ 7–10 µs (1.5–2× SMPTE 170M nominal ~4.7 µs). Gives camera shutter a larger target window to land its capture inside the active video region without straddling V-blank — eliminates filmed-CRT sync bar. Industry wisdom (2026-05-11). Tunable per-profile so DPs can adjust to their shutter angle.
- Alternating 90° colorburst phase offset between fields (toggle). Improves CRT chroma stability (playbook Ch. 5).
- Subcarrier coherent vs non-coherent toggle (playbook Ch. 4).
- Sync tip voltage trim — ±100 mV around SMPTE −286 mV (for oddball-AGC CRTs).
- Setup pedestal: 7.5 IRE (NTSC-M) vs 0 IRE (NTSC-J).
- Output mode select: NTSC / NTSC-J / PAL / PAL-M.
- Field cadence / pulldown options for non-matching rates: off / hard switch / crossfade.
- VITC insertion in output.

---

## 10. Behavior controls

- Signal loss behavior: black / freeze / last-good-frame-for-N-seconds.
- Burn-in protection: auto-darken or pixel-shift after N minutes static.
- Burn-in recovery / repair mode: standalone scrolling white/black/gray patterns at user-set rate. Runs from front panel with no input. Known CRT repair technique.
- Degauss trigger output: GPIO/relay for pro CRTs that accept remote degauss.

---

## 11. EDID

- Editable / emulatable EDID on HDMI inputs.
- Resolution + rate + preset selectable independently (UI menu § 1.2).
- Force-mode presets: 1080p24, 1080p23.98, 1080p25, 720p, Custom (web-upload `.bin`).
- Without correct EDID, playback laptops negotiate to whatever they feel like and burn shoot time on format debugging. Day-1 critical.

---

## 12. Test pattern generator

- SMPTE color bars (75 % / 100 % / SMPTE).
- PLUGE.
- Color reference fields.
- Geometry grid (100 % / 95 % / 90 % safe area).
- Convergence pattern (operator CRT alignment, separate from content warp).
- Purity (full-field R/G/B).
- Focus / zone plate (center + corners).
- Burn-in repair scroll patterns.
- **Shutter Phase Reference** — alternating-field two-color signal for visually phasing a film camera's shutter to the CRT. Solid color in viewfinder = correctly phased; split color = mis-phased. Default Blue/Yellow (industry convention); color pair operator-configurable.
- **Custom user-loaded test signals** (8 slots) — operator uploads PNG/TIFF via web UI; stored on TE0720 eMMC, persist across power cycles.

---

## 13. Still image buffers

- 4 image buffers on TE0720 eMMC, selectable as input source via source mux. Persist across power cycles.
- **Format:** PNG up to 1920×1080. Downscaled on the fly to output rate. Typical ~1–5 MB per slot.
- **Primary storage:** TE0720 eMMC (8 GB total; ~25 MB used for 4 slots).
- **Storage:** on-module eMMC (8 GB) holds the image library; firmware updates + library load over network / USB-C. (Front-panel microSD dropped 2026-06-11 — only one free PS SDIO controller, taken by WiFi; see `sheet3-te0720-som-backbone.md` §4.)
- **Load time:** cold load from eMMC < 1 s; cached in DDR3 < 10 ms.
- **First-boot state:** Buffer 1 pre-populated at factory with a Schindler splash image (logo + IP + firmware version). Buffers 2–4 ship empty.
- **Use cases:** power-on splash, idle reference frame, custom brand ident, quick-recall reference for QC, signal-loss fallback, source for EFX burn-in ghost overlay.
- **Thumbnails:** Pro front-panel TFT shows 4-wide horizontal thumbnail strip; Mini OLED shows text-only buffer status; web UI shows full-quality thumbnails.

---

## 14. Networking + control plane

> ⚠️ **Partially superseded — see the 2026-06-13 direction update atop [`control-plane-architecture.md`](control-plane-architecture.md).** UI is now **unified across all SKUs on a standalone off-SoM MCU** (one firmware = front panel + web UI); `schindlerd` becomes a thin PS-side AXI register agent. The PS-hosted web server below is being reworked; the head-MCU choice (ESP32-S3 vs RP2040 + Ethernet/WiFi) is the open sub-decision. Propagated here once the MCU is locked.

- **Zynq PS (dual A9 Cortex @ 866 MHz) running PetaLinux** hosts the control plane on both SKUs: web UI server (Node.js / Flask), color calibration UI, configuration persistence, EDID negotiation, mDNS, OTA updates, SSH / SCP, NTP, status logging.
- **Wired:** GbE on TE0720 (PHY on-module) → RJ45 magjack on carrier → rear panel.
- **WiFi:** Laird Sterling LWB5+ module on carrier — pre-certified, 88W8997 chipset, dual-band a/b/g/n/ac + BT5.0. WiFi on **SDIO0 (PS MIO40–45, strapped to 1.8 V — direct, no level shifter)**; BT on a separate PS UART. ~$30. Concurrent AP + STA via Linux hostapd + wpa_supplicant. Mini may stuff lower-cost ESP32-WROOM (~$5) as a cost-down option; assembly-time decision per `packaging-skus.md`.
- **Antennas:** 2× RP-SMA stubs on rear panel (Pro) or internal chip antenna (Mini compact option).
- **BLE:** for initial pairing/setup. Companion app discovers Schindler via BLE, sends WiFi credentials over encrypted GATT.
- **USB-C** on rear panel for service / firmware update / debug. PetaLinux exposes console + ethernet-over-USB gadget for ops access without network.

---

## 15. Front panel — SKU variants

> ⚠️ **Partially superseded — see the 2026-06-13 direction update atop [`control-plane-architecture.md`](control-plane-architecture.md).** UI is now **unified across all SKUs on a standalone off-SoM MCU** (one firmware = front panel + web UI). The display *hardware* below still stands (Mini OLED / Pro TFT), but "no dedicated UI MCU on Mini" and the PS-driven Mini UI are retired — both SKUs run the off-SoM MCU head. Head-MCU choice (ESP32-S3 vs RP2040 + Ethernet/WiFi) is the open sub-decision; propagated here once locked.

### 15.1 Mini front panel [Mini only]

- Power button (lighted soft pushbutton).
- 1.3" mono OLED display (I²C, SH1106 or SSD1306) — status display + menu.
- 5-way navigation switch (D-pad + center enter) — GPIO via EMIO to Zynq PS.
- 4× tactile preset buttons (P1–P4) — GPIO via EMIO to Zynq PS.
- Single tri-color status LED (green=locked, amber=input issue, red=sync loss/error).
- **No dedicated UI MCU.** PetaLinux user-space app drives OLED via `/dev/i2c-N` and buttons via `gpio-sysfs` interrupt handlers.

### 15.2 Pro front panel [Pro only]

Separate mezzanine board mounted behind the front-panel aluminium, connected to main carrier via UART + power cable.

- Power button (lighted soft pushbutton).
- **Front TFT — Newhaven NHD-2.9-376960AF-ASXP** — 2.9" 376×960 IPS, mounted landscape (effective 960×376), ST7701SN driver. 24-bit parallel RGB. 1050 cd/m². Bezel-opening cutout 69×28 mm.
- **BridgeTek BT817Q EVE 4 graphics controller** — drives the NHD-2.9 over 24-bit parallel RGB, holds frame in 1 MB internal RAM_G, renders from high-level command lists sent by RP2040 over SPI. ~$10–13.
- **Mezzanine RP2040** (separate from genlock RP2040 on carrier) — UI MCU. Reads encoders + buttons via PIO/GPIO, sends EVE command lists over SPI, syncs UI state to Zynq PS over UART. ~$1.
- 2× ALPS EC11E18244AU rotary encoders (36 detents / 18 PPR, integrated push-switch, **knob shroud / guard** mandatory).
- 4 fixed tactile buttons: Home / Back / Menu / Confirm.
- 2–3 quick-select tactile buttons (defaults: BLACK / MONO / Proc Amp bypass).
- Front status LED column (mirrors rear per-connector LED state).
- **NHD-2.9 backlight: 6.0 V boost regulator** on mezzanine (TI TPS61040 class, ~$0.50).

---

## 16. Rear panel — SKU variants

### 16.1 Mini rear panel [Mini only]

| Connector | Qty | Notes |
|---|---|---|
| HDMI Type A | 2 | IN + OUT |
| BNC 75 Ω | 6 | 1× CVBS IN + 1× CVBS OUT + 3× component OUT + 1× genlock REF IN |
| Mini-DIN 4-pin | 0 or 1 | S-Video silicon-capable; connector optional per build |
| RJ45 magjack | 1 | GbE |
| USB-C | 1 | Service / firmware update |
| DC power jack OR IEC C14 | 1 | Pending PSU-style decision (external brick vs internal LRS-50-12) |
| RP-SMA WiFi antenna | 0 or 2 | Internal chip antenna or external |

### 16.2 Pro rear panel [Pro only]

| Connector | Qty | Notes |
|---|---|---|
| IEC C14 (FN9260B-6-06) | 1 | Mains + integrated fuse + EMI filter |
| HDMI Type A | 2 | IN + OUT |
| BNC 75 Ω | 16 | 1× CVBS IN + 1× CVBS OUT + 3× component IN + 3× component OUT + 2× REF (IN + LOOP) + 2× SYNC OUT + 4× SDI (IN + IN LOOP + OUT + OUT mirror) |
| F-connector | 1 | RF modulator output (on the RF daughter board's own panel edge) |
| RJ45 magjack | 1 | GbE |
| USB-C | 1 | Service / firmware update |
| RP-SMA WiFi antennas | 2 | Dual antennas for AP+STA |
| **Rear status LCD** | 1 | NHD-1.5 240×240 (see § 17) |
| Per-connector status LEDs | ~21 | Tricolor R/A/G (see § 18) |

### 16.3 Rear status LCD [Pro only]

- **Newhaven NHD-1.5-240240AF-CSXP** — 1.5" 240×240 IPS square, ST7789VI with internal controller + frame RAM. 32.52 × 35.32 mm module, ~28 × 28 mm active cutout. 1200 cd/m².
- Interface: 8-bit 8080-II parallel OR 3/4-wire SPI; **4-wire SPI hardwired via strap pins** IM0=0/IM1=1/IM2=1.
- **Backlight: 3.0 V / 100 mA** — small LDO from 3.3 V (~$0.20).
- Owned by Zynq PS over one dedicated SPI port. ~1 s refresh.
- Content: paginated summary view — selected ref + lock state + IP + page-through I/O detail. Read-only.

### 16.4 Per-connector status LEDs [Pro only]

- Tricolor R/A/G LED at every Pro rear-panel connector. **Lumex SSF-LXH409SISUGW** — 3 mm bi-color R/G **common-anode**, one-piece **right-angle PCB indicator** (emits parallel to the board → faces the rear panel; no holder or light pipe), ~$0.60–1.00 each (confirm at procurement). Banked 2026-06-13c.
- **Driver:** 3× **TLC59116F** (TI) — 16-channel constant-current I²C drivers with per-channel PWM dimming. ~$1.50 each.
- **Convention (inputs):** Red = expected/missing, Amber = present/not-in-use, Green = present/in-use, Off = disabled.
- **Convention (outputs):** Green = present/outputting, Amber = configured/no source, Off = disabled.
- **Convention (sync IN):** Red = invalid, Amber = locked/not selected, Green = locked/selected as ref, Off = nothing.
- Default brightness ~10 %; ramps up on fault.
- Owned by Zynq PS over I²C. Front-panel LED column mirrors rear state on Pro.

---

## 17. UI architecture

> ⚠️ **Partially superseded — see the 2026-06-13 direction update atop [`control-plane-architecture.md`](control-plane-architecture.md).** UI is now **unified across all SKUs on a standalone off-SoM MCU** — one firmware drives both the front panel and the web UI; the per-SKU split below (Pro RP2040+PS / Mini PS-direct) is retired. `schindlerd` shrinks to a thin PS-side AXI register agent. Head-MCU choice (ESP32-S3 vs RP2040 + Ethernet/WiFi) is the open sub-decision; propagated here once locked.

### 17.1 Pro UI [Pro only]

- Front-panel mezzanine owns its own subsystem: RP2040 UI MCU + BT817Q EVE + NHD-2.9 TFT + encoders + buttons + front LED column.
- Mezzanine ↔ main carrier link: UART + power only.
- RP2040 ↔ Zynq PS: UART for state sync.
- RP2040 ↔ BT817Q: SPI at ~30 MHz for graphics command-list streaming.
- UI framework: **BridgeTek EVE Asset Builder / EVE Screen Editor** + the FT8xx command set. No TouchGFX, no LVGL, no LTDC. Higher-level paradigm (display lists + co-processor commands) than the pixel-blit-and-DMA approach an STM32+LTDC path would require.
- UI alive in < 1 s from cold boot via RP2040; Linux takes 15–30 s to boot on Zynq PS behind the scenes with progress shown on TFT.

### 17.2 Mini UI [Mini only]

- 1.3" mono OLED + buttons + tri-color LED all wired directly to Zynq PS.
- PetaLinux user-space app `schindler-ui` handles event detection, menu state, preset save/recall (filesystem), and LED color/blink patterns.
- I²C via `/dev/i2c-N` for OLED; GPIO via `gpio-sysfs` interrupt handlers for buttons.
- **No dedicated UI MCU on Mini.** UI alive once PetaLinux user-space app starts (typically ~15–30 s post power-on; Mini accepts longer cold-boot vs Pro because the simpler UI doesn't need to be alive before the rest of the system).

Full menu hierarchy in [`ui-menu.md`](ui-menu.md).

---

## 18. Expansion header — design rule

- 2× 20-pin (or 1× 40-pin) 2.54 mm header on the carrier exposes unused TE0720 PL pins + 3.3 V / 5 V / GND rails + I²C bus tap + (optional) SPI bus tap.
- Preserves field-upgrade and prototype-extension paths for future add-on boards or experimental modules.
- ~$5 in connector + minimal PCB area. Insurance against early architectural lock-in.

---

## 19. Debug / dev interfaces

- 10-pin 2.54 mm JTAG header (Xilinx standard) for external JTAG cable access.
- 3- or 4-pin UART debug header for PetaLinux console fallback.
- Boot mode DIP switch or jumper block (QSPI / SD / JTAG boot selection).
- PS reset (POR) button.
- PL reset button (optional).
- Board-level status LEDs (power, PL_DONE, PS_BOOT, 2–4× user).

---

## 20. Cross-references

- **Active development arc:** [`dev-roadmap.md`](dev-roadmap.md)
- **SKU packaging details:** [`packaging-skus.md`](packaging-skus.md)
- **Bill of materials:** [`bom-v1.md`](bom-v1.md)
- **Signal flow diagrams:** [`signal-flow.md`](signal-flow.md)
- **Panel layouts (front + rear, both SKUs):** [`panel-layout.md`](panel-layout.md)
- **UI menu hierarchy (Pro):** [`ui-menu.md`](ui-menu.md)
- **MVPHD-24 comparison + gap analysis:** [`mvphd-comparison.md`](mvphd-comparison.md)
- **RF modulator subsystem detail:** [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md)
- **Op-amp output stage design:** [`opamp-stage.md`](opamp-stage.md)
- **R-2R DAC bench reference:** [`r2r-dac.md`](r2r-dac.md)
- **Development narrative:** [`schindler-playbook.md`](schindler-playbook.md)

Decision history: [`01-spec-changelog.md`](01-spec-changelog.md).

---

## 21. Open questions / parked decisions

- **Mini WiFi chip:** LWB5+ (same as Pro, ~$30, dual-band a/c + BT5.0) vs ESP32-WROOM (~$5, 2.4 GHz only). Assembly-time stuffing decision. **Pending Justin's call.**
- **Mini PSU strategy:** internal LRS-50-12 + IEC inlet (matches Pro, same carrier wiring, ~$33 BOM) vs external 12V brick + DC barrel jack on carrier (cheaper, looser positioning, different rear-panel cutout). **Pending Justin's call.**
- **Mini S-Video output connector:** silicon-capable on the carrier (ADV7393 in composite mode). Add mini-DIN to Mini rear panel or omit. **Pending decision.**
- **S-Video input** to ADV7280 path: free in silicon, costs one mini-DIN + 2 traces. Common on retro source gear (VHS, S-VHS, Hi8). **Pending decision.**
- **SDI daughter card option (Pro):** the Pro SDI silicon is currently spec'd as factory-stuffed on Pro carriers. A daughter-card-on-headers approach was considered for field-upgrade of Mini → Pro SDI, but adds signal-integrity complexity (3G-SDI through mezzanine). Default: factory-stuff on Pro, no daughter card. **Confirm.**
- **Field-upgrade path Mini → Pro:** since Mini and Pro share the same carrier PCB with stuffing differences, a "Pro upgrade kit" (factory-installed silicon retrofit) is theoretically possible. Need to decide whether to support it as a product offering or treat the SKUs as one-way commitments at purchase. **Defer until Mini ships.**
- **VGA OUT [both SKUs]:** dedicated terminal encoder for driving VGA-input CRTs on camera at 24/30 fps film cadences. Architecture under consideration: ADV7125 triple 8-bit video DAC (~$6) + 74AHCT125 sync level shifter + HD-15 panel-mount + passives, ~$10/unit BOM addition each SKU. Frame-doubles source cadence to VGA-compatible refresh (24p → 48 Hz, 30p → 60 Hz) so VGA CRTs lock and camera shutter catches integer refresh cycles per camera frame. Requires new FPGA HDL block: HD bus tap → 1:2 frame doubler → VGA-rate pixel timing → RGB to DAC. Prototype path on Zybo via Pmod VGA (Digilent 410-345, on inbound) before committing carrier silicon. **Pending Justin's call to bank as confirmed feature.**

---

## 22. Out of scope (deliberately)

| Feature | Why not |
|---|---|
| NDI / SRT / RTMP input | Market wants deterministic frame-locked playback, not streaming. |
| ST 2110 | Wrong market. |
| HDR processing | HDMI 1.4 doesn't carry HDR metadata; CRTs and analog outputs can't display HDR; HDR pipeline DSP cost not justified. |
| Multiviewer | Single output by design. |
| Recording / capture | Downstream concern. |
| Logo / lower-third / CC overlay | Out of mission. |
| Touchscreen UI | Glare, smudges, no tactile, fails in production environments. Replaced by rotary encoders + dynamic TFT (Pro) or mono OLED + buttons (Mini). |
| DisplayPort IN | Dropped 2026-05-11 connector simplification. |
| VGA IN (HD-15) | Significant HDL complexity (auto-positioning + sample-phase recovery) for a declining input format. Out of scope for V1. |
