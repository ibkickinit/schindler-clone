# Schindler 2.0 — Reference Designs & Commercial Models

**Status:** Active 2026-05-14
**Purpose:** Catalog of FPGA reference designs, open-source projects, and commercial architectures to seed from / model after for the HD pipeline build (Phase A–G in [`dev-roadmap.md`](dev-roadmap.md)). Particularly for the scaler (Phase C), frame rate conversion (Phase D), and downconvert-to-SD inside the terminal encoders.

This is a research/reference document, not a build target. The active dev plan stays as written in `dev-roadmap.md`.

---

## 1. Tier 1 — drop-in for Zynq-7020 (Zybo Z7-20 → TE0720)

These compile against the same silicon family already in use. Highest leverage for Phase A–C.

### 1.1 AMD/Xilinx Video Processing Subsystem (VPSS) + Video Scaler IP
- Free in Vivado IP catalog. No license cost on Z-7020.
- Polyphase scaler, configurable taps. Matches Phase C target (8-tap H / 4-tap V) exactly.
- AXI4-Stream Video native; plugs straight into the VDMA topology planned for Phase B.
- Reference docs: **PG231** (V Scaler), **PG230** (VPSS), **PG044** (AXI VDMA).
- Use as the **golden reference** to A/B against any custom polyphase HDL written for Phase C. If a custom 8H/4V implementation matches the Xilinx IP on standard test patterns (zone plate, multiburst, sweep), the custom is validated — no need to invent a separate yardstick.

### 1.2 Xilinx Targeted Reference Designs (TRDs)
- **XAPP1167** / "Zynq All-Programmable SoC TRD" — full HDMI-in → VDMA → scaler → HDMI-out stack with PetaLinux control plane.
- **ZC706 Image Processing TRD** — same pipeline shape, larger Z-7045 part. Logic is portable to Z-7020 modulo BRAM/DSP capacity.
- These are the closest published designs to what Schindler 2.0 *is* at the system-architecture level.

### 1.3 Digilent Zybo Z7-20 HDMI demo
- Already on Phase A's path. Correct seed for HDMI infrastructure validation.
- GitHub: `Digilent/Zybo-Z7-20-HDMI` (or current equivalent).
- Validates HDMI RX (LT8619C-style PHY) and HDMI TX (ADV7511-style) end-to-end on the dev platform.

---

## 2. Tier 2 — open source, retro/CRT-aligned

Less directly portable than Tier 1 (different silicon, different tools), but the *problem domain* overlaps Schindler's CRT-targeted goals more than the broadcast-grade Xilinx TRDs do.

### 2.1 MiSTer FPGA framework scaler
- Repo: `MiSTer-devel/Main_MiSTer` (and per-core repos).
- DE10-Nano (Cyclone V SoC) — different vendor, but the polyphase scaler and scandoubler logic is plain (System)Verilog and reads cleanly.
- License: GPL — read for understanding, don't lift wholesale into a commercial product without a license-compatibility audit.
- Especially useful for: cadence-edge cases on the output side, scandoubling/tripling for CRT-friendly output, EDID handling.

### 2.2 OSSC / OSSC Pro
- Repo: `marqs85/ossc` and `marqs85/ossc_pro`.
- Cyclone IV / Cyclone 10 GX. Open-source line-multiplier targeted directly at PVM/CRT workflows.
- Not a full polyphase scaler (line-multiply rather than arbitrary resample), but the **sync handling, EDID, output timing for CRTs**, and the general "preserve every pixel" philosophy are directly relevant to the terminal-encoder side of Schindler.

### 2.3 HDMI2USB / Numato Opsis
- Repo: `timvideos/HDMI2USB-litex-firmware`.
- Spartan-6 based, MIT-licensed. Older, but the pipeline organization (HDMI RX → framebuffer → HDMI TX) is clean and self-contained.

### 2.4 GBS-Control
- Repo: `ramapcsx2/gbs-control`.
- Firmware for the TVIA 5725-based GBS-8200 board. Not FPGA, but the *configuration* of a commercial scaler chip for CRT-friendly output documents a lot of practical scaler tuning that's hard to find elsewhere.

---

## 3. Tier 3 — commercial architectures to model after

Closed source. Use the publicly available block diagrams, white papers, and spec sheets as architectural references — same way broadcast engineers have always done it.

