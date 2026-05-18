# Mackin Blender — Design Doc

Status: **WIP draft** — 2026-05-18 overnight implementation. Will be revised once parallel research agents return.

## Goal

Per-pixel temporal blender that linearly interpolates between two pixel streams (the "current" framestore and the "previous" framestore in the VDMA ring). With a single α coefficient, the blender:
- **Degenerates to drop/repeat** at clean integer rate ratios (α = 0 or 1)
- **Smoothly blends** at near-1:1 ratios where the "virtual shutter" window of an output frame overlaps two input frames

Replaces nearest-neighbor frame selection in the VDMA Dynamic Genlock path for FRC modes where motion smoothness matters more than crispness.

Named after the algorithm popularized by Tyler Mackin in the RT4K firmware (per memory [[frc-mackin-virtual-shutter-blend]]).

## Algorithm (strawman, pre-research)

### Math

```
out_c = prev_c + ((α · (curr_c - prev_c) + 0x4000) >> 15)
                                        ^^^^^^^^^^
                                        round-to-nearest bias
```

per channel c ∈ {R, G, B}. α is unsigned Q1.15:
- `α = 0x0000` → out = prev (pure repeat of previous frame)
- `α = 0x4000` → out ≈ 50/50 blend (intermediate)
- `α = 0x8000` → out = curr (pure pass-through of current frame)

Valid range `α ∈ [0, 0x8000]`. Values > 0x8000 are unsupported (clamp in firmware).

### Why this form (diff-and-add vs. raw lerp)

Pure lerp:
```
out = (α · curr + (0x8000 − α) · prev + 0x4000) >> 15
```

Diff-and-add:
```
out = prev + ((α · (curr − prev) + 0x4000) >> 15)
```

