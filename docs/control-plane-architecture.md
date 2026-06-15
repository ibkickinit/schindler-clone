# Schindler 2.0 — Control-Plane Architecture

**Status:** Draft 2026-05-31
**Scope:** how operator-facing surfaces (web UI, front panel, future remote control) drive HDL state on the FPGA. Defines the protocol stack, schema, persistence model, and versioning.

> ## ⚠️ Direction update — 2026-06-13 (supersedes the PS-hosted-UI model below)
>
> **Committed:** the operator UI is **unified across ALL SKUs** and **hosted on a standalone off-SoM MCU** — not on the Zynq PS. One UI firmware drives **both** the front-panel TFT **and** the web UI, Mini and Pro alike. **Head = ESP32-S3 (locked 2026-06-13).**
>
> **Why:** the Mini can't host PetaLinux the way the Pro can, so a PS/PetaLinux-hosted UI (and a PS-served web app) can't be the universal solution. Rather than fork the UI (Pro = RP2040 panel + PS web; Mini = PS-direct OLED), all SKUs share one off-SoM UI head. This **kills the control-plane fork.**
>
> **What this changes vs. the model documented below:**
> - The **UI authority moves off the PS to the MCU** — catalog + profiles + panel rendering + web serving all live on the MCU.
> - **Control path = ESP32 ↔ UART ↔ PS thin agent ↔ AXI (FINALIZED 2026-06-13).** Both SKUs keep a TE0720, so both have a Zynq PS — the PS stays the register authority (`schindlerd`), as in the original plan. The ESP32 holds UI + catalog + profiles + web and sends operator-intent to the PS over the mezzanine UART; the PS writes the PL's AXI registers. On the **Pro** the agent runs under full PetaLinux (alongside the heavy pipeline + storage); on the **Mini** (a lighter-memory 0720 that won't host full PetaLinux) it runs as a thin/bare-metal agent — same UART contract. *(The earlier 'PS-independent FPGA-fabric AXI-Lite bridge' idea is dropped — it was insurance for a no-PS Mini we're not building. Staying on the 0720 makes the PS path simpler and reuses the original `schindlerd`.)*
> - The **catalog, JSON-RPC/COBS protocol, profile schema, and versioning rules below all still apply** — catalog + profiles + web server + panel UI run on the ESP32; it speaks the protocol to the PS agent over UART, and the PS writes the registers. The protocol shape is unchanged from the original doc.
> - The **web UI is served by the ESP32**, not a PS Node.js server.
> - **Front-panel interconnect (Pro):** the ESP32-S3 sits on the front-panel/mezzanine board with the BT817Q EVE, NHD-2.9 TFT, both EC11 encoders, buttons, and the LED column — all timing-sensitive UI I/O stays local (EVE↔TFT 24-bit parallel RGB never leaves the panel board; ESP32→EVE SPI is on-board; encoders/buttons on ESP32 GPIO). The mezzanine↔carrier link is a single **FFC** (~10-pin) carrying **power + GND + the ESP32↔PS UART (2) + the power-button line + the 2 ESP32 flash-control lines (EN, GPIO0/BOOT) for PS-driven recovery** (see *Firmware / update paths*). UART is cable-trivial, keeping the only fast signal (EVE SPI) on-board. The NHD-2.9's own FFC tail is the panel-board↔glass connection. **Mini:** same ESP32-S3 on the main board, driving the mono OLED directly (I²C) + buttons (GPIO) — identical firmware, EVE/TFT path disabled by SKU gating. WiFi: U.FL ESP32-S3 module → short coax → panel-mount antenna (keep off the front metal — layout item).
>
> **DECIDED 2026-06-13:** head = **ESP32-S3** (integrated WiFi; one chip drives the EVE + serves HTTP/WebSocket + reads encoders/buttons). Control transport = **ESP32 ↔ UART ↔ PS thin agent ↔ AXI** (PS is the register authority). **Mini = a lighter-memory TE0720** (has a PS, runs the thin agent; not full PetaLinux). The **Mini-silicon scope question is closed**: never below a 0720, so §0's one-carrier / same-SoM premise holds — no packaging rewrite for different silicon. **LWB5+ WiFi dropped** — the ESP32 provides WiFi (saves ~$30 + the SDIO routing).
>
> **Firmware / update paths (proposed 2026-06-13):**
> - **PS + FPGA bitstream + PS rootfs:** rear **USB-C → PS** (Zynq USB0, recovery / console / ethernet-gadget) + GbE/WiFi OTA + the §19 JTAG header; boot media = module QSPI/eMMC. The rear USB stays on the carrier/PS — the PS is what most needs a wired recovery path if the network is down.
> - **ESP32-S3 (UI/web/catalog/profiles):** primary = **OTA over its own WiFi** via the web UI it serves (add a firmware page). Recovery = **the PS reflashes it over the mezzanine UART** (ESP32 ROM serial bootloader), driving **EN + GPIO0(BOOT)** across the FFC — so the single rear USB-C is a whole-box recovery path and a bad ESP32 OTA isn't a brick. No dedicated ESP32 USB connector; its native USB → internal test pad only.
> - **Genlock RP2040 (U900):** rarely updated — add a small **SWD or BOOTSEL service header** near U900 (open-box service update), or a resident UART bootloader the PS can drive. Low frequency, not field-critical.
> - **Profiles / catalog data** (not firmware): on ESP32 flash, import/export via the web UI (§8).
>
> **Cascading / propagation (now unblocked):** GbE kept (Pro dev/OTA + Mini network). Into `refdes-map.md` Sheet 10/11 + A2 + BOM: drop the **LWB5+ (U1000)**; A2 mezzanine MCU → **ESP32-S3** (was RP2040); `J1100` FFC pin-count ~6 → ~10 (power + UART + PWR_BTN + EN + GPIO0); add the RP2040 service header. Spec §14/§15/§17 + `packaging-skus.md` get the rewrite to the ESP32-UI + PS-thin-agent model. Sheet 10/11 rework is now small.

## Why this doc exists

Today (bench): an ad-hoc UART command parser in `sw/phase-b/src/main.c` does direct AXI-GPIO writes. `s 100`, `m 50`, `b 0 0 0`, `w 255 255 255`, `a 8000` — one-char dispatch, no schema, no versioning, no introspection.

Production (per `docs/01-spec.md` §14 + `docs/ui-menu.md`): multiple concurrent operator surfaces (Pro front-panel TFT via RP2040 over UART, Mini OLED, Web UI on Linux), persistent JSON profiles, OTA updates, status logging, audit.

The gap: there is no documented schema or protocol library tying those surfaces to the HDL. This doc closes it.

## Three-tier stack

```
┌─────────────────────────┐    ┌─────────────────────────┐
│   Pro v2 front panel    │    │       Web UI            │
│   RP2040 ↔ EVE ↔ TFT   │    │   Browser ↔ Node.js     │
└────────────┬────────────┘    └────────────┬────────────┘
             │                                │
             │ Length-prefixed JSON          │ JSON-RPC over
             │ over UART + COBS framing      │ WebSocket
             │                                │
             └──────────────┬─────────────────┘
                            │
                  ┌─────────▼──────────┐
                  │  schindlerd        │  ← Single source of authority for
                  │  (Python daemon    │     all HDL state. No other process
                  │   on Zynq PS       │     touches the AXI registers.
                  │   PetaLinux)       │
                  └─────────┬──────────┘
                            │ mmap of UIO devices
                            │ ↓ direct register writes
                  ┌─────────▼──────────┐
                  │  AXI peripherals   │
                  │  (GPIOs, VDMA,     │
                  │   VTC, scaler,     │
                  │   color stack)     │
                  └────────────────────┘
```

- **`schindlerd`** is the only process that touches the FPGA. Everything else asks `schindlerd` over its protocol. Eliminates write-after-write races, makes audit logs trivial, makes UIs hot-swappable.
- **Web UI** is a Node.js (or Flask) HTTP+WebSocket server that exposes the daemon to a browser. Stateless toward the daemon.
- **RP2040 front-panel firmware** uses the same JSON catalog over UART. Different transport, same protocol shape.
- **Future remote control surfaces** (SDP-bridge, Companion module, OSC bridge, etc.) plug into the daemon's WebSocket exactly like the web UI.

## The control catalog

Every tunable in the system is declared in a single JSON document — the **control catalog**. The daemon, web UI, and RP2040 firmware all generate code from this catalog so they stay in sync.

### Catalog schema (JSON Schema definition)

```yaml
catalog:
  version: "0.2.0"   # semver; daemon advertises at handshake (current as of 2026-05-31)
  controls:
    - id: color.saturation                  # dot-namespaced key
      title: Saturation
      type: number                          # number | enum | bool | text | trigger
      unit: percent                          # display unit
      range: [0, 200]                       # for numbers
      default: 100
      persistent: true                       # included in profile snapshots
      hdl_address: 0x41200000               # AXI GPIO base
      hdl_encoding: q1_15                   # how the number maps to bits
      surface: [front, web]
      category: color
      tags: [bench, production]
    - id: color.matrix.preset
      title: Color matrix preset
      type: enum
      options:
        - { value: identity,  label: Identity (full color) }
        - { value: rec601_gray, label: Rec.601 grayscale }
        - { value: custom,    label: Custom (drag handles) }
      default: identity
      ...
    - id: scaler.kernel_h
      title: Scaler kernel — H
      type: enum
      options:
        - { value: nn,        label: Nearest neighbor (sharp, drops cols) }
        - { value: 2tap_box,  label: 2-tap boxcar (production) }
        - { value: 4tap_box,  label: 4-tap boxcar (softer) }
      default: 2tap_box
      requires_iter: 14                     # gated until iter14 ships
      ...
    - id: output.mode
      title: Output mode
      type: enum
      options:
        - { value: "720p60",  label: 720p60 }
        - { value: "1080p30", label: 1080p30 }
        - { value: "1080p60", label: 1080p60 (production carrier only) }
      default: "720p60"
      requires_hw: external_phy             # 1080p60 needs external HDMI chip
      ...
    - id: status.s2mm_sr                    # read-only telemetry
      title: S2MM status register
      type: number
      read_only: true
      poll_interval_ms: 100
      hdl_address: 0x40000000
      ...
```

### Required fields per control

- `id`, `title`, `type`, `default`, `persistent`, `surface`, `category`
- `range` / `options` per type
- `hdl_address`, `hdl_encoding` — daemon-only; not exposed to UI clients
- `requires_iter` / `requires_hw` / `requires_sku` — gating attributes that prevent broken controls from appearing on builds that can't honor them

### Versioning rules

- `version` follows semver
- **Patch** bump: bug fix in an existing control (e.g., range correction)
- **Minor** bump: new control added, OR existing control gains an `options` value, OR `default` changes
- **Major** bump: control removed, `id` changed, `type` changed, `options` value removed

Daemon advertises its catalog version at handshake; clients check compat. Web UI / RP2040 firmware reject majors they don't understand; tolerate minor mismatches.

## Daemon ↔ Web UI protocol (WebSocket + JSON-RPC 2.0)

```jsonc
// → from client to daemon
{ "jsonrpc": "2.0", "id": 7, "method": "control.set",
  "params": { "id": "color.saturation", "value": 110 } }

// ← response
{ "jsonrpc": "2.0", "id": 7, "result": { "value": 110, "applied_at": "2026-05-31T12:34:56.789Z" } }

// ← push (server-initiated, no id)
{ "jsonrpc": "2.0", "method": "status.update",
  "params": { "id": "status.s2mm_sr", "value": 0x11100 } }
```

### Methods

- `catalog.get(version?)` — fetch full catalog (optional version filter)
- `control.get(id)` / `control.set(id, value)` — single control
- `control.batch_set([{id, value}, ...])` — atomic group (one profile recall)
- `profile.list()` / `profile.save(name)` / `profile.load(name)` / `profile.delete(name)`
- `system.identify()` — model, serial, firmware version, catalog version
- `subscribe(ids[])` — opt into push for those control IDs

### Push channel

Telemetry (`status.*` controls) and async events (alarms, source-change notifications) come over the same WebSocket as pushes. UI clients subscribe to whatever they need; status bar subscribes to source/sync/profile; deep diagnostics page subscribes to telemetry.

## Daemon ↔ RP2040 (front panel) protocol

Same JSON message shape. Different transport:

- UART at 921600 8N1 (or higher; up to PS UART capability)
- **COBS** framing (Consistent Overhead Byte Stuffing) — zero byte = packet boundary; no escape sequences in payload
- Each frame: 1-byte type + 1-byte seq + 2-byte length-LE + JSON-or-binary payload + 0x00 terminator
- Types: `0x01` request, `0x02` response, `0x03` status-push, `0x04` log

The RP2040 only needs to handle the subset of controls that map to the front-panel UI hierarchy. The catalog's `surface` attribute filters: only entries with `front` or both surfaces. The same JSON schema validates on both sides.

## Daemon ↔ HDL (UIO + memory-mapped AXI)

PetaLinux exposes each AXI peripheral as a UIO device (`/dev/uio0`, `/dev/uio1`, ...) when the device tree is configured. The daemon mmaps each one and writes/reads registers directly. No kernel-mode driver needed for the slow control path; UIO is sufficient.

For the high-bandwidth telemetry (DDR3 frame buffer dumps, ILA streaming if added later), separate fast-path mechanisms apply — out of scope for v0.

## Profile format

JSON file, catalog-version-stamped, signed checksum:

```jsonc
{
  "schema": "schindler-profile",
  "schema_version": "0.1.0",         // profile-format schema (separate semver)
  "catalog_version": "0.2.0",       // catalog this profile was authored against
  "name": "BVM-D24",
  "created_at": "2026-05-31T08:00:00Z",
  "controls": {
    "color.saturation": 100,
    "color.matrix.preset": "rec601_gray",
    "output.mode": "720p60",
    ...
  },
  "checksum": "sha256:abc...def"
}
```

On load: validate against current catalog. Missing keys → use current default + warn. Extra keys (forward compat from a newer profile) → ignore + warn. Range violations → reject with operator-actionable error.

Profiles live in `/var/lib/schindler/profiles/<name>.json`. Importable via web UI drag-drop; exportable to USB via front panel.

## Persistence: where state lives

| Layer | What persists | Storage |
|---|---|---|
| Catalog | Read-only build artifact | `/opt/schindler/catalog.json` (shipped with firmware) |
| Active profile | Current `control.set` state | RAM-only by default; written to flash via explicit "Save" |
| Profile library | All named profiles | `/var/lib/schindler/profiles/` on eMMC |
| Telemetry / logs | Rolling history | `/var/log/schindler/` on eMMC, rotated |
| Hardware identity | Model, serial, calibration | `/etc/schindler/identity.json` (provisioned at factory) |

Default-on-boot behavior: load profile named in `/etc/schindler/default_profile` if present; otherwise apply catalog defaults.

## Audit + logging

Every `control.set` (and every `profile.load`) emits a structured log line:

```jsonc
{ "ts": "2026-05-31T12:34:56.789Z", "actor": "web:192.168.1.50",
  "method": "control.set", "id": "color.saturation",
  "old": 100, "new": 110 }
```

Audit lives in the same `/var/log/schindler/` directory; tail-able over SSH; rotated weekly.

## V0 minimum-viable build

The protocol can be developed and tested on the **current Zybo dev environment** before PetaLinux exists. Phased rollout:

### V0a — host-side bridge daemon (no PetaLinux required)

- Python `schindlerd` runs on the dev host (the laptop driving xsct)
- Talks UART over `/dev/ttyUSB1` to the existing bare-metal firmware
- Firmware adds a minimal JSON-RPC-over-UART command (one new `J` UART command that brackets a JSON payload)
- Catalog v0.2.0 covers current bench controls: `color.saturation`, `color.matrix.preset`, `color.correct.black_r/g/b`, `color.correct.white_r/g/b`, `scaler.kernel_h/_v`, plus status fields. (`frc.mackin_alpha` is declared but gated `requires_branch: mackin-impl-wip`.)
- Web UI is a single-page React/Vue app served by the daemon at `http://localhost:8080`
- Profiles persist on host filesystem
- Audit log lines to stdout / journald

**What this gives:** real protocol exercised end-to-end. UI engineers can build screens. Operators can save/load profiles. Logging works. No FPGA changes beyond the new UART command.

### V0b — PetaLinux on Zybo (intermediate)

- Boot PetaLinux on the Zybo PS (Cortex-A9 already idle alongside bare-metal in current config)
- Move `schindlerd` from host to Zybo PS user space
- Same protocol, same web UI; just hosted on the FPGA instead of the laptop
- Network reachable at `http://schindler-bench.local`
- Validates everything the production path needs except the front-panel MCU

### V0c — RP2040 front panel (Pro SKU dev)

- Build RP2040 firmware that speaks the protocol over UART to Zybo PS
- Add EVE BT817Q driver
- Build front-panel hierarchy from the catalog
- Cross-check that web + front-panel both render the same control set and stay in sync

## What's holding up V0a — *nothing serious*

V0a can be built **today** with what's in tree. Specifically:

| Need | Status | Effort |
|---|---|---|
| Firmware `J` UART command for JSON-RPC | not built | ~2 hours — extend existing `uart_poll_and_dispatch` |
| Catalog file (v0.2.0) covering current bench controls | ✅ shipped 2026-05-31 | `control-plane/catalog-v0.2.0.json` |
| Python `schindlerd` skeleton | not built | ~4 hours — UART transport + JSON-RPC dispatcher + WebSocket relay |
| Web UI scaffold (React/Vue) | not built | ~1 day for a minimal control panel (sliders, dropdowns, profile picker) |
| Profile save/load infra | not built | ~2 hours — JSON file read/write + validate against catalog |

**Total V0a effort: ~2-3 days of focused work.** Most of it parallelizable with current bench work.

## What's holding up V0b

- **PetaLinux build infrastructure not set up.** ~1 day to add `tcl/build_petalinux.tcl` (or move to Yocto, depending on Justin's preference). Requires Xilinx Vitis Linux tooling stack, which is in the same install as Vivado/Vitis already on disk.
- **Device tree changes** to expose AXI GPIOs / VDMA / VTC as UIO devices. ~1 hour.
- **Network bring-up** on Zybo. Memory `zybo_z7_clk125_phy` documents the 125 MHz refclk for the Ethernet PHY — should already work in PetaLinux's reference BSP.

V0b is realistic ~1 week effort once V0a is working.

## What's holding up V0c (front-panel RP2040)

- **Hardware:** Pro v2 mezzanine PCB doesn't exist. RP2040 + BT817Q + NHD-2.9 TFT need to be on a carrier. ~3-4 weeks PCB design + fab + assembly.
- **Firmware:** no RP2040 code in tree at all.

V0c is a separate hardware track. Not a v0 prerequisite for V0a/V0b control plane work.

## Open design questions for early review

1. **JSON-RPC 2.0 vs custom envelope?** JSON-RPC is standard and well-tooled. The only friction is that it's optimized for request-response — for status push we'd use the no-id variant ("notification"). Acceptable.

2. **Catalog hot-reload?** If the daemon re-reads `catalog.json` while running, clients need a notification to re-sync. Recommend: catalog is fixed at daemon start; firmware updates restart the daemon. Simpler.

3. **Auth model?** Web UI on a LAN: nobody assumes you have it. Add basic auth + TLS via reverse proxy when shipping. RP2040 over UART: physical access = trust. Not for v0.

4. **Audit retention.** Default: 30 days of rotated logs, ~50 MB cap. Operator-actionable knob in catalog?

5. **Profile vs preset distinction.** Per `01-spec.md` §278, profiles are NovaTool-pattern. Spec doesn't clarify whether "factory preset" is a separate concept from "user profile" — recommend: presets are profiles shipped as read-only in firmware.

6. **HDL discoverability.** Should the daemon read AXI ID registers from each peripheral at boot and validate they match the catalog? Catches firmware/HDL version skew at startup instead of at first wrong write.

## Related docs

- `docs/01-spec.md` §14 (Networking + control plane), §278 (Profiles)
- `docs/ui-menu.md` (operator-facing UI hierarchy)
- `docs/packaging-skus.md` (Mini vs Pro SKU differences)
- `docs/wiki/COLOR-PIPELINE.md` (current bench controls + AXI GPIO map)
- `docs/wiki/FIRMWARE-INTERFACE.md` (current UART command parser)

## Recommended next steps

1. **Author catalog v0.1.0** from current bench controls — ✅ shipped 2026-05-31, bumped to v0.2.0 same day with two new DIAG-derived status fields.
2. **Build V0a** — the host-side Python daemon + minimal web UI + JSON-over-UART firmware bridge. ~2-3 days.
3. **Bench-verify** parity between web UI and current UART commands.
4. **Iterate catalog** as iter14 + Phase E2 land — every new control = one catalog entry.
5. **Boot PetaLinux** on Zybo PS (V0b transition) when convenient — moves the same daemon to the target hardware.
6. **Pro v2 mezzanine PCB** when ready — V0c becomes feasible.
