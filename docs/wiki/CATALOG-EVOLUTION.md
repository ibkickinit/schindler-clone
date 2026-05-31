# Catalog Evolution

How to extend the V0a control catalog without breaking deployed clients. Audience: anyone adding a new tunable knob to Schindler.

For the architectural context see [CONTROL-PLANE](CONTROL-PLANE.md). For ops see [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md).

## Where the catalog lives

Single living file: [`control-plane/catalog-v0.2.0.json`](../../control-plane/catalog-v0.2.0.json). When the in-file `schema_version` bumps, the filename bumps too. Convention: filename always tracks the **highest** version that has shipped, and the file represents the current live state. Historical versions can be recovered from git (no `archive/` directory needed for v0.x flux).

## Semver discipline

| Bump | Allowed change | Example |
|---|---|---|
| **Patch** (0.2.0 → 0.2.1) | Bug fix in an existing control: range typo, encoding fix, unit relabel, description rewording. **No behavior change for clients.** | range was `[0, 100]`, actual hardware is `[0, 200]` — correct it. |
| **Minor** (0.2.0 → 0.3.0) | New control added, new enum value added at end of existing list, default value changed. Forward-compatible: old clients ignore new fields. | iter15 lands, add `scaler.kernel_h` mode value `polyphase_4tap`. |
| **Major** (0.2.0 → 1.0.0) | Control removed, control renamed (id changed), control type changed, enum value removed, encoding changed in a non-bug way. **Old clients break.** | rename `color.matrix.preset` → `color.preset`. v1 schema lock. |

Daemon advertises catalog version at the WS handshake; UI checks compat at connect and surfaces a banner on mismatch. Major mismatch = red banner; UI keeps running but warns. Minor mismatch = silent if UI ≤ daemon; yellow banner if UI > daemon.

## How to add a control

### 1. Edit the catalog file

Add an entry to the `controls[]` array:

```json
{
  "id": "color.gamma",
  "title": "Gamma",
  "category": "color",
  "type": "number",
  "unit": "ratio",
  "range": [0.5, 3.0],
  "default": 2.2,
  "persistent": true,
  "surface": ["front", "web"],
  "uart_command": "y <val>",
  "hdl_module": "color_gamma",
  "axi_gpio_register": "axi_gpio_3.ch1 [31:16] (Q4.12)",
  "encoding": "q4_12"
}
```

Required: `id` (dot-namespaced), `title`, `category` (one of the existing `categories[]`), `type` (`number` / `enum` / `boolean` / `trigger` / `text`), `default`, `surface` (`["front"]` / `["web"]` / `["front", "web"]` / `[]` for hidden).

### 2. Bump `schema_version`

Per the table above. Update the filename to match if it bumps. If you're patching, leave the filename alone but bump the in-file `schema_version`. If multiple patches accumulate before a minor bump, that's fine.

### 3. Add the firmware handler

In `sw/phase-b/src/main.c`, the `CP_CONTROLS[]` table at the bottom of the V0a JSON-RPC bridge section. Each entry needs an `int (*set)(int v)` and `int (*get)(int *out)` pair:

```c
static int cp_set_gamma(int v) {
    /* v is Q4.12; firmware-side range check */
    if (v < 0x800 || v > 0x3000) return -2;
    Xil_Out32(AXI_GPIO_3 + 0x00, (Xil_In32(AXI_GPIO_3 + 0x00) & 0x0000FFFFu) | ((u32)v << 16));
    return 0;
}
static int cp_get_gamma(int *o) {
    *o = (int)((Xil_In32(AXI_GPIO_3 + 0x00) >> 16) & 0xFFFF);
    return 0;
}
```

Register it: `{"color.gamma", cp_set_gamma, cp_get_gamma}` in the `CP_CONTROLS[]` array.

### 4. Restart the daemon

```bash
pkill -f schindlerd.py && /tmp/schindlerd-venv/bin/python control-plane/schindlerd/schindlerd.py -v &
```

Daemon re-reads the catalog at startup. Reload the browser. The new slider appears. No web UI code change needed.

## Gating attributes

A control can be declared in the catalog but hidden when the substrate doesn't support it. Three opt-out flags, all optional:

- `requires_iter: 14` — needs a specific iter substrate. Currently informational.
- `requires_branch: "mackin-impl-wip"` — gates against the build's branch. Used today for `frc.mackin_alpha` so it doesn't appear on iter5 builds.
- `requires_hw: "adv7393"` — gates against detected hardware. Used for future Phase G controls.
- `requires_status: "placeholder"` — explicit "wire is fake, hide me". Used today for `frc.mackin_alpha`.

The daemon's `system.catalog` response annotates each entry with `available: true/false` based on these plus the firmware's `system.list_controls` reply. UI skips entries with `available: false`. So a single living catalog can describe controls that exist on some substrates only.

## Categories

Add a new category via the top-level `categories[]` array. Same simple schema: `{id, title, description}`. Categories appear as sections in the UI in `categories[]` order.

## Status entries (read-only)

Status fields use `read_only: true` and live under `category: "status"`. They render with no input widget; values come from `status.update` notifications driven by the daemon's `TelemetryParser`. To add a status field:

1. Catalog entry with `type: number`/`text`/`boolean`, `read_only: true`.
2. Daemon-side: extend `TelemetryParser.RE_*` regexes to capture the firmware text, call `self._update(id, value)` on match.
3. No firmware change needed — the firmware DIAG print is the source.

See [STATUS-PANEL](STATUS-PANEL.md) for the full status push protocol.

## Profile compatibility

Profile files include `catalog_version`. On load, the daemon best-effort-applies all known control ids and skips unknown ones with a warning. A major catalog bump invalidates older profiles — by convention, ship a migration script alongside the bump or document the breaking changes.

## Don'ts

- **Don't bump major casually.** Major bumps break every deployed client. Defer for as long as the bug or rename can be tolerated.
- **Don't change a control's `id`.** Once an id is shipped, it's load-bearing in profile files. Add a new id, deprecate the old, plan removal at next major.
- **Don't put the same firmware register behind two catalog ids.** Aliasing is confusing and breaks the readback-after-set invariant.
- **Don't hard-code the schema_version in code.** It's read from the catalog file at daemon startup — the file is the SSOT.

## Cross-links

- [CONTROL-PLANE](CONTROL-PLANE.md)
- [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md)
- [STATUS-PANEL](STATUS-PANEL.md)
- [FACTORY-PROFILES](FACTORY-PROFILES.md)
- [`../control-plane-architecture.md`](../control-plane-architecture.md) — architectural reference
