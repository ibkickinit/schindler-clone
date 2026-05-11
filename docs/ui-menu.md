# Schindler 2.0 — UI Menu Structure

**Status:** Draft 2026-05-11
**Scope:** complete hierarchical menu structure covering all V1 settings, surfaced on the front-panel TFT + web UI. Rear-panel LCD is read-only and shows the status grid only (no navigation).
**Sources:** `01-spec.md` (feature set), `panel-layout.md` (physical controls), `signal-flow.md` (architecture for which settings apply where).

This doc is the structural intent. Wireframes, exact widget choices, and field validation rules belong in a later UX-design pass.

---

## Surface conventions

| Surface | Owner | Role |
|---|---|---|
| **Front-panel TFT** (~2.8–3.5" color, LTDC parallel) | UI MCU (STM32H735) | Operator navigates with 2 rotary encoders + 4 fixed buttons + 2–3 quick-select buttons. Drives the full menu hierarchy below. |
| **Web UI** (Node.js on Zynq PS) | Zynq PS | Same menu hierarchy, richer widgets (sliders, color pickers, drag-handles, file uploads for LUT / profile imports). Accessible at `http://schindler-<serial>.local` over GbE / WiFi. |
| **Rear-panel status LCD** (2.4" 16:9 SPI) | Zynq PS | Read-only status grid: per-connector lock/state/format/rate. No menu navigation. Header bar shows IP / hostname / firmware / current ref source. |
| **Front-panel status LED column** | UI MCU | Mirrors rear per-connector LEDs (genlock / signal-present / link / fault). |

**Setting-type legend used below:**
- `[toggle]` — boolean on/off
- `[enum]` — pick-one from a list
- `[num]` — numeric value (with unit + range)
- `[text]` — free text (hostname, profile name)
- `[action]` — invokes an operation (run test pattern, restart, etc.)
- `[ro]` — read-only display

**Surface column:** `F` = front panel, `W` = web, `B` = both (default).

---

## 0. Home (root / status overview)

The default screen on boot. Shows current operating state at a glance.

| Item | Type | Surface | Notes |
|---|---|---|---|
| Current source | `[ro]` | B | HDMI / SDI / Composite / Component / TPG / no signal |
| Source rate | `[ro]` | B | 1080p59.94 / etc., from incoming signal |
| Master clock state | `[ro]` | B | Lock state + quality metric + selected ref |
| Per-output rates | `[ro]` | B | HDMI / Composite / Component / SDI / SYNC1 / SYNC2 — current rate each |
| Active profile | `[ro]` | B | Per-CRT profile name (if loaded) |
| Alarms / faults | `[ro]` | B | Any active red-LED conditions |
| ↓ menu navigation | `[action]` | F | Encoder press / "Menu" button enters main menu |

---

## 1. Inputs

| 1.1 Source select | `[enum]` | B | Auto / HDMI / SDI / Composite / Component / TPG. Default: Auto (picks the first valid signal seen) |
| 1.2 EDID profile | `[enum]` | B | Per-input EDID negotiation profile: Default / 1080p24 / 1080p23.98 / 1080p25 / 720p / Custom |
| 1.3 EDID custom upload | `[action]` | W | Web-only — upload a .bin EDID file |
| 1.4 HDMI input | submenu | B | |
| 1.4.1 → Signal info | `[ro]` | B | Rate, color space, HDCP authentication state, source name (from InfoFrame) |
| 1.4.2 → 5V cable-power | `[toggle]` | B | TPD12S016 5V switch — usually on |
| 1.4.3 → Hotplug behavior | `[enum]` | B | Always assert HPD / Toggle on source change / Off |
| 1.5 SDI input *(broadcast tier)* | submenu | B | |
| 1.5.1 → Signal info | `[ro]` | B | Rate, payload ID (SMPTE 352), VITC if present |
| 1.5.2 → Use as genlock ref | `[toggle]` | B | Enable / disable SDI as available genlock source |
| 1.6 Composite input | submenu | B | |
| 1.6.1 → Standard | `[enum]` | B | Auto / NTSC / NTSC-J / PAL / PAL-M / SECAM |
| 1.6.2 → Termination | `[toggle]` | B | 75 Ω on/off |
| 1.6.3 → Signal info | `[ro]` | B | Detected standard, sync presence, level |
| 1.7 Component input | submenu | B | |
| 1.7.1 → Standard | `[enum]` | B | Auto / 480i / 480p / 576i / 576p / 720p / 1080i / 1080p |
| 1.7.2 → Termination | `[toggle]` | B | 75 Ω on/off |
| 1.7.3 → Signal info | `[ro]` | B | Detected standard, sync presence, levels |

---

## 2. Outputs

Each output has its own submenu — independent and concurrent configuration.

### 2.1 HDMI OUT

| 2.1.1 Enable | `[toggle]` | B | Master on/off for HDMI output |
| 2.1.2 Output rate | `[enum]` | B | Match source / 1080p60 / 1080p59.94 / 1080p50 / 1080p30 / 1080p29.97 / 1080p25 / 1080p24 / 1080p23.98 / 720p60 / 720p59.94 / 720p50 |
| 2.1.3 Color space | `[enum]` | B | Auto / RGB / YCbCr 4:2:2 / YCbCr 4:4:4 |
| 2.1.4 InfoFrame name | `[text]` | W | Source-name field passed to downstream |
| 2.1.5 HDCP override *(requires consent — see § 11)* | `[toggle]` | B | Default off; enabling requires attestation dialog before HDCP-protected source can flow |

### 2.2 Composite OUT

| 2.2.1 Enable | `[toggle]` | B | |
| 2.2.2 Standard | `[enum]` | B | NTSC / NTSC-J / PAL / PAL-M |
| 2.2.3 Output rate | `[enum]` | B | 23.976 / 24.000 / 25.000 / 29.97 / 30.000 fps |
| 2.2.4 Cadence convert | `[enum]` | B | Off (matched-rate only) / 5:2 pulldown (60→24) / 6:5 (60→25) / 4:5 pulldown / Slip 23.98→24 |
| 2.2.5 Sync structure | submenu | B | Per-CRT-profile sync tweaks (see § 8.4 below) |
| 2.2.6 Setup pedestal | `[enum]` | B | 7.5 IRE (NTSC-M) / 0 IRE (NTSC-J) |
| 2.2.7 Subcarrier mode | `[enum]` | B | Coherent (clean phase to line rate) / Non-coherent (3.579545 MHz absolute) |
| 2.2.8 Burst phase alternation | `[toggle]` | B | 90° alternation between fields (playbook Ch. 5 / CRT stability) |
| 2.2.9 Sync tip voltage trim | `[num]` | B | ±100 mV around SMPTE -286 mV (for oddball AGC CRTs) |
| 2.2.10 VITC insertion | `[toggle]` + `[enum]` | B | Insert timecode in VBI; source: Genlock / Free-run / Manual offset |

### 2.3 Component OUT

| 2.3.1 Enable | `[toggle]` | B | |
| 2.3.2 Format | `[enum]` | B | YPbPr / RGB |
| 2.3.3 Output rate | `[enum]` | B | Match source / specific rates (full list per spec) |
| 2.3.4 Levels | `[enum]` | B | SMPTE / Beta / Wide |
| 2.3.5 Mode-switch with composite | `[ro]` | B | Reminder: ADV7393 is I²C-switched between composite and component; selecting one disables the other on the analog BNCs |

### 2.4 SDI OUT *(broadcast tier)*

| 2.4.1 Enable | `[toggle]` | B | |
| 2.4.2 Output rate | `[enum]` | B | Match source / 1080p60 / etc. |
| 2.4.3 Payload ID | `[enum]` | B | SMPTE 352 auto / forced |
| 2.4.4 VITC insertion | `[toggle]` + `[enum]` | B | |
| 2.4.5 Embedded audio | `[toggle]` | B | Pass through embedded audio (if present in source) |

### 2.5 SYNC OUT 1

| 2.5.1 Enable | `[toggle]` | B | |
| 2.5.2 Format | `[enum]` | B | Black burst / Tri-level sync / LTC. (DARS / Word Clock are firmware-future, surface them as greyed-out "coming soon" entries so the operator sees the option even before it's enabled) |
| 2.5.3 Output rate | `[enum]` | B | 23.976 / 24 / 25 / 29.97 / 30 / 50i / 59.94i / 60i / 50p / 59.94p / 60p |
| 2.5.4 Output level | `[num]` | B | Trim ±20 % around nominal for downstream gear quirks |
| 2.5.5 Phase offset | `[num]` | B | Sub-line phase trim relative to master clock (degrees or ns) |
| 2.5.6 LTC payload | submenu | B | Only visible when format = LTC (frame rate, user bits, drop-frame mode) |

### 2.6 SYNC OUT 2

Identical structure to SYNC OUT 1.

---

## 3. Color

Live preview on rear LCD + on output while adjusting. All settings are per-profile and per-input source where it makes sense.

| 3.1 Gamma | `[num]` per channel | B | 1D LUT, 1024 entries, 12-bit. Web UI: drag curve. Front panel: ±slope adjust on master. |
| 3.2 Color matrix | `[num]` × 9 | B | 3×3 matrix. Web UI: drag 9 cells. Front panel: select cell → adjust value. |
| 3.3 White point | submenu | B | |
| 3.3.1 → Preset | `[enum]` | B | 3200 K / 4800 K / 5600 K / 6500 K / 9300 K / Custom |
| 3.3.2 → Custom temp | `[num]` | B | 2700–10000 K |
| 3.3.3 → Tint | `[num]` | B | ±20 magenta/green |
| 3.4 Black point | `[num]` per channel | B | RGB black trim |
| 3.5 White point | `[num]` per channel | B | RGB white trim |
| 3.6 Saturation | `[num]` | B | 0–200 % |
| 3.7 Hue | `[num]` | B | ±30° |
| 3.8 Black level | `[num]` | B | ±5 IRE (composite) |
| 3.9 LUT import | `[action]` | W | Upload .cube or .csv 1D LUT |
| 3.10 LUT export | `[action]` | W | Download current LUT |
| 3.11 Reset to defaults | `[action]` | B | |

---

## 4. Geometry

| 4.1 Active window position | `[num]` X + Y | B | X/Y pixel offset trim (playbook calls this the early bug — must be a UI control) |
| 4.2 Scaling | `[enum]` | B | Anamorphic / Letterbox / Center cut / Custom |
| 4.3 Pincushion | `[num]` H + V | B | ±10 % |
| 4.4 Keystone | `[num]` H + V | B | ±10° |
| 4.5 4-corner warp | submenu | W | Drag-handle interface on web UI; numeric tweak on front panel |
| 4.6 Overscan compensation | `[enum]` | B | Safe-area-only / Fill-with-overscan |
| 4.7 Aspect ratio | `[enum]` | B | 4:3 / 16:9 / Custom |
| 4.8 Reset to defaults | `[action]` | B | |

---

## 5. Genlock / Sync

| 5.1 Reference source | `[enum]` | B | Auto / LTC / Black burst / Tri-level / SDI / Free-run / Hold |
| 5.2 Reference priority list | `[enum]` ordered list | W | Web-only: drag to reorder autosense priority |
| 5.3 Loop bandwidth | `[enum]` | B | Tight (~2 Hz) / Default (~0.5 Hz) / Wide (~0.1 Hz) |
| 5.4 Free-run rate | `[num]` | B | Used when no reference is present |
| 5.5 Hold behavior | `[enum]` | B | Last value / Average over last N s / Operator-set rate |
| 5.6 Lock state | `[ro]` | B | Acquiring / Locked / Lost — with quality metric (phase error, drift) |
| 5.7 Quality metric | `[ro]` | B | Phase-error magnitude + 1 s stddev — live bar graph on web UI |
| 5.8 LTC offset | `[num]` | B | ±99 frames offset applied to LTC output relative to incoming TC |
| 5.9 Drop-frame mode | `[enum]` | B | Auto (match rate) / Force DF / Force NDF |
| 5.10 Genlock LED feedback | `[ro]` | B | Mirrors the per-connector and front-panel LED states |

---

## 6. Test Patterns

Replaces the input source with an internal generator. Source select (1.1) becomes "TPG" when active.

| 6.1 Pattern | `[enum]` | B | SMPTE color bars 75 % / 100 % / SMPTE / PLUGE / Geometry grid / Convergence / Purity (R/G/B) / Focus / Zone plate / Burn-in repair scroll (white/black/gray) |
| 6.2 Pattern rate | `[enum]` | B | Match selected output rate |
| 6.3 Burn-in scroll speed | `[num]` | B | 1–60 s per cycle (when burn-in scroll pattern selected) |
| 6.4 Auto-cycle patterns | `[toggle]` + `[num]` | B | Cycle through all patterns every N seconds (for QC sweeps) |

---

## 7. Profiles (per-CRT calibration)

| 7.1 Active profile | `[enum]` | B | Pick from saved list |
| 7.2 Save current as | `[action]` | B | Snapshots color + geometry + sync structure |
| 7.3 Rename | `[text]` | B | |
| 7.4 Delete | `[action]` | B | |
| 7.5 Import / Export | `[action]` | W | JSON file (NovaTool tile-profile pattern) |
| 7.6 Quick recall | `[action]` × 4 | F | Front-panel quick-select buttons can be bound to specific profiles |

---

## 8. Behavior

| 8.1 Signal loss behavior | `[enum]` | B | Black / Freeze / Last-good-frame-for-N-seconds-then-black |
| 8.2 Signal loss timeout | `[num]` | B | Seconds (1–120) |
| 8.3 Burn-in protection | submenu | B | |
| 8.3.1 → Auto-darken trigger | `[num]` | B | After N minutes of static (0 = disabled) |
| 8.3.2 → Pixel-shift trigger | `[num]` | B | After N minutes of static (0 = disabled) |
| 8.3.3 → Pixel-shift amount | `[num]` | B | Pixels of shift |
| 8.4 CRT sync structure (per profile) | submenu | B | |
| 8.4.1 → Front porch | `[num]` | B | 1.0–5.0 µs |
| 8.4.2 → Back porch | `[num]` | B | 3.0–12.0 µs (**default 7.0 µs for 24p camera-shoot profiles** — wider than SMPTE 4.7 µs nominal to give camera shutters a larger target window and avoid visible sync bar on filmed CRT footage) |
| 8.4.3 → Equalizing pulse count | `[num]` | B | Standard 6 / Tweakable per CRT |
| 8.4.4 → Serration pulse width | `[num]` | B | Standard / Wide |
| 8.5 Field cadence behavior (non-matching rates) | `[enum]` | B | Off / Hard switch / Crossfade |
| 8.6 Degauss trigger | `[action]` | B | Pulses GPIO/relay for pro CRTs with remote-degauss input |

---

## 9. Test / Maintenance

| 9.1 Burn-in repair scroll | `[action]` | B | Standalone mode — runs scrolling white/black/gray at front-panel-selected speed, no input required |
| 9.2 Self-test | `[action]` | B | Internal loopback test: TPG → all terminals → INA226 reads stable, lock detector reports green |
| 9.3 Output verification | `[action]` | B | Generates known SMPTE bars on all outputs simultaneously; operator confirms each downstream display matches |
| 9.4 Factory reset | `[action]` | B | Confirms via dialog before wiping |

---

## 10. System

| 10.1 Network | submenu | B | |
| 10.1.1 → Mode | `[enum]` | B | DHCP / Static |
| 10.1.2 → Static config | `[text]` | B | IP / Netmask / Gateway / DNS |
| 10.1.3 → Hostname | `[text]` | B | Used for mDNS (`schindler-<name>.local`) |
| 10.2 WiFi | submenu | B | |
| 10.2.1 → AP mode | `[toggle]` | B | Default on |
| 10.2.2 → AP SSID | `[text]` | B | Default: `Schindler-<serial>` |
| 10.2.3 → AP password | `[text]` | B | Generated unique per unit, displayable on front panel for pairing |
| 10.2.4 → STA mode | `[toggle]` | B | Default off |
| 10.2.5 → STA SSID list | `[action]` | B | Scan + select; multiple saved networks |
| 10.2.6 → STA password | `[text]` | B | |
| 10.2.7 → BLE pairing | `[action]` | B | Enter pairing mode for companion-app credential push |
| 10.3 Firmware | submenu | B | |
| 10.3.1 → Current version | `[ro]` | B | Bitstream + PetaLinux + UI MCU + RP2040 versions |
| 10.3.2 → Check for updates | `[action]` | W | Web only |
| 10.3.3 → Upload firmware | `[action]` | W | Web only — .img file |
| 10.3.4 → Update via USB | `[action]` | F | Insert USB stick with firmware bundle |
| 10.3.5 → Rollback to previous | `[action]` | B | A/B firmware slots |
| 10.3.6 → Reboot | `[action]` | B | Confirms first |
| 10.4 Time / Date | submenu | B | |
| 10.4.1 → NTP server | `[text]` | B | Default `pool.ntp.org` |
| 10.4.2 → Timezone | `[enum]` | B | |
| 10.4.3 → Manual set | `[text]` | B | |
| 10.5 System info | `[ro]` | B | Serial number, hardware rev, uptime, temperatures, voltage rail readings from INA226 + on-SOM monitors, fan RPM |
| 10.6 Diagnostic logs | `[action]` | B | View / download last N lines of system log |
| 10.7 Status LED brightness | `[num]` | B | 0–100 %, default 10 % |

---

## 11. Compliance / Consent

Centralized place for legal-posture toggles. Mostly the HDCP override gate.

| 11.1 HDMI passthrough HDCP override | `[toggle]` + consent flow | B | Toggling on opens an attestation dialog: *"I attest that my use of the HDMI passthrough output for HDCP-protected source material is a non-violating use under applicable law and licensing. I accept responsibility for compliance with content licensing terms."* User must check the attestation box and press a hardware button (front panel: Confirm; web: type "I AGREE") to enable. Once enabled, persists for the session; auto-disables on power cycle by default (configurable). |
| 11.2 Persistence | `[enum]` | B | Per-session / Persist across power cycles / Persist until manually disabled |
| 11.3 Override history | `[ro]` | W | Timestamp log of when override was toggled, by whom (web UI auth user), for audit |
| 11.4 Service mode | `[action]` | B | Locks all outputs to test patterns + disables HDCP override toggle entirely (for shipping / loaner state) |

---

## Navigation patterns

### Front panel (TFT + encoders + buttons)

- **Encoder A** (left): scrolls within current menu level.
- **Encoder A press:** enters submenu / selects item.
- **Encoder B** (right): adjusts the focused setting (numeric / enum tick).
- **Encoder B press:** confirms current value / closes.
- **Home button:** jumps back to root status screen.
- **Back button:** one level up.
- **Menu button:** toggles between status overview and main menu.
- **Confirm button:** alternate confirm path for dialogs (especially HDCP consent).
- **Quick-select buttons (2–3):** bindable to common actions — defaults: Output Mode toggle, Profile recall, Genlock source.

### Web UI (Node.js on Zynq PS)

- Same hierarchy presented as a left-rail tree + main panel.
- Live preview region: small thumbnail of each output (driven by HDMI passthrough or composite captured back via internal loopback).
- Drag-handles for color matrix, geometry warp, 4-corner.
- File upload widgets for EDID / LUT / Profile import.
- Real-time charts for genlock quality metric, INA226 power draw.

### Rear LCD (read-only)

Status grid only — no menu. Auto-refreshes every 1 s. See `01-spec.md` Rear panel — status display section for content layout.

---

## Open UI questions

- **Menu depth on the front panel.** The current hierarchy is up to 3 levels deep (1.5.1 etc.). At 36-detent encoders this is navigable but verbose. Consider flattening Inputs / Outputs into a more grid-like "card per port" view on the front-panel TFT, while keeping the strict hierarchy on web.
- **Profile autoload behavior.** Should connecting a known CRT (identified by EDID or measured colorimetry) auto-load its profile? Or always start with the last-active profile?
- **Quick-select button defaults.** Three buttons, three defaults. Output Mode toggle + Profile recall + Genlock source is a reasonable starting set; revisit after operator testing.
- **HDCP consent persistence — power-cycle default.** Auto-disable on power cycle is defensive (safer default). Some operators may want persist-across-restart for legitimate sustained workflows (a long shoot day). Default to auto-disable; let the operator opt-in to persistence after first attestation.
- **Front-panel TFT vs LTDC parallel decision.** Currently spec says ILI9341 SPI for prototyping → LTDC parallel for production polish. Front-panel menu depth (this doc) supports either; LTDC parallel just renders faster. Confirm bench finds the SPI ILI9341 prototype path adequate before committing carrier traces to the parallel bus.

---

## Cross-references

- Architecture + decision history: [`01-spec.md`](01-spec.md) + [`01-spec-changelog.md`](01-spec-changelog.md)
- Signal flow + per-output terminal encoders: [`signal-flow.md`](signal-flow.md)
- Physical panel layout (what each connector is + where the LEDs are): [`panel-layout.md`](panel-layout.md)
- BOM mapping: [`bom-v1.md`](bom-v1.md)
