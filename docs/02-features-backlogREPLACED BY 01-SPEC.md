# Schindler 2.0 — Features Backlog

**Status:** Draft 2026-05-10
**Sources:** `README.md`, `docs/schindler-playbook.md`, feature scoping session 2026-05-10
**Working principle:** Stay Schindler-shaped. Width dilutes the product.

---

## V1 — Already in scope (per README + playbook - NOT FINAL)

### Inputs
- HDMI in (TI TMDS141 retimer → FPGA AXI VDMA)
- DisplayPort in

### Outputs
- Composite out (NTSC, NTSC-J, PAL, PAL-M)
- Component out (YPbPr)

### Frame rates
- 23.976, 24.000, 25.000, 29.97, 30.000

### Genlock / reference
- LTC in (BNC + op-amp + comparator + RP2040 decode)
- Tri-level sync in
- Black burst in
- RP2040 + Si5351 PLL drives FPGA pixel clock

### Color pipeline (port from Screenie)
- 1D LUT per channel (gamma, 1024 × 12-bit)
- 3×3 color matrix (color space + white point)
- Per-channel gain/offset (fine trim)
- RGB white/black point controls
- Color temperature presets (3200K, 4800K, 5600K) + custom
- Saturation, hue, black level

### Geometry
- Anamorphic, letterbox, center cut, custom scaling
- Pincushion, keystone
- 4-corner warp
- Polyphase scaler (8-tap H, 4-tap V)

### Per-CRT calibration
- JSON profiles (NovaTool tile-profile pattern)
- Import / export, recall by name

### Control
- Pi CM4 web UI
- 2.4" OLED + Bourns rotary encoder + 4 soft buttons
- Front-panel preset recall

---

## V1 — Added in 2026-05-10 scoping

### Sync / timing additions

#### 60Hz → 25fps PAL cadence conversion — V1
- **Why:** US 60Hz-family sources (1080p59.94, 1080p60) on European-region CRTs without requiring offline pre-conversion.
- **Approach:** Crossfade at field boundaries, 6:5 ratio. Reuses the same cadence framework as 60→24 (5:2).
- **Dev phase:** Until cadence converter is built, dev runs with matched-rate-only fallback — PAL output works only when source is 25/50 fps. Cadence work is non-blocking and integrates after the rest of the pipeline is functional.

#### SDI reference input — V1
- **Why:** Camera teams not always savvy to LTC/tri-level/BB. SDI tap off the camera is a single-cable reference + timecode source.
- **Hardware:** Semtech GS2971-class receiver (~$20) + cable EQ + FPGA logic.
- **Implementation:** Lock PLL to recovered SDI clock; extract VITC for timecode; format auto-detect drives frame-rate selection.
- **Side benefit:** Same chip enables SDI video input as V2 paid tier (firmware-gated).

### Analog video inputs

#### Composite + Component input — V1
- **Why:** On-mission for vintage source → vintage CRT through Schindler color pipeline (VHS, laserdisc, retro consoles, broadcast decks). Strongest market-fit input addition.
- **Hardware:** ADV7280-class multi-format video decoder (~$5-10 chip, ~$15 with passives) + 4 BNC connectors (1 composite, 3 component) + AC coupling + clamp + anti-alias filter.
- **Output to FPGA:** ITU-R BT.656 8-bit YCbCr 4:2:2 over parallel bus, ingested via existing VDMA path.
- **Effort:** ~2 days carrier PCB + ~2 days FPGA bring-up + Pi-side input source selector.
- **Panel impact:** 4 additional BNC on rear panel. Triggers panel layout review during Rev A (total port count now 18+).

### CRT-specific signal controls
- **Sync structure parameters** — front porch, back porch, equalizing pulse count, serration pulse width. Per-profile.
- **Alternating 90° colorburst phase offset** between fields. Toggle. (Playbook Ch. 5)
- **Subcarrier coherent vs non-coherent** toggle. (Playbook Ch. 4)
- **Sync tip voltage trim** — saves service calls on oddball AGCs. (Playbook Ch. 3 — the Zenith)
- **Setup pedestal:** 7.5 IRE (NTSC-M) vs 0 IRE (NTSC-J).
- **Output mode select:** NTSC / NTSC-J / PAL / PAL-M (drops out of frame rate).
- **Field cadence / pulldown options** for non-matching rates. Off / hard switch / crossfade.
- **VITC insertion** in output (separate from incoming LTC reference).

### Behavior controls
- **Signal loss behavior:** black / freeze / last-good-frame-for-N-seconds.
- **Burn-in protection:** auto-darken or pixel-shift after N minutes static.
- **Burn-in recovery / repair mode:** standalone scrolling white/black/gray patterns at user-set rate. Runs from front panel with no input. Known CRT repair technique.
- **Degauss trigger output:** relay/GPIO for pro CRTs that accept remote degauss.

### EDID — Day 1 critical
- **Editable / emulatable EDID** on HDMI and DP inputs.
- Force-mode presets: 1080p24, 1080p23.98, 1080p25, 720p, custom.
- Without this, playback laptops negotiate to whatever they feel like and burn shoot time on format debugging.

### Geometry additions
- **Active window position trim** (X/Y pixel offset). Must be a UI control — playbook calls this the early bug.
- **Overscan compensation modes:** safe-area-only vs fill-with-overscan.

### Test pattern generator (ship complete set)
- SMPTE color bars (75% / 100% / SMPTE)
- PLUGE
- Color reference fields
- Geometry grid (100% / 95% / 90% safe area)
- Convergence pattern (operator CRT alignment, separate from content warp)
- Purity (full-field R/G/B)
- Focus / zone plate (center + corners)
- Burn-in repair scroll patterns

### Front-panel / status
- **Lock-state tally:** red → yellow → green for genlock + video presence + output valid. (Playbook Ch. 11)
- **Built-in waveform/vectorscope** readout in web UI.

---

## V2 / Paid tier

- **SDI video input** — activates the receiver already on the V1 board via firmware key. License-gated upsell.
- **Multiple HDMI inputs with switching** — only if customers ask. External switcher solves for ~$200.
- **Pre-distortion warp for CRT geometry** — different problem from content warp. Requires per-CRT measurement workflow (camera + grid + solver).

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

---

## Open questions / parked decisions

- **Production DAC choice:** ADV7393 / AD9709 / similar 10-12 bit. R-2R perfboard is first-light only; do not let it creep into Rev A carrier.
- **V2 SDI license enforcement:** firmware keygen vs hardware dongle vs subscription. Defer until business model is concrete.
- **Rear-panel layout on 1RU:** with V1 additions (SDI ref, composite in, component in), total port count is 18+. Requires panel sketch / mock before Rev A carrier layout.

---

## Revision history

- 2026-05-10 — Initial draft from feature scoping session. V1 confirmed for SDI ref input, composite + component input, all CRT-specific controls, EDID, test pattern set, behavior controls including burn-in repair mode. 60→50 PAL cadence confirmed V1 via crossfade; dev phase uses matched-rate-only fallback until built.