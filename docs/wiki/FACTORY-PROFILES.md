# Factory Profiles

Read-only baseline profiles shipped with `schindlerd` in `control-plane/profiles/factory/`. Loadable from the web UI's profile picker the same way user profiles are. V0a+1 shipped 2026-05-31.

## What ships

| Name | Description | Headline values |
|---|---|---|
| `identity` | Pass-through reference. All controls at defaults. | sat=100%, matrix=identity, black=(0,0,0), white=(255,255,255) |
| `grayscale` | Rec.601 luma-mix grayscale via the saturation knob + matrix preset. | sat=0%, matrix.preset=grayscale |
| `warm` | Slight punch (110%) + tungsten-leaning white balance. Pleasing for skin tones. | sat=110%, white=(255, 240, 220) |
| `cool` | Slight punch (110%) + daylight-leaning white balance. Good for outdoor footage. | sat=110%, white=(220, 240, 255) |

All four are bench-validated on iter5-1080p-clean.

## Profile schema (v0.1.0)

```json
{
  "schema": "schindler-profile",
  "schema_version": "0.1.0",
  "catalog_version": "0.2.0",
  "name": "warm",
  "description": "Slightly punchy saturation (110%) with a warm white balance...",
  "factory": true,
  "controls": {
    "color.saturation":         110,
    "color.matrix.preset":      "identity",
    "color.matrix_saturation":  100,
    "color.correct.black_r":    0,
    "color.correct.black_g":    0,
    "color.correct.black_b":    0,
    "color.correct.white_r":    255,
    "color.correct.white_g":    240,
    "color.correct.white_b":    220,
    "scaler.kernel_h":          "boxcar_2tap",
    "scaler.kernel_v":          "boxcar_2tap"
  }
}
```

- `schema` + `schema_version` describe the **profile file format**, separate from the catalog semver.
- `catalog_version` records which catalog the profile was authored against. Daemon best-effort-loads; ids the catalog no longer recognizes are silently skipped with a warning.
- `controls` maps catalog id → value. Enum values are strings (matching the catalog's `options[].value`); numerics are integers (UI percent / raw8 / etc).
- `factory: true` is informational — the read-only-ness comes from filesystem location, not this flag.

## Factory vs user

Two roots, configured at daemon start:

- **User**: `~/.schindler/profiles/` (default). Writable. `profile.save` always lands here.
- **Factory**: `control-plane/profiles/factory/` (default). Read-only by the daemon — `profile.save` never touches it.

`profile.list` returns both, marked with `factory: true/false` per entry. Browser UI shows factory entries with " (factory)" suffix.

**Shadowing rule**: if a user profile and a factory profile have the same name, the user wins on `profile.load`. So you can `save` a profile named `identity` to override the factory `identity` for your bench. Delete the user file (or rename it) to restore factory behavior.

## How to add a factory profile

1. Author `control-plane/profiles/factory/<name>.json` with the schema above.
2. Commit it to the repo — it's part of what ships.
3. Restart `schindlerd` — file list is read fresh.
4. The new entry appears in the UI picker after a reload.

No daemon code change. No catalog change (unless the new profile references a new control id).

## Why these four

The four picks span the most useful operator preset axes:

- **identity** — the regression / "what does the bench look like in pure passthrough" reference.
- **grayscale** — the "make sure color isn't lying to me" mode. Useful for verifying gamma, levels, and crush points without chroma confounding.
- **warm** + **cool** — the two most common subjective biases. Skin-pleasing vs daylight-faithful. Operators recognize these from consumer monitors and will reach for them without needing documentation.

We deliberately did **not** ship a "saturated" / "vivid" or "muted" preset — those map directly onto the saturation slider and offer no insight beyond what the slider gives.

## Open work

- Profile validation against the live catalog: today `profile.load` applies best-effort and reports failed ids. Stricter mode would reject the load if any required id is missing.
- Catalog-version major-mismatch handling. Currently the daemon trusts the profile — a major bump would silently drop incompatible ids. Could surface a warning at load time.
- Per-operator profile library overlay (V0b consideration).

## Cross-links

- [CONTROL-PLANE](CONTROL-PLANE.md)
- [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md)
- [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md)
