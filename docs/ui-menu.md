# Schindler 2.0 — UI Menu Structure

**Status:** Draft 2026-05-11 (rev 3)
**Scope:** complete hierarchical menu structure covering all V1 settings, surfaced on the front-panel TFT + web UI. Rear-panel LCD is read-only and shows the status grid only (no navigation).
**Sources:** `01-spec.md` (feature set), `panel-layout.md` (physical controls), `signal-flow.md` (architecture for which settings apply where).

This doc is the structural intent. Wireframes, exact widget choices, and field validation rules belong in a later UX-design pass.

---

## Conventions

**Surfaces:**
- **front+web** — appears on both front-panel TFT and web UI
- **front only** — front-panel TFT only
- **web only** — web UI only (typically file uploads, fine-grained drag-handle controls, or admin/audit features)

**Setting types:**
- `toggle` — boolean on/off
- `enum` — pick one from a list (options enumerated below the setting)
- `num` — numeric value with unit + range
- `text` — free text (hostname, profile name)
- `action` — invokes an operation
- `ro` — read-only display

**Auto-type settings — UI affordance:** when an `enum` setting has an `Auto` option, the displayed value shows the resolved detected value in parentheses. E.g. `Auto (NTSC)`, `Auto (1080p59.94)`. Operator sees both the choice and the result without having to dig into Signal Info.

**Surface owners:**

