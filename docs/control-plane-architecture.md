# Schindler 2.0 — Control-Plane Architecture

**Status:** Draft 2026-05-31
**Scope:** how operator-facing surfaces (web UI, front panel, future remote control) drive HDL state on the FPGA. Defines the protocol stack, schema, persistence model, and versioning.

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
