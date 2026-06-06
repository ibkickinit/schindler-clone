# Geometric corrections — design scope (pincushion · keystone · warp)

**Status:** design only. All three ride the **`pg_affine` addrgen + `pg_tilecache` fetch** engine
proven feasible by the gate ([[affine-warp-gate-results]], `tools/affine_tilecache_gate.py`). The
engine HDL is **deferred** (owner's call); this doc makes the three corrections shovel-ready so they
drop straight onto the engine when greenlit.

## Shared substrate (why all three are "the same engine")

The read engine walks the OUTPUT raster and, per output pixel `(ox,oy)`, needs a **source coord
`(sx,sy)`** (+ the bilinear fractions). Everything downstream — tile-cache fetch, bilinear sample,
Mackin FRC blend, compose — is identical and already exists. **A correction is *only* a function
`(ox,oy) → (sx,sy)`** (the inverse map: where in the distorted source does this corrected output
pixel come from). So the three corrections are three addrgen variants over one fetch:

| correction | addrgen map | params | per-pixel HW cost |
|---|---|---|---|
| **pincushion/barrel** | radial: `s = c + (1 + k₁r² + k₂r⁴)·d` | k₁, k₂, center | ~4 mults + adds (separable-ish) |
| **keystone** | projective 3×3 homography + divide | 8 (or 2 simple) | matrix + **1 divide** (reciprocal) |
| **warp** | mesh: bilinear-interp a grid of source coords | N×M vertices | cell lookup + bilinear |

Warp is the general case; pincushion and keystone are parametric special cases of it. Build order
(owner): **pincushion → warp → keystone** — pincushion is the simplest math and the cleanest first
proof of the engine.

---

## 1. Pincushion / barrel (radial) — FIRST

### Model
Lens/CRT radial distortion. The read engine inverse-maps the *corrected* output to the *distorted*
source:

```
dx = ox - cx ,  dy = oy - cy                 (offset from distortion center)
r² = (dx² + dy²) / R²                          R² = (W/2)² + (H/2)²  → r∈[0,1] at the corner
f  = 1 + k₁·r² + k₂·r⁴                          radial gain
sx = cx + dx·f ,  sy = cy + dy·f               sample the source farther/closer by f
```

- `k₁ > 0` pushes edges outward → **corrects barrel** (source bows out → straightened).
- `k₁ < 0` pulls edges inward → **corrects pincushion**.
- `k₂` is the higher-order term — usually 0; expose as an "advanced" fine knob.
- One signed slider covers both directions. **k₁=0 ⇒ exact identity (zero regression).**

### Parameter ranges (from the previewer, `tools/pincushion_preview.py`)
Corner displacement `= (W/2)·k₁` (at r=1, ignoring k₂). For 1280-wide output, ±100 px of corner
correction ⇒ `k₁ ≈ ±0.16`. Useful slider: **k₁ ∈ [−0.30, +0.30]** (±192 px corner), default 0,
step ~0.005. Fixed-point: **Q2.14 signed** (range ±2, 0.00006 resolution) — plenty.

### Addrgen (HW, when built)
Not separable (radial), so compute per pixel — but cheap and pipelinable:
`dx², dy²` (2 mults) → `r²` (add + ×1/R² constant) → `r⁴=r²·r²` (1 mult) → `f = 1 + k₁r² + k₂r⁴`
(2 mults + adds) → `sx=cx+dx·f, sy=cy+dy·f` (2 mults). ~7 mults/pixel, all DSP-friendly. Bilinear
fractions = `frac(sx), frac(sy)` (already consumed by the existing lerp).

### Firmware / UI
- Firmware: sends `k₁, k₂, cx, cy` (GPIO, like the geometry slices). No per-frame compute (constants).
- UI (Color/Geometry-adjacent, under Engine 1): **"Lens distortion"** slider (−0.30…+0.30, labelled
  Barrel ↔ Pincushion), an **advanced k₂** fine slider, and optional **center X/Y** for off-axis lenses.

### Validation
`tools/pincushion_preview.py` renders a grid/checkerboard test pattern through the correction → PPM,
and prints corner-displacement metrics, so the math + slider range are dialed before any HDL.

---

## 2. Keystone (projective / perspective)

### Model
Correct trapezoidal (off-axis projector/camera) distortion. A 3×3 homography maps output→source in
homogeneous coords, with a **perspective divide**:

```
[sx']   [h00 h01 h02] [ox]
[sy'] = [h10 h11 h12] [oy]            sx = sx'/w' ,  sy = sy'/w'
[w' ]   [h20 h21  1 ] [ 1]
```

### Control surface (two tiers)
- **Simple (v1):** two sliders — *horizontal keystone* + *vertical keystone* — which set `h20,h21`
  (the perspective terms); the rest stays affine. Covers the common projector tilt case with 2 knobs.
- **Full (later):** **4-corner drag** — the operator drags the 4 output corners; firmware solves the
  4-point homography (8×8 linear solve, done once per change on the Zynq CPU — cheap, not per-frame).

### Addrgen (HW)
Matrix-multiply per pixel (incrementally evaluable along the scan: `sx' += h00`, etc. per step — no
mult in the inner loop) **+ one divide** `sx'/w'`, `sy'/w'`. The divide is the cost: a pipelined
divider or a reciprocal-LUT(`1/w'`)×mult. `w'` varies slowly across a row → reciprocal LUT + a few
Newton steps is feasible. **This is the only correction that needs a divide** — the HW risk item.

### Firmware / UI
- Firmware computes the 9 coeffs (from 2 sliders or 4 corners) once per change; sends them.
- UI: 2 keystone sliders (v1); a 4-corner drag overlay on a preview (later).

---

## 3. Warp (general mesh) — the superset

### Model
An N×M grid (e.g. 9×9) over the output; each vertex stores a source `(sx,sy)`. Per output pixel:
find its grid cell, **bilinear-interpolate** the 4 surrounding vertices' source coords → `(sx,sy)`.
Bicubic for smoothness later. Subsumes pincushion + keystone (bake either into the mesh).

### Addrgen (HW)
Mesh in BRAM (9×9×2×16b = 2.6 Kb — tiny). Per pixel: cell index (from ox,oy / cell size) + the 2D
bilinear of 4 vertices (the lerp we already have, applied to coords not colors). Cheap once the mesh
is loaded. No divide. The complexity is **authoring the mesh** (the UI), not the HW.

### Firmware / UI
- Firmware: holds/loads the mesh (calibration); could derive it from a measured pattern later.
- UI: draggable mesh-grid overlay (the meatiest UI of the three), or load a calibration profile.
- Use cases: complex CRT geometry, lens profiles, projection mapping.

---

## Build order & incremental cost (when HDL is greenlit)

1. **`pg_affine` + `pg_tilecache` engine** (the deferred big rebuild — prerequisite for ALL three).
2. **Pincushion** — addrgen radial map + 1–2 GPIO coeffs + UI slider. Cleanest first proof. Small.
3. **Warp** — mesh BRAM + 2D-bilinear addrgen + mesh-editor UI. Medium (UI-heavy).
4. **Keystone** — homography addrgen + **the divide** (reciprocal-LUT) + corner-solve firmware.
   Sequenced last because the divide is the one new HW risk; or do the 2-slider subset early (no
   full divide if constrained).

Each correction after the engine is incremental (one addrgen variant); the fetch/bilinear/FRC/compose
tail is shared and done.

## Open questions
- Distortion **center** offset: needed for off-axis lenses? (v1 = image center.)
- Keystone divide: reciprocal-LUT precision vs a true pipelined divider — settle at HDL time.
- Warp mesh resolution (9×9 vs finer) + interpolation (bilinear vs bicubic) — driven by use case.
- Do corrections compose (pincushion *then* keystone)? On the mesh, yes (bake both); as separate
  addrgen stages, that's two passes. Likely answer: **warp mesh is the composition point.**
