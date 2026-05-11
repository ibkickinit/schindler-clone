# Schindler 2.0 — Spec & Backlog

**Status:** Draft 2026-05-10 PM
**Sources:** `README.md`, `docs/schindler-playbook.md`, feature scoping session 2026-05-10, hardware architecture session 2026-05-10 PM
**Working principle:** Stay Schindler-shaped. Width dilutes the product.

This is the SSOT for the current spec. Items marked **[PROPOSED]** are awaiting confirmation; everything else is confirmed. Revision history at the bottom shows decision chronology.

---

## Hardware foundation

### Production architecture
- **SoC:** Trenz TE0720 SOM — Xilinx Zynq-7020. **Production: TE0720-04-62I33MA** (XC7Z020-2I speed grade, industrial -40°C to +85°C, 1 GB DDR3L, 32 MB QSPI flash, 8 GB eMMC, GbE PHY). **Bench/prototype: TE0720-04-31C33MA** (-1 speed grade, commercial 0°C to +70°C, same memory config) — cheaper, better DigiKey stock, identical pinout/footprint so dev work ports directly to production silicon. **Explicitly ruled out: -61C530A and similar 256 MB DDR3 / no-eMMC variants** — insufficient memory for Linux-hosted video pipeline (need 1 GB DDR3 for frame buffers + PetaLinux footprint + Node.js heap + working memory; need eMMC for Linux rootfs). 152 FPGA I/O via Samtec Razor Beam connectors.
- **Carrier:** custom 6-8 layer PCB, accepts TE0720 SOM, hosts all input/output, control, and power circuitry
- **Genlock subsystem:** RP2040 + Si5351 generates pixel clock from selected reference; FPGA locks output timing to it
- **UI MCU:** STM32H735IGT6 (LQFP176, 480 MHz Cortex-M7) on carrier — owns front panel (TFT, encoders, buttons, LEDs); communicates with Zynq PS over UART or SPI
- **Output DAC:** Analog Devices ADV7393 — triple 11-bit DAC with composite/S-Video/Component encoding, I²C-configured
- **Input video decoder:** ADV7280-class multi-format decoder for composite/component analog inputs

### Development hardware
- Digilent Zybo Z7-20 — FPGA pipeline bring-up (matches production silicon)
- Trenz TE0720-04-31C33MA + TE0703-07 carrier — production SOM (commercial-grade variant for bench) on Trenz dev carrier for porting FPGA design to production silicon before custom carrier rev
- 33337 springloaded heatsink for TE0720 — passive thermal dissipation under continuous video pipeline load
- EVAL-ADV7393EBZ — output DAC eval board (replaces R2R perfboard after first-light)
- STM32H735G-DK (~$70) — UI MCU + TFT bench development; produces production-quality UI in TouchGFX or LVGL, ports to STM32H735IGT6 on production carrier
- Oscilloscope — signal analysis

### Resolution ceiling
- v1: 1080p60 max input. HDMI 1.4 input handled in Z-7020 IOLOGIC TMDS deserialization; DisplayPort handled via DP-to-HDMI level-shifter chip on carrier (Z-7020 has no MGTs).
- 4K input deferred to v2 — would require SOM upgrade (Z-7030 with GTPs) or external 4K receiver chip feeding Zynq at 1080p.

---

## V1 base unit — In scope

### Inputs
- HDMI in (TI TMDS141 retimer → FPGA AXI VDMA)
- DisplayPort in (via DP-to-HDMI level shifter on carrier)
- Composite in (1 BNC)
- Component in (3 BNCs, YPbPr)
- ADV7280-class decoder feeds analog inputs to FPGA via ITU-R BT.656 8-bit YCbCr 4:2:2 over parallel bus → existing VDMA path
- SDI reference in (1 BNC) — Semtech GS3470 receiver. Locks PLL to recovered SDI clock, extracts VITC for timecode, format auto-detect drives frame-rate selection. **[PROPOSED upgrade from prior GS2971-class spec]** — GS3470 is newer, lower power, smaller package, includes 2×2 input mux enabling native loop-through for broadcast tier.

### Outputs
- **One ADV7393 chip serves both output modes via runtime selection** (I²C-switched, mutually exclusive): composite/S-Video mode (DAC_A=CVBS, DAC_B=Y, DAC_C=C) OR component mode (DAC_A=Y, DAC_B=Pb, DAC_C=Pr). Operator chooses output mode in the UI; the unused output BNC/mini-DIN goes to 0 V / blanking (analog mux or buffer-disable on carrier handles physical routing). Composite and component are never both live; confirmed 2026-05-10 PM 7th update.
- Composite out (1 BNC) — NTSC, NTSC-J, PAL, PAL-M
- Component out (3 BNCs, YPbPr)
- S-Video out (1 mini-DIN 4-pin) — generated free from ADV7393, just adds connector
- HDMI out (1 connector) — loop-through confidence monitoring; FPGA pipeline drives a TMDS retimer on the carrier; same DAC-fed pipeline mirrored to digital output