### 3.1 AJA FS1 / FS-HDR (frame syncs / standards converters)
- Canonical "input decoder → framestore → scaler → FRC → output encoder" textbook diagram.
- AJA white papers describe the pipeline at exactly the abstraction level needed for Schindler's HD pipeline arc.
- Best single reference for "how is a frame sync structured."

### 3.2 Decimator MD-HX / DD4
- Small, single-purpose downconverters. Public block diagrams.
- Closest commercial functional analog to a Schindler "downconvert terminal" off the HD signal bus.

### 3.3 Calibre UK HQView / HQUltra
- Image processor product line. Calibre's app notes on polyphase scaling and de-interlacing are some of the better-written pieces of literature on the topic.
- Worth pulling app-note PDFs from `calibreuk.com` for the polyphase-coefficient discussion specifically.

### 3.4 Blackmagic Mini Converter HDMI to SDI 6G / Teranex Mini
- Functional analog to the Mini SKU — same form factor target, same "one job, do it well" philosophy.
- Closed source, but spec sheets reveal the I/O topology and supported format matrix.

### 3.5 Snell Kahuna / Imagine Communications Selenio
- Reference points for **frame rate conversion (Phase D)** at the high end.
- Motion-compensated FRC is the SOTA there. **Schindler is not chasing that** — banked-rate cadence conversion (3:2, 5:2, etc.) without motion comp is the V1 target — but Snell/Imagine white papers explain why the simple cadences are hard enough on their own.

---

## 4. What NOT to emulate

- **Faroudja / Genesis FLI-series motion-adaptive deinterlace** — IP-encumbered, and the open community has nothing comparable. Avoid as a reference target.
- **Pixelworks ImageProcessor / Sigma Designs scalers** — closed silicon, opaque architecture. Not a useful reference.
- **Teranex (full Teranex, not Teranex Mini)** — uses motion-compensated FRC on a custom VLIW DSP. Wrong scale of project to model.

---

## 5. Recommendation by phase

### Phase A — HDMI passthrough
**Seed:** Digilent Zybo Z7-20 HDMI demo (already planned).

### Phase B — VDMA frame buffer
**Seed:** Xilinx TRD (XAPP1167) VDMA topology + PG044 (AXI VDMA datasheet).
**Alt reference:** HDMI2USB framebuffer organization.

### Phase C — Polyphase scaler
**Primary:** Xilinx Video Scaler IP as golden reference. Build the custom 8H/4V HDL alongside; A/B against the IP on zone plate / multiburst / sweep test patterns.
**Secondary reference:** MiSTer scaler — read for plain-Verilog polyphase coefficient handling.
**Architectural literature:** Calibre UK app notes.

### Phase D — Frame rate conversion
**Primary architectural model:** AJA FS1 block diagram (input → framestore → scaler → FRC → output).
**Secondary reference:** OSSC + MiSTer for CRT-side cadence and sync nuances.
**Explicitly out of scope:** motion-compensated FRC (Snell/Imagine territory). V1 stays banked-cadence (3:2, 5:2, 6:5, 4:5, 2:1, 1:2, slip) per `dev-roadmap.md` § 1 Phase D.

### Phase E — Color pipeline
Port from Screenie per the existing roadmap. No external reference needed.

### Phase F — Geometry warp
Xilinx Warp Initialization IP / Remap IP can serve as a starting point if a from-scratch implementation stalls.

### Phase G — Terminal encoder re-attach
Phase 2 HDL (`vid_timing.v` / `vbi_gen.v` / `chroma_gen.v` / `sample_gen.v`) plugs back in as planned. No external reference needed for the encoder itself.

For the **HD-to-SD downconvert** that lives inside the composite/component terminals: the Decimator MD-HX block diagram is the cleanest commercial reference for "how small can this stage be." Functionally it's `scaler (HD→SD resolution) + cadence-convert (HD rate→SD rate) + encode` — which is exactly the chain Phase C + Phase D + Phase G compose.

---

## 6. Cross-references

- Active dev plan: [`dev-roadmap.md`](dev-roadmap.md)
- Pipeline architecture: [`01-spec.md`](01-spec.md) § 4 (HD signal bus, terminal encoders)
- Signal flow diagrams: [`signal-flow.md`](signal-flow.md)
- MVPHD-24 gap analysis (for context on what the original device did vs. Schindler 2.0): [`mvphd-comparison.md`](mvphd-comparison.md)
