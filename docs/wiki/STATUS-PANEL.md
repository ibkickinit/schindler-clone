# Status Panel

How the read-only "Status" section in the web UI is wired. V0a+1 shipped 2026-05-31.

For framing see [CONTROL-PLANE](CONTROL-PLANE.md). For client extension see [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md).

## The pipeline

```
firmware DIAG/TELEMETRY/VTC_RX lines (text, over UART)
   │
   ▼
UartBridge.text_log_handler  (asyncio bridge from worker thread)
   │
   ▼
TelemetryParser.feed(line)  (regex match → typed value)
   │  dedup against last value
   ▼
StatusBus.publish({jsonrpc, method: "status.update", params: {id, value}})
   │  fan-out to all subscribed WS clients
   ▼
ws_handler drain task → ws.send(...) → browser
   │
   ▼
handleStatusUpdate(params) → controlRows[id].value.textContent = formatValue(...)
```

## What fields are wired today

| Catalog id | Source | Refresh |
|---|---|---|
| `status.s2mm_sr` | DIAG line `S2MM_SR=0x...` | every 1s (firmware DIAG cadence) |
| `status.mm2s_sr` | DIAG line `MM2S_SR=0x...` | every 1s |
| `status.source_lock` | DIAG line presence + "VTC_RX: dvi2rgb pLocked stable" | every 1s + once at boot |
| `status.source_rate_hz` | DIAG line `src=N` field | every 1s |
| `status.output_rate_hz` | DIAG line `out=N` field | every 1s |
| `status.source_format` | "VTC_RX: HACTIVE=W VACTIVE=H" line (one-shot at boot) | once |
| `status.output_format` | "VTC: configuring 720p60" / similar (one-shot at boot) | once |

`source_format` and `output_format` are caught only if the daemon is running when the board boots. V0a+2 will add periodic re-emit to the firmware.

## Snapshot replay on connect

When a new WS client connects, the daemon replays the last-known value of every status field it has seen. This means a browser refresh doesn't have to wait up to 1 s for the next DIAG line — the panel populates immediately.

## Dedup

`TelemetryParser._update(id, value)` keeps a `last` dict and only publishes on change. A DIAG line where `S2MM_SR` hasn't moved triggers zero broadcasts. This keeps the WS chatter proportional to actual register activity, not the DIAG cadence.

## Adding a new status field

1. Add the catalog entry (`type: number`/`text`/`boolean`, `read_only: true`, `category: "status"`, `surface: ["web"]` or `["front", "web"]`).
2. Extend a regex in `TelemetryParser`: either add a capture group to an existing one or write a new `RE_*` and handler.
3. Call `self._update(id, value)` on match.
4. Restart daemon, reload UI — new row appears in the Status section, ticking live.

No firmware change needed if the data is already in an existing DIAG/TELEMETRY line. If you want a new source, add a `xil_printf("FOO: bar=%d\r\n", val)` in the firmware main loop and write a `RE_FOO` for it.

## Why text-line parsing rather than firmware J calls

Two reasons:

1. **Free**: the firmware already prints these lines for human bench debugging. Parsing them costs us nothing on the firmware side.
2. **Push, not poll**: the daemon would otherwise have to poll the firmware for every status field every N ms, multiplying UART traffic. Text-line parsing is push by default.

The trade-off is that the regex set is **fragile against firmware print format drift**. If somebody reformats a DIAG line, status fields silently degrade. The pytest harness (task #69) is the mitigation: captured DIAG strings get checked into tests, so format drift is caught at PR time.

## Open work

- Multi-client throttle: the bus fan-out is unbounded. If a slow client falls behind, its asyncio queue fills (capped at 64) and events drop. Acceptable today (single browser); needs a per-client rate-limit or backpressure model when the client count grows.
- Telemetry parser test coverage: as of 2026-05-31 the regexes have no automated test. Task #69 (FakeSerial + pytest) closes this.
- Periodic re-emit of one-shot lines from firmware so `source_format`/`output_format` self-heal across daemon restarts.

## Cross-links

- [CONTROL-PLANE](CONTROL-PLANE.md)
- [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md)
- [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md) — what the firmware prints over UART
- [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md) — operating the daemon