### Frame rates
- 23.976, 24.000, 25.000, 29.97, 30.000

### Genlock / reference inputs
- Auto-sensing front-end across LTC / black burst / tri-level sync (Architecture A confirmed 2026-05-10 PM 7th update). Each input passes through clamp diodes, switchable 75 Ω termination, AC-coupled buffer, programmable-gain amplifier (LTC6912 or AD8369 class — final PGA selection deferred), switchable analog LPF, then **Analog Devices AD9204-20** (dual-channel 10-bit 20 MSPS ADC, 1.8 V analog supply, 1.8-3.3 V output drive — single chip handles both BNC inputs; pin-compatible upgrade path to AD9231/AD9251/AD9258/AD9268 for 12/14/14/16-bit if future need) to FPGA. FPGA runs detection logic in parallel and identifies signal type by characteristic signature (LTC biphase mark + 0xBFFC sync, black burst 15.734 kHz line rate + 3.58 MHz burst, tri-level pulse pattern). PGA-driven AGC loop solves input level frustration — no front-panel padding/gain needed.
- Connector mix: 1× XLR for balanced LTC, 2× BNC autosensing (LTC unbalanced, black burst, or tri-level)
- RP2040 + Si5351 PLL drives FPGA pixel clock from whichever reference is selected/auto-preferred (priority: LTC > tri-level > black burst > free-run). RP2040 handles slow-control (autosense decision, PGA gain commands, Si5351 register writes, status reporting); FPGA does high-rate signal classification of the 20 MSPS ADC stream.
- VITC extracted from SDI ref input (when present) provides timecode without separate LTC connection

### 60 Hz → 25 fps PAL cadence conversion
- US 60Hz-family sources (1080p59.94, 1080p60) on European-region CRTs without offline pre-conversion
- Crossfade at field boundaries, 6:5 ratio. Reuses 60→24 (5:2) cadence framework
- Dev phase: matched-rate-only fallback until cadence converter is built — non-blocking, integrates after pipeline is functional

### Color pipeline (port from Screenie)
- 1D LUT per channel (gamma, 1024 × 12-bit)
- 3×3 color matrix (color space + white point)
- Per-channel gain/offset (fine trim)
- RGB white/black point controls
- Color temperature presets (3200 K, 4800 K, 5600 K) + custom
- Saturation, hue, black level

### Geometry
- Anamorphic, letterbox, center cut, custom scaling
- Pincushion, keystone
- 4-corner warp
- Polyphase scaler (8-tap H, 4-tap V)
- Active window position trim (X/Y pixel offset) — must be a UI control (playbook calls this the early bug)
- Overscan compensation modes: safe-area-only vs fill-with-overscan

### Per-CRT calibration
- JSON profiles (NovaTool tile-profile pattern)
- Import / export, recall by name

### CRT-specific signal controls
- Sync structure parameters — front porch, back porch, equalizing pulse count, serration pulse width. Per-profile.
- Alternating 90° colorburst phase offset between fields. Toggle. (Playbook Ch. 5)
- Subcarrier coherent vs non-coherent toggle. (Playbook Ch. 4)
- Sync tip voltage trim — saves service calls on oddball AGCs. (Playbook Ch. 3 — the Zenith)
- Setup pedestal: 7.5 IRE (NTSC-M) vs 0 IRE (NTSC-J)
- Output mode select: NTSC / NTSC-J / PAL / PAL-M (drops out of frame rate)
- Field cadence / pulldown options for non-matching rates: off / hard switch / crossfade
- VITC insertion in output (separate from incoming LTC reference)

### Behavior controls
- Signal loss behavior: black / freeze / last-good-frame-for-N-seconds
- Burn-in protection: auto-darken or pixel-shift after N minutes static
- Burn-in recovery / repair mode: standalone scrolling white/black/gray patterns at user-set rate. Runs from front panel with no input. Known CRT repair technique.
- Degauss trigger output: relay/GPIO for pro CRTs that accept remote degauss

### EDID — Day 1 critical
- Editable / emulatable EDID on HDMI and DP inputs
- Force-mode presets: 1080p24, 1080p23.98, 1080p25, 720p, custom
- Without this, playback laptops negotiate to whatever they feel like and burn shoot time on format debugging

### Test pattern generator (ship complete set)
- SMPTE color bars (75% / 100% / SMPTE)
- PLUGE
- Color reference fields
- Geometry grid (100% / 95% / 90% safe area)
- Convergence pattern (operator CRT alignment, separate from content warp)
- Purity (full-field R/G/B)
- Focus / zone plate (center + corners)
- Burn-in repair scroll patterns

