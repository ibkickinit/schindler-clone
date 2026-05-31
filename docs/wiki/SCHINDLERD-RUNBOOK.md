# schindlerd Runbook

How to install, run, and troubleshoot the V0a control-plane daemon. Audience: anyone operating a Schindler bench — not just Claude.

For architectural context see [CONTROL-PLANE](CONTROL-PLANE.md). This page is operator-facing.

## What schindlerd is

A Python daemon that bridges the bare-metal firmware over `/dev/ttyUSB1` (UART) and the web UI / future clients over WebSocket on `:8081`. Also serves the web UI static files on HTTP `:8080`. Single file: [`control-plane/schindlerd/schindlerd.py`](../../control-plane/schindlerd/schindlerd.py).

## Install (one-time)

```bash
python3 -m venv /tmp/schindlerd-venv
/tmp/schindlerd-venv/bin/pip install pyserial websockets
```

Requires Python ≥ 3.9. `pyserial >= 3.5`, `websockets >= 12.0`.

Bench host needs the user to be in the `dialout` group for `/dev/ttyUSB1` access (standard udev rule on most distros).

## Run

```bash
cd /home/justin/Dropbox/_PROJECTS/Schindler-2.0
/tmp/schindlerd-venv/bin/python control-plane/schindlerd/schindlerd.py -v
```

Useful flags:
- `-v` once → INFO logging; `-v -v` → DEBUG (includes mirrored firmware text lines and outgoing WS frames).
- `--port /dev/ttyUSB2` — override UART device.
- `--catalog /path/to/catalog-v0.X.Y.json` — override catalog (default: next-to-daemon).
- `--profiles ~/.schindler/profiles` — override user profile dir.
- `--http-port 9000 --ws-port 9001` — override ports.
- `--host 0.0.0.0` — bind all interfaces (**don't** without TLS+auth — see release-gate risk N1).

## Then open

[http://127.0.0.1:8080](http://127.0.0.1:8080) in any modern browser. The UI auto-reconnects on daemon restart with a 2 s backoff.

## Stop

`Ctrl-C` in the terminal, or `pkill -f schindlerd.py`. Daemon releases `/dev/ttyUSB1` on exit.

## Troubleshooting

### "device reports readiness to read but returned no data"

Something else has `/dev/ttyUSB1` open. Almost always picocom from a manual debug session.

```bash
fuser /dev/ttyUSB1   # find the holder
```

Close it (`Ctrl-A Ctrl-X` in picocom) and restart the daemon. The daemon and picocom are mutually exclusive on the same UART.

### "ws: client connected" but the UI shows dashes everywhere

The firmware J handler isn't responding. Two likely causes:

1. **Wrong firmware.** Only iter5-1080p-clean and successors include the J handler. Verify with `?` over picocom: the help text must include `J <json>` at the bottom.
2. **UART speed mismatch.** Default is 115200 8N1. Override with `--baud N`.

### Browser shows "disconnected" indefinitely

Daemon isn't listening. Check `ss -tlnp | grep :8081`. If empty, daemon crashed or the websockets package failed to bind. Look at the daemon's stdout / `-v -v` log.

### Sliders fire 100 times during drag and stall

UI bug — should be fixed by the per-control coalescing in commit `3d393c6`. If you see it, you're on an old `web/index.html`. Hard-reload (Ctrl-Shift-R).

### Status panel shows dashes (`—`) for source format / output format

These are populated from boot-only firmware lines (`VTC_RX:` and `VTC: configuring...`). If the daemon started after the firmware boot, it missed them. Fix: power-cycle the board with the daemon already running, or restart the daemon and re-program the board. V0a+2 will add periodic re-emit from the firmware to make this self-healing.

### Profile save / load 404s

Check `~/.schindler/profiles/` exists. Daemon creates it on first start; if writing failed, look for permission errors in the daemon log. Factory profiles live in `control-plane/profiles/factory/` and are read-only.

## Smoke testing without the daemon

`control-plane/schindlerd/jsmoke.py` exercises the firmware `J` command directly over UART. Useful when isolating "is this a daemon bug or a firmware bug":

```bash
/tmp/schindlerd-venv/bin/python control-plane/schindlerd/jsmoke.py
```

9 happy-path + 2 error-path checks. Exits 0 on full pass.

## Port summary

| Port | Protocol | Purpose |
|---|---|---|
| `/dev/ttyUSB1` | UART 115200 8N1 | bare-metal firmware UART (PS UART1 on Zybo) |
| `127.0.0.1:8080` | HTTP | web UI static files |
| `127.0.0.1:8081` | WebSocket + JSON-RPC 2.0 | client API |

## Cross-links

- [CONTROL-PLANE](CONTROL-PLANE.md) — what schindlerd fits into
- [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md) — how to extend
- [STATUS-PANEL](STATUS-PANEL.md) — what the UI's status section actually shows
- [BUILD-AND-PROGRAM](BUILD-AND-PROGRAM.md) — getting a firmware on the board that speaks the J command