| Surface | Owner | Role |
|---|---|---|
| Front-panel TFT (~2.8–3.5" color, LTDC parallel) | UI MCU (STM32H735) | Operator navigates via 2 rotary encoders + 4 fixed buttons + 2–3 quick-select buttons |
| Web UI (Node.js on Zynq PS) | Zynq PS | Same hierarchy, richer widgets. Accessible at `http://schindler-<serial>.local` |
| Rear-panel status LCD (2.4" 16:9 SPI) | Zynq PS | Read-only status grid; no navigation |
| Front-panel status LED column | UI MCU | Mirrors rear per-connector LEDs |

### Persistent status bar

A single-line status bar is **always visible** at the top of every front-panel menu screen AND every web UI page (except modal dialogs). Even when deep in nested menus, the operator never loses sight of:

- **Left:** Current input source + resolution + rate (e.g. `HDMI · 1080p59.94`)
- **Center:** Sync reference source + rate + lock state (e.g. `LTC 29.97 ● Locked`, with the dot color matching the genlock LED — green/amber/red)
- **Right:** Active profile name + IP address (e.g. `BVM-D24 · 10.0.1.42`)

On the rear LCD this same bar shows as the header above the status grid (already specified in `01-spec.md` Rear panel section).

The bar refreshes ~1 s. On the front panel it persists across menu navigation; on web UI it sits at the top of every page in the rail.

---

## 0. Home

The default screen on boot. Summary view of current operating state.

**0.1 Current source** — `ro`, front+web
- HDMI / SDI / Composite / Component / TPG / "no signal"

**0.2 Source resolution + rate** — `ro`, front+web
- Detected from incoming signal (e.g. `1080p · 59.94`)

**0.3 Master clock state** — `ro`, front+web
- Lock state + quality metric + selected reference source

**0.4 Per-output state** — `ro`, front+web
- Compact list: each output showing resolution + rate + lock state

**0.5 Active profile** — `ro`, front+web
- Per-CRT profile name (if loaded)

**0.6 Alarms / faults** — `ro`, front+web
- Any active red-LED conditions

**0.7 Enter main menu** — `action`, front only
- Encoder press or Menu button enters the main menu

**0.8 I/O Status Page** — `action`, front+web
- Opens a full-screen view matching the rear LCD content: one row per I/O connector with name | status icon | resolution + rate + format + lock state. Same data the rear LCD displays continuously — front panel and web get an on-demand version.

---

## 1. Inputs

### 1.1 Source select — `enum`, front+web

Default: `Auto`

- `Auto` — picks the first valid signal seen (Auto-affordance: displays detected source, e.g. `Auto (HDMI)`)
- `HDMI`
- `SDI` (broadcast tier only)
- `Composite`
- `Component`
- `TPG` — internal test pattern generator
- `Buffer 1` / `Buffer 2` / `Buffer 3` / `Buffer 4` — internal still image buffers (see § 1.7)

### 1.7 Still image buffers

Four FLASH-backed image buffers on the TE0720 eMMC, selectable as input source via § 1.1. Image content persists across power cycles. Used for: power-on splash, idle-state reference frame, custom brand ident, quick-recall reference for QC.

**1.7.1 Buffer slot status** — `ro`, front+web
- Per slot: `Empty` / `Loaded: <name>` / resolution + rate of stored image

**1.7.2 Capture output to buffer** — `action`, front+web
- Captures current pipeline output to selected buffer (1–4). Operator-edited name (8-char default).

**1.7.3 Load image into buffer** — `action`, web only
- Upload PNG / TIFF (or similar) into selected buffer. Web only — file upload not practical on front panel.

**1.7.4 Save buffer image to file** — `action`, web only
- Download the stored image as a file for archival or transfer to another Schindler.

**1.7.5 Clear buffer** — `action`, front+web
- Erase buffer contents (replaces with `<blank>` placeholder).

**1.7.6 Auto-load on boot** — `enum`, front+web
- `Off` (default) — boot to last-active source
- `Buffer 1` / `2` / `3` / `4` — boot directly to a chosen buffer (splash-screen behavior)

### 1.8 Proc Amp bypass — `toggle`, front+web — default `off` (= bypass off, proc-amp active)

Single toggle to bypass ALL input proc-amp adjustments (color, contrast, brightness, Y/C delay) on the currently-selected source. Returns processing to unity gain. Used for quick "raw vs adjusted" comparison without resetting individual values. Bindable to a front-panel quick-select button.

### 1.2 EDID

EDID controls what resolutions and rates Schindler advertises to upstream HDMI/DP sources. Splitting resolution and rate lets the operator constrain each independently.

**1.2.1 EDID resolution** — `enum`, front+web
- `Allow all` — advertise full range (default)
- `1080p`
- `1080i`
- `720p`
- `480p`
- `576p`
- `Custom`

**1.2.2 EDID rate** — `enum`, front+web
- `Allow all` — advertise full range (default)
- `60.000`
- `59.94`
- `50.000`
- `30.000`
- `29.97`
- `25.000`
- `24.000`
- `23.98`

**1.2.3 EDID preset** — `enum`, front+web
- `Default` (allow all)
- `1080p24` (force 1080p / 24)
- `1080p23.98` (force 1080p / 23.98)
- `1080p25`
- `720p59.94`
- `Custom` (uses uploaded EDID — see 1.2.4)

Picking a preset auto-sets the resolution + rate above.

**1.2.4 EDID custom upload** — `action`, web only
- Upload a `.bin` EDID file. Web UI only because file upload isn't practical on the front panel.

### 1.3 HDMI input

**1.3.1 Signal info** — `ro`, front+web
- Resolution (e.g. `1920×1080p`)
- Rate (e.g. `59.94 fps`)
- Color space (RGB / YCbCr 4:2:2 / YCbCr 4:4:4)
- HDCP authentication state (None / Authenticated 1.4 / Authenticated 2.x / Failed)
- Source name (from InfoFrame, if present)

**1.3.2 5V cable-power** — `toggle`, front+web — default `on`
- Controls the TPD12S016 5V switch on HDMI input

**1.3.3 Hotplug behavior** — `enum`, front+web
- `Always assert HPD`
- `Toggle on source change`
- `Off`

**1.3.4 HDCP status** — `ro`, front+web
- Current HDCP authentication state on the HDMI input — live display
- Values: `None (clear)`, `Authenticated HDCP 1.4`, `Authenticated HDCP 2.x`, `Authentication failed`, `Source disabled HDCP`

**1.3.5 HDCP override** — `toggle` with consent flow, front+web — default `off`
- Required to pass HDCP-protected source content through HDMI OUT (and other digital outputs as applicable). See **§ 13** for the attestation dialog.
- Persistence and audit log live in **§ 13** Compliance.

### 1.4 SDI input *(broadcast tier)*

**1.4.1 Signal info** — `ro`, front+web
- Resolution (e.g. `1920×1080p`)
- Rate (e.g. `59.94 fps`)
- Payload ID (SMPTE 352 — link type, structure, color space)
- VITC (if present)
- Embedded audio channel count + sample rate

**1.4.2 Use as genlock reference** — `toggle`, front+web — default `on`
- Enables / disables SDI as an available genlock source (§ 5)

### 1.5 Composite input

**1.5.1 Standard** — `enum`, front+web
- `Auto` — detects from sync signature (Auto-affordance: e.g. `Auto (NTSC)`)
- `NTSC`
- `NTSC-J`
- `PAL`
- `PAL-M`
- `SECAM`

**1.5.2 Termination** — `toggle`, front+web — default `on`
- 75 Ω termination on/off

**1.5.3 Signal info** — `ro`, front+web
- Detected standard, sync presence, level, detected resolution

### 1.6 Component input

**1.6.1 Standard** — `enum`, front+web
- `Auto` (Auto-affordance shows detected, e.g. `Auto (1080i59.94)`)
- `480i` / `480p` / `576i` / `576p` / `720p` / `1080i` / `1080p`

**1.6.2 Termination** — `toggle`, front+web — default `on`

**1.6.3 Signal info** — `ro`, front+web
- Detected standard, sync presence, levels, resolution + rate

---

## 2. Outputs

Each output has its own submenu. All outputs are **independent and concurrent**. Resolution and rate are selected independently per output.

### 2.1 HDMI OUT

**2.1.1 Enable** — `toggle`, front+web — default `on`

**2.1.2 Resolution** — `enum`, front+web
- `Match source` (default)
- `1080p`
- `1080i`
- `720p`
- `576p`
- `480p`

**2.1.3 Rate** — `enum`, front+web
- `Match source` (default)
- `60.000`
- `59.94`
- `50.000`
- `30.000`
- `29.97`
- `25.000`
- `24.000`
- `23.98`

**2.1.4 Color space** — `enum`, front+web
- `Auto`
- `RGB`
- `YCbCr 4:2:2`
- `YCbCr 4:4:4`

**2.1.5 InfoFrame source name** — `text`, web only
- Source-name string passed to downstream gear via HDMI InfoFrame

(HDCP override for the HDMI OUT path is configured under **§ 1.3.5** and **§ 13** Compliance — moved out of this section.)

### 2.2 Composite OUT

**2.2.1 Enable** — `toggle`, front+web — default `on`

**2.2.2 Standard** — `enum`, front+web
- `NTSC` (525-line, 59.94 Hz field)
- `NTSC-J` (NTSC without 7.5 IRE pedestal)
- `PAL` (625-line, 50 Hz field)
- `PAL-M` (525-line, 60 Hz field)

**2.2.3 Rate** — `enum`, front+web
- `23.976 fps`
- `24.000 fps`
- `25.000 fps`
- `29.97 fps`
- `30.000 fps`

**2.2.4 Cadence convert** — `enum`, front+web — default `Auto`
- `Auto` — system picks the appropriate cadence based on source rate vs output rate
- `3:2 auto-detect` — when source is 30 / 60 fps with 3:2 cadence in the data (telecined 24p material), detect the cadence pattern and extract the original 24p sequence without motion filtering. Produces a cleaner 24p output than blind frame-rate conversion. Auto-falls-back to motion filtering if 3:2 cadence isn't detected.
- `Off` — matched-rate only; rejects mismatched-rate sources
- `5:2 pulldown` — 60 → 24 (classic 3:2 pulldown)
- `6:5` — 60 → 50 / 25
- `4:5 pulldown` — 24 → 30
- `2:1` — drop every other frame (60 → 30, 50 → 25)
- `1:2` — duplicate every frame (24 → 48, 30 → 60)
- `Slip 23.98 → 24` — drift compensation, no cadence

**2.2.5 Motion filter** — `enum`, front+web — default `Quadratic`
- `Quadratic` — 3-frame motion filtering, highest quality, used for non-cadence frame-rate conversion
- `Linear` — 2-frame motion filtering, lighter cost
- `Off` — drop or repeat frames as needed (produces judder)

**2.2.5 Sync structure tweaks** — link, front+web
- Deep sync parameters (front porch, back porch, eq pulses, etc.) live in **§ 6.1 Composite OUT sync structure** so all output-sync controls are in one place.

**2.2.6 Setup pedestal** — `enum`, front+web
- `7.5 IRE` (NTSC-M)
- `0 IRE` (NTSC-J)

**2.2.7 Subcarrier mode** — `enum`, front+web
- `Coherent` — clean phase to line rate (playbook Ch. 4)
- `Non-coherent` — 3.579545 MHz absolute, NTSC-decoder compatible

**2.2.8 Burst phase alternation** — `toggle`, front+web — default `on`
- 90° phase alternation between fields (playbook Ch. 5 — improves CRT stability)

**2.2.9 VITC insertion** — submenu, front+web
- Enable: `toggle`
- Source: `enum` — `Genlock` / `Free-run` / `Manual offset`

### 2.3 Component OUT

**2.3.1 Enable** — `toggle`, front+web — default `on`

**2.3.2 Format** — `enum`, front+web
- `YPbPr`
- `RGB`

**2.3.3 Resolution** — `enum`, front+web
- `Match source` (default)
- `1080p`
- `1080i`
- `720p`
- `576p`
- `576i`
- `480p`
- `480i`

**2.3.4 Rate** — `enum`, front+web
- `Match source` (default)
- Same rate list as HDMI OUT (2.1.3)

**2.3.5 Levels** — `enum`, front+web
- `SMPTE`
- `Beta`
- `Wide`

**2.3.6 Mode-switch with composite** — `ro`, front+web
- Reminder: ADV7393 is I²C-switched between composite and component; selecting one disables the other on the analog BNCs.

### 2.4 SDI OUT *(broadcast tier)*

**2.4.1 Enable** — `toggle`, front+web — default `on`

**2.4.2 Resolution** — `enum`, front+web
- `Match source` (default)
- `1080p` / `1080i` / `720p`

**2.4.3 Rate** — `enum`, front+web
- `Match source` (default)
- Same rate list as HDMI OUT (2.1.3)

**2.4.4 Payload ID (SMPTE 352)** — `enum`, front+web
- `Auto`
- `Forced` (specify payload ID byte values)

**2.4.5 VITC insertion** — submenu, front+web
- Same fields as 2.2.9

**2.4.6 Embedded audio passthrough** — `toggle`, front+web
- Pass through embedded audio (if present in source)

### 2.5 SYNC OUT 1

**2.5.1 Enable** — `toggle`, front+web — default `on`

**2.5.2 Format** — `enum`, front+web
- `Black burst` (NTSC / PAL composite reference)
- `Tri-level sync` (HD video reference)
- `LTC` (timecode, audio-rate biphase mark)
- `DARS` — *coming soon* (greyed out; hardware-ready, firmware-future)
- `Word Clock` — *coming soon* (greyed out; hardware-ready, firmware-future)

**2.5.3 Resolution** — `enum`, front+web (visible when format = Black burst or Tri-level)
- `1080p` / `1080i` / `720p` / `576i` / `480i`

**2.5.4 Rate** — `enum`, front+web
- `23.976` / `24.000` / `25.000` / `29.97` / `30.000`
- `50` / `59.94` / `60` (progressive or interlaced per resolution)

**2.5.5 Output level** — `num`, front+web
- ±20 % around nominal for downstream gear quirks

**2.5.6 Phase offset** — `num`, front+web
- Sub-line phase trim relative to master clock (degrees or ns)

**2.5.7 LTC payload** — submenu, front+web (visible only when format = LTC)
- **Frame rate** — `enum`: matches output rate options
- **User bits** — `text`: 8 hex digits
- **Drop-frame mode** — `enum`: `Auto` / `Force DF` / `Force NDF`

**2.5.8 Sync structure tweaks** — link, front+web
- Deep parameters live in **§ 6.3 SYNC OUT 1 sync structure**.

### 2.6 SYNC OUT 2

Identical structure to **§ 2.5** (SYNC OUT 1). Each OUT is configured independently. Sync structure tweaks live in **§ 6.4**.

---

## 3. Color

Live preview on rear LCD + on output while adjusting. Settings are per-profile and per-input-source where it makes sense.

### 3.1 Gamma — `num` per channel, front+web

1D LUT, 1024 entries, 12-bit per channel.
- **Web UI:** drag the curve directly
- **Front panel:** ±slope adjust on master, plus per-channel offset

### 3.2 Color matrix — `num` × 9, front+web

3×3 color transformation matrix.
- **Web UI:** drag the 9 cells
- **Front panel:** select cell with encoder A → adjust with encoder B

### 3.3 White point / Color temperature

Two adjustment modes available — pick whichever fits your workflow:

**Mode A — RGB white point (standard photographic approach)**

**3.3.1 Preset** — `enum`, front+web
- `3200 K` / `4800 K` / `5600 K` / `6500 K` / `9300 K` / `Custom`

**3.3.2 Custom temp** — `num`, front+web
- 2700–10000 K

**3.3.3 Tint** — `num`, front+web
- ±20 (magenta ↔ green)

**Mode B — YUV color-circle adjust (preserves brightness + saturation)**

This mode shifts color temperature in YUV space rather than RGB. Because Y (luminance) stays untouched, the image doesn't darken when changing color temp; because chroma is added rather than RGB subtracted, saturation stays consistent. Inherited from MVPHD-24's approach (operator manual Ch. 5) — preferred by video colorists familiar with vectorscope X/Y conventions.

**3.3.4 X axis** — `num`, front+web — default `0`
- ±100 horizontal offset on the color circle. Negative = more yellow, positive = more blue.

**3.3.5 Y axis** — `num`, front+web — default `0`
- ±100 vertical offset. Negative = more cyan, positive = more red.

**3.3.6 Color circle visual** — `ro`, web only
- Vectorscope-style indicator showing where current X/Y lands on the color circle. Live preview on the rear LCD as you adjust.

**3.3.7 Save as user preset** — `action`, front+web
- Store current X/Y as user color-temp preset (4 slots: `PST1` / `PST2` / `PST3` / `PST4`, 5-char user name).

**Note:** YUV color-temp adjustment only adds color to white / lighter areas — no color is added to black. Combined with § 3.6 Monochrome (or the front-panel `MONO` quick action), this enables a "security-cam B&W with color tint" period look.

### 3.4 Black point — `num` per channel, front+web

RGB black trim.

### 3.5 White point trim — `num` per channel, front+web

RGB white trim (separate from temp preset).

### 3.6 Saturation — `num`, front+web

0–200 %.

### 3.7 Hue — `num`, front+web

±30°.

### 3.8 Black level — `num`, front+web

±5 IRE (composite output specifically).

### 3.9 LUT import — `action`, web only

Upload a `.cube` or `.csv` 1D LUT.

### 3.10 LUT export — `action`, web only

Download the current LUT.

### 3.11 Reset to defaults — `action`, front+web

---

## 4. Geometry

### 4.1 Active window position — `num` X + Y, front+web

X/Y pixel offset trim. Playbook calls this "the early bug" — must be a UI control.

### 4.2 Aspect Ratio Conversion (ARC) — `enum`, front+web

Specifies how aspect-ratio mismatches are handled in **both directions** (16:9 → 4:3 and 4:3 → 16:9). The web UI shows a small mockup of each option as you scroll through.

- `Anamorphic`
  - 16:9 → 4:3 = no processing, image squashed horizontally
  - 4:3 → 16:9 = no processing, image stretched horizontally
- `Letter / Pillar Box`
  - 16:9 → 4:3 = letterbox (black bars top + bottom, full source preserved)
  - 4:3 → 16:9 = pillarbox (black bars left + right, full source preserved)
- `14:9 Letter / Pillar Box` — compromise: small crop + small bars (broadcast convention when content has important info at very edges)
  - 16:9 → 4:3 = slight horizontal crop + slight letterbox
  - 4:3 → 16:9 = slight vertical crop + slight pillarbox
- `Cut / Crop`
  - 16:9 → 4:3 = center-cut (sides cropped, full vertical preserved)
  - 4:3 → 16:9 = vertical-crop (top + bottom cropped, full horizontal preserved)
- `Custom` — specify scale factor manually in 4.7

### 4.3 Pincushion — `num` H + V, front+web

±10 % each axis.

### 4.4 Keystone — `num` H + V, front+web

±10° each axis.

### 4.5 4-corner warp — submenu

- **Web UI:** drag-handle interface
- **Front panel:** select corner → numeric tweak

### 4.6 Overscan compensation — `enum`, front+web

- `Safe-area-only`
- `Fill-with-overscan`

### 4.7 Aspect ratio — `enum`, front+web

- `4:3`
- `16:9`
- `Custom` (specify ratio)

### 4.8 Reset to defaults — `action`, front+web

---

## 5. Genlock / Sync input

Locks the master clock to an incoming reference. For OUTGOING sync configuration, see **§ 6 Output Sync Structure**.

### 5.1 Reference source — `enum`, front+web

- `Auto` — autosense priority fallback (Auto-affordance: shows resolved source, e.g. `Auto (LTC)`)
- `LTC` — pin to LTC reference
- `Black burst` — pin to BB
- `Tri-level` — pin to tri-level
- `SDI` — pin to SDI recovered clock (broadcast tier)
- `Free-run` — no external reference, NCO runs at programmed rate
- `Hold` — freeze the current lock state, ignore further reference changes

### 5.2 Reference priority list — ordered list, web only

Drag to reorder autosense priority. Default order: LTC > tri-level > BB > SDI > free-run.

### 5.3 Loop bandwidth — `enum`, front+web

- `Tight` (~2 Hz) — fast tracking, more jitter passthrough
- `Default` (~0.5 Hz) — playbook Ch. 8 value
- `Wide` (~0.1 Hz) — slow tracking, max jitter rejection

### 5.4 Free-run rate — `num`, front+web

Used when no reference is present. Specify in fps.

### 5.5 Hold behavior — `enum`, front+web

- `Last value` — freeze the integrator
- `Average over last N s` — windowed average
- `Operator-set rate` — fall back to free-run rate (5.4)

### 5.6 Lock state — `ro`, front+web

Live display: `Acquiring` / `Locked` / `Lost`, plus current quality metric.

### 5.7 Quality metric — `ro`, front+web

Phase-error magnitude + 1 s standard deviation. Live bar graph on web UI.

### 5.8 LTC offset — `num`, front+web

±99 frames applied to LTC output relative to incoming TC.

### 5.9 Drop-frame mode — `enum`, front+web

- `Auto` — match incoming rate
- `Force DF`
- `Force NDF`

### 5.10 Genlock LED feedback — `ro`, front+web

Mirrors the per-connector and front-panel LED states for the genlock chain.

---

## 6. Output Sync Structure

Dedicated menu for adjusting outgoing sync signal structure on each video output. These are the per-CRT tweaks that DPs and rental-house engineers reach for when tuning a specific monitor or shoot. Saved per-profile.

### 6.1 Composite OUT sync structure

**6.1.1 Front porch** — `num`, front+web
- 1.0–5.0 µs around SMPTE 170M nominal

**6.1.2 Back porch** — `num`, front+web
- 3.0–12.0 µs
- **Default for 24p camera-shoot profiles: 7.0 µs** — wider than SMPTE 4.7 µs nominal to give camera shutters a larger target window and avoid the visible sync bar on filmed CRT footage (industry wisdom, 2026-05-11)

**6.1.3 Equalizing pulse count** — `num`, front+web
- Standard `6` / tweakable per CRT

**6.1.4 Serration pulse width** — `enum`, front+web
- `Standard`
- `Wide`

**6.1.5 Sync tip voltage trim** — `num`, front+web
- ±100 mV around SMPTE −286 mV (for oddball-AGC CRTs — e.g. the Zenith from playbook Ch. 3)

### 6.2 Component OUT sync structure

**6.2.1 Sync mode** — `enum`, front+web
- `Sync on Y` (most common for pro YPbPr)
- `Sync on composite` (separate sync channel emulation)

**6.2.2 Sync amplitude** — `num`, front+web
- ±20 % around nominal

**6.2.3 Trilevel vs bilevel** — `enum`, front+web
- `Bilevel` (for SD)
- `Tri-level` (for HD)
- `Auto` (Auto-affordance: shows chosen, e.g. `Auto (Tri-level)`)

### 6.3 SYNC OUT 1 sync structure

(Visible when SYNC OUT 1 format = Black burst or Tri-level — see 2.5.2)

**6.3.1 Front porch** — `num`, front+web
**6.3.2 Back porch** — `num`, front+web
**6.3.3 Equalizing pulses** — `num`, front+web
**6.3.4 Serration width** — `enum`, front+web
**6.3.5 Burst amplitude** (BB only) — `num`, front+web

### 6.4 SYNC OUT 2 sync structure

Identical to **§ 6.3**.

### 6.5 Field cadence behavior (non-matching rates)

Applies when source rate ≠ output rate AND the per-output cadence convert is set to something other than `Auto`.

**6.5.1 Mode** — `enum`, front+web
- `Off` — reject mismatched-rate sources
- `Hard switch` — clean cut at field boundary
- `Crossfade` (default for cinema-grade output) — short blend at field boundary

**6.5.2 Crossfade duration** — `num`, front+web
- Field count for crossfade (1–8)

---

## 7. Test Patterns

Replaces the input source with an internal generator. Source select (§ 1.1) becomes `TPG` when active.

### 7.1 Pattern — `enum`, front+web

- `SMPTE color bars 75 %`
- `SMPTE color bars 100 %`
- `SMPTE color bars (SMPTE-spec)`
- `PLUGE`
- `Geometry grid` (100 % / 95 % / 90 % safe area)
- `Convergence pattern`
- `Purity (full-field R / G / B)`
- `Focus / zone plate`
- `Burn-in repair scroll` (white / black / gray)
- `Shutter Phase Reference` — alternating-field two-color signal for visually phasing a film camera's shutter to the CRT. Companion to the wide-back-porch setting in § 6.1.2. Default field 1 = blue, field 2 = yellow (industry convention); operator-configurable color pair (see 7.5).
- `Custom Signal 1` … `Custom Signal 8` — operator-loaded full-frame patterns (see 7.6)

### 7.5 Shutter Phase Reference colors — `enum`, front+web — default `Blue / Yellow`

Visible only when § 7.1 = Shutter Phase Reference.

- `Blue / Yellow` — industry default (high contrast, MVPHD convention)
- `Red / Cyan`
- `Magenta / Cyan`
- `Black / White` — extreme contrast for fine phase tuning
- `Custom` — specify RGB for field 1 and field 2

### 7.6 Custom test signals — `action`, web only

Eight slots for operator-uploaded full-frame test patterns (PNG / TIFF up to 1920×1080). Use cases: focus charts specific to your production, custom alignment grids, brand idents, calibration cards.

- Upload to slot 1–8 with editable name (8-char default)
- Slots persist across power cycles (stored on TE0720 eMMC)
- Select via § 7.1 `Custom Signal N`

### 7.2 Pattern rate — `enum`, front+web

Match the selected output rate.

### 7.3 Burn-in scroll speed — `num`, front+web

1–60 s per cycle (only visible when burn-in scroll pattern selected).

### 7.4 Auto-cycle patterns — `toggle` + `num`, front+web

Cycle through all patterns every N seconds (for QC sweeps).

---

## 8. Effects

A library of signal-transformation effects applied to the active source (or test pattern). Effects can be **temporarily toggled** from the front panel / web UI OR **saved into a profile** (§ 9) for permanent operation — useful for the "make this LCD look like a CRT" workflow (scanlines + slight blur + warm tint saved into a profile).

Quick-action buttons on the front panel default to the two most-used effects: `BLACK` (fade-to-black) and `MONO` (monochrome). See Navigation patterns at the bottom of this doc.

### 8.1 Active effect — `enum`, front+web — default `Off`

One effect active at a time. The effect modifies the active source in real time.

- `Off` (default)
- `Freeze frame` — captures the current frame and holds on output until released
- `Random noise` (snow) — full-frame TV static
- `Block artifacts` — MPEG-style block distortion, intensity-configurable
- `CRT power-off` — collapse to a horizontal line → center dot → bright flash → fade to black. ~1.5 s animation. Classic CRT shutdown look.
- `CRT power-on` — paired with power-off: flash + electron-beam scan-in from top → settle to image
- `Vertical hold loss / rolling` — picture rolls vertically with V-blank visible as a moving bar
- `Snow burst / channel change` — brief noise blast (0.2–2 s), then return to source. "Click of the dial" effect.
- `Color rolling` — chroma demod unsync simulation; hue rotates around the color circle
- `VHS tracking error` — drifting noise bars across the frame (count + height + speed configurable)
- `Hum bars` — slow horizontal dim bars (50 Hz / 60 Hz roll, classic composite-output hum)
- `Burn-in ghost overlay` — faint pattern overlay simulating phosphor burn-in from prior content
- `Scanline emphasis` — exaggerated horizontal scanlines (for **CRT look on a downstream LCD**)
- `Blur` — Gaussian blur (Tier 3 HDL cost — may land later in V1)
- `Solarize` — invert colors above a threshold (surreal partial-inverted look)
- `Posterize` — reduce color bit depth (chunky color stepping)

### 8.2 Blend / mixer — `num`, front+web — default `100`

0–100 % wet/dry. At 0 % the effect is invisible (clean source); at 100 % the effect fully replaces source video. Lets the operator dial in a subtle vs heavy look.

### 8.3 Transition time — `num`, front+web — default `0` frames

0–240 frames fade-in / fade-out duration when the effect toggles on/off. At 0, the effect engages instantly; at 30 frames @ 24 fps the effect smoothly fades over ~1.25 s.

### 8.4 Effect-specific parameters

Visible parameters depend on which effect is active in § 8.1. Web UI shows contextual sliders; front panel shows parameters in a follow-on submenu.

**Random noise:** density (0–100 %), grain size (1×1 ↔ 4×4 pixel blocks).

**Block artifacts:** block size (4×4 ↔ 32×32 pixels), distortion intensity (0–100 %), DCT bias (mild ↔ severe).

**CRT power-off / power-on:** total duration (0.5–3.0 s), flash brightness (50–200 %).

**Vertical hold loss:** roll speed (0.1 ↔ 5 Hz), direction (up / down), V-blank bar visibility (subtle ↔ obvious).

**Snow burst:** burst duration (0.2–2 s).

**Color rolling:** rotation speed (0.1 ↔ 2 Hz), hue range (full circle / partial arc).

**VHS tracking error:** bar count (1–5), bar height (1 line ↔ 10 % of frame), drift speed (slow ↔ fast), intensity (subtle ↔ severe), jitter (regular ↔ random position).

**Hum bars:** bar count (1–3), bar darkness (10–80 %), roll speed (50 Hz / 60 Hz / custom), direction (up / down).

**Burn-in ghost overlay:** ghost image source (one of 4 still buffers, or operator-uploaded), opacity (5–50 %), position offset (X + Y).

**Scanline emphasis:** line spacing (every line / every 2nd / every 3rd), darkness (10–80 %), thickness (1 px / 2 px), color tint (true black / slight warmth / slight cool).

**Blur:** intensity (light / medium / heavy — kernel size). Note: Gaussian blur is HDL-expensive; may ship later in V1.

**Solarize:** threshold (0–100 %; pixels above this brightness get inverted), softness (hard cutoff vs gradient).

**Posterize:** bit depth target per channel (`8` → `4` → `3` → `2` bits).

### 8.5 Save effect to profile — `action`, front+web

Snapshots the current effect + parameters into the active profile (§ 9) so it loads automatically next time that profile is selected. Used for the "Sony LCD shoot — scanlines + slight blur + warm tint" persistent setup.

### 8.6 Quick-recall bindings — `action`, front only

Bind a configured effect (with its parameters) to a front-panel quick-select button. Default bindings:
- Quick-select 1 → `BLACK` (fade-to-black with current transition time)
- Quick-select 2 → `MONO` (monochrome toggle — implemented as a special effect that sets saturation to 0)
- Quick-select 3 → `Proc Amp bypass` toggle (see § 1.8)

Operator can rebind any quick-select to any effect or any other action.

---

## 9. Profiles (per-CRT calibration)

JSON profiles in the NovaTool tile-profile pattern.

### 9.1 Active profile — `enum`, front+web

Pick from saved list.

### 9.2 Save current as — `action`, front+web

Snapshots color + geometry + sync structure + behavior settings.

### 9.3 Rename — `text`, front+web

### 9.4 Delete — `action`, front+web

### 9.5 Import / Export — `action`, web only

JSON file upload / download.

### 9.6 Quick recall — `action` × 4, front only

Front-panel quick-select buttons can be bound to specific profiles.

---

## 10. Behavior

### 10.1 Signal loss behavior — `enum`, front+web

- `Black`
- `Freeze`
- `Last-good-frame-for-N-seconds-then-black` (timeout in 9.2)

### 10.2 Signal loss timeout — `num`, front+web

Seconds (1–120).

### 10.3 Burn-in protection

**10.3.1 Auto-darken trigger** — `num`, front+web
- After N minutes of static (`0` = disabled)

**10.3.2 Pixel-shift trigger** — `num`, front+web
- After N minutes of static (`0` = disabled)

**10.3.3 Pixel-shift amount** — `num`, front+web
- Pixels of shift

### 10.4 Degauss trigger — `action`, front+web

Pulses a GPIO / relay output for pro CRTs with remote-degauss input.

---

## 11. Test / Maintenance

### 11.1 Burn-in repair scroll — `action`, front+web

Standalone mode: runs scrolling white/black/gray at front-panel-selected speed, no input required.

### 11.2 Self-test — `action`, front+web

Internal loopback: TPG → all terminals → INA226 power-rail read → lock detector reports green.

### 11.3 Output verification — `action`, front+web

Generates known SMPTE bars on all outputs simultaneously; operator confirms each downstream display matches.

### 11.4 Factory reset — `action`, front+web

Confirms via dialog before wiping all profiles and settings.

---

## 12. System

### 12.1 Network

**12.1.1 Mode** — `enum`, front+web
- `DHCP`
- `Static`

**12.1.2 Static config** — `text`, front+web (visible when mode = Static)
- IP, Netmask, Gateway, DNS

**12.1.3 Hostname** — `text`, front+web
- Used for mDNS (`schindler-<name>.local`)

### 12.2 WiFi

**12.2.1 AP mode** — `toggle`, front+web — default `on`

**12.2.2 AP SSID** — `text`, front+web
- Default: `Schindler-<serial>`

**12.2.3 AP password** — `text`, front+web
- Generated unique per unit, displayable on front panel for pairing

**12.2.4 STA mode** — `toggle`, front+web — default `off`

**12.2.5 STA SSID list** — `action`, front+web
- Scan + select; multiple saved networks

**12.2.6 STA password** — `text`, front+web

**12.2.7 BLE pairing** — `action`, front+web
- Enter pairing mode for companion-app credential push

### 12.3 Firmware

**12.3.1 Current version** — `ro`, front+web
- Bitstream + PetaLinux + UI MCU + RP2040 versions

**12.3.2 Check for updates** — `action`, web only

**12.3.3 Upload firmware** — `action`, web only — `.img` file

**12.3.4 Update via USB** — `action`, front only

**12.3.5 Rollback to previous** — `action`, front+web — A/B firmware slots

**12.3.6 Reboot** — `action`, front+web — confirms first

### 12.4 Time / Date

**12.4.1 NTP server** — `text`, front+web — default `pool.ntp.org`

**12.4.2 Timezone** — `enum`, front+web

**12.4.3 Manual set** — `text`, front+web

### 12.5 System info — `ro`, front+web

- Serial number, hardware rev, uptime, temperatures, voltage rails (INA226 + on-SOM monitors), fan RPM

### 12.6 Diagnostic logs — `action`, front+web

View / download last N lines of system log.

### 12.7 Status LED brightness — `num`, front+web — 0–100 %, default `10`

---

## 13. Compliance / Consent

Centralized place for legal-posture toggles and audit. The HDCP override toggle itself lives in **§ 1.3.5** (input-side, where the protected content is detected); this section holds the persistence policy, audit log, and service-mode lockdown.

### 13.1 HDCP override persistence — `enum`, front+web

What happens to the HDCP override on power cycle:
- `Per-session` — auto-disable on every power cycle *(default — safer)*
- `Persist across power cycles`
- `Persist until manually disabled`

### 13.2 HDCP override consent dialog

Triggered when § 1.3.5 is toggled on. Dialog text:

> **HDCP passthrough consent**
>
> I attest that my use of the HDMI passthrough output for HDCP-protected source material is a non-violating use under applicable law and licensing. I accept responsibility for compliance with content licensing terms.
>
> *[ ] I attest (checkbox)*

To enable, user must check the box AND confirm:
- **Front panel:** press the `Confirm` hardware button
- **Web UI:** type `I AGREE` in a confirmation field

### 13.3 Override history — `ro`, web only

Audit log: timestamp + web-auth user (if applicable) for each toggle event.

### 13.4 Service mode — `action`, front+web

Locks all outputs to test patterns AND disables HDCP override toggle entirely. Used for shipping units, loaner units, or unattended demo state.

---

## Navigation patterns

### Front panel (TFT + encoders + buttons)

The persistent status bar sits at the top; the main menu fills the rest of the screen.

- **Encoder A** (left): scrolls within current menu level
- **Encoder A press:** enters submenu / selects item
- **Encoder B** (right): adjusts the focused setting (numeric tweak / enum tick)
- **Encoder B press:** confirms current value / closes
- **Home button:** jumps back to root status screen
- **Back button:** one level up
- **Menu button:** toggles between status overview and main menu
- **Confirm button:** alternate confirm path for dialogs (especially HDCP consent)
- **Quick-select buttons (2–3):** bindable to common actions. **Defaults (post MVPHD review, 2026-05-11):**
  - Default 1: `BLACK` — fade-to-black (uses § 8.3 transition time)
  - Default 2: `MONO` — monochrome toggle
  - Default 3: `Proc Amp bypass` — toggle § 1.8 (raw-vs-adjusted compare)
  - Alternate bindings the operator may swap to: Output Mode toggle (composite ↔ component), Profile recall, Genlock source, Freeze frame, Snow burst, any other configured effect.

### Web UI (Node.js on Zynq PS)

- Persistent status bar at top of every page.
- Same hierarchy presented as a left-rail tree + main panel.
- Live preview region with small thumbnails for each output.
- Drag-handles for color matrix, geometry warp, 4-corner.
- File upload widgets for EDID / LUT / Profile import.
- Real-time charts for genlock quality metric, INA226 power draw.

### Rear LCD (read-only)

Status grid only — no menu. Auto-refreshes every ~1 s. Header bar matches the persistent status bar from front+web. See `01-spec.md` Rear panel — status display section for content layout.

---

## Open UI questions

- **Menu depth on the front panel.** Hierarchy is up to 3 levels deep. Consider flattening Inputs / Outputs into a "card per port" view on the front-panel TFT while keeping the strict hierarchy on web.
- **Profile autoload behavior.** Should connecting a known CRT (identified by EDID or measured colorimetry) auto-load its profile? Or always start with the last-active profile?
- **Quick-select button defaults.** Three buttons, three defaults — revisit after operator testing on real hardware.
- **HDCP consent persistence default.** Per-session auto-disable is defensive. Some operators may want persist-across-restart for legitimate sustained workflows. Default to per-session; let the operator opt-in.
- **Front-panel TFT bus.** Currently spec says ILI9341 SPI for prototyping → LTDC parallel for production. Front-panel menu depth supports either; LTDC parallel just renders faster. Confirm SPI ILI9341 prototype path is adequate before committing carrier traces to the parallel bus.
- **Resolution × rate combination validation.** With resolution and rate selected independently per output, some combinations are invalid (e.g. 1080p120 is outside HDMI 1.4 bandwidth). UI should gray out invalid pairs at the moment of selection, with a tooltip explaining why.

---

## Cross-references

- Architecture + decision history: [`01-spec.md`](01-spec.md) + [`01-spec-changelog.md`](01-spec-changelog.md)
- Signal flow + per-output terminal encoders: [`signal-flow.md`](signal-flow.md)
- Physical panel layout: [`panel-layout.md`](panel-layout.md)
- BOM mapping: [`bom-v1.md`](bom-v1.md)
- MVPHD feature comparison: [`mvphd-comparison.md`](mvphd-comparison.md) *(in progress)*
