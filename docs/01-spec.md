# Schindler 2.0 — Spec & Backlog

**Status:** Draft 2026-05-11
**Sources:** `README.md`, `docs/schindler-playbook.md`, feature scoping session 2026-05-10, hardware architecture session 2026-05-10 PM
**Working principle:** Stay Schindler-shaped. Width dilutes the product.

This is the SSOT for the current spec. Items marked **[PROPOSED]** are awaiting confirmation; everything else is confirmed. Dated decision history lives in [`01-spec-changelog.md`](01-spec-changelog.md).

---

## Hardware foundation

### Production architecture
- **SoC:** Trenz TE0720 SOM — Xilinx Zynq-7020. **Production: TE0720-04-62I33MA** (XC7Z020-2I speed grade, industrial -40°C to +85°C, 1 GB DDR3L, 32 MB QSPI flash, 8 GB eMMC, GbE PHY). **Bench/prototype: TE0720-04-31C33MA** (-1 speed grade, commercial 0°C to +70°C, same memory config) — cheaper, better DigiKey stock, identical pinout/footprint so dev work ports directly to production silicon. **Explicitly ruled out: -61C530A and similar 256 MB DDR3 / no-eMMC variants** — insufficient memory for Linux-hosted video pipeline (need 1 GB DDR3 for frame buffers + PetaLinux footprint + Node.js heap + working memory; need eMMC for Linux rootfs). 152 FPGA I/O via Samtec Razor Beam connectors.
- **Carrier:** custom 6-8 layer PCB, accepts TE0720 SOM, hosts all input/output, control, and power circuitry
- **Genlock subsystem:** RP2040 + Si5351 generates pixel clock from selected reference; FPGA locks output timing to it. **RP2040 confirmed in V1** — owns sync slow-control (autosense decision, PGA gain commands, Si5351 register writes, status reporting); FPGA does high-rate signal classification of the 20 MSPS ADC stream.
- **UI MCU:** STM32H735IGT6 (LQFP176, 480 MHz Cortex-M7) on carrier — owns front panel (TFT, encoders, buttons, LEDs); communicates with Zynq PS over UART or SPI
- **Output DAC:** Analog Devices ADV7393 — triple 11-bit DAC with composite / S-Video / component encoding, I²C-configured. S-Video output is silicon-capable but no dedicated rear-panel connector in V1 (mini-DIN dropped in 2026-05-11 connector simplification).
- **Input video decoder:** ADV7280-class multi-format decoder for composite/component analog inputs

### Development hardware
- Digilent Zybo Z7-20 — FPGA pipeline bring-up (matches production silicon)
- Trenz TE0720-04-31C33MA + TE0703-07 carrier — production SOM (commercial-grade variant for bench) on Trenz dev carrier for porting FPGA design to production silicon before custom carrier rev
- 33337 springloaded heatsink for TE0720 — passive thermal dissipation under continuous video pipeline load
- EVAL-ADV7393EBZ — output DAC eval board (replaces R2R perfboard after first-light)
- STM32H735G-DK (~$70) — UI MCU + TFT bench development; produces production-quality UI in TouchGFX or LVGL, ports to STM32H735IGT6 on production carrier
- Oscilloscope — signal analysis

### Resolution ceiling
- v1: 1080p60 max input. HDMI 1.4 input handled by **Lontium LT8619C** HDMI RX, which produces parallel RGB into the FPGA (Z-7020 has no MGTs so no direct TMDS deserialize). DisplayPort IN dropped from V1 in the 2026-05-11 connector simplification — not in spec.
- 4K input deferred to v2 — would require SOM upgrade (Z-7030 with GTPs) or external 4K receiver chip feeding Zynq at 1080p.

### Power & safety (confirmed 2026-05-11)

**Power budget:** ~14–16 W typical, ~20–22 W peak (full pipeline + WiFi + SDI + UI MCU + LCDs + all LEDs at max brightness).

**AC entry — pre-certified module path.** Custom AC-DC design intentionally avoided: would add ~$15–25K and 3–6 months of NRTL certification (UL 62368-1 / IEC 62368-1 / FCC / CE) with no benefit at Schindler's lifetime volume (~75 units). All AC-side components carry their own certifications.