Both are equivalent algebraically. Diff form has one slight advantage:
- At `α = 0`, raw out = prev with **zero error** (no multiply needed structurally, but more importantly: rounding can't perturb).
- At `α = 0x8000`, out = prev + (curr − prev) = curr **exactly**.

Both endpoints land precisely. Intermediate α has the same precision in either form. Pick diff-and-add.

### Bit width derivation

| Signal | Width | Type | Range |
|---|---|---|---|
| `curr_c`, `prev_c` | 8-bit | unsigned | 0..255 |
| `diff = curr - prev` | 9-bit | signed | −255..+255 |
| `α` | 16-bit | unsigned Q1.15 | 0..0x8000 |
| `α · diff` | 25-bit | signed | ±255·0x8000 = ±8.36 M |
| `(α · diff + 0x4000) >> 15` | 10-bit | signed | −256..+256 |
| `prev + scaled` | 10-bit | signed | −1..+511 (worst case) |
| clamp to `[0, 255]` | 8-bit | unsigned | 0..255 |

One DSP per channel, 3 DSPs total per blender.

### Rounding mode

Round-to-nearest, ties-toward-positive (add `0x4000` then arithmetic shift right). Equivalent to `round(x + 0.5)` for non-negative, slightly biased positive for negative — acceptable for video; visually invisible.

## Why TWO streams?

VDMA Dynamic Genlock currently advances MM2S's RDSTORE pointer once per output frame, reading one framestore per output. For Mackin blend, we need to read TWO framestores in parallel (current and previous in the ring). Three options:

| Option | Approach | Complexity | Resource cost |
|---|---|---|---|
| **A** | Second VDMA instance, MM2S-only, RDSTORE one slot behind | Medium BD work, shared HP port | ~2× MM2S BRAM/DSP |
| **B** | Single VDMA + DDR3 line buffer for previous-pixel | Large HDL, BRAM-hungry at 1080p | Doesn't fit |
| **C** | `v_frmbuf_rd` × 2 instances | Newer IP, two instances | Unknown |

→ **Plan A.** See research agent's findings (pending) for shared-DDR3 / HP-port arbitration details.

## AXIS port shape

```verilog
module mackin_blender (
    input  wire        aclk,
    input  wire        aresetn,

    // AXIS slave: current-frame pixels
    input  wire [23:0] s_curr_tdata,
    input  wire        s_curr_tvalid,
    output wire        s_curr_tready,
    input  wire        s_curr_tlast,
    input  wire        s_curr_tuser,

    // AXIS slave: previous-frame pixels
    input  wire [23:0] s_prev_tdata,
    input  wire        s_prev_tvalid,
    output wire        s_prev_tready,
    input  wire        s_prev_tlast,
    input  wire        s_prev_tuser,

    // AXIS master: blended output
    output reg  [23:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser,

    // Blend coefficient (Q1.15, 0..0x8000)
    input  wire [15:0] alpha_async
);
```

### Handshake rule

Both input AXIS streams must present valid pixels on the SAME cycle. The blender's `s_*_tready` outputs are equal — it accepts a pixel pair only when both are valid. Downstream stall propagates back to both.

Asymmetric stall is a hazard: if `s_prev` runs faster than `s_curr`, we drop pixels from `s_prev` waiting for `s_curr`. Resolution: rely on VDMA's frame-aligned synchronization — both MM2S instances genlock-follow the same VTC fsync, so they emit pixels at the same line rate. Skid buffers on the inputs handle one-cycle skew (small AXIS FIFO of depth 2 per input).

### Byte order

Per [[schindler-pipeline-rbg-byte-order]] memory: tdata[23:16]=R, [15:8]=B, [7:0]=G. The lerp is channel-independent so byte order doesn't affect math, but the HDL unpacks/repacks in R-B-G for consistency with other Schindler color HDL.

## Pipeline depth

3 stages (matching color_matrix structurally):
- **Stage 1:** capture pixels into pipeline regs, compute diff (curr − prev) per channel
- **Stage 2:** multiply diff × α, add rounding bias
- **Stage 3:** shift >>15, add prev, clamp [0,255], pack output

At 74.25 MHz pixel clock (Zynq -1) this is comfortable.

## α coefficient firmware-side

Firmware computes α from rate ratio + phase tracker. For 5:2 cadence (60→24):
```
output frame index:  0  1  2  3  4
source frame index:  0  2  5  7 10  (drift pattern)
alpha per frame:    0x8000 0x8000 0x8000 0x8000 0x8000  ← drops cleanly
                    (or 0x0000 0x0000... if "previous" is the kept one)
```

For 1000:1001 NTSC drift:
- Slowly cycle α from 0x8000 → 0x7FFF → 0x7FFE … → 0x0000 → 0x8000 over 1001 output frames as the phase walks one full input-frame period

Firmware writes α once per output vsync via axi_gpio_7. CDC handled by 2-FF sync inside HDL.

## GPIO layout

New `axi_gpio_7` (after the color GPIOs 3/4/5/6):
- **Channel 1** [15:0] = α (Q1.15, unsigned 0..0x8000)
- **Channel 2** = reserved (future: per-channel α for chromaticity-preserving blends, phase counter readback, etc.)

Boot default: α = 0x8000 → pure curr → identical to current iter5 nearest-neighbor behavior, so the blender is a no-op until firmware enables real α tracking.

## Open questions (pre-research)

1. **Algorithm spec authority** — is "virtual shutter" precisely the linear-overlap weighting I'm assuming, or is it more sophisticated (e.g., box-filter at shutter speed `<` frame period)? See research agent 1.
2. **Precision** — Q1.15 might be overkill or underkill. See research agent 2.
3. **Second MM2S synchronization** — pointer offset mechanism + HP port arbitration. See research agent 3.
4. **Drop-mode rounding** — at α=0x8000 the math gives `out = prev + (curr-prev) = curr` exactly. At α=0 it's `out = prev + 0 = prev` exactly. Verified clean — see above.

## Testbench plan

- **Python golden** (`sim/mackin/mackin_ref.py`): reference implementation, bit-exact match expected.
- **Verilog tb** (`sim/mackin/mackin_blender_tb.v`): runs the same input vectors through HDL via xsim, dumps output, diff against golden.
- **Test vectors** (`sim/mackin/vectors/`):
  - 5:2 cadence (60→24 clean): α schedule = [0x8000, 0x8000, 0x8000, ...]
  - 6:5 ugly: α schedule walks
  - 1000:1001 NTSC: α schedule slowly cycles
  - Edge cases: α=0, α=0x8000, α=0x4000 (50/50)
  - All-black, all-white, gradient, random-RGB frames

## References

- [[frc-mackin-virtual-shutter-blend]] — memory: strategic context
- [[schindler-frc-architecture-compass]] — memory: where this fits in Phase E
- [[fpga-video-ascal-reference]] — memory: prior art (MiSTer ascal blender)
- [[schindler-color-pipeline]] — memory: where the blender slots in (before color pipeline)
- [[schindler-pipeline-rbg-byte-order]] — memory: byte order convention

## Revision log

- 2026-05-18 02:0X: initial strawman before research lands
- (pending) research-driven revisions
