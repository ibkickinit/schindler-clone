# Schindler 2.0 vs MVPHD-24 — Feature Comparison & Gap Analysis

**Status:** Draft 2026-05-11
**Source documents:** `MVPHD-24-OM-v0-9-0.pdf` (Cal Media / Schindler Imaging operator manual, Oct 2020, firmware v0.9.0), `MVPHD-24-flyer-v2.pdf`, and Schindler 2.0's own `01-spec.md` + `ui-menu.md` + `panel-layout.md` + `bom-v1.md`.
**Purpose:** Side-by-side feature catalog, gap analysis, and priority-ranked recommendations for what to add to V1. Flagged for review — no spec changes made yet.

The MVPHD-24 is the reference target. It's the device Schindler 2.0 is being built to spiritually succeed. Anywhere we're materially worse on a feature that affects working DPs / rental houses / 24p-playback specialists, we should look hard at the gap.

---

## 1. Inputs

| Feature | MVPHD-24 | Schindler 2.0 V1 | Status |
|---|---|---|---|
| Composite IN | 1 BNC | 1 BNC | ✓ Match |
| Y/C (S-Video) IN | 2 BNCs (multi-format) | Silicon-capable (ADV7280) but no V1 connector | ⚠ Connector dropped |
| Component YPbPr IN | 3 BNCs | 3 BNCs | ✓ Match |
| Component RGB IN (sync-on-green) | 3 BNCs (multi-format) | Not in spec | ✗ Missing |
| VGA IN (HD-15) | 1 HD-15, up to 1080p | Dropped from V1 | ✗ Killed by design |
| HDMI IN | HDMI 1.4 Type A, up to 1080p | HDMI 1.4 via Lontium LT8619C | ✓ Match |
| DisplayPort IN | Not in MVPHD | Dropped from V1 | — |
| SDI IN | SD / HD / 3G, up to 1080p60 | 3G-SDI via Semtech GS3470 (broadcast tier only) | ✓ Match (gated by SKU) |
| SDI Loop Out (re-clocked) | 1 BNC, active re-clocked | Not present (passive loop-through was dropped) | ✗ Missing |
| Still Image Buffers as input | 4 FLASH-backed buffers | Not in spec | ✗ Missing |
| Raspberry Pi as input (HDMI via USB drive) | Future, in MVPHD spec | Not applicable (no Pi in V1) | — |

---

## 2. Outputs

| Feature | MVPHD-24 | Schindler 2.0 V1 | Status |
|---|---|---|---|
| Composite OUT | 1 BNC | 1 BNC | ✓ Match |
| Y/C OUT | Multi-format BNCs | Silicon-capable, no V1 connector | ⚠ Connector dropped |
| Component YPbPr OUT | 3 BNCs | 3 BNCs | ✓ Match |
| Component RGB OUT | 3 BNCs | Not in spec | ✗ Missing |
| VGA OUT | 2× HD-15 | Dropped | ✗ Killed by design |
| HDMI OUT | HDMI 1.4 Type A | HDMI 1.4 direct FPGA TX | ✓ Match (broader scope — full HD passthrough vs monitoring) |
| SDI OUT | 2× BNC | 1× BNC (broadcast tier) | ⚠ Reduced count |
| Configurable sync ref OUTs | 2× BNC (CBVS/REF1 + CBVS/REF2), each independently configurable across composite video / composite sync / black burst / tri-level / TTL composite sync / TTL Vertical Drive / TTL Frame Drive | 2× BNC (SYNC OUT 1 + SYNC OUT 2), each format-selectable across black burst / tri-level / LTC; hardware-ready for DARS / Word Clock | ✓ Match in slot count; Schindler covers fewer specialized sync formats but adds LTC + DARS + WC |

**Sync format coverage gap:** MVPHD has TTL Vertical Drive, TTL Frame Drive, TTL composite sync — these are sub-line-rate sync signals used by film cameras and legacy gear. Schindler currently doesn't list them. Worth checking if any V1 customers actually need TTL Drive signals (most modern cameras lock to tri-level or LTC).