### Networking & control
- **[PROPOSED]** Drop Pi CM4 from architecture. Zynq PS (dual A9, 1 GB DDR3) hosts PetaLinux running Node.js web UI, REST API, EDID negotiation, mDNS, OTA updates, config persistence. Single Linux to maintain; Screenie color pipeline JS code ports onto Node-on-Zynq. Saves ~$50 BOM, eliminates inter-processor RPC layer and CM4 supply risk.
- Wired: GbE on TE0720 (PHY on-module) → RJ45 on rear panel
- WiFi/BT module: Laird Sterling LWB5+ (pre-certified, 88W8997 chipset, dual-band a/b/g/n/ac, BT5.0) via SDIO to Zynq PS
- Concurrent AP + STA via Linux hostapd + wpa_supplicant — AP for greenfield setup, STA for venue network, both can stay live simultaneously
- Dual external antennas: 2× RP-SMA stubs on rear panel
- BLE for initial pairing/setup: companion app discovers Schindler boxes via BLE, sends WiFi credentials over encrypted GATT characteristic
- USB on rear panel for service / firmware update / debug

### Front panel
- Power button (lower-left)
- Status LED column: genlock lock, signal present per input, network link, fault — multi-color, visible at a glance from across the rack
- Center: 2.8" or 3.5" color TFT (ILI9341 SPI for prototyping, LTDC parallel for production polish) — driven by dedicated UI MCU, shows menu and parameter context
- Two rotary encoders: **ALPS EC11E18244AU** — 11mm metal D-shaft (6 mm × 20 mm), 36 detents / 18 PPR (half-step quadrature; firmware decoder counts edges, not full cycles), integrated push switch, sealed, -40 to +85°C industrial range, 15k-cycle rotational life. ~$2-3.50 in singles at DigiKey / Mouser / LCSC. Navigation (CW/CCW + push to select), value adjustment (CW/CCW + push to confirm). Software acceleration on long scrolls advised given fine 36-detent click pitch (~10° per click).
- Four hardware-fixed buttons: Home, Back, Menu, Confirm
- 2-3 quick-select buttons for common functions (Output Mode toggle, EDID profile, Genlock source)
- **HARD REQUIREMENT: Physical knob guard / shroud preventing lateral torque on encoder shafts during transit and rack handling.** Recessed encoder pocket, side rail bars, or equivalent. Must survive being dropped face-down in a road case.
- Front-panel preset recall

### UI architecture
- Dedicated UI MCU on carrier owns front panel — TFT, encoders, buttons, LEDs all on the MCU
- UI alive in <1 second from cold boot; main system can take 15-30 s to boot Linux behind the scenes with progress bar shown
- UI MCU ↔ Zynq PS: UART or SPI for state sync
- Pattern B for v1: single TFT + 2 encoders + buttons. Pattern A (per-encoder OLEDs, DiGiCo-style) reserved for v2 if menu surface area justifies it.
- Bench dev: STM32H735G-DK (~$70) → production silicon STM32H735IGT6 (LQFP176, ~$8)
- UI framework: TouchGFX (visual designer, ST-supported) or LVGL (open-source, more code-driven)

---

## V1 broadcast feature set

These features are physically present on the v1 carrier. **[PROPOSED — SKU strategy pending]**: deliver via separate hardware SKU (broadcast units have additional silicon populated) or single hardware with firmware-tier license unlock. **Recommendation: single hardware, firmware-gated.** All v1 carriers ship with the silicon populated; base license uses GS3470 for SDI ref only; broadcast license unlocks full SDI video features.

- Full SDI video input (uses GS3470 already populated for ref)
- SDI video output (Semtech GS2962 transmitter, ~$15-20)
- Native passive SDI loop-through (uses GS3470 2×2 mux — independent of processed output, both available simultaneously)
- 3 BNCs on rear panel for SDI: 1× IN, 1× processed OUT (via GS2962), 1× passive loop OUT (via GS3470)

---

## V1.5 / proposed sync conversion expansion [PROPOSED]

**Status:** [PROPOSED] 2026-05-10 PM 7th update. Idea raised this session; architectural feasibility confirmed but not committed to V1. Recommended path: design V1 to preserve the option, build the feature as V1.5 / sibling product after V1 ships.

**Capability:** Cross-rate sync conversion with timecode translation. Accept genlock + LTC IN at one frame rate (e.g., 29.97), output genlock reference + LTC OUT at a different frame rate (e.g., 24.000), with output domain phase-locked to input via the appropriate rational ratio and timecode math preserved across the boundary (drop-frame rules, jam-sync behavior).

