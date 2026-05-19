# Color pipeline — SSOT

**Status:** SEALED at commit `6c1efe0` ("mackin_blender: decouple tready from tvalid — fixes pipeline deadlock"). This is the canonical reference for the color pipeline as it exists at that milestone. Work past that commit (CDC fixes, ADV7393 bring-up, TPG, fsync sync attempts) does not change the pipeline described here.

**Companion docs:** [`mackin-blender-design.md`](mackin-blender-design.md) (Mackin algorithm + dual-VDMA recipe), [`phase-b-pipeline.md`](phase-b-pipeline.md) (full HDMI pipeline including color stages).

---

## 1. Pipeline order

The color pipeline sits between VDMA MM2S and `axis_to_vid_io`, on `clk_wiz_pixclk_out` (74.25 MHz output clock domain).

```
MM2S → axis_clone → mackin_blender → color_saturation → color_correct → color_matrix → axis_to_vid_io
```

| Stage | Module | Role | Bit-exact sim | In BD | Functional |
|---|---|---|---|---|---|
| 1 | `axis_clone` | Fan-out single MM2S stream into two AXIS streams (Mackin needs `curr` + `prev`) | n/a | ✅ | ✅ (placeholder — both copies identical) |
| 2 | `mackin_blender` | Per-pixel temporal lerp between `curr` and `prev` (FRC blending) | ✅ (3,360 vectors) | ✅ | ⚠️ **Structural only** — see §3 |
| 3 | `color_saturation` | Rec.601 luma-mix saturation control (0% gray → 200%) | ✅ | ✅ | ✅ |
| 4 | `color_correct` | Per-channel diagonal scale + offset (black/white per channel) | ✅ | ✅ | ✅ |
| 5 | `color_matrix` | General 3×3 RGB matrix + per-channel offsets (Q2.14 signed) | ✅ | ✅ | ✅ |

The order is deliberate: temporal blend before color → saturation before per-channel diagonal → general matrix last (the matrix can subsume saturation + correct if calibration ever demands it; both are retained because their per-knob UART control is cheap and well-tested).

All five modules clock from `clk_wiz_pixclk_out/clk_out1` and reset from `rst_pixclk_out/peripheral_aresetn`. AXIS TDATA is 24-bit `R[23:16] | B[15:8] | G[7:0]` per the [`schindler-pipeline-rbg-byte-order`] memory convention. TUSER marks first active pixel of a frame; TLAST marks last pixel of a row.

---

## 2. Reserved-for-analog modules (sim-validated, not in BD)

Two additional modules exist in [`hdl/`](../hdl/) but are deliberately held out of the current HDMI build. They will be wired into the analog output path during ADV7393 bring-up.

| Module | Role | Bit-exact sim | In BD | Notes |
|---|---|---|---|---|
| `rgb_to_ycbcr` | RGB 4:4:4 → YCbCr 4:4:4 (Rec.601 / Rec.709 selectable) | ✅ ([`sim/analog/rgb_to_ycbcr_tb.v`](../sim/analog/rgb_to_ycbcr_tb.v) + Python ref) | ❌ | Reserved for composite/component DAC drive |
| `ycbcr_444_to_422` | Chroma downsample 4:4:4 → 4:2:2 | ✅ ([`sim/analog/ycbcr_422_tb.v`](../sim/analog/ycbcr_422_tb.v) + Python ref) | ❌ | Reserved for ADV7393 input format |

These are intentionally absent from the HDMI build. They join the build when the analog output substrate exists.

---

## 3. The Mackin "structural-only" caveat

`mackin_blender` is wired into the pipeline at commit `6c1efe0` and proven to pass pixels through cleanly without deadlock. **But it is a no-op in the current build**: both AXIS inputs (`s_curr` and `s_prev`) are wired from the same MM2S via `axis_clone`, so for every pixel `curr == prev` and the blend produces `prev + (α · 0) = prev = curr`.

