# schindlerd as a managed service

`schindlerd` used to be launched as a bare `nohup` from whatever session happened to start it —
no health check, no auto-restart, and it died silently across sessions (which caused the
2026-06-29 "UI control does nothing" confusion when an old orphaned copy kept running). It now
runs as a **systemd user service** with auto-restart.

## Install (one time, per machine)

```bash
mkdir -p ~/.config/systemd/user ~/.local/state
install -m 644 control-plane/deploy/schindlerd.service ~/.config/systemd/user/schindlerd.service
systemctl --user daemon-reload
systemctl --user enable --now schindlerd.service
loginctl enable-linger "$USER"        # survive logout / headless reboot
```

The unit uses the venv at `~/.local/share/schindlerd-venv` (pyserial + websockets), runs from
`control-plane/`, owns `/dev/ttyUSB1`, and binds `:8080`/`:8081`. `Restart=on-failure`.

## Operate

```bash
systemctl --user status   schindlerd      # state + recent log lines
systemctl --user restart  schindlerd      # after editing schindlerd.py (picks up new code)
journalctl --user -u schindlerd -f        # follow logs (also appended to ~/.local/state/schindlerd.log)
```

**After editing `schindlerd.py`, `systemctl --user restart schindlerd`** — otherwise the running
daemon keeps the old code (and `system.identify` will report a stale `daemon_version`/method list,
which the web UI now warns about on connect).
