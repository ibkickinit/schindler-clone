# V0a Scope Fence — V0b and V0c are post-v1

**Decision:** the V0a control-plane shipped 2026-05-31 is the production control surface for v1. V0b (PetaLinux on Zynq PS) and V0c (RP2040 front panel with EVE TFT) are explicitly deferred to post-v1.

Source of decision: 2026-05-31 PM Trajectory re-audit flagged V0a sequel scope creep as the standing WATCH. This doc codifies the answer so future agents don't sneak V0b/V0c into v1 conversations.

## Why V0a is enough for v1

- Catalog v0.2.0 covers every operator-tunable knob on the production substrate (`iter5-1080p-clean`): color stack, scaler kernel modes, status read-outs.
- Browser UI on `http://localhost:8080` is the operator surface. Localhost binding is acceptable because the v1 ship customer plugs the bench host directly into the operator's laptop or KVM.
- Profile save/load (user + factory) gives operators preset recall — the customer-facing equivalent of front-panel "scenes" without the front panel.
- Bench-host dependency is OK for v1. The customer is renting a configured rig, not building one from parts.

## What v1 explicitly does NOT promise

- PetaLinux running on the Zynq PS (V0b).
- RP2040 front-panel firmware (V0c).
- EVE BT817Q TFT driver.
- Pro v2 mezzanine PCB.
- Cross-platform web UI (mobile, tablet) — desktop browser only.
- Companion module / OSC bridge / SDP-bridge.
- TLS / auth on the daemon (acceptable today because localhost-only; becomes a release-gate the moment we bind anything other than 127.0.0.1).

## Why the fence

PM Trajectory re-audit verbatim (2026-05-31):

> V0a opens the door to web UI / RP2040 front-panel work — is that on the critical path or scope creep? […] Recommendation: **freeze V0a at current scope, defer V0b/V0c to v2.** Don't let RP2040 + EVE + PCB design enter v1 conversation.

The risk isn't that V0b/V0c are bad ideas. They're the right next layer once v1 ships. The risk is that they're each multi-week tracks with hardware dependencies (PetaLinux build + boot, PCB layout, firmware bring-up, TFT driver, dual-CPU coordination) and any one of them, if treated as v1, eclipses the actual v1 ship list:

1. Matrix Phase 2 verification (~10 bench hours).
2. Phase G NTSC bring-up (chip ETA pending).
3. Optional TE0720 verification pass for the 1080p60-OUT column.

That's the v1 critical path. Everything else is post-ship.

## What v1+ work IS in scope

These post-v1 items are valid because they finish v1 commitments, not because they expand v1 scope:

- **Catalog v0.2.x patches** — bug fixes, range corrections, unit relabels (no schema break).
- **Daemon hardening** — multi-client throttle, better profile validation, status push for boot-only fields (the 2026-05-31 firmware periodic re-emit already mostly closed this).
- **Test harness extensions** — `make sim` headless TB runner (Test Methodology investment #2), Playwright web UI smoke (#3+).
- **Documentation completeness** — the wiki round-out items still owed (ARCHITECTURE diagram V0a sidecar, GLOSSARY new terms, HISTORICAL-NARRATIVE entry).

## Reopening the fence

Any of the following triggers a documented reopening:

- v1 ship + at least one rented engagement closes successfully.
- A customer specifically asks for the front panel (push from market signal, not technical interest).
- The TE0720 production-silicon path is verified and we're ready to ship a non-Zybo carrier.

Until then: V0a is the control surface; V0b and V0c are scheduled for "after v1 ships."

## Cross-links

- [`control-plane-architecture.md`](control-plane-architecture.md) §V0a / V0b / V0c
- [`build-manifest.md`](build-manifest.md) §"2026-05-31 — V0a control plane"
- [`format-support-matrix.md`](format-support-matrix.md) §"v1 Ship List"
- [`matrix-scope-cut-v1.md`](matrix-scope-cut-v1.md)
- [`docs/wiki/CONTROL-PLANE.md`](wiki/CONTROL-PLANE.md)