This was the right milestone to seal. The work proves:
- The HDL is bit-exact correct against the Python golden across 3,360 vectors.
- The module integrates into the BD without breaking the pipeline (the `6c1efe0` tready/tvalid decoupling fixed the deadlock that previously prevented this).
- The firmware control path (axi_gpio_7 alpha, UART command) is verified end-to-end via readback.

What's deferred to a future iter: adding a second VDMA instance (MM2S-only, Genlock Slave, `FrmDly=2`) that exposes a real "previous frame" stream. Recipe is in [`mackin-blender-design.md` §"Why TWO streams"](mackin-blender-design.md), and the related work in [`mackin-dual-vdma-recipe.md`](mackin-dual-vdma-recipe.md). The structural integration is done; what remains is the dual-VDMA plumbing.

Until then, Mackin's UART command works (readback confirms), boot default α = `0x8000` (pure-curr = no-op), and the rest of the pipeline behaves identically to a build without Mackin.

---

## 4. Register map and UART control

### 4.1 `color_saturation` + `color_correct` — AXI GPIO 3

Single combined write covers both modules ([`sw/phase-b/src/main.c:243`](../sw/phase-b/src/main.c)).

| Register | Bits | Field |
|---|---|---|
| `GPIO3 + 0x00` (ch1) | `[31:24]` | `sat[7:0]` (low byte of 16-bit Q1.15 saturation) |
| | `[23:16]` | `black_b` |
| | `[15:8]` | `black_g` |
| | `[7:0]` | `black_r` |
| `GPIO3 + 0x08` (ch2) | `[31:24]` | `sat[15:8]` (high byte) |
| | `[23:16]` | `white_b` |
| | `[15:8]` | `white_g` |
| | `[7:0]` | `white_r` |

- **Saturation:** 16-bit Q1.15. `0x0000` = grayscale, `0x8000` = identity (100%), `0xFFFF` ≈ 200%. Helper: `color_sat_from_percent(unsigned pct)`.
- **Black levels:** per-channel offset. `0` = true black. Subtracted before the white scale.
- **White levels:** per-channel scale ceiling. `255` = full white. Sets the channel's maximum.

API: `color_set(sat, black_r, black_g, black_b, white_r, white_g, white_b)`. UART readback prints the full state on every write.

### 4.2 `color_matrix` — AXI GPIO 4 / 5 / 6

3×3 matrix + 3 offsets ([`sw/phase-b/src/main.c:293`](../sw/phase-b/src/main.c)).

| Register | Field |
|---|---|
| `GPIO4 + 0x00` | `(m01 << 16) | m00` |
| `GPIO4 + 0x08` | `(m10 << 16) | m02` |
| `GPIO5 + 0x00` | `(m12 << 16) | m11` |
| `GPIO5 + 0x08` | `(m21 << 16) | m20` |
| `GPIO6 + 0x00` | `(spare << 16) | m22` |
| `GPIO6 + 0x08` | `(off_b << 16) | (off_g << 8) | off_r` |

- **Coefficients:** Q2.14 signed (`s16`). Float → fixed-point: `m_fixed = round(m_float × 16384.0)`. Identity = `0x4000`.
- **Offsets:** `s8` per channel, ±127. Output is `matrix · in + offset`, then clamped to `[0, 255]`.

API: `color_matrix_set(m00..m22, off_r, off_g, off_b)`. Convenience: `color_matrix_identity()` (pass-through).

### 4.3 `mackin_blender` — AXI GPIO 7

Alpha-only ([`sw/phase-b/src/main.c:319`](../sw/phase-b/src/main.c)).

| Register | Bits | Field |
|---|---|---|
| `GPIO7 + 0x00` (ch1) | `[15:0]` | `alpha_q15` |

- **Alpha:** 16-bit Q1.15 unsigned, valid range `[0, 0x8000]`. `0x0000` = pure `prev`, `0x4000` = 50/50 blend, `0x8000` = pure `curr`. Values > `0x8000` clamp to `0x8000` in firmware.
- **CDC:** 2-FF sync inside the HDL on the alpha bus.
- **Boot default:** `0x8000` (pure-curr → no-op, matching pre-Mackin pipeline behavior).

