# Adjustable Scaler — Geometry Control (size / zoom / crop / position)

**Scope: V1** (Justin, 2026-06-01). Basic size (shrink), zoom, crop, X-Y position. Pincushion / keystone / warp are V2 (different engine — see §Out of scope).

**Architecture: master + per-output presentation** (Justin, 2026-06-01, agreed as written). This doc supersedes the earlier input-side-geometry draft — the dual-output use cases proved geometry must be a **post-color, per-output presentation stage**, not input-side.

## Use cases that drive the architecture

- **UC1 — HDMI primary.** Frame + color for HDMI as the deliverable. Analog out is a *downconvert* of the HDMI-framed image (letterbox or stretch to 4:3 composite).
- **UC2 — Analog primary.** Composite is the deliverable. Source arrives 16:9 (squeeze/letterbox → 4:3) or pillarbox center-cut. HDMI becomes a **confidence monitor** with a user toggle: stretched-16:9 (fill) or pillarbox-correct-aspect (true framing + bars).

**Unifying insight:** both cases are one shape — a single *master-framed, colored* image, with the other output a *re-presentation* of it. "Primary" only decides whose native aspect frames the master. So this is **one master + per-output presentation**, never two independent chains.

## Order of operations (authoritative)

```
HDMI in
  1. INPUT FORMAT-SCALE   source → master canvas        (input side; bandwidth-driven; frames to PRIMARY aspect)
  2. CREATIVE COLOR       saturation / correct / matrix  (applied ONCE → shared look)
  ── DDR master frame (1280×720 working res) ──
        ├ HDMI:   3. PRESENT-GEOMETRY (size/crop/pos/aspect)  4. opt. NTSC-safe preview     5. 720p timing → rgb2dvi
        └ ANALOG: 3. PRESENT-GEOMETRY (aspect-fit → 4:3)      4. NTSC-safe conditioning     5. 480i timing → ADV7393
```

Three load-bearing principles:

1. **Color once, on the master, before the split.** A confidence monitor is only honest if HDMI shows the analog's *actual* graded color.
2. **Geometry presentation is per-output and lives AFTER color.** This is what makes UC1↔UC2 and the confidence-aspect toggle fall out — each output independently letterboxes / pillarboxes / stretches the same master.
3. **NTSC-safe is a small per-output conditioning stage** (7.5 IRE setup, gamut clamp) on the analog leg; optionally mirrored on HDMI as a "preview broadcast-safe" toggle.

### Two geometry stages, two different jobs (not redundant)
- **Input format-scale** (stage 1): frames *source → master* at the **primary's** aspect. Stays input-side because storing the master at working res (720p) — not full source res — is what keeps DDR bandwidth + the genlock ring small. "Master aspect follows primary" (agreed): for analog-primary the input-scale squeezes/center-cuts 16:9→4:3 so the master holds 4:3 content at full working res (analog downconverts at best quality; HDMI just pillarboxes it).
- **Per-output present-geometry** (stage 3): adapts *master → each output raster*. For the primary output this is ~1:1; for the secondary it's the adaptation (pillarbox / stretch / letterbox). This is the new runtime size/crop/position engine.

For **v1 (HDMI-only)** the two collapse: input format-scale = the existing 1080→720 downscale; present-geometry = the user's size/crop/position knobs on one output.

## The resampler we build on

`scaler_h` is a Bresenham/DDA (confirmed in `hdl/scaler_h.v`):
```
per input pixel:  accum += OUT_W ; if accum >= in_w_active: emit; accum -= in_w_active
```
- ratio = `OUT_W / in_w_active`; `in_w_active` already runtime (iter4e); `OUT_W` step is compile-time.
- polyphase `phase`/coeffs are dead on the 2-tap kernel → **no runtime divider needed** to change ratio. This is what makes adjustable geometry cheap.

## HDL deltas (revised — geometry is post-color)

