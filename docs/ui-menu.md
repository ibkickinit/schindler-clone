# Schindler 2.0 — UI Menu Structure

**Status:** Draft 2026-05-11 (readability pass)
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

**Surface owners:**

| Surface | Owner | Role |
|---|---|---|
| Front-panel TFT (~2.8–3.5" color, LTDC parallel) | UI MCU (STM32H735) | Operator navigates via 2 rotary encoders + 4 fixed buttons + 2–3 quick-select buttons |
| Web UI (Node.js on Zynq PS) | Zynq PS | Same hierarchy, richer widgets. Accessible at `http://schindler-<serial>.local` |
| Rear-panel status LCD (2.4" 16:9 SPI) | Zynq PS | Read-only status grid; no navigation |
| Front-panel status LED column | UI MCU | Mirrors rear per-connector LEDs |

---

## 0. Home (root / status overview)

The default screen on boot. Shows current operating state at a glance.

**0.1 Current source** — `ro`, front+web
- Displays: HDMI / SDI / Composite / Component / TPG / "no signal"

**0.2 Source rate** — `ro`, front+web
- Detected rate from the incoming signal (e.g. `1080p59.94`)

**0.3 Master clock state** — `ro`, front+web
- Lock state + quality metric + selected reference source

**0.4 Per-output rates** — `ro`, front+web
- One row per output (HDMI / Composite / Component / SDI / SYNC1 / SYNC2) showing current rate

**0.5 Active profile** — `ro`, front+web
- Per-CRT profile name (if loaded)

**0.6 Alarms / faults** — `ro`, front+web
- Any active red-LED conditions

**0.7 Enter main menu** — `action`, front only
- Encoder press or "Menu" button enters the main menu

---

## 1. Inputs

### 1.1 Source select — `enum`, front+web

Default: `Auto`

- `Auto` — picks the first valid signal seen
- `HDMI`
- `SDI` (broadcast tier only)
- `Composite`
- `Component`
- `TPG` — internal test pattern generator

### 1.2 EDID profile — `enum`, front+web

Per-input EDID negotiation profile.

- `Default`
- `1080p24`
- `1080p23.98`
- `1080p25`
- `720p`
- `Custom` (uses uploaded EDID — see 1.3)

### 1.3 EDID custom upload — `action`, web only

Upload a `.bin` EDID file. Web UI only because file upload isn't practical on the front panel.

### 1.4 HDMI input

**1.4.1 Signal info** — `ro`, front+web
- Detected rate, color space, HDCP authentication state, source name (from InfoFrame)

**1.4.2 5V cable-power** — `toggle`, front+web — default `on`
- Controls the TPD12S016 5V switch on HDMI input

**1.4.3 Hotplug behavior** — `enum`, front+web
- `Always assert HPD`
- `Toggle on source change`
- `Off`

### 1.5 SDI input *(broadcast tier)*

**1.5.1 Signal info** — `ro`, front+web
- Rate, payload ID (SMPTE 352), VITC if present

**1.5.2 Use as genlock reference** — `toggle`, front+web — default `on`
- Enables/disables SDI as an available genlock source

### 1.6 Composite input

**1.6.1 Standard** — `enum`, front+web
- `Auto`
- `NTSC`
- `NTSC-J`
- `PAL`
- `PAL-M`
- `SECAM`

**1.6.2 Termination** — `toggle`, front+web — default `on`
- 75 Ω termination on/off

**1.6.3 Signal info** — `ro`, front+web
- Detected standard, sync presence, level

### 1.7 Component input

**1.7.1 Standard** — `enum`, front+web
- `Auto`
- `480i`
- `480p`
- `576i`
- `576p`
- `720p`
- `1080i`
- `1080p`

**1.7.2 Termination** — `toggle`, front+web — default `on`
- 75 Ω termination on/off

**1.7.3 Signal info** — `ro`, front+web
- Detected standard, sync presence, levels

---

## 2. Outputs

Each output has its own submenu. All outputs are **independent and concurrent** — settings here apply to one output only.

### 2.1 HDMI OUT

**2.1.1 Enable** — `toggle`, front+web — default `on`

**2.1.2 Output rate** — `enum`, front+web
- `Match source`
- `1080p60`
- `1080p59.94`
- `1080p50`
- `1080p30`
- `1080p29.97`
- `1080p25`
- `1080p24`
- `1080p23.98`
- `720p60`
- `720p59.94`
- `720p50`

**2.1.3 Color space** — `enum`, front+web
- `Auto`
- `RGB`
- `YCbCr 4:2:2`
- `YCbCr 4:4:4`

**2.1.4 InfoFrame source name** — `text`, web only
- Source-name string passed to downstream gear via HDMI InfoFrame

**2.1.5 HDCP override** — `toggle` with consent flow, front+web — default `off`
- Required to pass HDCP-protected source content through HDMI OUT. See **§ 11** for the attestation dialog.

### 2.2 Composite OUT

**2.2.1 Enable** — `toggle`, front+web — default `on`

**2.2.2 Standard** — `enum`, front+web
- `NTSC`
- `NTSC-J`
- `PAL`
- `PAL-M`

**2.2.3 Output rate** — `enum`, front+web
- `23.976 fps`
- `24.000 fps`
- `25.000 fps`
- `29.97 fps`
- `30.000 fps`

**2.2.4 Cadence convert** — `enum`, front+web
- `Off` — matched-rate only; rejects mismatched-rate sources
- `5:2 pulldown` — 60 → 24
- `6:5` — 60 → 50 / 25
- `4:5 pulldown` — 24 → 30
- `Slip 23.98 → 24`

**2.2.5 Sync structure** — submenu, front+web
- Per-CRT-profile sync tweaks; see **§ 8.4**

**2.2.6 Setup pedestal** — `enum`, front+web
- `7.5 IRE` (NTSC-M)
- `0 IRE` (NTSC-J)

**2.2.7 Subcarrier mode** — `enum`, front+web
- `Coherent` — clean phase to line rate (playbook Ch. 4)
- `Non-coherent` — 3.579545 MHz absolute, NTSC-decoder compatible

**2.2.8 Burst phase alternation** — `toggle`, front+web — default `on`
- 90° phase alternation between fields (playbook Ch. 5 — improves CRT stability)

**2.2.9 Sync tip voltage trim** — `num`, front+web
- Range ±100 mV around SMPTE −286 mV — used for oddball-AGC CRTs (e.g. the Zenith from playbook Ch. 3)

**2.2.10 VITC insertion** — submenu, front+web
- `Enable VITC` — `toggle`
- `Source` — `enum`: `Genlock` / `Free-run` / `Manual offset`

### 2.3 Component OUT

**2.3.1 Enable** — `toggle`, front+web — default `on`

**2.3.2 Format** — `enum`, front+web
- `YPbPr`
- `RGB`

**2.3.3 Output rate** — `enum`, front+web
- `Match source`, plus full rate list per spec

**2.3.4 Levels** — `enum`, front+web
- `SMPTE`
- `Beta`
- `Wide`

**2.3.5 Mode-switch with composite** — `ro`, front+web
- Reminder: ADV7393 is I²C-switched between composite and component; selecting one disables the other on the analog BNCs.

### 2.4 SDI OUT *(broadcast tier)*

**2.4.1 Enable** — `toggle`, front+web — default `on`

**2.4.2 Output rate** — `enum`, front+web
- `Match source`
- `1080p60` / `1080p59.94` / `1080p50` / `1080p30` / `1080p29.97` / `1080p25` / `1080p24` / `1080p23.98`
- `720p60` / `720p59.94` / `720p50`

**2.4.3 Payload ID (SMPTE 352)** — `enum`, front+web
- `Auto`
- `Forced` (specify payload ID byte values)

**2.4.4 VITC insertion** — submenu, front+web
- Same fields as 2.2.10

**2.4.5 Embedded audio passthrough** — `toggle`, front+web
- Pass through embedded audio (if present in source)

### 2.5 SYNC OUT 1

**2.5.1 Enable** — `toggle`, front+web — default `on`

**2.5.2 Format** — `enum`, front+web
- `Black burst` (NTSC / PAL composite reference)
- `Tri-level sync` (HD video reference)
- `LTC` (timecode, audio-rate biphase mark)
- `DARS` — *coming soon* (greyed out; hardware-ready, firmware-future per spec)
- `Word Clock` — *coming soon* (greyed out; hardware-ready, firmware-future)

**2.5.3 Output rate** — `enum`, front+web
- `23.976` / `24.000` / `25.000` / `29.97` / `30.000`
- `50i` / `59.94i` / `60i`
- `50p` / `59.94p` / `60p`

**2.5.4 Output level** — `num`, front+web
- ±20 % around nominal for downstream gear quirks

**2.5.5 Phase offset** — `num`, front+web
- Sub-line phase trim relative to master clock (degrees or ns)

**2.5.6 LTC payload** — submenu, front+web (visible only when format = LTC)
- **Frame rate** — `enum`: matches output rate options
- **User bits** — `text`: 8 hex digits
- **Drop-frame mode** — `enum`: `Auto` / `Force DF` / `Force NDF`

### 2.6 SYNC OUT 2

Identical structure to **§ 2.5** (SYNC OUT 1). Each OUT is configured independently.

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

### 3.3 White point

**3.3.1 Preset** — `enum`, front+web
- `3200 K`
- `4800 K`
- `5600 K`
- `6500 K`
- `9300 K`
- `Custom`

**3.3.2 Custom temp** — `num`, front+web
- 2700–10000 K

**3.3.3 Tint** — `num`, front+web
- ±20 (magenta ↔ green)

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

### 4.2 Scaling — `enum`, front+web

- `Anamorphic`
- `Letterbox`
- `Center cut`
- `Custom` (specify scale factor)

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

## 5. Genlock / Sync

### 5.1 Reference source — `enum`, front+web

- `Auto` — autosense priority fallback
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

What the NCO does on reference loss:
- `Last value` — freeze the integrator
- `Average over last N s` — use a windowed average of recent corrections
- `Operator-set rate` — fall back to the free-run rate (5.4)

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

## 6. Test Patterns

Replaces the input source with an internal generator. Source select (§ 1.1) becomes `TPG` when active.

### 6.1 Pattern — `enum`, front+web

- `SMPTE color bars 75 %`
- `SMPTE color bars 100 %`
- `SMPTE color bars (SMPTE-spec)`
- `PLUGE`
- `Geometry grid` (100 % / 95 % / 90 % safe area)
- `Convergence pattern`
- `Purity (full-field R / G / B)`
- `Focus / zone plate`
- `Burn-in repair scroll` (white / black / gray)

### 6.2 Pattern rate — `enum`, front+web

Match the selected output rate.

### 6.3 Burn-in scroll speed — `num`, front+web

1–60 s per cycle (only visible when burn-in scroll pattern selected).

### 6.4 Auto-cycle patterns — `toggle` + `num`, front+web

Cycle through all patterns every N seconds (for QC sweeps).

---

## 7. Profiles (per-CRT calibration)

JSON profiles in the NovaTool tile-profile pattern.

### 7.1 Active profile — `enum`, front+web

Pick from saved list.

### 7.2 Save current as — `action`, front+web

Snapshots color + geometry + sync structure + behavior settings.

### 7.3 Rename — `text`, front+web

### 7.4 Delete — `action`, front+web

### 7.5 Import / Export — `action`, web only

JSON file upload / download.

### 7.6 Quick recall — `action` × 4, front only

Front-panel quick-select buttons can be bound to specific profiles.

---

## 8. Behavior

### 8.1 Signal loss behavior — `enum`, front+web

- `Black`
- `Freeze`
- `Last-good-frame-for-N-seconds-then-black` (timeout in 8.2)

### 8.2 Signal loss timeout — `num`, front+web

Seconds (1–120).

### 8.3 Burn-in protection

**8.3.1 Auto-darken trigger** — `num`, front+web
- After N minutes of static (`0` = disabled)

**8.3.2 Pixel-shift trigger** — `num`, front+web
- After N minutes of static (`0` = disabled)

**8.3.3 Pixel-shift amount** — `num`, front+web
- Pixels of shift

### 8.4 CRT sync structure (per profile)

**8.4.1 Front porch** — `num`, front+web
- 1.0–5.0 µs

**8.4.2 Back porch** — `num`, front+web
- 3.0–12.0 µs
- **Default for 24p camera-shoot profiles: 7.0 µs** — wider than SMPTE 4.7 µs nominal to give camera shutters a larger target window and avoid the visible sync bar on filmed CRT footage (industry wisdom from a 24-frame production veteran, 2026-05-11)

**8.4.3 Equalizing pulse count** — `num`, front+web
- Standard `6` / tweakable per CRT

**8.4.4 Serration pulse width** — `enum`, front+web
- `Standard`
- `Wide`

### 8.5 Field cadence (non-matching rates) — `enum`, front+web

- `Off` — reject mismatched-rate sources
- `Hard switch`
- `Crossfade` (default for cinema-grade output)

### 8.6 Degauss trigger — `action`, front+web

Pulses a GPIO / relay output for pro CRTs with remote-degauss input.

---

## 9. Test / Maintenance

### 9.1 Burn-in repair scroll — `action`, front+web

Standalone mode: runs scrolling white/black/gray at front-panel-selected speed, no input required.

### 9.2 Self-test — `action`, front+web

Internal loopback: TPG → all terminals → INA226 power-rail read → lock detector reports green.

### 9.3 Output verification — `action`, front+web

Generates known SMPTE bars on all outputs simultaneously; operator confirms each downstream display matches.

### 9.4 Factory reset — `action`, front+web

Confirms via dialog before wiping all profiles and settings.

---

## 10. System

### 10.1 Network

**10.1.1 Mode** — `enum`, front+web
- `DHCP`
- `Static`

**10.1.2 Static config** — `text`, front+web (visible when mode = Static)
- IP, Netmask, Gateway, DNS — each as separate text fields

**10.1.3 Hostname** — `text`, front+web
- Used for mDNS (`schindler-<name>.local`)

### 10.2 WiFi

**10.2.1 AP mode** — `toggle`, front+web — default `on`

**10.2.2 AP SSID** — `text`, front+web
- Default: `Schindler-<serial>`

**10.2.3 AP password** — `text`, front+web
- Generated unique per unit, displayable on front panel for pairing

**10.2.4 STA mode** — `toggle`, front+web — default `off`

**10.2.5 STA SSID list** — `action`, front+web
- Scan + select; multiple saved networks

**10.2.6 STA password** — `text`, front+web

**10.2.7 BLE pairing** — `action`, front+web
- Enter pairing mode for companion-app credential push

### 10.3 Firmware

**10.3.1 Current version** — `ro`, front+web
- Bitstream + PetaLinux + UI MCU + RP2040 versions

**10.3.2 Check for updates** — `action`, web only

**10.3.3 Upload firmware** — `action`, web only
- `.img` file

**10.3.4 Update via USB** — `action`, front only
- Insert USB stick with firmware bundle

**10.3.5 Rollback to previous** — `action`, front+web
- A/B firmware slots

**10.3.6 Reboot** — `action`, front+web
- Confirms first

### 10.4 Time / Date

**10.4.1 NTP server** — `text`, front+web
- Default `pool.ntp.org`

**10.4.2 Timezone** — `enum`, front+web

**10.4.3 Manual set** — `text`, front+web

### 10.5 System info — `ro`, front+web

- Serial number
- Hardware rev
- Uptime
- Temperatures (Zynq SOM, chassis)
- Voltage rail readings (from INA226 + on-SOM monitors)
- Fan RPM

### 10.6 Diagnostic logs — `action`, front+web

View / download last N lines of system log.

### 10.7 Status LED brightness — `num`, front+web

0–100 %, default `10`.

---

## 11. Compliance / Consent

Centralized place for legal-posture toggles. Primary item is the HDCP override gate for HDMI passthrough.

### 11.1 HDMI passthrough HDCP override — `toggle` with consent flow, front+web

Default `off`. Toggling on opens an attestation dialog:

> **HDCP passthrough consent**
>
> I attest that my use of the HDMI passthrough output for HDCP-protected source material is a non-violating use under applicable law and licensing. I accept responsibility for compliance with content licensing terms.
>
> *[ ] I attest (checkbox)*

To enable, user must check the box AND confirm:
- **Front panel:** press the `Confirm` hardware button
- **Web UI:** type `I AGREE` in a confirmation field

Once enabled, persists per the **11.2** policy.

### 11.2 Persistence — `enum`, front+web

What happens to the HDCP override on power cycle:
- `Per-session` — auto-disable on every power cycle *(default — safer)*
- `Persist across power cycles`
- `Persist until manually disabled`

### 11.3 Override history — `ro`, web only

Audit log: timestamp + web-auth user (if applicable) for each toggle event.

### 11.4 Service mode — `action`, front+web

Locks all outputs to test patterns AND disables HDCP override toggle entirely. Used for shipping units, loaner units, or unattended demo state.

---

## Navigation patterns

### Front panel (TFT + encoders + buttons)

- **Encoder A** (left): scrolls within current menu level
- **Encoder A press:** enters submenu / selects item
- **Encoder B** (right): adjusts the focused setting (numeric tweak / enum tick)
- **Encoder B press:** confirms current value / closes
- **Home button:** jumps back to root status screen
- **Back button:** one level up
- **Menu button:** toggles between status overview and main menu
- **Confirm button:** alternate confirm path for dialogs (especially HDCP consent)
- **Quick-select buttons (2–3):** bindable to common actions
  - Default 1: Output Mode toggle (composite ↔ component on the ADV7393)
  - Default 2: Profile recall
  - Default 3: Genlock source

### Web UI (Node.js on Zynq PS)

- Same hierarchy presented as a left-rail tree + main panel
- Live preview region with small thumbnails for each output
- Drag-handles for color matrix, geometry warp, 4-corner
- File upload widgets for EDID / LUT / Profile import
- Real-time charts for genlock quality metric, INA226 power draw

### Rear LCD (read-only)

Status grid only — no menu. Auto-refreshes every ~1 s. See `01-spec.md` Rear panel — status display section for content layout.

---

## Open UI questions

- **Menu depth on the front panel.** Hierarchy is up to 3 levels deep. Consider flattening Inputs / Outputs into a "card per port" view on the front-panel TFT while keeping the strict hierarchy on web.
- **Profile autoload behavior.** Should connecting a known CRT (identified by EDID or measured colorimetry) auto-load its profile? Or always start with the last-active profile?
- **Quick-select button defaults.** Three buttons, three defaults — revisit after operator testing on real hardware.
- **HDCP consent persistence default.** Per-session auto-disable is defensive. Some operators may want persist-across-restart for legitimate sustained workflows. Default to per-session; let the operator opt-in.
- **Front-panel TFT bus.** Currently spec says ILI9341 SPI for prototyping → LTDC parallel for production. Front-panel menu depth supports either; LTDC parallel just renders faster. Confirm SPI ILI9341 prototype path is adequate before committing carrier traces to the parallel bus.

---

## Cross-references

- Architecture + decision history: [`01-spec.md`](01-spec.md) + [`01-spec-changelog.md`](01-spec-changelog.md)
- Signal flow + per-output terminal encoders: [`signal-flow.md`](signal-flow.md)
- Physical panel layout: [`panel-layout.md`](panel-layout.md)
- BOM mapping: [`bom-v1.md`](bom-v1.md)
