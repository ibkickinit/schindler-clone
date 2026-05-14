# Schindler 2.0 — Development Roadmap

**Status:** Active 2026-05-13
**Purpose:** SSOT for "what's being built right now, what's deferred, what's the next milestone." Prevents the same confusion that hit when forward-looking architecture docs got mistaken for active dev state.

Active dev runs on the **Digilent Zybo Z7-20** development board (Zynq-7020 silicon, same family as the production TE0720 SOM). HDL ports from Zybo to TE0720 1:1 when the migration activates.

---

## 1. Active right now — HD pipeline on Zybo Z7-20

Building top-down. Pipeline first, terminal encoders later. Each phase is scope-checkable on the Zybo.

| Phase | Goal | Effort | Status |
|---|---|---|---|
| **A** | HDMI passthrough on Zybo (Digilent reference design as seed). Computer HDMI source → Zybo HDMI Source → AXI4-Stream Video → Zybo HDMI Sink → monitor. Validates HDMI infrastructure end-to-end on this board. | 1–2 days | **Next up** |
| **B** | Frame buffer in DDR3 via Xilinx AXI VDMA. Double-buffered ping-pong, no tearing. Inserted between HDMI RX and HDMI TX. Foundation for scaler and FRC. | ~1 week | Pending A |
| **C** | Polyphase scaler. Xilinx Video Scaler IP vs custom 8-tap H / 4-tap V. 1080p → 720p / 480p test cases. | 2–3 weeks | Pending B |
| **D** | Frame rate conversion (FRC). Cadence convert per banked rate matrix (3:2 pulldown, 5:2, 6:5, 4:5, 2:1, 1:2, slip). 3:2 cadence auto-detect for inverse-telecine. | 2–4 weeks | Pending C |
| **E** | Color pipeline (port from Screenie). 1D LUT + 3×3 matrix + per-channel trim + YUV color-circle adjust. | 3–4 weeks | Pending D |
| **F** | Geometry warp. Pincushion + keystone + 4-corner. | 2–3 weeks | Pending E (low priority — can land late) |
| **G** | Re-attach analog terminal encoders. Plug Phase 2 HDL (`vid_timing.v` + `vbi_gen.v` + `chroma_gen.v` + `sample_gen.v`) back in as the NTSC composite encoder terminal off the HD signal bus. Add I/Q chroma modulator for active-video color. | 2–3 weeks | Pending E |

**First-week concrete actions for Phase A:**
1. Verify Vivado version on bench (need 2025.x or compatible with Digilent's Zybo Z7-20 board files + HDMI demo design)
2. Pull Digilent's Zybo Z7-20 HDMI demo from their GitHub
3. Open in Vivado, generate bitstream, program Zybo, validate computer-HDMI-source → Zybo HDMI Sink → external monitor
4. Once passthrough works, fork the project for Schindler-specific development (new top-level distinct from the existing Phase 2 R2R-output `top.v`)

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

## 2.5. Side-arcs — silicon bench bring-up (parallel to Phase A–G)

Bench bring-up of each production silicon piece on its EVAL board, **standalone**, before the production carrier exists. Independent of the Phase A–G ordering — each side-arc can land any time its EVAL board is on the bench.

Naming convention: `Side-arc N` to keep distinct from `Phase A–G` (HD pipeline) and the historical `Phase 1/2` (R-2R composite first-light).

| Side-arc | Goal | Status | Doc |
|---|---|---|---|
| **Side-arc 1** | ADV7393 EVAL composite bench bring-up. Zybo PMODs → BT.656 8-bit → EVAL board → CVBS BNC → scope shows NTSC color bars from FPGA HDL. Also locks in **day-1 split bus** (HDMI bus + analog bus, independent). | Planned | [`side-arc-1-adv7393-bench.md`](side-arc-1-adv7393-bench.md) |
| **Side-arc 2** | Genlock / sync subsystem bench bring-up. Five sub-arcs (2a–2e): Si5351 standalone → ADC+PGA → BB sync separator → closed-loop digital PLL → H/V phase trim. Locks in **Si5351-routes-master-clock-in-both-regimes** architecture. ~3–5 weeks of focused work. **2a unblocked** (Si5351 board + RP2040 on bench). | Sub-arc 2a ready to start | [`side-arc-2-genlock-bench.md`](side-arc-2-genlock-bench.md) |
| Side-arc 3 | ADV7511 EVAL HDMI TX bench bring-up | Future | — |
| Side-arc 4 | ADV7280 EVAL multi-format decoder bench bring-up | Future | — |
| Side-arc 5 | LT8619C-EVB HDMI RX bench bring-up | Future | — |
| **Side-arc 6** | TE0720 + TE0703-07 production-target silicon bring-up. Four sub-arcs (6a–6d): power+JTAG → Trenz toolchain → PetaLinux boot → Zybo HDL portability check. De-risks production migration. ~1 week of focused work. **Hardware on bench (2026-05-14).** | Ready to start | [`side-arc-6-te0720-bringup.md`](side-arc-6-te0720-bringup.md) |

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