### v1 (G1/G2 — HDMI single output)
1. **New `present_geom` block, post-color, before `axis_to_vid_io`.** It is a DDA resampler (reuse `scaler_h`/`scaler_v` core) with **runtime** step + crop + output-window, operating on the colored master read from MM2S.
   - **Size** = runtime accumulator step (`dst_w`,`dst_h` ≤ raster). Shrink → pillarbox/letterbox.
   - **Crop/zoom/pan** = runtime input sub-rect of the master (`src_x,src_y,src_w,src_h`).
   - **Position** = output window offset (`dst_x,dst_y`) into a matte-filled raster.
   - **Downscale-only guard** (firmware): reject `dst > src`.
2. **Matte fill** for the area outside the window (background color, default black). For a post-color output-side block this is cleanest as an **output compositor** (emit matte outside window, picture inside) — route B from the prior draft, now preferred *because* geometry is post-DDR per-output. No framebuffer-clear gymnastics.
3. The existing input `scaler_top` (1080→720 format downscale) stays as-is for v1.

### Dual-output (Phase-G-gated, documented now so v1 extends cleanly)
- Instance a **second present_geom + second output timing (480i) + NTSC-safe** reading the **same DDR master**.
- Read topology: two MM2S engines on one master framebuffer at two rasters/rates (720p60 + 480i59.94). Either a second VDMA MM2S-only instance or a standalone reader. Genlock across two output rates is the hard part — deferred with Phase G HDL; **the order of operations above does not change.**
- "Primary" is a firmware/UI policy that sets sensible defaults for both present_geom stages + the input-scale master aspect.

## Control-plane surface (catalog v0.3.0)

Per-output, namespaced so the dual-output future is already addressable:
```
hdmi.size_h / size_v       %    25..100   default 100
hdmi.pos_x  / pos_y        px   signed    default 0
hdmi.zoom                  %   100..400   default 100   (crop-based; source-limited)
hdmi.pan_x  / pan_y        px   signed    default 0
hdmi.aspect                enum  native | stretch16x9 | pillarbox4x3   (UC2 confidence toggle)
display.matte_rgb          color default #000000
# analog.* mirror appears when Phase G revives
```
Firmware translates operator knobs → `(src_*, dst_*)` rects + downscale guard → GPIO regs. Catalog 0.2.0 → 0.3.0 (additive, minor).

## Risks
1. **Throughput** (`schindler_scaler_pipeline_throughput`): `cycles-per-px × emits-per-line ≤ row-time`. Shrink helps; zoom-in (near-1:1) is the stress case — sim at extremes.
2. **Output compositor on the output clock**: new block at 74.25 MHz; watch WNS. CDC false-paths for its runtime regs follow the `/inst/ km_q1` pattern.
3. **Upscale guard** in firmware (`dst ≤ src`) — load-bearing for no-upscale policy.
4. **Aspect math / rounding**: odd widths, anamorphic squeeze ratios; validate in a sim vector set.

## Phasing
| Phase | Delivers | Gate |
|---|---|---|
| **G1** | post-color present_geom: runtime size + position + matte compositor (HDMI) | arbitrary size/position pillarbox-letterbox, 3-boot clean |
| **G2** | crop + zoom + pan + aspect presets | zoom/pan on a sub-region; UC2 confidence-aspect toggle |
| **G-analog** | 2nd present_geom + 480i + NTSC-safe (Phase-G-gated) | dual-output UC1/UC2 on real ADV7393 |
| **V2** | pincushion / keystone / warp | warp-mesh engine, separate |

## Out of scope (V2)
Pincushion / keystone / warp need a per-output-pixel source-coordinate transform (warp mesh + 2-D sampler) — random-access framebuffer read, not a 1-D DDA per axis. Separate V2 engine.

## Build sequencing
iter5-1080p-clean (v1 trunk). HDL starts after the mackin merge is repaired + we're confirmed on iter5. Never `git checkout`/competing-build during a running Vivado build.
