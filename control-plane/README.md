# control-plane/

Production control-plane assets — the catalog + daemon + future web UI scaffold per `docs/control-plane-architecture.md`.

This directory is the **V0a buildout** of the control-plane stack: the JSON catalog of all operator-tunable controls + the daemon that exposes them over JSON-RPC. The catalog is the single source of truth that the daemon, web UI, and future RP2040 firmware all generate code from.

## Files

| File | Purpose | Status |
|---|---|---|
| `catalog-v0.2.0.json` | Inventory of all controls + status fields. | ✅ v0.1.0 shipped 2026-05-31; bumped to v0.2.0 (+2 status fields) |
| `schindlerd/` | Python daemon. Talks UART to bare-metal firmware, exposes JSON-RPC over WebSocket. | ✅ v0.1 skeleton 2026-05-31 |
| `web/` | Single-page browser UI served by schindlerd. No build step. | ✅ v0.1 skeleton 2026-05-31 |
| firmware bridge | `J` UART command in `sw/phase-b/src/main.c`. | ✅ shipped 2026-05-31 |

## Catalog versioning (semver)

- **Patch** bump (0.1.0 → 0.1.1): bug fix in an existing control (range correction, encoding fix, etc.)
- **Minor** bump (0.1.0 → 0.2.0): new control added, new enum value added, default changed
- **Major** bump (0.1.0 → 1.0.0): control removed, id changed, type changed, enum value removed

Daemon advertises its catalog version at WebSocket handshake. Web UI / RP2040 firmware check compat; reject majors they don't understand, tolerate minor mismatches by ignoring unknown controls.

## How agents extend the catalog

1. Add a new entry to the `controls[]` array in the highest-version catalog file.
2. Each entry needs: `id` (dot-namespaced), `title`, `category` (matching one in `categories[]`), `type`, `default`, `surface`, plus type-specific fields (`range`, `options`, etc.).
3. If the control requires a feature not yet shipped, add `requires_iter`, `requires_branch`, or `requires_hw` gating attributes.
4. Bump the version per semver rule above.
5. Commit and push. The daemon re-reads at next restart.

## Why this lives here, not in docs/

The catalog is **executable data** — the daemon parses it at startup and generates client schemas from it. It's not documentation; it's the central schema that everything-else-is-generated-from. Putting it in a top-level `control-plane/` directory makes that clear and keeps it adjacent to the daemon code that consumes it.

`docs/control-plane-architecture.md` is the architectural reference. `control-plane/catalog-v0.2.0.json` is the live artifact.