---

## 3. Frame rates / video formats

| Capability | MVPHD-24 | Schindler 2.0 V1 |
|---|---|---|
| Base frame rates | 23.976 / 24.000 / 25.000 / 29.970 / 30.000 (multiples allowed) | Same for CRT-driving outputs |
| HD throughput rates | Not explicitly stated for HDMI/SDI; 1080p60 supported | 1080p50 / 1080p59.94 / 1080p60 / 720p50/59.94/60 in addition to CRT-driving rates (HD pipeline scope, 2026-05-11) |
| Composite output formats | NTSC / NT443 / PAL-M / PAL / PAL-N / SECAM | NTSC / NTSC-J / PAL / PAL-M |
| Internal processing | 4:2:2 10-bit per channel, 54 MHz (SD), 148.5 MHz (HD) | RGB or YCbCr 4:2:2, up to 1080p60 (148.5 MHz pixel clock) |

**Slight gap:** NT443 (NTSC 4.43) and PAL-N missing from Schindler. NT443 is a transcoder mode used to display NTSC content on PAL CRTs (4.43 MHz subcarrier instead of 3.58 MHz). PAL-N is the Argentina/Paraguay/Uruguay variant. Both add minimal HDL complexity if needed.

---

## 4. Menu categories — structural comparison

| MVPHD-24 (button) | Schindler 2.0 (`ui-menu.md`) | Comment |
|---|---|---|
| INPUTS | § 1 Inputs | Schindler more granular per-input |
| VIDEO PROC | partially under § 3 Color | Schindler missing per-input proc-amp toggle (Proc Amp Enable bypass) |
| PICTURE SIZE/POS | § 4 Geometry | Match |
| COLOR CORRECT (output RGB gain/gamma/pedestal) | § 3 Color (mixed input/output) | Schindler covers gain/trim but not separate output gamma per channel |
| OUTPUTS | § 2 Outputs | Schindler more elaborated for HD pipeline + per-output independent config |
| TIMING | § 5 Genlock + § 6 Output Sync Structure | Split into input-side genlock and output-side sync |
| PRESETS | § 8 Profiles | Match (Schindler adds per-CRT semantics + JSON import/export) |
| STILLS | **MISSING** | ✗ |
| SYSTEM | § 11 System | Match (Schindler adds WiFi/BLE/OTA) |
| AUDIO (future) | not in spec | both deferred |