- **IEC inlet:** Schaffner **FN9260B-6-06** — C14 connector + 6 A rating + integrated fuse holder + 1-stage EMI filter, panel-mount. ~$18 BOM.
- **Mains fuse:** 2 A T (time-lag), 5×20 mm cartridge in the FN9260B fuse holder. Sized for 120 VAC worst-case operation (Schindler is universal-input but spec'd for low-line because RMS current and inrush are both higher there). At 120 VAC: 7–10× steady-state headroom (steady state ≈ 0.21 A RMS), comfortably absorbs ~25 A / 5 ms cold-start inrush of the PSU module's bulk-cap charge.
- **No rocker switch.** IEC cord = service disconnect; front-panel soft power button handles daily on/off. Matches modern broadcast convention.
- **PSU module — primary:** Mean Well **LRS-50-12** — 50 W / 12 V single output, 85–264 VAC universal input, enclosed aluminum case, convection-cooled (no fan), screw-terminal AC input, UL 62368-1 listed, EN 55032 Class B emissions. ~$15–20 BOM. Industrial-grade workhorse with very wide distributor availability (DigiKey / Mouser / TRC / Jameco / Bravo Electro / Amazon). Lower cost; slightly higher switching noise than the TDK-Lambda alternate but still well within EN 55032 Class B with proper chassis layout.
- **PSU module — alternate (drop-in):** TDK-Lambda **HWS50A-12/A** — same 50 W / 12 V / enclosed / universal-input form factor, ~$50 BOM. Lower noise (preferred for pro-audio-adjacent applications), tighter availability concentrated at DigiKey. Reserved as the swap-in if Mean Well noise levels show up as audible artifact during bench characterization.
- **Mains wiring inside chassis:** UL 1015 stranded, 18–20 AWG, three-conductor (live + neutral + earth), short captive run from FN9260B output terminals to PSU module input terminals.
- **Earth bonding:** chassis ground stud as the single bond point. IEC earth pin → stud, PSU module earth → stud, chassis enclosure bonded → stud. Carrier digital ground tied to chassis earth at one point only (single-point earth — prevents ground loops through the analog signal chain).

**Carrier-side 12 V input protection chain.** Independent of any decisions about the PSU module. Order: PSU 12 V → reverse-polarity FET → polyfuse → TVS → INA226 sense → bulk caps → downstream regulators.

| Function | Part | Specs | Notes |
|---|---|---|---|
| Reverse-polarity FET | Diodes Inc **DMP3098L-7** | P-channel, −30 V, −6.7 A, R<sub>DS(on)</sub> 31 mΩ, SO-8 | Source to PSU 12 V, drain to downstream, gate to GND via 100 kΩ. ~60 mV continuous drop at 2 A. Continuous loss ≈ 0.12 W. |
| Polyfuse (self-resetting) | Bourns **MF-MSMF200-2** | I<sub>hold</sub> 2 A, I<sub>trip</sub> 4 A, 16 V, SMD | Self-resetting — transient fault doesn't require service trip. |
| TVS clamp | Littelfuse **SMBJ12A** | Unidirectional, V<sub>WM</sub> 12 V, V<sub>BR</sub> 13.3 V, V<sub>C</sub> 19.9 V peak, 600 W, SMB | Unidirectional because the FET catches reverse. Sustained over-voltage → TVS conducts → polyfuse trips → graceful fault isolation. |
| Current/voltage monitor | TI **INA226** + 5 mΩ shunt | I²C 16-bit power monitor on 12 V rail | Reports actual current draw + rail voltage to Zynq PS. Telemetered to rear LCD + web UI. Doubles as a "PSU healthy" check (LRS-50-12 and HWS50A-12/A both lack a DC-OK signal pin). |
| Bulk input cap | 3× Murata **GRM32** 22 µF 25 V X7R MLCC in parallel | ~66 µF total bulk | MLCC over electrolytic for service life. Pro broadcast gear should outlast 10+ years; electrolytics dry out. |
| PSU → carrier connector | Molex **Mini-Fit Jr.** 2-pin, locking | 12 V + GND, 9 A rating with derating | Locking mate prevents transit shake-out. |

**Total carrier protection BOM: ~$6.20.** No additional soft-start needed (PSU has internal soft-start; 66 µF bulk MLCC inrush is gentle).

**Per-rail regulators (downstream of protected 12 V rail).** Selected at carrier-schematic time; each off-the-shelf TI / ADI buck or LDO has built-in per-rail OCP + thermal shutdown so no extra protection layer needed. Typical rails:
- 5 V (USB host power, fan, analog op-amps) — buck, ~3 A
- 3.3 V (most digital I/O, LEDs, low-power analog) — buck, ~2 A
- 1.8 V (FPGA bank Vcco, DDR3L Vddq) — buck, ~3 A
- 1.35 V (DDR3L Vdd) — buck, ~1 A
- 1.0 V (FPGA Vccint) — buck, ~3 A
- VAUX rails (AD9204 1.8 V analog, ADV7280 analog, op-amp dual supplies, etc.) — LDOs from 3.3 V or 5 V

---

## V1 base unit — In scope

### Inputs
- HDMI in (Lontium LT8619C HDMI 1.4 RX → parallel RGB → FPGA → AXI VDMA)
- Composite in (1 BNC)
- Component in (3 BNCs, YPbPr)
- ADV7280-class decoder feeds analog inputs to FPGA via ITU-R BT.656 8-bit YCbCr 4:2:2 over parallel bus → existing VDMA path
- SDI video input (broadcast-tier units, 1 BNC) — Semtech GS3470 receiver (confirmed over prior GS2971-class candidate). Serves dual duty: video data into the FPGA pipeline (see `signal-flow.md` diagram 1) **and** provides a recovered SDI clock + VITC into the genlock subsystem as one possible reference source (see `signal-flow.md` diagram 2 and the Genlock section below). There is no dedicated "SDI reference input" connector — the SDI video input is the SDI reference path. The 2×2 input mux on GS3470 is unused in V1 (passive loop-through dropped in the 2026-05-11 connector simplification).

### Pipeline architecture (confirmed 2026-05-11)
- **The FPGA pipeline is HD-bandwidth throughout** — RGB or YCbCr 4:2:2 at up to 1080p60 (148.5 MHz pixel clock) carried from input decoder all the way through scaler, color, and geometry to a shared HD signal bus. Downconversion to SD or rate-conversion happens **only inside the per-output terminal encoder** that needs it (composite, S-Video, SD component).
- **Outputs are independent and concurrent.** The HD signal bus fans out to one terminal encoder per output. All terminals can run simultaneously at their own format and rate. Example: 1080p60 HDMI source can drive 1080p60 HDMI OUT (passthrough) + NTSC composite OUT (downconvert + 5:2 cadence + composite encode) + HD component OUT (YPbPr) all live from the same source.
- **Terminal encoders (independent FPGA blocks):**
  - **HDMI passthrough terminal** — format-match or rate-convert + HDMI 1.4 TX (FPGA-internal, no chip). HDCP-protected content gated by UI consent dialog (see HDCP architecture below).
  - **NTSC/PAL composite encoder terminal** — HD-to-SD downconvert + cadence convert + luma+chroma encode + sync gen. HDL: `hdl/vid_timing.v` + `hdl/vbi_gen.v` + `hdl/chroma_gen.v` + `hdl/sample_gen.v` (Phase 2 first-light validated).
  - **Component YPbPr encoder terminal** — HD passthrough or SD downconvert, feeds ADV7393 in component mode.
  - **SDI passthrough terminal** — HD re-serialize, feeds GS2962 (broadcast tier only).
- **Test pattern generator** is one selectable source feeding the pipeline (alongside HDMI / SDI / composite / component inputs), default at power-on before any source is connected. See `signal-flow.md` diagram 1.

### Outputs
- **One ADV7393 chip serves both analog output modes via runtime selection** (I²C-switched, mutually exclusive): composite/S-Video mode (DAC_A=CVBS, DAC_B=Y, DAC_C=C) OR component mode (DAC_A=Y, DAC_B=Pb, DAC_C=Pr). Operator chooses analog output mode in the UI; the unused output BNC/mini-DIN goes to 0 V / blanking (analog mux or buffer-disable on carrier handles physical routing). Composite and component are never both live on the analog BNCs; confirmed 2026-05-10 PM 7th update.
- **Composite out** (1 BNC) — NTSC, NTSC-J, PAL, PAL-M. Driven by composite encoder terminal.
- **Component out** (3 BNCs, YPbPr) — HD or SD rate selectable. Driven by component encoder terminal.
- **S-Video out** (silicon-capable, no V1 rear-panel connector) — generated free from ADV7393 in composite mode (Y on one DAC channel, C on another). Mini-DIN connector dropped from V1 panel in 2026-05-11 simplification. The silicon path is preserved so a future panel revision can add the connector without carrier changes.
- **HDMI out** (1 connector) — **full-quality HD passthrough**, up to 1080p60, driven by HDMI passthrough terminal. Not a degraded monitoring view. Same source video as the other outputs, independently rate/format-configured per the operator's choice (e.g. HDMI passthrough at source rate, while composite OUT does cadence conversion to 24 p NTSC for CRT-driving).
- **SDI out** (1 BNC, broadcast tier only) — processed HD re-serialize via GS2962. Not a passive loop-through.

### HDCP architecture (confirmed 2026-05-11)
- **Default-safe behavior:** HDCP-protected content (detected on HDMI / SDI input via the source's HDCP authentication state) is **blocked from full-quality HDMI OUT** by the HDMI passthrough terminal. Protected content can still flow to the analog outputs (composite / component / S-Video — these don't carry HDCP) and to SDI OUT (broadcast workflow assumption).
- **UI consent gate (operator override):** the operator can manually unlock full-quality HDMI passthrough of protected content via a UI dialog requiring explicit attestation ("I attest this is a non-violating use"). Once attested, the HDMI passthrough terminal permits HDCP-protected content through to HDMI OUT for the session. Pattern is attorney-advised: keeps the device's default behavior compliant with DMCA §1201 / DCP Compliance Rules, and shifts compliance responsibility to the operator for any override.
- **Non-protected content** flows through HDMI OUT without any gate — no dialog, no degradation, no friction.
- **No HDCP encryption on HDMI OUT** — protected content that flows through (post-consent) reaches HDMI OUT unencrypted. Saves the Xilinx HDCP IP license + DCP Adopter Agreement cost path explicitly avoided in the 9th update HDMI subsystem decision. Documented user-facing language: "HDMI output is provided for broadcast / production use. Users are responsible for compliance with content licensing and applicable laws regarding downstream signal use. Protected content from HDCP-authenticated sources is blocked by default; the override is provided for non-violating professional workflows including production preview of owned content, internal monitoring of licensed material, and signal analysis."

### Frame rates
- **Pipeline throughput rates** (HD path): 1080p23.98 / 1080p24 / 1080p25 / 1080p29.97 / 1080p30 / 1080p50 / 1080p59.94 / 1080p60 / 1080i50 / 1080i59.94 / 720p50 / 720p59.94 / 720p60.
- **CRT-driving rates** (composite / component encoder output): 23.976 / 24.000 / 25.000 / 29.97 / 30.000 fps.
- **Per-output rate selection:** each terminal encoder targets its own output rate. Cadence-convert logic in each terminal handles input-to-output rate translation when they differ (e.g. 60 → 24 via 5:2 pulldown + crossfade, 60 → 25 via 6:5, 23.98 → 24 via slip).
- **3:2 cadence auto-detect (confirmed 2026-05-11)** — when source is 30 / 60 fps with 3:2 cadence in the data (telecined 24 p material), the converter detects the cadence pattern and extracts the original 24 p sequence without motion filtering. Cleaner result than blind frame-rate conversion. Auto-falls-back to motion filtering when 3:2 cadence isn't detected. Default mode is `Auto`, operator can pin to `3:2 auto-detect`, `Off` (matched-rate only), or one of the manual cadence ratios (5:2 / 6:5 / 4:5 / 2:1 / 1:2 / slip).
- **Motion filter selection** — `Quadratic` (default, 3-frame motion filtering) / `Linear` (2-frame, lighter) / `Off` (drop or repeat frames). Trades quality vs DSP load.

### Genlock / reference inputs
- Auto-sensing front-end across LTC / black burst / tri-level sync (Architecture A confirmed 2026-05-10 PM 7th update). Each input passes through clamp diodes, switchable 75 Ω termination, AC-coupled buffer, **LTC6912 programmable-gain amplifier** (confirmed 2026-05-11; MIKROE-2555 click board inbound for bench evaluation), switchable analog LPF, then **Analog Devices AD9204-20** (dual-channel 10-bit 20 MSPS ADC, 1.8 V analog supply, 1.8-3.3 V output drive — single chip handles both BNC inputs; pin-compatible upgrade path to AD9231/AD9251/AD9258/AD9268 for 12/14/14/16-bit if future need) to FPGA. FPGA runs detection logic in parallel and identifies signal type by characteristic signature (LTC biphase mark + 0xBFFC sync, black burst 15.734 kHz line rate + 3.58 MHz burst, tri-level pulse pattern). PGA-driven AGC loop solves input level frustration — no front-panel padding/gain needed.
- **Connector mix (confirmed 2026-05-11):** 2× BNC on the input side — **REF IN** (selected reference) + **REF LOOP** (passive loop-through of REF IN for daisy-chaining). Both BNCs feed the autosense front-end. XLR balanced LTC IN/OUT dropped from V1 to simplify panel — LTC accepted on either BNC unbalanced; downstream balanced gear uses a passive BNC-to-XLR adapter. XLR may return in a later rev if panel space allows.
- **Reference sources available at the selector mux:** the autosense BNC path (LTC / BB / tri-level decoded in FPGA), the SDI recovered clock + VITC (broadcast-tier units only, derived from the SDI video input via GS3470 — not a separate connector), and free-run from the FPGA NCO. Operator picks via front panel / web UI; autosense priority fallback is LTC > tri-level > BB > SDI > free-run.
- **Genlock loop is fully digital** — FPGA fabric implements phase/frequency detector, loop filter (configurable bandwidth, default ~0.5 Hz per playbook Ch. 8), NCO/integrator (holds last value on ref loss → free-run hold), and lock detector (3-state machine Acquiring / Locked / Lost plus phase-error magnitude + 1 s stddev as quality metric). The integrator's correction is pushed to Si5351 via RP2040 over I²C as slow-control updates.
- **RP2040 slow-control** owns I²C config of Si5351 + PGA gain, autosense status, lock state reporting to Zynq PS. FPGA does high-rate signal classification of the 20 MSPS ADC stream.
- **Operator control surface** (front panel + web UI): reference source select (auto / specific / hold / free-run), loop bandwidth tweak (default / tight / wide), per-OUT format + rate selection, real-time lock-state and quality readout. State flows: lock detector → Zynq PS state aggregator → rear LCD + per-connector LEDs + front-panel UI MCU + web UI.
- **VITC** from the SDI video input feeds the timecode subsystem when broadcast-tier SDI is populated and selected as the reference source — removes the need for a separate LTC cable when SDI video is already connected.

### Reference outputs — dual SYNC OUT
- **Connector mix (confirmed 2026-05-11):** 2× BNC on the output side — **SYNC OUT 1** + **SYNC OUT 2**, independently configurable.
- **Per-OUT format selection (runtime):** black burst (NTSC / PAL composite ref) | tri-level sync (HD video ref) | LTC unbalanced. Each OUT also targets its own frame rate, locked to the input reference via rational ratio (e.g., 24 fps IN → 29.97 on OUT1 + 25.00 on OUT2 simultaneously). This is the V1.5 sync-conversion expansion absorbed into V1.
- **Per-OUT signal generation:** independent FPGA phase accumulator per OUT, each ticking at the per-pixel increment for the selected format/rate; drives a parameterized waveform generator (`vid_timing` / `chroma_gen` / LTC biphase modulator) → 12-bit DAC (AD9744 class or PWM+LPF) → 75 Ω cable driver op-amp (ADV3000 / EL5170 / THS6212 class, single IC per OUT, ~$3) → BNC.
- **Hardware provisioning for future formats (firmware-only upgrade):** the per-OUT driver chain is spec'd to also support **DARS** (AES3id digital audio reference, 48 kHz frame rate) and **Word Clock** (square wave, 48/96 kHz). Driver bandwidth (DC to ~10 MHz) and output swing (≥2 Vpp into 75 Ω) cover both. Word Clock will run at 1–2 Vpp rather than vintage 5 Vpp CMOS — accepted by all modern WC inputs (Pro Tools HD, Lavry, Antelope, etc.). DARS / Word Clock format options ship dark in V1 firmware; enabled by software update once positioned. Positioning when enabled: "video-locked audio reference" for on-set use, not mastering-grade master clock (Si5351 + FPGA jitter floor is appropriate for video-rate sync, not sub-picosecond audio mastering work).
- **Si5351 channel allocation:** ch0 → FPGA primary pixel clock; ch1/ch2 reserved for future direct-clock outputs (e.g., GPS-locked 10 MHz distribution) — none consumed by V1 OUT generation since per-OUT phase accumulators run in FPGA off the master clock.

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
- **YUV color-circle color-temperature adjust (confirmed 2026-05-11)** — X/Y axes on the chroma plane, in addition to the RGB-based controls above. Preserves luminance and saturation when shifting color temp (unlike pure RGB subtraction which darkens and desaturates). Inherited from MVPHD-24's approach. Operator uses whichever mode fits their workflow.
- Saturation, hue, black level
- **Proc Amp bypass toggle** (confirmed 2026-05-11) — single per-input toggle to disable all proc-amp adjustments and return to unity gain. Used for raw-vs-adjusted quick compare. Bindable to a front-panel quick-select button (default Q3).

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
  - **Wide-back-porch default for 24p camera shoots** (2026-05-11 — wisdom from a 24-frame production veteran): back porch should default broader than SMPTE 170M nominal (~4.7 µs) when the output is going to a CRT being filmed at 24p. A wider back porch gives the camera shutter a larger target window to land its capture inside the active video region without straddling the V-blank — which is what produces the visible "sync bar" stripe on filmed CRT footage. Default recommendation: 1.5–2× nominal (≈7–10 µs) for the "24p camera shoot" profile. Tunable per-CRT-profile so DPs can adjust to their shutter angle.
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
- **Shutter Phase Reference** (confirmed 2026-05-11) — alternating-field two-color signal for visually phasing a film camera's shutter to the CRT. Solid color seen in viewfinder = correctly phased; split color seen = mis-phased. Companion tool to the wide-back-porch wisdom. Default field 1 = blue, field 2 = yellow (industry convention); operator-configurable color pair.
- **Custom user-loaded test signals** (8 slots, confirmed 2026-05-11) — operator uploads PNG / TIFF full-frame patterns via web UI; stored on TE0720 eMMC, persist across power cycles. Slots selectable via test pattern menu. Use cases: focus charts, custom alignment grids, brand idents, production-specific calibration cards.

### Still image buffers (confirmed 2026-05-11)
- **Four image buffers** on the TE0720 eMMC, selectable as input source via the source mux. Image content persists across power cycles.
- **Format:** PNG, up to 1920×1080. Downscaled on the fly to whichever output rate is active. Typical PNG size ~1–5 MB per slot.
- **Primary storage: TE0720 eMMC** (8 GB total; ~25 MB used for 4 slots). Always present, fast.
- **Optional extended storage: front-panel microSD slot** (confirmed 2026-05-11). Operator can hold a card with extended image libraries — load any image from the card into one of the 4 active buffers. Same slot doubles as the firmware-update vehicle (MVPHD-familiar pattern).
- **Load time:** cold load from eMMC < 1 s (PNG decode on Zynq A9 dual-core dominates ~250–500 ms); from microSD adds ~50–200 ms; once cached in DDR3, subsequent loads of the same slot are < 10 ms (effectively instant).
- **Use cases:** power-on splash, idle-state reference frame, custom brand ident, quick-recall reference for QC, "blank to a known image" behavior on signal loss, source for the EFX burn-in ghost overlay (§ 8.4).
- **First-boot state:** Buffer 1 pre-populated at factory with a Schindler splash image (logo + IP + firmware version, identifiable even before any config). Buffers 2–4 ship empty.
- **Static only in V1.** Animated buffers (looped sequences) are not planned; would add complexity without strong demand.
- **Thumbnails:** front-panel TFT shows a **4-wide horizontal strip of buffer thumbnails (~240 × 180 px each at the 960×376 landscape panel)** in the buffer-management screen. Each thumbnail has its buffer name + slot number labeled below. Web UI shows full-quality thumbnails.

### Effects library (confirmed 2026-05-11)
- **EFX menu — 13 effects + modifiers** for signal-transformation looks. See `ui-menu.md` § 8 for the full menu structure.
- **Effects:** Freeze frame, Random noise (snow), Block artifacts, CRT power-off (collapse + flash + black), CRT power-on (flash + scan-in), Vertical hold loss (rolling), Snow burst (channel change), Color rolling (chroma desync), VHS tracking error (drifting noise bars), Hum bars (slow horizontal dim bars), Burn-in ghost overlay, Scanline emphasis (CRT look on downstream LCD), Blur (Gaussian — Tier 3 HDL cost, may land later in V1), Solarize, Posterize.
- **Modifiers:** blend/mixer (0–100 % wet/dry), transition time (0–240 frames fade in/out), per-effect intensity parameters.
- **Profile-persistent:** effects can be temporarily toggled OR saved into a per-CRT profile for permanent operation. Enables the "make this LCD look like a CRT in-shot" workflow (scanlines + slight blur + warm tint saved into a profile).
- **HDL effort:** original MVPHD set + Tier 1 CRT effects ~2–3 weeks of HDL post-first-light; Tier 3 effects (blur, possibly chromatic aberration in V1.x) may land later in the V1 cycle.

### Networking & control
- **Zynq PS hosts the control plane.** Pi CM4 dropped from V1 (confirmed 2026-05-11). Zynq PS (dual A9, 1 GB DDR3) runs PetaLinux + Node.js web UI, REST API, EDID negotiation, mDNS, OTA updates, config persistence. Single Linux to maintain; Screenie color pipeline JS code ports onto Node-on-Zynq. Saves ~$50 BOM, eliminates inter-processor RPC layer and CM4 supply risk.
- Wired: GbE on TE0720 (PHY on-module) → RJ45 on rear panel
- WiFi/BT module: Laird Sterling LWB5+ (pre-certified, 88W8997 chipset, dual-band a/b/g/n/ac, BT5.0) via SDIO to Zynq PS
- Concurrent AP + STA via Linux hostapd + wpa_supplicant — AP for greenfield setup, STA for venue network, both can stay live simultaneously
- Dual external antennas: 2× RP-SMA stubs on rear panel
- BLE for initial pairing/setup: companion app discovers Schindler boxes via BLE, sends WiFi credentials over encrypted GATT characteristic
- USB on rear panel for service / firmware update / debug

### Rear panel — status display
- **Read-only status LCD on rear panel (confirmed 2026-05-11).** **Newhaven NHD-1.5-240240AF-CSXP** — 1.5" 240×240 IPS square TFT, ST7789VI controller, 32.52 × 35.32 mm module outline (~28 × 28 mm active area cutout). Interface: 8-bit 8080-II parallel OR 3/4-wire SPI (4-wire SPI preferred — uses one SPI peripheral on the Zynq PS). ~1 s refresh.
- **Content:** fixed status grid — one row per I/O connector with name | status icon | detail (rate, format, lock state). Header bar shows IP address, hostname, firmware version, current reference source. No buttons; pure status display for at-rack patching from behind the rack.
- **Rationale:** standard pro practice (Evertz, Imagine, some Ross openGear cards have it). When patching from behind the rack, the engineer sees connection state, lock status, and rate of every port without walking around to the front panel.

### Per-connector status LEDs
- **Tricolor R/A/G LED at every rear-panel connector (confirmed 2026-05-11).** 3 mm body, recessed bezel, ~$0.20 each.
- **Convention (input connectors):** Red = signal expected but missing | Amber = signal present, not in use (or wrong rate / not selected) | Green = signal present and in use | Off = port disabled.
- **Convention (output connectors):** Green = present and outputting | Amber = configured but no source | Off = disabled.
- **Convention (sync IN BNCs):** Red = invalid signal | Amber = locked but not selected as ref | Green = locked + selected as reference | Off = nothing.
- **Driver:** I²C LED drivers, **3× TLC59116F** (16-channel constant-current with per-channel PWM dimming, ~$1.50 each, 48 channels total covers ~21 connectors × 2 colors with headroom). Owned by Zynq PS (Zynq already drives EDID negotiation and signal-lock detection, so it holds the state). UI MCU mirrors the same state on the front-panel status column.
- **Default brightness:** ~10 % so the panel isn't a Christmas tree in a dark machine room. Ramps up on fault.

### Front panel
- Power button (lower-left)
- **microSD card slot (confirmed 2026-05-11)** — front-accessible push-push microSD socket. Dual purpose: (a) firmware updates without rear-panel access (MVPHD-familiar pattern), (b) extended still-image library for the 4 still buffers (operator loads any image from card into an active buffer). Resolves the prior `panel-layout.md` open question.
- Status LED column: genlock lock, signal present per input, network link, fault — multi-color, visible at a glance from across the rack. Mirrors the per-connector LED state on the rear panel.
- Center: **Newhaven NHD-2.9-376960AF-ASXP** — 2.9" 376×960 IPS TFT mounted **rotated 90° to landscape (effective 960 × 376)**, ST7701SN controller, 32.6 × 78.7 mm module outline (~69 × 28 mm bezel-opening cutout in landscape orientation). Interface: 24-bit parallel RGB OR **4-wire SPI** — the SPI option lets the STM32H735 drive it directly from a standard SPI peripheral on the prototype path (no LTDC routing needed); production path can switch to parallel RGB on the same module if frame-rate demands it. 190 PPI for crisp text + thumbnails (~6× the pixel count of the prior 480×272 plan).
- Two rotary encoders: **ALPS EC11E18244AU** — 11mm metal D-shaft (6 mm × 20 mm), 36 detents / 18 PPR (half-step quadrature; firmware decoder counts edges, not full cycles), integrated push switch, sealed, -40 to +85°C industrial range, 15k-cycle rotational life. ~$2-3.50 in singles at DigiKey / Mouser / LCSC. Navigation (CW/CCW + push to select), value adjustment (CW/CCW + push to confirm). Software acceleration on long scrolls advised given fine 36-detent click pitch (~10° per click).
- Four hardware-fixed buttons: Home, Back, Menu, Confirm
- 2-3 quick-select buttons for common functions. **Defaults (confirmed 2026-05-11 post MVPHD review):** Q1 = `BLACK` (fade-to-black), Q2 = `MONO` (monochrome toggle), Q3 = `Proc Amp bypass`. Operator can rebind to any effect or any other action — alternate defaults: Output Mode toggle, EDID profile, Genlock source, Freeze frame, Snow burst.
- **HARD REQUIREMENT: Physical knob guard / shroud preventing lateral torque on encoder shafts during transit and rack handling.** Recessed encoder pocket, side rail bars, or equivalent. Must survive being dropped face-down in a road case.
- Front-panel preset recall

### UI architecture
- Dedicated UI MCU on carrier owns front panel — TFT, encoders, buttons, front-panel LED column
- Zynq PS owns rear-panel LCD + per-connector LEDs (state authority) and pushes mirror updates to UI MCU
- UI alive in <1 second from cold boot; main system can take 15-30 s to boot Linux behind the scenes with progress bar shown
- UI MCU ↔ Zynq PS: UART or SPI for state sync
- Pattern B for v1: single TFT + 2 encoders + buttons. Pattern A (per-encoder OLEDs, DiGiCo-style) reserved for v2 if menu surface area justifies it.
- Bench dev: STM32H735G-DK (~$70) → production silicon STM32H735IGT6 (LQFP176, ~$8)
- UI framework: TouchGFX (visual designer, ST-supported) or LVGL (open-source, more code-driven)

---

## V1 broadcast feature set

**Delivery model: factory-populated hardware option** (confirmed 2026-05-11). Every V1 carrier is broadcast-ready — the board and PCB build are identical, and the SDI silicon footprints exist on every board. Broadcast units have GS3470 + GS2962 populated at factory; base units leave those positions unpopulated. Daughter-card on headers is the favored mechanism for field-installable upgrade — see [SDI daughter card](#sdi-daughter-card-option) below.

- Full SDI video input (Semtech GS3470 receiver, ~$15)
- SDI video output (Semtech GS2962 transmitter, ~$15-20)
- 2 BNCs on rear panel for SDI: 1× IN, 1× processed OUT (via GS2962). Passive loop-through dropped from V1 broadcast tier per 2026-05-11 connector simplification.

### SDI daughter card option

**Status:** [PROPOSED] 2026-05-11. Provides a field-installable / dealer-installable upgrade path for base units to gain the broadcast SDI feature set without unsoldering BGAs.

**Concept.** GS3470 + GS2962 + SDI BNC pair (and supporting passives) live on a small mezzanine PCB that plugs into two carrier headers:
- **High-speed header** — SDI differential pairs (FPGA TX to GS2962, GS3470 RX to FPGA), reference clock, ground returns. Wants controlled-impedance routing, short stub length, and a quality high-density connector (Samtec QStrip QSE/QSH class — 0.8 mm pitch, ground-plane-friendly).
- **Low-speed header** — I²C control bus, power rails (1.2V / 1.8V / 3.3V), enable/reset GPIOs, status returns. Standard 0.1" or 2 mm pitch is fine; signal integrity is not a concern at I²C rates.

**Carrier-side provisions.** Daughter-card footprints (both headers) populated on every V1 carrier regardless of whether the broadcast option is ordered. Footprints unpopulated on base units; daughter card adds ~$35 in silicon + connectors + small PCB at qty 100. Carrier must include termination + pull-ups so that absent daughter card produces clean idle states on the SDI-routed FPGA pins.

**Rear-panel mechanical.** Two SDI BNC cutouts on the rear panel populated on broadcast units and capped/blanked on base units. Option A: BNCs live on the daughter card itself and pass through panel cutouts (cleanest electrically, requires the daughter card mechanical envelope to align with the rear panel — chassis design dependency). Option B: BNCs mount to the carrier with short coax pigtails up to the daughter card (worse signal integrity, easier mech). **Open question** for Justin's call; Option A favored if the chassis/PCB stack-up allows.

**Trade-offs vs always-populated.**
- Pro: clean BOM differentiation, lower base-unit cost, field/dealer upgrade path, broadcast positioning preserved for those who pay for it.
- Con: 3G-SDI through a mezzanine connector pair adds signal-integrity risk (PCIe-grade SI practice — short stubs, matched lengths, solid ground return) and one more thing that can be misaligned during installation. Always-populated avoids both.
- Crossover decision: if broadcast attach rate exceeds ~50–70%, the BOM savings on base units don't justify the SI complexity — populate on every carrier. Below that, daughter-card pays off.

**Open sub-questions.**
- BNCs on daughter card (Option A) vs carrier with pigtail (Option B) — pending chassis layout decision.
- Daughter-card connector family selection (Samtec QStrip QSE/QSH, Molex SearchLight, Hirose FX-series). Defer until carrier signal-integrity simulation tells us the via/stub tolerance.
- Whether to spec a single dual-purpose mezzanine connector (e.g. high-density 80-pin combining HS + LS) vs the two-connector approach proposed above. Two-connector is mechanically more robust against rocking forces; single connector is cheaper but stresses keying.

---

## RF modulator output (built-in)

**Status:** CONFIRMED 2026-05-11 PM. Built into every V1 carrier (both Base and Broadcast SKUs); no daughter card, no SKU tier bifurcation. Adds an RF modulated output on NTSC Ch3 or Ch4 (operator-selectable) for 1970s consumer CRTs with antenna-only inputs. Full architecture, parts spec, and bench bring-up checklist in [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md).

**Why this is on-mission.** The README and playbook target 1970s consumer CRTs explicitly (the 1976 Zenith and 1979 Sony console from Playbook Ch. 1 and Ch. 5). Most consumer sets in that vintage band have RF-only inputs — composite as a back-panel jack didn't become common until the early-to-mid 1980s. Without RF out, Schindler 2.0 can't fully serve the period market its own mission statement names.

**Why baked in, not a daughter card.** BOM delta is ~$32 — too small to justify SKU bifurcation the way SDI's $32 of broadcast-specific silicon does. Customer segments are fuzzy (any DP hauling a Schindler to set could encounter a period CRT on a given shoot). FCC scope already covers every unit (WiFi/BT cert required regardless), so RF is incremental in cert, not bifurcating. Clean product story: every Schindler 2.0 has HDMI + SDI + one selectable analog output (composite / RF / component). SKU axis collapses to Base + Broadcast only.

### Operator mental model: one analog output, three modes

The operator picks ONE of three analog output modes via UI. F-connector lives **beside** the composite BNC on the rear panel; both are physically present, only one is electrically live per mode:

| Mode | Live connectors | ADV7393 state | RF chain |
|---|---|---|---|
| **Composite** | composite BNC | composite mode | disabled |
| **RF Ch3** | F-connector | composite mode | enabled, Si5351 ch1 → 61.25 MHz |
| **RF Ch4** | F-connector | composite mode | enabled, Si5351 ch1 → 67.25 MHz |
| **Component** | 3× component BNC (YPbPr) | component mode | disabled |

Composite mode and the two RF modes share the same ADV7393 composite encoding; they differ only in which output path is gated live. Mode-mux logic on the carrier (ADG419 SPST switch on composite BNC + FET switch on ERA-3 bias supply) handles the gating from Zynq PS GPIOs.

HDMI and SDI remain independently live per the pipeline architecture; they're not part of the analog-output mode mux.

### Architecture summary

The RF chain consumes the same buffered composite signal that drives the composite BNC (single LMH6643 buffer, no additional channel needed). A dedicated Si5351 on the carrier (separate from the genlock Si5351 so the constantly-nudged genlock chip doesn't cross-couple into RF) generates the video carrier and pilot audio carrier. An ADL5391 analog multiplier does the AM modulation (video on Y input, RF carrier on X input, DC bias on Z input for negative modulation reference). Modulated output is combined with the silent pilot audio carrier in a resistive combiner, passed through a 56–73 MHz LC bandpass filter (covers both Ch3 and Ch4 video + audio frequencies, naturally suppresses harmonics outside the channel band), amplified by an ERA-3SM+ MMIC, matched 50→75 Ω via a resistive minimum-loss pad (43.2 Ω series + 86.6 Ω shunt, 5.7 dB IL, ~$0.10 in passives), DC-blocked, ESD-protected, and routed to the panel F-connector. Shield can covers the modulator + amp + Si5351 + bandpass filter section for FCC compliance.

### Modulation choice — DSB-AM, no VSB filter, silent pilot audio

- **DSB-AM (not VSB):** True VSB requires per-channel SAW filters or sharp LC bandpass networks. DSB-AM uses 2× the spectrum but works fine into consumer TV receivers — they're VSB *receivers* that filter the unwanted sideband at the IF stage internally. We're not broadcasting; we're cabling 2 m into a CRT.
- **Silent audio pilot (Path A, confirmed 2026-05-11 PM):** Unmodulated CW carrier at video_carrier + 4.5 MHz from Si5351 ch2. Satisfies the period-CRT intercarrier AGC requirement (TV detects carrier presence, no audio to demodulate, speaker stays silent). Schindler's mission is camera-captured visuals; film cameras don't record CRT speaker audio. If V1.x customer evidence drives real audible audio later, the discrete-Colpitts-VCO + FPGA-generated-1-kHz-tone path (Path B from 2026-05-11 audio analysis, ~$3 BOM, ~1 day HDL) is the documented next step.

### Why Ch3/Ch4 only

- US-centric customer base (film/TV production driving period US CRTs). Every period US set tunes Ch3 or Ch4 as the VCR-connect channel pair.
- Bandpass filter centered 56–73 MHz covers both video + audio carriers for both channels; rejects everything outside the band including 2nd harmonics (which fall at 122.5–134.5 MHz, well outside passband). Eliminates need for a separate harmonic LPF.
- Simpler UI: Ch3/Ch4 toggle.
- PAL/NTSC-J/PAL-M expansion is firmware-only later — same hardware, different Si5351 register loads + wider bandpass filter swap if international demand ever materializes.

### Output level

~−40 to −30 dBm at the F-connector. Adjustable via ADL5391 GADJ pot + ERA-3 fixed gain. Designed for short-coax-into-CRT use, not broadcast. Stays inside FCC Part 15.119 cable-output device limits.

### Key parts (full spec in `rf-modulator-subsystem.md`)

- **AM modulator:** ADL5391ACPZ-R7 primary (Analog Devices DC–2.0 GHz multiplier, ~$15 single qty, ~$18 at qty 100, modern symmetric-core architecture); AD835ARZ fallback (250 MHz multiplier, 8-SOIC, ~$25 at qty 100, classic part). Order both for prototype bench eval.
- **RF carrier gen:** Si5351A-B-GT local on carrier dedicated to RF subsystem + 25 MHz crystal (~$2). Decoupled from genlock Si5351 to avoid cross-coupling; genlock Si5351 ch1/ch2 stay reserved for future GPSDO.
- **RF amp:** Mini-Circuits ERA-3SM+ MMIC (DC–3 GHz, ~22 dB gain, ~$3.50).
- **Output bandpass:** 5th-order LC, centered ~64 MHz, passband 56–73 MHz (~$1.50 in Coilcraft 0805CS inductors + C0G ceramic caps).
- **Mode-mux:** ADG419BRZ SPST analog switch on composite BNC + FET switch on ERA-3 bias supply (~$1.80 total).
- **F-connector:** Amphenol RF 82-4421 class panel-mount 75 Ω (~$1.50).
- **Shield can:** Wurth WE-SHC or Laird small-format (~$2.50).
- **Total RF subsystem BOM:** ~$32 per V1 unit (all SKUs).

### Bench bring-up path (cheap)

ADI ADL5391-EVALZ is ~$300 at DigiKey — too expensive for what it provides. Cheap path confirmed 2026-05-11:

- **EC Buying ADL5391 breakout board** (~$15-25 AliExpress) for primary bench eval.
- **ADL5391ACPZ-R7** ($15 DigiKey) as known-authentic backup chip in case the Chinese-board silicon is counterfeit (verify by characterizing chip behavior against datasheet; swap bare chip in via dead-bug if needed).
- **AD835ARZ** ($25 DigiKey) as architectural fallback.
- Total bench-eval starter: ~$55 in silicon + ~$20 in connectors/passives = ~$75 vs $300 ADI eval board.

### FCC strategy

Stay within Part 15.119 cable-output device limits: shielded RF section, output limited to coaxial F-connector (no antenna driven), bandpass filter for natural harmonic suppression, bench-verify radiated emissions before commercial sale. Formal Part 15 test campaign rolls into the WiFi/BT cert already required for every unit — incremental, not separate. Estimated additional test scope: ~$2–5K beyond the WiFi/BT-only campaign.

### Open questions for bench-eval phase

- Final modulator chip selection (ADL5391 vs AD835) — prototype-characterization decision.
- Output bandpass topology (Chebyshev vs Butterworth) — synthesize after measuring actual harmonic content.
- Channel-selection UI surface (front-panel button vs web-only) — defer to UI spec phase.
- Audio FM modulation in V1.x (Path B) — defer until customer evidence drives speaker output need.

---

## Sync conversion capability (V1 — absorbed)

**Status:** banked in V1 as of 2026-05-11. Originally scoped as a V1.5 follow-on; absorbed into V1 via the dual SYNC OUT BNCs (SYNC OUT 1 + SYNC OUT 2 on the output side of the sync zone) and per-output independent format / rate selection in the FPGA.

**What it does.** Cross-rate sync conversion with timecode translation. Accepts an incoming reference (LTC / BB / tri-level / SDI VITC) at one frame rate, generates reference signals at independent rates and formats on each of the two SYNC OUTs. Output domains are phase-locked to the input via rational ratios; timecode math (drop-frame, jam-sync) is preserved across the boundary. Example: 29.97 LTC IN → SYNC OUT 1 = 24.000 black burst + LTC, SYNC OUT 2 = 25.000 tri-level + LTC, both live simultaneously.

**Why it matters.** Mixed-rate productions otherwise need a separate broadcast-grade sync converter (Evertz 5600, AJA OG-Frame, BMD Sync Generator family) alongside the CRT prop driver. With this in-box, Schindler is a broadcast-grade rate-domain bridge that happens to drive period CRTs.

**Hardware (already in V1 — see Reference outputs section):**
- 2× BNC SYNC OUT (SYNC OUT 1 + SYNC OUT 2). Each driven by its own FPGA phase accumulator + waveform gen + 12-bit DAC + 75 Ω cable driver, format-selectable across BB / tri-level / LTC. Driver chain hardware-ready for DARS / Word Clock as firmware-only future addition.

**HDL building blocks (to be authored as V1 development progresses):**
- LTC decoder (bit-sync + biphase decode + frame assembler) — `LTC_DEC` in signal-flow diagram 2. Already required for genlock; doubles as timecode source for the conversion math.
- LTC encoder (frame builder + biphase modulator + DAC waveform shaping) — sits in the per-OUT waveform gen blocks when an output is LTC-format.
- Timecode math module (rational rate converter, drop-frame logic, jam-sync behavior on input loss) — feeds the per-OUT LTC encoder.
- Per-OUT phase accumulators locked to the master clock via rational ratios — `ACC` block in diagram 2.
- Tri-level / black burst sample generator at output rate (parameterized variant of `vid_timing.v` + `vbi_gen.v`) — sits in the per-OUT waveform gen blocks for BB / tri-level outputs.

**Effort estimate:** 2–3 weeks dedicated FPGA + RP2040 work for first-light across common rate pairs (24, 25, 29.97, 30). Possibly 1–2 months for all corner cases (full drop-frame jam-sync correctness, freewheel behavior on input loss, all input × output rate combinations).

---

## V2 / future

- **4K video support** — DEFERRED to a separate future product (Schindler 4K / Schindler 3.0). Significant architecture change touching most subsystems, so V1 ships HD-only without 4K-readiness headroom. Summary of what 4K would require:
  - **SoC upgrade:** Zynq-7020 → Zynq UltraScale+ (ZU3EG/ZU4EV/ZU5EV class) via TE0820/TE0822 SoM (~pin-compatible carrier upgrade, but signal integrity must be designed for higher rates). SoM cost $230 → $480–750.
  - **HDMI:** LT8619C (HDMI 1.4-class, V1 baseline) → HDMI 2.0/2.1 receiver chip or direct GTH transceivers on UltraScale+. HDCP 2.2/2.3 licensing required ($15K/yr DCP fee).
  - **SDI:** GS3470/GS2962 (3G-SDI) → GS12281/GS12141 (12G-SDI), +$30–50 per unit.
  - **Memory:** Zynq UltraScale+ DDR4 (25–50 GB/s) needed for 4K60 frame buffer (~4–8 GB/s). Zynq-7020 DDR3 (12.8 GB/s) marginal for 4K30.
  - **Color pipeline DSP scaling:** linear with pixel rate — 4× for 4K30, 8× for 4K60 vs 1080p30. UltraScale+ has 360–1248 DSPs vs Zynq-7020's 220.
  - **Power/thermal:** ~10W → 25–40W total. Active cooling (small fan) becomes necessary; passive in 1RU is borderline.
  - **PCB:** 6–8 layer → 8–10 layer with low-loss dielectric (Megtron 6, I-Tera MT). 12G-SDI BNCs need 75Ω high-grade parts. PCB cost +$50–80 per unit.
  - **Schedule:** +6–10 months dev time (HDL for 4K HDMI + 12G-SDI: 2–4 mo; color pipeline optimization: 1–2 mo; bench validation with 12G scopes: 1 mo; HDCP cert: 3 mo).
  - **BOM impact:** +$410–475 per unit at qty 100 across all variants.
  - **What does NOT change:** analog video pipeline (composite stays SD; component stays HD-or-SD per ADV7393 capability), genlock / LTC / sync conversion front-end, dual SYNC OUT, UI MCU, rear LCD, per-connector LEDs, WiFi, chassis dimensions, power topology. CRT-driving use case is unaffected by 4K — CRTs cap at 1080i.
  - **Decision rationale:** Schindler V1 already serves multiple use cases (CRT driving + general broadcast HD signal processor + sync conversion); 4K isn't required for any of those — CRTs cap at 1080i, broadcast routing at this tier is largely 3G-SDI, and sync conversion is rate-agnostic. 4K matters mostly for a future Mini/HDMI consumer variant. Building 4K-ready signal integrity headroom into V1 carrier costs +$50–80 BOM headroom that may never be populated. Cleaner to ship V1 focused on HD, validate the platform, then design Schindler 3.0 / 4K Pro as a deliberate follow-on with the right silicon selected at that point (chip landscape will have evolved by then).
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
| HDR processing | HDMI 1.4 doesn't carry HDR metadata; CRTs and analog outputs can't display HDR; HDR pipeline DSP cost not justified for the target market. |
| Multiviewer | Single output by design. |
| Recording / capture | Downstream concern. |
| Logo / lower-third / CC overlay | Out of mission. |
| Touchscreen UI | Glare, smudges, no tactile, fails in production environments. Replaced by rotary encoders + dynamic TFT. |

---

## Open questions / parked decisions

- **S-Video input** to ADV7280 path: free in silicon (decoder supports it natively), costs one mini-DIN connector + 2 traces. Common on consumer retro source gear (VHS, S-VHS decks, Hi8). **Pending decision.**
- **SDI daughter-card connector choice** (Samtec QStrip class vs alternative high-density mezzanine connectors) and BNC routing (on-daughter-card vs ribbon-back-to-carrier) — see [SDI daughter card](#sdi-daughter-card-option) for the open sub-questions.

---

## Revision history

Moved to [`01-spec-changelog.md`](01-spec-changelog.md). This file holds only the current state of the spec; the changelog holds the dated decision narrative.