API: `mackin_set(alpha_q15)`. UART readback confirms register state.

---

## 5. Boot defaults

Set in firmware at startup (search `boot` / `identity` in [`sw/phase-b/src/main.c`](../sw/phase-b/src/main.c)):

| Module | Boot default | Behavior |
|---|---|---|
| `color_saturation` | sat = `0x8000` (100%) | Identity (±0.4% Q1.15 error) |
| `color_correct` | black = (0,0,0), white = (255,255,255) | Identity |
| `color_matrix` | Identity matrix, zero offset | Pass-through |
| `mackin_blender` | α = `0x8000` (pure curr) | Pass-through (no-op until dual-VDMA) |

Net effect: at boot, the entire color pipeline is a unity pass-through. Any visible deviation from the input image is a bug, not an intentional default.

(Pre-`f97da45`, boot default was grayscale due to an uninitialized color matrix register. That commit fixed it.)

---

## 6. Test infrastructure

All four functional modules have bit-exact Python golden references in [`sim/`](../sim/):

| Module | Sim path | Golden ref |
|---|---|---|
| `mackin_blender` | [`sim/mackin/`](../sim/mackin/) | `mackin_ref.py`, 3,360 vectors (8 α × 420 pixel sets) |
| `rgb_to_ycbcr` | [`sim/analog/`](../sim/analog/) | `rgb_to_ycbcr_ref.py` |
| `ycbcr_444_to_422` | [`sim/analog/`](../sim/analog/) | `ycbcr_422_ref.py` |
| `color_matrix`, `color_saturation`, `color_correct` | (informally validated against bench output during development; no dedicated tb suite at this milestone) | — |

Adding bench-validation regressions for the three matrix-family modules is reasonable future work; they're stable and shipped but don't currently have committed golden vectors.

---

## 7. Future work (chapter-close TODOs)

Carried forward as known gaps, not blockers for the chapter being sealed.

1. **Dual-VDMA bring-up** — activates Mackin functionally. Recipe in [`mackin-blender-design.md`](mackin-blender-design.md) §"Why TWO streams" and [`mackin-dual-vdma-recipe.md`](mackin-dual-vdma-recipe.md). Open question: PG020's `FrmDly` semantics at slot offset N−2 (may need bench iter to confirm `FrmDly=2` vs `FrmDly=3`).
2. **Gamma linearization** — Mackin's Eq. 2 wants `g(Σ α[k] · g⁻¹(F_s[k]))`. Current HDL blends in encoded RGB. Full linearization needs a 256-entry inverse-gamma LUT before the blender and a 256-entry gamma LUT after. Bounded visible error today; not a correctness blocker for 1:1 or near-1:1 ratios.
3. **3-input-frame Mackin** — current 2-frame implementation underweights one of three overlapping inputs at K > 2 (60→24, 60→12). Acceptable first-cut; full fidelity requires three AXIS inputs + three α coefficients summing to 1. Deferred.
4. **Bench golden vectors for matrix-family modules** — `color_saturation`, `color_correct`, `color_matrix` are exercised in firmware and visually validated but lack committed test suites parallel to Mackin's.
5. **Analog-output integration** — wiring `rgb_to_ycbcr` + `ycbcr_444_to_422` into the BD when ADV7393 bring-up reaches that stage.

---

## 8. Why this chapter closes here

The four-module color pipeline (`color_saturation` + `color_correct` + `color_matrix` + `mackin_blender` structurally) is the architectural endpoint for the color work as initially scoped. After commit `6c1efe0`:

- All four are in the BD.
- All four have firmware control with UART readback.
- All four boot to identity / pass-through.
- Mackin is sim bit-exact (3,360 vectors).
- The pipeline passes pixels cleanly — no deadlock, no glitches.

The work that follows on `mackin-impl-wip` (CDC tightening, ADV7393 I2C, TPG, the failed fsync attempts) belongs to different chapters. This one is done.