| MVPHD-24 active button | Schindler 2.0 | Comment |
|---|---|---|
| EFX (effects) | **MISSING** | ✗ Freeze, noise, blocks, fade-to-black |
| TSG (test signals) | § 7 Test Patterns | Schindler has standard set; **missing F1-BLU/F2-YEL shutter-phasing pattern**; **missing custom user-loaded test signals** |
| COLOR TEMP (X/Y color circle) | partially in § 3 Color | Schindler has white-point preset + RGB trim, but **missing X/Y in YUV color space adjust** (MVPHD's brightness/saturation-preserving approach) |
| BLACK (Go to black, quick toggle) | partially via § 6 Output settings, no quick action | ✗ No quick "go to black" hardware button mapping |
| MONO (monochrome) | **MISSING** | ✗ No quick monochrome toggle |
| FAN (chassis fan enable + speed) | § 11 System has fan brightness, but no quick toggle | ⚠ Reduced |

---

## 5. Features MVPHD-24 has that Schindler 2.0 doesn't (gap list)

Ranked by my read of how much they matter to working operators. Open for Justin's adjustment.

### High priority — most likely worth adding

1. **Still image buffers** — 4 FLASH-backed buffers selectable as input source; load/save via SD card or web upload. Workflow: power-on splash, idle-state reference frame, quick "go-to-known-image" for QC, custom-uploaded brand idents. The MVPHD spec is explicit about this being a major feature ("Four FLASH based still image buffers available as inputs"). Without it, Schindler can't blank to anything other than black or test patterns.
2. **EFX (effects)** — Freeze, Random Noise ("snow"), Small Blocks (MPEG block artifact look), Large Blocks, Fade to Black. Each with EFX Mixer transparency control and EFX Transition Time (0–240 frames). Used for transitions, intentional effect for filmed-CRT content, signal-loss fallback look.
3. **BLACK quick-action button** — one-press "go to black" on the front panel. Currently we don't expose this as a quick-select default. Easy add: rebind one quick-select button to BLACK as default.
4. **MONO quick-action button** — one-press monochrome toggle. Same comment — easy add as a quick-select default. Combined with color-temp control creates the "security-cam B&W with color cast" effect per MVPHD Chapter 5.
5. **F1-BLU / F2-YEL camera shutter phasing test pattern** — specific field-alternating pattern (blue field 1, yellow field 2) for visually phasing a film camera's shutter to the CRT. When properly phased, viewer sees one solid color; mis-phased shows a split. Direct workflow tool for DPs. Add to test pattern list (§ 7.1).
6. **Output Color Temperature in YUV color circle** — MVPHD-24's color temp uses X/Y on the color circle, applied in YUV space. The advantage (documented in MVPHD Chapter 5): preserves brightness and saturation when shifting color temp, vs the standard RGB-based approach which desaturates and darkens. Schindler currently uses RGB trim. Worth offering as an alternate adjustment mode under § 3.3 White point.
7. **3:2 cadence auto-detect** — MVPHD detects 3:2 cadence in 30/60fps source and extracts the original 24fps sequence without using motion filtering. Schindler's cadence convert has "5:2 pulldown" but no auto-detect mode. The auto-detect produces a cleaner 24p extraction than blind motion filtering. Add as a sub-option to § 2.2.4 Cadence convert.
8. **Proc Amp Enable single-toggle bypass** — one toggle that disables ALL input proc-amp controls (level/setup/chroma/hue/Y-C delay) returning to unity gain. Lets operator quickly compare "raw vs adjusted" without resetting individual values. Add to § 1 Inputs.
9. **Y/C Delay input control** — adjusts the horizontal alignment of color vs luma on input. Fixes color-smear artifacts from VTRs and tape sources. Add to the Composite input submenu (§ 1.5).
10. **Custom user-loaded test signals** — 8 slots for user-uploaded test patterns (TIFF/PNG, full-frame). MVPHD has SD-card load mechanism; Schindler's natural fit is web-UI upload to one of N user slots. Useful for productions with specific reference patterns (focus charts, custom alignment grids, brand idents).
11. **Aspect Ratio Conversion explicit modes** — MVPHD has named ARC modes: `Anamorphic` / `Letter Box` / `Pillar Box` / `14:9 Letter` / `14:9 Pillar` / `Cut/Crop`. Schindler § 4.2 lists "Anamorphic / Letterbox / Center cut / Custom" but is less explicit about 16:9↔4:3 direction. Worth restructuring § 4.2 to mirror MVPHD's clarity since this is a common operator-facing decision.

### Medium priority — useful additions

12. **Motion Filter selection (Quadratic / Linear / Off)** — MVPHD exposes the frame-rate-conversion motion filter. Schindler hides this. Add to § 2.x output cadence sub-menu since the user may want to choose between quality-vs-judder trade-offs for specific content.
13. **CBVS Vertical Filter** — interlace flicker reducer for composite output when source is progressive (VGA-class or HD-class downscaled). Single toggle in MVPHD. Add to § 2.2 Composite OUT.
14. **GPIO DB-15** — MVPHD has DB-15 with 8 GPIO + 5V/500 mA aux power, contact-closure activation. Used for tally lights, remote button bindings, output triggers, fault relay. Schindler doesn't have GPIO. Adds ~$2 BOM + DB-15 connector + ESD protection per GPIO. Worth considering for rental-house workflows.
15. **Dashboard (Ross openGear) compatibility** — MVPHD speaks Ross openGear protocol so it's controllable from existing broadcast facility consoles. Schindler has its own web UI. Adding openGear support is a software-only addition on the Zynq PS side (~few weeks dev). Worth it if a meaningful fraction of customers are in Ross-equipped facilities.
16. **Active SDI Loop Out** — MVPHD has a re-clocked active loop output (separate from the processed SDI OUT). Schindler dropped passive loop in the 2026-05-11 connector simplification but could add re-clocked active via the GS3470's 2×2 mux (which we noted as unused). 1 BNC + minor HDL work.
17. **Free Run Frequency Adjustment (ppm-level)** — MVPHD allows ±8 ppm trim of the master clock when free-running. Useful for matching a slowly-drifting external source without genlock. Schindler has "free-run rate" in fps but no ppm-level trim. Add under § 5.4.
18. **Universal Lock (lock to non-standard input)** — MVPHD has a future feature for locking to non-standard VGA-class signals by sync-pattern analysis. Schindler genlock is autosense for standard formats only. Lower priority unless customers ask.
19. **Front-panel SD card slot** — MVPHD has SD/MMC for firmware updates + still image storage. Schindler has rear USB-C for service. Adding front SD is a convenience (no rear access needed). Noted as open question in `panel-layout.md`.
20. **Hours-of-operation counter** — MVPHD's status menu shows total powered-on hours. Useful for warranty tracking + maintenance scheduling. Trivial to add (Zynq PS persistent counter, displayed in System Info).

### Low priority — only if scope demands

21. **Y/C (S-Video) input connector** — silicon already supports it; would only need a mini-DIN. Reach into consumer retro source market (VHS, S-VHS, Hi8). Probably skip unless Justin wants to pursue that customer segment.
22. **RGB component (sync-on-green) IN/OUT** — used by some legacy projection / production gear. Most modern workflows are YPbPr. Skip unless customer-asked.
23. **NT443 (NTSC 4.43) composite mode** — niche format for displaying NTSC content on PAL CRTs. Could be a firmware addition later if needed.
24. **PAL-N composite mode** — Argentina/Uruguay/Paraguay variant. Same niche.
25. **VGA in/out** — explicitly killed by design.

---

## 6. Features Schindler 2.0 has that MVPHD-24 doesn't

Things we'd be selling against the MVPHD as upgrades.

- **Modern connectivity:** WiFi (AP + STA, dual-band), BLE pairing for companion app, mDNS discovery. MVPHD is Ethernet-only.
- **Modern web UI** (Node.js on Zynq PS). MVPHD uses Ross Dashboard exclusively for remote control.
- **Rear-panel status LCD** — read-only at-rack patching display. MVPHD has no rear display.
- **Per-connector status LEDs** at every rear connector (R/A/G with PWM dimming). MVPHD has only a front-panel `GEN LOCK` indicator.
- **Full HD HDMI passthrough at native source rate** — 1080p60 IN can go to 1080p60 OUT on HDMI without conversion. MVPHD docs imply HDMI OUT is generally same as analog (constrained to chosen output frame rate).
- **Per-output independent rate and format** running concurrently. MVPHD has a single "Primary Output Mode" that one output gets optimally; others may be degraded.
- **HDCP override consent flow** for HDMI passthrough of HDCP-protected content (attorney-advised, attestation-gated). MVPHD predates HDCP-protected-source workflows entirely.
- **Per-CRT JSON profile system** with named profiles + import/export (NovaTool pattern). MVPHD has Preset #1–4 with 8-char names; less rich.
- **Burn-in protection** (auto-darken + pixel-shift after N minutes of static). Not in MVPHD.
- **Burn-in repair scrolling patterns** (standalone mode, no input required). Not in MVPHD.
- **Persistent status bar** across all menu surfaces. MVPHD's OLED top-line is similar in spirit but Schindler's bar is richer (input + sync + lock + profile + IP).
- **Lock quality metric** (phase-error magnitude + 1 s stddev, live). MVPHD has `LOCKED` / `UNLOCKED` / `Free Run` state but no continuous quality readout.
- **Configurable loop bandwidth** (Tight / Default / Wide). MVPHD doesn't expose this.
- **Wide back-porch default for 24p camera shoots** (industry wisdom banked 2026-05-11). Tunable per-profile.
- **INA226 power telemetry** — rail voltage + current draw reported in System Info and rear LCD. MVPHD has hours-of-operation counter but no power telemetry.
- **Internal modern PSU** (LRS-50-12 + carrier protection chain). MVPHD has medical-grade PSU; both are pre-cert modules but Schindler's is more deeply specified.
- **OTA firmware updates** via web UI / WiFi. MVPHD requires SD card.
- **Single Linux to maintain** (Zynq PS only). MVPHD has separate Raspberry Pi for control + main processor — two domains, two firmwares.
- **Modern HDCP path** (Lontium LT8619C with embedded keys) — no DCP Adopter Agreement required at this scale.

---

## 7. Things to deliberately NOT bring forward from MVPHD-24

Items in MVPHD that we should leave behind on purpose:

- **VGA in/out (HD-15)** — already killed. VGA cards lack a standard and the Auto-positioning / sample-phase machinery to make VGA reliable is significant HDL complexity for a dying connector.
- **Multi-format BNC sharing** (where the same 3 BNCs serve composite + Y/C + YPbPr + RGB depending on Input Source menu) — operationally confusing on a multi-customer rental unit. Schindler's separate connectors per format are clearer.
- **"Primary Output Mode" trade-off** — MVPHD admits "not capable of producing perfect images on all outputs simultaneously" and forces operator to pick which output gets the good signal. Schindler's per-output independent terminal-encoder model fixes this — all outputs are first-class.
- **Raspberry Pi as separate processor domain** — adds maintenance + supply-chain complexity. Schindler folds the entire control plane onto the Zynq PS.
- **DashBoard-only remote control** — vendor lock-in to Ross's ecosystem. Schindler has its own web UI + REST API, optionally adds Dashboard compatibility later.
- **Ground-closure GPIO via DB-15 only** — modern broadcast control increasingly uses network protocols (NMOS IS-04/IS-05, Ember+, etc). DB-15 GPIO is useful for legacy tally but Schindler should not consider it the primary remote-control surface. Add as a v1.x option if customers ask.

---

## 8. Recommendation summary

If we add the **high-priority** items in § 5 (#1–#11), Schindler 2.0 V1 feature-matches or exceeds the MVPHD-24 in operator-facing capability, with substantial upgrades in connectivity, UI, and per-output flexibility.

The high-priority adds break down into:

- **Mostly UI/firmware work** (no carrier change): #2–4, #6–11 — EFX effects, BLACK / MONO quick actions, F1-BLU/F2-YEL test pattern, YUV color temp adjust, 3:2 cadence auto-detect, Proc Amp Enable bypass, Y/C Delay, custom test signal upload, ARC modes
- **HDL + storage work**: #1 Still image buffers — needs FLASH allocation on TE0720 eMMC + image format spec
- **HDL work**: #5 F1-BLU/F2-YEL pattern (extend `sample_gen.v`)

Medium-priority items #12–#20 are a mix of firmware (motion filter, free-run trim, hours counter), software (Dashboard compat, Universal Lock), and minor hardware (GPIO DB-15, front SD slot, active SDI loop).

None of the gaps require a carrier respin if caught now — most are firmware additions to the existing block-level architecture.

**Suggested next step:** Justin reviews the high-priority list (#1–#11), picks which to commit to V1 vs defer, and we update `01-spec.md` + `ui-menu.md` accordingly.

---

## Cross-references

- MVPHD-24 source docs: `MVPHD-24-flyer-v2.pdf`, `MVPHD-24-OM-v0-9-0.pdf` in project root
- Current spec + feature set: [`01-spec.md`](01-spec.md), [`01-spec-changelog.md`](01-spec-changelog.md)
- Current UI menu: [`ui-menu.md`](ui-menu.md)
- Current panel layout: [`panel-layout.md`](panel-layout.md)
- BOM mapping: [`bom-v1.md`](bom-v1.md)
