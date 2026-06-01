# Next-Session Brief — Schindler 2.0

Written end-of-day 2026-05-31. Read this first thing next time you sit down to work.

## Where things stand

- **Production substrate**: `iter5-1080p-clean` @ `f2e7862`. Bench-clean ✅ (3-boot rule satisfied; multi-bundle audit follow-ups verified).
- **V0a control plane is live** at `http://127.0.0.1:8080` when `schindlerd` is running. Catalog v0.2.0.
- **Tests**: 78 pytest (incl. 8 Playwright web smoke) + `make sim` (Python kernel compare) + `make sim-vivado` (xsim TB). All green.
- **Audit verdicts**: 6/7 PASS. Only HDL stays WATCH because Mackin TB lives on the mackin branch (not on iter5).

## Quick start

```bash
# Pick up where we left off — daemon + browser
/tmp/schindlerd-venv/bin/python control-plane/schindlerd/schindlerd.py -v &
# open http://127.0.0.1:8080

# Or just verify everything still passes
make ci                      # pytest + Python kernel sim
source /tools/Xilinx/2025.2/Vitis/settings64.sh && make sim-vivado   # xsim
make web-smoke               # Playwright (needs daemon running)
```

If picocom fights schindlerd for `/dev/ttyUSB1`: `pkill -f schindlerd.py` then `picocom -b 115200 /dev/ttyUSB1`.

## What's queued (in rough priority order)

### Bench-blocked (need your hands)

1. **Matrix Phase 2 verification** — `docs/format-support-matrix.md` has 20 ⚠️ cells. ~7-10 bench hours, batchable across 4-6 sessions. Each cell: 3 cold boots + record outcome in build-manifest. Largest remaining v1-ship risk after the silicon-blocked column. See `docs/v1-critical-path.md`.
2. **Phase G chip arrival** — ADV7393 replacement on order; no ETA. Resume per `docs/wiki/PHASE-G-ANALOG.md`. Composite color-bars first-light is the unlock.
3. **Si5351 hardware fix + retest** — JESSINIE breakout needs 1 kΩ pull-ups + 0.1 µF cap. Firmware staged at `bb06224` on `phase-g-iter1`. Bench session probably 30-60 min once the hardware is sorted.
4. **Optional: TE0720 1080p60-OUT verify pass** — only if 1080p60-OUT is in v1 scope. ~3-4 bench hours. Skipped if v1 ships at 720p60-OUT only.

### Solo-doable (no bench required)

5. **Branch resync Phases 2 + 3** (task #65) — Phase 1 (`KERNEL_GPIO_INDEX` parameterization) shipped today. Phase 2 = merge iter5 → mackin (~2h + 30 min bench), Phase 3 = merge iter5 → phase-e1 (~3h + 1h bench, also clears LUCKY-BOOT). See `docs/branch-resync-plan.md`. Bench parts are gated by 1–4 above.
6. **iter14 mode 3 polyphase MAC** — HDL design + sim + bench. Catalog already reserves the slot (`reserved` enum value). Substantial work; defer past v1 per scope fence.
7. **Mackin TB regression** — wire `sim-vivado-mackin` once the TB sources live on iter5 (currently mackin-only).
8. **V0a+2 ideas in the queue** — daemon health endpoint, per-client rate limit (not just throttle), catalog hot-reload, profile diff/preview UI. None blocking.

### Strategic decisions for the maintainer

9. **Set a v1 ship-date target.** Critical-path math is now possible: ~10 bench h matrix + Phase G ETA + optional TE0720. See `docs/v1-critical-path.md` §"Open questions for the maintainer".
10. **Is 1080p60-OUT in v1 or v1+?** Determines whether the TE0720 pass is on the critical path.
11. **Pilot vs broader v1 release?** Affects bench coverage depth.

## What ships from today

- `docs/v1-critical-path.md` — the executable plan to ship v1; Method D commitment.
- `docs/v0a-scope-fence.md` — V0b/V0c are post-v1.
- `docs/branch-resync-plan.md` — task #65 mechanical plan with KERNEL_GPIO_INDEX proposal.
- 7 new wiki pages under `docs/wiki/` (CONTROL-PLANE, SCHINDLERD-RUNBOOK, CATALOG-EVOLUTION, STATUS-PANEL, FACTORY-PROFILES, BRANCH-RESYNC-PLAYBOOK, HDMI-COMPLIANCE) plus SCALER-KERNELS closing `AGENT_TASK[docs-15]`.
- `control-plane/` — catalog, daemon, web UI, factory profiles, JSON Schemas for catalog + profile.
- `tests/` — 78 tests with FakeSerial, schema validators, dispatcher, status bus, profile load, auth, and Playwright web smoke.
- `Makefile` — `make help` lists every target.

## Files most worth re-reading next session

1. `docs/v1-critical-path.md` (~140 lines, the strategic plan)
2. `docs/build-manifest.md` 2026-05-31 sections (forensic log)
3. `docs/wiki/START-HERE.md` (state at a glance, refreshed today)
4. `docs/branch-resync-plan.md` if you want to tackle items #5 / #65
5. `docs/wiki/CONTROL-PLANE.md` → `SCHINDLERD-RUNBOOK.md` if you need to operate or debug V0a

## Risks still on the table

- **Risk N1 (V0a auth at non-loopback)** — scaffold landed (`SCHINDLERD_AUTH_TOKEN` env var) and tested. Release-gate when binding 0.0.0.0; today's localhost-only is fine.
- **HDL P1 (axi_gpio_7 slot collision on mackin)** — code-unblocked today via KERNEL_GPIO_INDEX. Now a sibling-branch bench-work item, not a structural blocker.
- **Phase G chip ETA** — external blocker; only material schedule risk.

That's it. Pick #1 next time you're at the bench, or #5/#9–11 next time you're not.
