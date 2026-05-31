# control-plane/web/

V0a single-page browser UI for the Schindler 2.0 control plane. No build step — single `index.html` with inline CSS + vanilla JS, served by `schindlerd` on port 8080.

## How it works

1. Browser loads `index.html` from `http://127.0.0.1:8080/` (served by schindlerd's stdlib HTTP).
2. JS opens `ws://127.0.0.1:8081/` (schindlerd's WebSocket).
3. Calls `system.identify` then `system.catalog` to fetch the live catalog v0.1.0.
4. Renders one section per category, one row per control with `surface` containing `"web"`.
5. Slider/select changes fire `control.set` immediately; the response's echoed `value` becomes the readback display.
6. Status bar shows connection state; auto-reconnects on close with a 2 s backoff.

## Profile picker

- **Snapshot current →** captures the current state of every settable control to a named profile file (`~/.schindler/profiles/<name>.json`).
- **Load** applies the selected profile (best-effort per control; logs any failures).
- **Save…** overwrites the selected profile with the current state (with confirm).

## What the UI does *not* do (yet)

- No status push — read-only controls show `—` until the next `control.get` poll (manual via reload for now).
- No multi-client coordination — if two browsers are open, the second won't see the first's changes until it refreshes.
- No catalog version warning if the daemon and UI disagree.

These are V0a+1 follow-ups; the v0.1 scaffold is intentionally minimal.

## To add a new control

1. Add a `controls[]` entry to `catalog-v0.1.0.json` (or the next bumped version).
2. Restart schindlerd.
3. Reload the page. The new control appears automatically — no UI code change needed.

This is the whole point of a catalog-driven UI: HDL/firmware/daemon move together, the UI never has to be hand-edited per control.
