# Control Plane (V0a)

Catalog-driven control surface for Schindler. Operator-tunable knobs and read-only status fields are declared once in a JSON catalog; the daemon, web UI, and (future) RP2040 front-panel firmware all generate their code from the same file. Shipped 2026-05-31.

For the full architectural reference see [`../control-plane-architecture.md`](../control-plane-architecture.md). This page is the wiki entry point.

## Three tiers

```
┌─────────────┐  ┌──────────────┐  ┌──────────────┐
│ Web UI      │  │ RP2040 panel │  │ Other clients│
│ (browser)   │  │ (V0c, later) │  │ (Companion…) │
└──────┬──────┘  └──────┬───────┘  └──────┬───────┘
       │ JSON-RPC over   │ COBS-framed     │
       │ WebSocket :8081 │ JSON over UART  │
       └────────┬────────┴─────────────────┘
                │
         ┌──────┴──────┐
         │ schindlerd  │  Python daemon, loads catalog,
         │  (host)     │  validates coercion at boundary
         └──────┬──────┘
                │ JSON-RPC over UART via 'J' command
                ▼
       ┌────────────────┐
       │ Bare-metal     │  sw/phase-b/src/main.c —
       │ Zynq firmware  │  J handler dispatches to
       │ (PS UART1)     │  per-control set/get fns
       └────────────────┘
```

## What's shipped (V0a)

- **Catalog**: [`../../control-plane/catalog-v0.2.0.json`](../../control-plane/catalog-v0.2.0.json) — 11 writable controls + 7 status fields. Bumped 0.1.0 → 0.2.0 same day with two DIAG-derived status entries.
- **Firmware bridge**: `J <json>` UART command in `sw/phase-b/src/main.c`. Hand-rolled JSON tokenizer (no malloc). Dispatches `system.identify` / `system.list_controls` / `control.get` / `control.set`.
- **Daemon**: [`schindlerd`](../../control-plane/schindlerd/schindlerd.py) — Python, loads catalog, runs UART worker thread, exposes JSON-RPC over WS on `:8081`, serves the web UI on `:8080`. See [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md).
- **Web UI**: [`control-plane/web/index.html`](../../control-plane/web/index.html) — no build step, vanilla JS. Renders one section per catalog category, one row per control with the right widget. See [STATUS-PANEL](STATUS-PANEL.md).
- **Factory profiles**: four shipped (`identity`, `grayscale`, `warm`, `cool`). See [FACTORY-PROFILES](FACTORY-PROFILES.md).

## V0a+1 (also shipped 2026-05-31)

- Live status push: daemon parses firmware DIAG lines + broadcasts `status.update` notifications. UI shows live S2MM/MM2S registers + source/output rate + source lock.
- Catalog version handshake: UI declares its expected catalog version; daemon advertises the live version; mismatch surfaces as a banner.
- Multi-client coordination: every `control.set` is broadcast as `control.changed` to all connected clients so multiple browsers stay in sync.

## V0b (future)

PetaLinux on the Zynq PS so `schindlerd` runs on the board rather than the dev host. Same protocol, just moves the host-side daemon onto the target. No HDL change.

## V0c (future, hardware-dependent)

RP2040-driven Pro front panel with EVE BT817Q TFT. Same catalog, same protocol shape, COBS-framed UART transport. Requires the Pro v2 mezzanine PCB.

## How to add a control

1. Edit [`catalog-v0.2.0.json`](../../control-plane/catalog-v0.2.0.json), add an entry. Mind the semver — see [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md).
2. Add the firmware setter/getter in `sw/phase-b/src/main.c`'s `CP_CONTROLS[]` table.
3. Restart `schindlerd` and reload the web UI. The new row appears automatically — no UI code change needed.

## Related wiki pages

- [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md) — install / run / troubleshoot
- [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md) — semver discipline, gating attributes
- [STATUS-PANEL](STATUS-PANEL.md) — status push protocol
- [FACTORY-PROFILES](FACTORY-PROFILES.md) — what ships, schema, factory vs user
- [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md) — UART command list (now includes `J`)

## Related docs and code

- [`../control-plane-architecture.md`](../control-plane-architecture.md) — architectural reference (308 lines)
- `control-plane/README.md` — directory-level overview
- `control-plane/schindlerd/jsmoke.py` — direct-UART smoke test, no daemon
- `control-plane/schindlerd/boot_capture.py` — short UART capture helper

## Memory cross-links

- [[schindler_uart_commands]] — the pre-V0a UART command parser that the `J` bridge sits alongside
- [[pmod_pin_naming]] — Zybo Pmod naming convention (not V0a-specific but bench-relevant)