**Why it matters:** Mixed-rate productions currently need a separate broadcast-grade sync converter (Evertz 5600, AJA OG-Frame, BMD Sync Generator family) alongside the CRT prop driver. Adding this in-box turns Schindler from "a CRT prop driver" into "a broadcast-grade rate-domain bridge that happens to drive period CRTs" — a meaningfully bigger market.

**Hardware additions** (relative to V1 carrier):
- 1× LTC OUT, balanced XLR (600 Ω drive) — op-amp driver + connector
- 1× reference OUT, BNC (tri-level or black burst, runtime-selectable) — reuses one ADV7393 DAC channel (potentially a second ADV7393 needed if all three DACs are already committed to video output)
- Optionally 1× LTC OUT, unbalanced BNC, for redundancy

**FPGA additions:**
- LTC decoder (bit-sync + biphase decode + frame assembler) — likely partially in RP2040 PIO and partially in FPGA fabric
- LTC encoder (frame builder + biphase modulator + XLR drive waveform shaping)
- Timecode math module (rational rate converter, drop-frame logic, jam-sync behavior on input loss)
- Output-domain phase accumulator, locked to input PLL via Si5351
- Tri-level / black burst sample generator at output rate (parameterized variant of `vid_timing.v` + `vbi_gen.v`)

**Effort estimate:** 2–3 weeks dedicated FPGA + RP2040 work for first-light across common rate pairs (24, 25, 29.97, 30). Possibly 1–2 months for all corner cases (full drop-frame jam-sync correctness, freewheel behavior on input loss, all input×output rate combinations).

**Architectural design hooks to preserve in V1** (so V1.5 retrofit is small):
- Clock-domain separation discipline in HDL (input ref clock and output pixel clock as separate domains, with proper CDC primitives) — already natural given the genlock design
- Reserve unused Si5351 output ports for future reference OUT generation
- Provision rear-panel layout for future XLR + BNC outputs (could be a faceplate-only change in V1.5)

**Decision pending:** committed to V1 (extends schedule ·1 month, adds 2–3 rear connectors to already-tight 1RU panel) vs V1.5 / sibling (V1 ships on schedule, feature lands as a follow-up product or upgrade).

---

## V2 / future

- **4K video support** — DEFERRED to a separate future product (Schindler 4K / Schindler 3.0). Significant architecture change touching most subsystems, so V1 ships HD-only without 4K-readiness headroom. Summary of what 4K would require:
  - **SoC upgrade:** Zynq-7020 → Zynq UltraScale+ (ZU3EG/ZU4EV/ZU5EV class) via TE0820/TE0822 SoM (~pin-compatible carrier upgrade, but signal integrity must be designed for higher rates). SoM cost $230 → $480–750.
  - **HDMI:** TMDS141 (HDMI 1.4-class) → TMDS181 or direct GTH transceivers for HDMI 2.0/2.1. HDCP 2.2/2.3 licensing required ($15K/yr DCP fee).
  - **SDI:** GS3470/GS2962 (3G-SDI) → GS12281/GS12141 (12G-SDI), +$30–50 per unit.
  - **Memory:** Zynq UltraScale+ DDR4 (25–50 GB/s) needed for 4K60 frame buffer (~4–8 GB/s). Zynq-7020 DDR3 (12.8 GB/s) marginal for 4K30.
  - **Color pipeline DSP scaling:** linear with pixel rate — 4× for 4K30, 8× for 4K60 vs 1080p30. UltraScale+ has 360–1248 DSPs vs Zynq-7020's 220.
  - **Power/thermal:** ~10W → 25–40W total. Active cooling (small fan) becomes necessary; passive in 1RU is borderline.
  - **PCB:** 6–8 layer → 8–10 layer with low-loss dielectric (Megtron 6, I-Tera MT). 12G-SDI BNCs need 75Ω high-grade parts. PCB cost +$50–80 per unit.
  - **Schedule:** +6–10 months dev time (HDL for 4K HDMI + 12G-SDI: 2–4 mo; color pipeline optimization: 1–2 mo; bench validation with 12G scopes: 1 mo; HDCP cert: 3 mo).
  - **BOM impact:** +$410–475 per unit at qty 100 across all variants.
  - **What does NOT change:** analog video pipeline (composite/component/S-Video are SD/HD-only), genlock / LTC / sync conversion front-end, UI MCU, WiFi, chassis dimensions, power topology, sync conversion (V1.5 feature). CRT-driving use case is unaffected by 4K — CRTs cap at 1080i.
  - **Decision rationale:** Schindler Pro's core use case (CRT driving) never needs 4K. 4K matters mostly for Mini/HDMI variant, which is already deferred to higher-volume future. Building 4K-ready signal integrity headroom into V1 carrier costs +$50–80 BOM headroom that may never be populated. Cleaner to ship V1 focused on HD, validate the platform, then design Schindler 3.0 / 4K Pro as a deliberate follow-on with the right silicon selected at that point (chip landscape will have evolved by then).
