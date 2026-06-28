# Warp Geometry Envelope (64-bit DataMover, 2026-06-28)

What corner-pin / rotation / pincushion geometry the warp engine can render **clean (full frame)** on the
shipping **64-bit DataMover** path, the prefetch **lead** each needs, and the recommended **clamps**.
Derived empirically via the auto-tune-lead-on-break harness (scan-all mode, min-of-8 measurement) — see
the `docs/autotune-*.csv` datasets. Scope decision: 64-bit is the shipping target; 128-bit DataMover /
NTILE-512 are the post-ship "more power" lever (see memory `schindler_64bit_ship_scope`).

## Definitions
- **Wall** = NO lead (4096..24576) produces a full frame → unrenderable on this hardware, regardless of
  tuning (flat opix across all leads = throughput-bound, the DataMover's job, not the lead's).
- **Renderable** = at least one lead gives a full frame (most are full at 4096 or 6144).

## 1. Corner-pin envelope (per output resolution)

256-combo sweep = every corner's X/Y at ±range, rot=0, pincushion=0.

| Corner range | 1080p walls | 720p walls |
|---|---|---|
| ±100 | **0%** | — |
| ±150 | 7% (18/256) | — |
| ±200 | 21% (53/256) | **10% (28/256)** |

**Resolution matters:** same ±200px walls **half as often at 720p** (10% vs 21%) — 720p's smaller raster
(921k vs 2.07M px/frame) gives ~2.3× fetch headroom, which beats the bigger fractional offset. So the px
clamp scales with resolution: **720p buys ~1.5× the corner range** of 1080p.

## 2. KEY FINDING — difficulty is RELATIVE (twist), not absolute position

Diagonal-anchor experiment (anchor one diagonal at 0, twist the other to ±200): walls track the
**differential between corners**, not their magnitude.
- Free corners moving **together** (both +200) → **full at 4096**, cheap, even at max magnitude.
- Free corners **opposed** (+200 / −200 = twist/saddle) → **WALL**.

So a **coherent warp** (real keystone/trapezoid correction — corners move in a coordinated way) is cheap
even at large offsets; the walls are **propeller/twist** configs a user is unlikely to dial deliberately.
**The px-box clamp is therefore conservative** (it punishes coherent warps like twists). A **twist-aware
clamp** (limit the opposite-corner anti-symmetric component) would allow more range where it's safe — but
the exact separator has sign/rotational structure (L1 differential alone doesn't cleanly split), so it's a
post-ship refinement, not a v1 item.

## 3. Static lead — retires the per-geometry sweep for corner-pin

Across ±100/±150/±200, **a single static lead of 6144 renders 99% of everything renderable** (deep enough
to clear shallow-lead misses at 4096, shallow enough to dodge deep-lead eviction at 12288+).

**Action:** `warp_calc_lead` should return **6144 when a corner-pin is active**, instead of the deep
~24576 it currently computes (which is what triggers the starve → autotune-sweep → flicker). The on-break
auto-tuner stays as the safety net for the <1% and the edges.

## 4. Rotation
- **Rotation ALONE is clean to 360°** (continuous 1° via per-angle hash LUT).
- **Rotation + heavy (twist) corner-pin walls at ≥30°** (20° narrows) — but that's continuous rotation from
  0° combined with the WORST twist corners, not a realistic use case.
- **CARDINAL ±15° + keystone = FULLY CLEAN (validated 2026-06-28, `autotune-cardinal-bands-1080p.csv`).**
  Every angle in {0,90,180,270}±15° renders full-frame with and without a coherent keystone (top-in 100px).
  Transpose bands (75–105°, 255–285°) are full at lead 4096; exact 0°/180° need 8192 (axis-aligned floor).
  **Recommended rotation spec = cardinal orient (0/90/180/270) + ±15° fine** — covers tilt/leveling +
  portrait/landscape/inverted, stays well inside the 64-bit envelope, and dodges the 30°+ walls and the
  45° resonance entirely. Static **lead 8192** covers the whole cardinal±15°+keystone spec.

## 5. Pincushion
Mild: ±10 narrows the lead window slightly, ±20 recovers; no walls on its own (from the axis sweep).

## Recommended shipping clamps (simple, safe, with margin)
| Control | 1080p | 720p |
|---|---|---|
| Corner-pin (per corner, px) | **±120** | **±180** |
| Rotation | **cardinal 0/90/180/270 + ±15° fine** (validated clean w/ keystone) | same |

| Pincushion | ±100‰ (current) | ±100‰ |
| Prefetch lead (corner-pin) | **6144 static** | 6144 (verify) |

The auto-tuner + OSD remain the safety net: anything past these renders best-effort and flags "near BW wall".

## Datasets
- `autotune-corners-100pct.csv` / `-150pct` / `-200pct` — 1080p corner sweeps
- `autotune-corners-200pct-720p.csv` — 720p apples-to-apples
- `autotune-axes-100pct.csv` — zoom/rotation/pincushion from 5 twist offenders (rotation≥30° wall)
- `autotune-diagonal-anchor-1080p.csv` — the relative-vs-absolute (twist) confirmation
- `autotune-corners-100pct.csv` predates the `scale_pct` column; the rest include it.
