# Schindler 2.0 — Development Roadmap

**Status:** Active 2026-05-16
**Purpose:** SSOT for "what's being built right now, what's deferred, what's the next milestone." Prevents the same confusion that hit when forward-looking architecture docs got mistaken for active dev state.

Active dev runs on the **Digilent Zybo Z7-20** development board (Zynq-7020 silicon, same family as the production TE0720 SOM). HDL ports from Zybo to TE0720 1:1 when the migration activates.

---

## 1. Active right now — HD pipeline on Zybo Z7-20

Building top-down. Pipeline first, terminal encoders later. Each phase is scope-checkable on the Zybo.

| Phase | Goal | Effort | Status |
|---|---|---|---|
| **A** | HDMI passthrough on Zybo. Pure-PL design — dvi2rgb (TMDS RX) → direct wire → rgb2dvi (TMDS TX). Validates HDMI infrastructure end-to-end. See [`phase-a-bench-test.md`](phase-a-bench-test.md). | 1–2 days | ✅ **Complete (2026-05-13)** — running stable at 1080p60 |
| **B** | Frame buffer in DDR3 via Xilinx AXI VDMA. Double-buffered ping-pong, no tearing. Inserted between HDMI RX and HDMI TX. Foundation for scaler and FRC. See [`phase-b-bench-test.md`](phase-b-bench-test.md). | ~1 week | ✅ **Complete (2026-05-14)** — Mac desktop running through DDR3 frame buffer at 1080p60. Five stacked bugs (source-side TMDS flicker, two unwired BD resets, VTC IP-time VIDEO_MODE default, VDMA AXIS width mismatch, missing VTC `RU` bit in firmware CTL write) all resolved. |
| **C** | Polyphase scaler. Custom 8-tap H / 4-tap V (Lanczos-2). Originally targeted 1080p→480p; pivoted to 1080p→720p mid-session because rgb2dvi IP only supports pixel clocks ≥40 MHz. See [`phase-c-design.md`](phase-c-design.md). | 2–3 weeks | ✅ **C.1 done (2026-05-14)** at 1080p→720p — Mac desktop running through the scaler, recognizable on bench monitor (`build/ila-capture/phase-c-victory/scaler-720p-monitor.jpg`). Build #5 produced a clean bitstream but bench-failed with half-frames; xsim testbench reproduced deterministically; root cause was scaler_v's 2-cycle output pipeline colliding with back-to-back v_cross events. Build #6 rewrites scaler_v to 1-cycle throughput — sim passes 0 errors, bench shows coherent picture. Residual cross-clock-domain tearing (input/output MMCMs both nominally 60 Hz but no genlock) is **Phase D scope**. 480p-via-HDMI deferred (rgb2dvi `kClkRange` patch — not on critical path; SD output goes through Phase G's analog terminal, not HDMI). |
| **D** | Frame rate conversion (FRC). Cadence convert per banked rate matrix (3:2 pulldown, 5:2, 6:5, 4:5, 2:1, 1:2, slip). 3:2 cadence auto-detect for inverse-telecine. | 2–4 weeks | 🟡 **D iter 1 (2026-05-14, superseded)** — output PixelClk genlocked to source via `dvi2rgb_0/PixelClk`. Eliminated temporal tearing for fixed-rate passthrough but blocks FRC because output rate = input rate by construction. Reversed in iter 4c. 🟡 **D iter 2 (2026-05-14)** — firmware source-event UART logging; auto-recovery attempted and abandoned (VDMA stays wedged across disconnect; needs deeper-than-driver reset). Manual recovery via `xsct tcl/program_phase_b_full.tcl`. 🟢 **D iter 3i SHIPPED (2026-05-15)** — deterministic vsync alignment via AXI GPIO + firmware spin to source vsync edge before VTC CTL write (Q-y spread = 0 px across 12 reboots, down from 700 px). Bundled: Mitchell-Netravali kernel, round-to-nearest MAC, `scaler_v` `lbuf_fresh` warmup gating. iter 3j/k addded MM2S +STRIDE read offset + per-slot guard region to hide remaining scaler_v warmup row + intermittent tail-read flicker line. 🟢 **D iter 3q SHIPPED (2026-05-15 late)** — ILA-localized "moving sparkle" at color-bar boundaries to scaler MAC; Mitchell's -0.036 negative sidelobes were amplifying ±1 LSB source variation into ±35 LSB output excursions. Replaced both MACs with nearest-neighbor bypass; coefficients kept on disk for future kernel revisit. 🟡 **D iter 4a–c (2026-05-16)** — FRC scaffolding: source rate detection (4a), free-running output PixelClk from FCLK_CLK0 (4c, commit `781eb56`) — reverses iter 1 genlock so input and output rates can differ. Bench: OUT = 60.027 Hz vs SRC = 60.146 Hz (0.2% delta) measurable, proves free-run is real. 🟡 **D iter 4d-1 (2026-05-16, commit `3f5082c`)** — output-side observability: AXI GPIO surfaces VTC vsync_out + clk_wiz_pixclk_out/locked into FCLK_CLK0 domain. 🟡 **D iter 4d-2 (2026-05-16, commit `5b37e77`, SUPERSEDED)** — cadence FSM + firmware-driven VDMA PARK_PTR_REG writes. 2-3 horizontal seams per frame because PG020 doesn't guarantee SOF-atomic PARK latching. Anti-pattern; resolved in iter 4d-3. 🟢 **D iter 4d-3 SHIPPED (2026-05-16, commit `c0e1038`)** — Dynamic Genlock (S2MM mode 2 / MM2S mode 3) + FrameDelay=1 + repeat_en=1, zero firmware writes during steady-state. Hardware-enforced collision avoidance per PG020. Bench: 4 SMPTE captures over 6 sec byte-identical at 95611 bytes (`build/ila-capture/phase-d/iter4d-3-step2-frame-*.jpg`). Open follow-ups: (1) judder evaluation under motion (static SMPTE can't distinguish frame-held from frame-replaced; Justin bringing a moving source); (2) 30p→60p and 24p→60p cadence on top of the Dynamic Genlock substrate — IRQ-driven from MM2S SOF, only acts at cadence boundaries; blocked on ImagePro source-rate change; (3) per-channel edge asymmetry (~30 LSB on one channel at high-contrast transitions, from iter 3m). |
| **E** | Color pipeline (port from Screenie). 1D LUT + 3×3 matrix + per-channel trim + YUV color-circle adjust. | 3–4 weeks | Pending D |
| **F** | Geometry warp. Pincushion + keystone + 4-corner. | 2–3 weeks | Pending E (low priority — can land late) |
| **G** | Re-attach analog terminal encoders. Plug Phase 2 HDL (`vid_timing.v` + `vbi_gen.v` + `chroma_gen.v` + `sample_gen.v`) back in as the NTSC composite encoder terminal off the HD signal bus. Add I/Q chroma modulator for active-video color. **Hardware on hand (2026-05-14)**: EVAL-ADV7393 board received — drives composite + S-Video + component (SD and HD) outputs. Plan: wire Zybo PMODs → ADV7393 digital-input header, configure chip via I²C from PS, drive with Phase 2 HDL outputting YCbCr 4:2:2 parallel + DCLK/HS/VS. | 2–3 weeks | Pending E. EVAL-ADV7393 hardware in hand. |

---

## 2. Recently completed — Phase 2 first-light on Zybo + R2R DAC

Pre-priority-shift work, validated and banked. Currently on hold per the HD-pipeline-first arc.

| Block | State |
|---|---|
| `hdl/vid_timing.v` — 54 MHz pixel clock, 3435×655 timing, 24.000 fps exact | ✅ Scope-validated. VSync-to-VSync 41.667 ms confirmed. |
| `hdl/vbi_gen.v` — 3+3+3 equalizing/serration/post-eq + 12 blank fill | ✅ Scope-validated. 6+6+6+12 pulse pattern counted on scope matches HDL. |
| `hdl/sample_gen.v` — gray / ramp / bars test patterns | ✅ Scope-validated. R2R DAC monotonic + linear; pixel timing rock-solid. |
| `hdl/chroma_gen.v` — 3.58 MHz colorburst on back porch, 32-bit NCO + 256-entry cosine LUT, ±20 IRE burst amplitude | ⏳ HDL written + integrated in `top.v` + builds clean (#197573 WNS +11.75 ns). **Chroma burst bench verification on scope still pending.** |

**Bench observations:**
- ~63 µs line rate, ~5 µs sync width, ~3 µs back porch, ~53 µs active video — all correct against `vid_timing.v` parameters
- Signal amplitude currently ~3 V p-p (peak white +2 V above blank, sync tip −1 V below blank). SMPTE target is 1 V p-p at 75 Ω. Calibration is bench-side analog gain reduction, not an HDL change.

---

## 3. Deferred until HD pipeline validates

Resumed after Phase G re-attaches the analog terminal. **Not abandoned — just out of order with current priority.**

- **Chroma burst bench verification** (`chroma_gen.v` on scope — confirm ~9-cycle 3.58 MHz sine on back porch at ±20 IRE)
- **I/Q chroma modulator HDL** — active-video color modulation. Multiplies color-difference signals with sin/cos of subcarrier; sums into composite output.
- **Colored test patterns** — extend `sample_gen.v` with SMPTE color bars, PLUGE, Shutter Phase Reference (alternating-field blue/yellow), purity (R/G/B full fields).
- **R2R amplitude calibration** — bench-side analog gain reduction to land on SMPTE 1 V p-p at 75 Ω.
- **CRT lock test** — once CRTs are on the bench. Confirm vertical lock at 24 fps on consumer + professional CRTs.

---

## 4. Forward-looking — hardware migration

### 4.1 Bench port: Zybo HDL → TE0720 SOM

When the TE0720-based bench platform is ready (TE0720 SOM + some carrier — currently considering options, no production carrier fabricated yet), the HD pipeline HDL ports 1:1. Same Z-7020 silicon family, different package and board files.

Port work: regenerate MMCM for TE0720's reference clocks, regenerate constraints file for TE0720 carrier pinout, rebuild bitstream targeting `xc7z020clg400-2I` (production). Typically ~half a day of porting.

### 4.2 Production carrier PCB design + fab

Comes after HD pipeline validates on Zybo. Custom 4-layer carrier per [`01-spec.md`](01-spec.md) § 1.2 with TE0720 sockets, full silicon stuffing, rear-panel I/O fanout. Layout effort estimate ~3–5 weeks focused work. Fab + assembly at JLCPCB / PCBWay / similar at qty 5 prototypes initially.

### 4.3 Analog production silicon hookup

ADV7393 (output DAC), ADV7280 (input decoder), ADV7511 (HDMI TX), LT8619C (HDMI RX) all hook up on the production carrier. Eval boards (EVAL-ADV7393EBZ already procured, others on hand or on order) can validate each chip standalone before carrier fab if helpful.

### 4.4 Production silicon — genlock chain

LTC6912 (PGA), AD9204 (ADC), Si5351 (clock gen), RP2040 (slow-control). All on the carrier per spec.

---

## 5. Forward-looking — SKU build-out

### 5.1 Mini v1 chassis + simple front panel

- Half-rack 1RU chassis sourcing + custom-milled aluminum panels
- 1.3" mono OLED + 5-way nav + 4 preset buttons + power + microSD + tri-color LED
- PetaLinux user-space `schindler-ui` app for the front-panel state machine
- Power: internal LRS-50-12 + IEC inlet OR external 12 V brick (pending decision)

### 5.2 Pro v2 chassis + mezzanine front panel

- Full-rack 1RU 19" chassis sourcing + custom-milled panels
- Mezzanine board: RP2040 + BT817Q EVE + NHD-2.9 TFT + dual ALPS EC11 encoders + buttons + front LED column
- EVE firmware development (BridgeTek EVE Asset Builder + FT8xx command set)
- **Dev hardware:** Riverdi RVT43HLBFWN00 (4.3" EVE4 intelligent display, BT817Q + flash on board, ~$62) on order — complete EVE dev environment, matches production BT817Q exactly. Allows EVE toolchain learning + UI flow prototyping in parallel with HDL phases on Zybo, without blocking on carrier PCB fab. NHD-2.9 production panel (376×960 parallel RGB) gets validated separately via custom adapter board later in mezzanine schematic phase.
- Rear NHD-1.5 status LCD + per-connector tricolor LED arrays (TLC59116F drivers)
- Internal LRS-50-12 + Schaffner FN9260B-6-06 IEC inlet

### 5.3 SKU bring-up sequencing

Mini ships first. Pro v2 work activates after Mini validates in the field.

---

## 6. Other future-evaluation candidates (not active dev)

Procured or considered for **future evaluation only** — NOT the active dev platform. Documented separately in the archive (`docs/Hardware/`).

- Smart Artix V1.3 (discrete Spartan-7 dev board)
- Smart Zynq SL V1.3 (different Zynq variant)
- TE0712-02 (different Trenz SOM)
- Tiny Zynq V1.1 (discontinued)
- TE0720-04-31C33MA + TE0703-07 (Trenz dev carrier — bought for bench eval, not committed as production path)
- TE0720-04-61C530A (cheaper TE0720 variant — considered, ruled out for memory reasons)
- Various LT8619C-EVB / EVAL-ADV7393EBZ / MIKROE-2555 / AD9204-80EBZ — bench eval boards for individual chips

These can be re-evaluated if the active dev path hits a wall, but the spec assumes Zybo Z7-20 dev platform → TE0720-04-62I33MA production target.

---

## 7. Decision changelog

Date-anchored design decisions live in [`01-spec-changelog.md`](01-spec-changelog.md). This roadmap doc is the operational "what's-being-built" view; the changelog is the historical "why-we-decided-X" view.

---

## 8. Cross-references

- Internal electronics architecture: [`01-spec.md`](01-spec.md)
- SKU packaging variants: [`packaging-skus.md`](packaging-skus.md)
- Bill of materials: [`bom-v1.md`](bom-v1.md)
- Signal flow diagrams: [`signal-flow.md`](signal-flow.md)
- Panel layouts: [`panel-layout.md`](panel-layout.md)
- Development narrative: [`schindler-playbook.md`](schindler-playbook.md)
- R-2R DAC bench reference: [`r2r-dac.md`](r2r-dac.md)
- Op-amp output stage design: [`opamp-stage.md`](opamp-stage.md)
- Future-eval hardware archive: [`Hardware/`](Hardware/)