- Original V2/future items continue below.
- 4K input support — superseded by the 4K analysis above
- Pre-distortion warp for CRT geometry — different problem from content warp. Requires per-CRT measurement workflow (camera + grid + solver).
- Pattern A UI (per-encoder OLEDs) — DiGiCo-style if menu depth ever justifies it
- Multiple HDMI inputs with switching — only if customers ask. External switcher solves for ~$200.

---

## Out of scope (deliberately)

| Feature | Why not |
|---|---|
| NDI / SRT / RTMP input | Market wants deterministic frame-locked playback, not streaming. |
| ST 2110 | Wrong market entirely. |
| HDR processing | Output is composite to a CRT. |
| Multiviewer | Single output by design. |
| Recording / capture | Downstream concern. |
| Logo / lower-third / CC overlay | Out of mission. |
| Touchscreen UI | Glare, smudges, no tactile, fails in production environments. Replaced by rotary encoders + dynamic TFT. |

---

## Open questions / parked decisions

- **Drop Pi CM4 architectural change:** switch web UI / EDID / config hosting from Pi CM4 to Zynq PS under PetaLinux. Eliminates second processor domain, second Linux to maintain, inter-processor RPC layer, and CM4 supply risk. ~$50 BOM savings. Screenie color pipeline (JavaScript) ports onto Node-on-Zynq. **Pending confirmation.**
- **SDI broadcast tier delivery:** Option 1 (hardware-distinguished SKU — base populates GS3470 only, broadcast SKU populates GS2962 + extra BNCs) vs Option 2 (single hardware, all silicon populated, firmware license unlocks broadcast features). **Recommendation: Option 2.** Single SKU is easier to manufacture, calibrate, and stock; ~$35 of always-populated silicon is rounding error on ~$700 BOM; license upsell is cleaner than physical SKU upsell. **Pending decision.**
- **LTC reference front-end:** RESOLVED 2026-05-10 PM 7th update — Architecture A (PGA + AD9204-20 ADC + RP2040 slow-control + FPGA high-rate classification) confirmed. PGA chip selection (LTC6912 vs AD8369) still deferred but doesn't gate carrier layout.
- **XLR balanced LTC input:** RESOLVED 2026-05-10 PM 7th update — included in Architecture A as 1× XLR balanced LTC plus 2× BNC autosensing.
- **S-Video input** to ADV7280 path: free in silicon (decoder supports it natively), costs one mini-DIN connector + 2 traces. Common on consumer retro source gear (VHS, S-VHS decks, Hi8). **Pending decision — open question raised this session.**
- **GS3470 confirmed over GS2971-class** for SDI receiver: better specs, smaller package, lower power, native 2×2 mux for loop-through. **Pending confirmation as the production part choice.**
- **ADV7393 confirmed** as production output DAC (closes prior open question pending explicit OK). Eval board ordered 2026-05-10.
- **V2 SDI license enforcement** (relevant only if Option 2 chosen above): firmware keygen vs hardware dongle vs subscription. Defer until business model is concrete.
- **Rear-panel layout on 1RU:** with all V1 additions plus 2× RP-SMA, total connector count is roughly 18-21 depending on broadcast SKU and S-Video IN decision. Requires panel sketch / mock before Rev A carrier layout. Half-rack 1RU likely too tight; full 1RU should fit but needs verification.

---

## Revision history

