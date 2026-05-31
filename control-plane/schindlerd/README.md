# schindlerd

V0a host-side bridge daemon for the Schindler 2.0 control plane. Single-file Python implementation per `docs/control-plane-architecture.md` §V0a.

## What it does

- Loads `control-plane/catalog-v0.1.0.json` and validates control IDs / value coercion at the daemon boundary.
- Opens `/dev/ttyUSB1` and talks to the firmware's `J` UART command (JSON-RPC 2.0 over UART).
- Serves JSON-RPC over WebSocket on `ws://127.0.0.1:8081` for the web UI (and any future remote surface).
- Serves the web UI static files from `control-plane/web/` on `http://127.0.0.1:8080`.
- Stores profiles as JSON files in `~/.schindler/profiles/`.

## Install

```bash
cd control-plane/schindlerd
pip install -r requirements.txt
```

## Run

```bash
python schindlerd.py --port /dev/ttyUSB1 -v
```

Then open http://127.0.0.1:8080 in a browser, or connect a JSON-RPC client to ws://127.0.0.1:8081.

## Methods exposed

| Method | Params | Returns |
|---|---|---|
| `system.identify`      | none | daemon+catalog+firmware versions |
| `system.catalog`       | none | full catalog v0.1.0 JSON |
| `system.list_controls` | none | `[control_id, …]` |
| `control.get`          | `{id}` | `{id, value}` (enum→string translated) |
| `control.set`          | `{id, value}` | `{id, value}` after readback |
| `profile.list`         | none | `[name, …]` |
| `profile.load`         | `{name}` | `{name, applied: [id, …]}` |
| `profile.save`         | `{name, controls?}` | `{name, saved: N}` |

Enum values cross the WS boundary as strings (`"boxcar_2tap"`); the daemon translates to integers (`1`) before talking to firmware.

## Protocol traces

When you turn on `-v -v` logging the daemon prints raw UART traffic. Firmware text-log lines (anything not starting with `{`) are mirrored to debug-level only.

## Limitations (v0.1)

- **No status push** — operator status bar polls via `control.get` until V0a+1.
- **No auth / TLS** — bind to localhost only by default. Reverse proxy when shipping.
- **One serial client at a time** — pyserial doesn't multiplex; daemon is the sole owner of `/dev/ttyUSB1` while running.
- **Profile validation is loose** — `profile.load` applies controls best-effort and skips failures; doesn't reject on catalog version mismatch yet.

## Where to extend

- Status push: add a polling task that reads `status.*` controls every N ms and broadcasts `notification` frames to subscribed WS clients.
- HTTP→WebSocket upgrade on the same port: rip out the stdlib HTTP and use `websockets.serve` with `process_request` to route static files.
- Profile validation: compare `profile.catalog_version` to `catalog.version` and reject majors.