- 2026-05-10 — Initial draft from feature scoping session. V1 confirmed for SDI ref input, composite + component input, all CRT-specific controls, EDID, test pattern set, behavior controls including burn-in repair mode. 60→50 PAL cadence confirmed V1 via crossfade; dev phase uses matched-rate-only fallback until built.
- 2026-05-10 PM — Hardware architecture session. **Confirmed:** TE0720 SOM (Z-7020 industrial) on custom carrier as production target; HD/1080p60 ceiling for v1 with DP via converter chip; HDMI OUT for loop-through monitoring; S-Video OUT (free from ADV7393); SDI as paired IN/OUT broadcast tier with native loop-through (GS3470 + GS2962); WiFi via Laird Sterling LWB5+ with concurrent AP+STA on dual RP-SMA antennas; BLE for setup pairing; UI Pattern B (single TFT + 2 rotary encoders + 4 buttons + status LED column) with hard requirement for physical knob guards; dedicated UI MCU on carrier (STM32H735); STM32H735G-DK as bench dev kit. **Proposed (pending decision):** drop Pi CM4 → Zynq PS hosts web UI; LTC PGA+ADC+AGC front-end with XLR + auto-sensing BNC inputs; ADV7393 as production DAC; GS3470 upgrade from GS2971-class for SDI ref; SKU strategy for broadcast tier (hardware SKU vs firmware unlock); S-Video input addition.
- 2026-05-10 PM (cont.) — **Encoder selection confirmed:** ALPS EC11E18244AU (replaces prior premium "Grayhill 62 / Bourns optical" placeholder recommendation). Value-tier mid-range encoder at ~$2-3.50 vs $20-40 premium tier; sufficient quality for the use case. Firmware note recorded: 18 PPR / 36 detents is half-step quadrature pattern — decoder must count edges rather than full cycles; software acceleration on long scrolls advised given fine 10° click pitch.
- 2026-05-10 PM (cont., 2nd update) — **ADC selection confirmed for genlock autosense front-end:** Analog Devices AD9204-20 (dual-channel 10-bit 20 MSPS, 1.8 V). Replaces prior AD9201/AD9215 reference — AD9201 confirmed legacy by ADI (Tony M response on EngineerZone). Dual-channel topology lets one chip handle both BNC autosense inputs; pin-compatible upgrade path to AD9231 (12-bit) / AD9251 (14-bit) / AD9258 (14-bit higher MSPS) / AD9268 (16-bit) provides future resolution headroom without board respin. **First DigiKey procurement order placed 2026-05-10:** TE0720-04-31C33MA (commercial-grade variant for bench), TE0703-07 dev carrier, EVAL-ADV7393EBZ, springloaded heatsink (33337). $628.74 incl. shipping. Second order pending.
- 2026-05-10 PM (cont., 3rd update) — **TE0720 silicon variant resolved.** Bench/prototype = TE0720-04-31C33MA (commercial -1 speed grade); production target = TE0720-04-62I33MA (industrial -2 speed grade). Both share 1 GB DDR3L + 32 MB QSPI + 8 GB eMMC memory config and identical pinout — dev work ports directly to production silicon. Evaluated stripped-down TE0720-04-61C530A variant (256 MB DDR3, no eMMC, ~$190) and ruled out — insufficient DDR for video frame buffers + PetaLinux + Node.js + working memory headroom; no eMMC for Linux rootfs (would force SD-card boot or external eMMC on carrier, neither acceptable). Memory cost is real and the cheap variant doesn't have enough.
- 2026-05-10 PM (cont., 4th update) — **First analog picture validated.** R2R DAC + op-amp output stage producing structurally correct NTSC composite signal: ~63 µs line rate, ~5 µs sync width, ~3 µs back porch, ~53 µs active video. Multi-step grayscale staircase test pattern rendering cleanly with crisp transitions and no visible ringing — DAC + op-amp settling adequate for NTSC pixel rates. **Amplitude calibration pending:** signal currently ~3 V p-p (peak white +2 V above blank, sync tip -1 V below blank); SMPTE target is 1 V p-p at 75 Ω (peak white +714 mV, sync tip -286 mV). Sync/video ratio currently ~1:2 (sync depth : peak-above-blank); SMPTE target ~1:2.5. Amplitude scale = analog gain adjustment (bench-side); sync depth ratio = FPGA DAC code value adjustment (Claude-owned iteration). **Workflow clarified:** Claude authors and iterates FPGA HDL; Justin operates bench, captures scope/CRT results, feeds back observations.
- 2026-05-10 PM (cont., 5th update) — **NTSC vertical blanking interval structure verified.** Scope capture confirmed complete, structurally correct VBI sequence on FPGA test pattern output: 6 pre-VSync equalizing pulses (narrow, ~31 µs spacing at 2× H rate) → 3-line broad vertical sync period with 6 serration teeth → 6 post-VSync equalizing pulses → ~12 blank horizontal lines → active video resumes. Matches NTSC spec exactly — signal should successfully lock vertical on standard CRTs. FPGA timing generator HDL validated end-to-end for monochrome NTSC composite output (horizontal + vertical structure both correct). CRT lock test pending (next bench step). Next FPGA milestone: chroma subcarrier (3.58 MHz color burst encoding + chroma modulation onto luma) for color test patterns.
- 2026-05-10 PM (cont., 6th update) — **Frame rate and DAC linearity validated against HDL parameters.** VSync-to-VSync measured at 41.6 ms = 24.04 Hz; cross-referenced against `hdl/vid_timing.v` which specifies `PIXELS_PER_LINE = 3435` (63.613 µs at 54 MHz pixel clock) × `LINES_PER_FRAME = 655` = 41.667 ms = exactly 24.000 fps. Scope matches HDL within measurement tolerance. Earlier diagnostic of "line count off by 6" from a noisy 41.3 ms reading was bad math; code is correct as written. VBI 6+6+6+12 pulse count also cross-referenced: `vbi_gen.v` specifies 3 pre-eq + 3 vsync + 3 post-eq + 12 blank fill lines, each eq/vsync line carrying 2 pulses at half-line spacing — produces exactly the 6/6/6/12 pulses Justin counted on the scope. **Gray test pattern:** flat gray at 2.2 V renders cleanly across full active line; correct front porch / sync / back porch transitions. **Ramp test pattern:** smooth linear ramp from ~1.1 V (at blanking level — verified at tight 5 µs/div zoom) up to peak end-of-line level, with no quantization steps, kinks, or glitches across the full ramp. Confirms R2R DAC ladder is monotonic and linear across the code range, and pixel timing is rock-solid (constant ramp slope = steady pixel clock). Line period ~63.5 µs, active video duration ~52 µs, sync structure all rendering within visual tolerance of NTSC spec at tight zoom. **HDL files in vault confirmed:** `hdl/vid_timing.v`, `hdl/vbi_gen.v`, `hdl/sample_gen.v`, `hdl/top.v`. Workflow going forward: read HDL design parameters first, predict scope behavior, then verify — not the reverse.
- **Pending bench work (non-blocking for FPGA dev):** (a) CRT lock test once CRTs are available, (b) amplitude calibration via bench-side analog gain reduction to land on SMPTE 1 V p-p, (c) tight scope re-capture of ramp minimum endpoint vs back porch level to confirm intentional alignment at blanking. **Next FPGA development milestone:** chroma subcarrier (3.58 MHz NTSC color burst on back porch + I/Q quadrature modulation of chroma onto luma), to be added as a new module integrated with `sample_gen.v` and gated by VBI/active signals from `vid_timing.v`.
- 2026-05-10 PM (cont., 8th update) — **HDCP strategy banked.** V1 Pro Full and Broadcast Digital will ship with **HDCP 1.4 support** on HDMI input. **Bench dev path:** derived/public HDCP 1.4 device keys used for internal bench bring-up only (master key publicly known since 2010 leak, mathematically valid for the authentication protocol but not DCP-issued). Murideo SIX-G (~$2,500) selected as HDCP-capable bench source for authentication testing. **Production path:** DCP Adopter Agreement (~$5K/year for HDCP 1.x) + Xilinx HDCP 1.4 IP license signed before first production run; DCP-issued production keys provisioned per-unit at factory programming step. HDCP 2.2/2.3 deferred until 4K product (consumer 4K content requires HDCP 2.2+). **Mac source workaround during bench dev:** HDFury Diva-class EDID-copying HDMI splitter (~$300) inserted between Mac and Schindler input lets Mac see a real HDCP-compliant TV downstream while Schindler taps the signal — enables Mac bench testing without HDCP infrastructure on Schindler side. **Architecture note:** HDCP handled inside FPGA via Xilinx IP (saves $5–15K licensing? Xilinx HDCP 1.4 IP comes with Vivado Enterprise or as standalone license; DCP Adopter Agreement is separate and required for shipping). Alternative path of moving HDCP to a dedicated chip (TMDS181 has HDCP 2.2 built in, NXP TDA19988 has HDCP 1.4) considered but not chosen — keeping HDCP in FPGA matches the color pipeline architecture and avoids adding silicon. **DCP-issued facsimile/test keys** to be used after DCP license arrives, replacing derived keys, for compliance pre-testing prior to production cert.
- 2026-05-10 PM (cont., 7th update) — **Output DAC, genlock front-end, and sync-conversion architecture decisions banked.** **ADV7393 confirmed with runtime mode selection:** one chip serves composite/S-Video OR component output (mutually exclusive, I²C-switched); never need both modes simultaneously, so a single ADV7393 covers all V1 analog video outputs. **Architecture A confirmed for genlock front-end:** AD9204-20 (dual ADC) + LTC6912 or AD8369 (PGA, selection deferred) + RP2040 (slow-control / autosense decision / Si5351 config) + Si5351 (programmable clock generator) + FPGA (high-rate signal classification of 20 MSPS ADC stream); XLR balanced LTC + 2× BNC autosensing connector mix confirmed. **ADV7280-A dev board to be ordered** for input-side analog video decoder evaluation. **NEW [PROPOSED] V1.5 expansion:** sync conversion with timecode translation — accept genlock+LTC at one rate, output a different rate's genlock+LTC with phase-locked TC math. Would position Schindler as a broadcast-grade rate-domain bridge with CRT driving as one capability (Evertz 5600 / AJA OG class with a CRT driver attached). V1 to preserve architectural option (clock-domain discipline, Si5351 output port reservation, rear-panel provisioning); build as V1.5 / sibling product after V1 ships. New spec section added covering hardware additions, FPGA additions, effort estimate, and architectural design hooks.
- 2026-05-10 PM (cont., 9th update) — **HDMI subsystem architecture finalized; supersedes 8th update.** Iterated through Xilinx-internal HDCP (path priced out at $5-15K license + $5K/yr DCP), then chip-based symmetric HDCP (ADV7611/ADV7513 ruled out as NRND/EOL; updated to LT8619C + IT66121FN), then questioned whether HDCP transmitter chip was needed at all given Schindler's position as a broadcast studio analysis device. **Final architecture:** Lontium **LT8619C** (HDMI 1.4 RX, parallel RGB/TTL out to FPGA, HDCP 1.4 keys embedded by Lontium under their DCP Adopter Agreement) on input + **direct FPGA HDMI 1.4 TX** via free Xilinx HDMI IP (no HDCP encryption on output) + **TPD12S016** ESD protection on both connectors. **Total HDMI subsystem cost: ~$8/unit at qty 100.** **Legal positioning:** Schindler is a broadcast studio device in the lineage of waveform monitors, vectorscopes, confidence preview tools, and signal-analysis equipment (Tektronix WFM, Leader, AJA HDR Image Analyzer category). HDMI output is intended for monitoring/analysis use: waveform/vectorscope visualization, signal lock and status dashboard, test pattern output, color analysis (histograms, gamut warnings, false color), heavily-degraded confidence preview. Architecture follows the letter and spirit of DMCA §1201 (primary-purpose test: signal analysis and color correction, not circumvention) and DCP Compliance Rules (HDMI output does not transmit Decrypted HDCP Content as a faithful copy; analysis/monitoring outputs are industry-standard for HDCP-capable equipment). End-user assumes responsibility for downstream content compliance, mirroring how every professional waveform monitor, scope tool, and broadcast analysis device on the market operates. **Product documentation will state:** "HDMI output is intended for monitoring and signal analysis. Users are responsible for compliance with content licensing and applicable laws regarding downstream signal use." **Cost savings vs symmetric-HDCP path:** no Xilinx HDCP IP license (~$5-15K saved one-time), no IT66121FN transmitter chip ($3/unit saved), DCP Adopter Agreement deferred (likely not strictly required at this scale and use case, but can be added later if Mini consumer SKU eventually ships). **Bench dev path:** LT8619C works out of the box with its embedded HDCP keys — no derived-keys workflow needed for the chip-based input path. For broader HDMI source testing including Macs, HDFury Diva-class EDID copier ($~300) available as bench-only workaround. **Mini variant (deferred):** when/if it ships, Mini targets consumer HDMI market and would require full HDCP 2.2 chain, DCP Adopter Agreement, and likely Xilinx HDCP 2.x IP or equivalent — separate decision at that time.
- 2026-05-11 — **LT8619C eval board + raw chip ordered.** Lontium LT8619C-EVB dev board and a single raw LT8619C chip on order for HDMI input bench bring-up. **HDMI loop-thru feature explicitly deferred** — no LT86102SXE splitter, no second HDMI output, no buffer chip with tap. V1 ships with single HDMI IN (LT8619C) and single HDMI OUT (direct FPGA TX) only. Loop-thru can be revisited as a V1.x or V2 feature if customer feedback requests it.
- 2026-05-11 — **Connector list and panel layout reorganized.** Final V1 rear panel connector list (single-row tall items plus two-row stackable items, 1RU full-rack 19" target): IEC C14 power (35 mm), 2× XLR LTC IN/OUT (52 mm) on single-row track; USB-C service (8 mm), RJ45 GbE (22 mm), 2× SMA WiFi (24 mm), 2× HDMI IN/OUT (44 mm), 2× BNC SDI IN/OUT (36 mm), 4× BNC composite/component IN (72 mm), 4× BNC composite/component OUT (72 mm), 3× BNC autosense IN/LOOP/OUT (54 mm) on two-row stacked layout. Single-row subtotal 87 mm; two-row halved subtotal 166 mm; grand total 253 mm of 432 mm available, leaving 179 mm of unused panel width for future expansion. **V1.5 sync conversion expansion now absorbed into V1** via the LTC OUT XLR and BNC autosense OUT slots — Schindler becomes a broadcast-grade rate-domain bridge with CRT driving as one capability rather than a CRT-only driver. **SDI simplified to 2× BNC** (IN + processed OUT only, dropped passive loop-through from broadcast tier). **Dropped from V1:** DisplayPort IN, mini-DIN S-Video OUT. **TFT and form factor decision:** 1RU full-rack confirmed with two-row connector layout; front panel TFT constrained to ~2.4" 16:9 by 1RU panel height; status-display UI pattern with web UI for detailed config (Evertz 5600 / AJA OG style). Future Mini variant likely compact desktop with 4.3" TFT. **HDMI subsystem chip selection finalized** per 9th update above: LT8619C RX + direct FPGA TX + TPD12S016 ESD protection × 2.
