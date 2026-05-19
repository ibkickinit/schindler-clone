# Mackin Blender — Design Doc

> **CHAPTER SEALED at commit `6c1efe0` ("mackin_blender: decouple tready from tvalid — fixes pipeline deadlock").** As of that commit, the blender is bit-exact in sim (3,360 vectors), wired into the BD, controlled via UART (axi_gpio_7 alpha with readback), and passes pixels through the pipeline without deadlock. Boot default α = `0x8000` makes it a no-op (pure-curr), so the pipeline behaves identically to the pre-Mackin build.
>
> **Important — structural success, not yet functional:** both AXIS inputs are currently wired from the same MM2S via `axis_clone`, so for every pixel `curr == prev` and α has no visible effect. Functional activation requires adding a second VDMA instance (MM2S-only, Genlock Slave, `FrmDly=2`) per the dual-VDMA recipe in §"Why TWO streams" below and [`mackin-dual-vdma-recipe.md`](mackin-dual-vdma-recipe.md). That work is deferred; it is the next chapter, not this one.
>
> See [`color-pipeline.md`](color-pipeline.md) for the SSOT covering this module's role in the full color pipeline, register maps, boot defaults, and chapter-close TODOs.

---

Status (historical, prior to chapter close): **HDL + sim COMPLETE 2026-05-18 overnight.** 3360-vector sim suite (8 alpha values × 420 vectors) bit-exact vs Python golden. BD integration and Vivado build in progress. Bench validation deferred to next session.

## Algorithm authority (per research 2026-05-18)

The algorithm is from **Alex Mackin** et al., *"A Frame Rate Conversion Method Based on a Virtual Shutter Angle"*, ICIP 2019 (Bristol Research Portal: [PDF](https://research-information.bris.ac.uk/ws/files/194366047/ICIP2019_VirtualShutter_OA.pdf)). (Common misattribution: "Tyler Mackin" — author is Alex Mackin.)

Mackin's core equation (Eq. 2):
```
F_d = g( Σ_{k=1..K}  α[k] · g⁻¹(F_s[k]) )    s.t.  Σ α[k] = 1, α[k] ≥ 0
```
where `g()` is the gamma transfer function. K = f_input / f_output.

For sv = 360° virtual shutter (output-period-wide), weights derive from **fractional overlap** between the output frame's window and each input frame's period. For Schindler's K = 2.5 (60→24), the rolling weight pattern is `[0.40, 0.40, 0.20]` — 3 input frames per output.

**This HDL implements the 2-frame special case.** That's correct for:
- K = 1 (60→60, identity, alpha = 0x8000 fixed)
- K = 1.001 (60→59.94 NTSC drift — the *primary FRC motivation*, where each output overlaps almost exactly 1 input + tiny fraction of next)
- K = 2 (60→30, alpha cycles 0x8000 → 0x0000 each output)

For K > 2 (60→24, 60→12), the 2-frame lerp underweights one of the three overlapping input frames. Acceptable first-cut behavior; would require a 3-input-frame extension for full Mackin fidelity. **Deferred to a future iter.**

Linear-light blending (gamma decode → blend → gamma encode) per Mackin's Eq. 2 is **NOT YET implemented**. Current HDL blends in encoded RGB space. Visible error is bounded; full linearization requires a 256-entry inverse-gamma LUT before the blender (matches the deferred [[gamma-lut]] task).

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

## Why TWO streams — option A confirmed by research

Per research 2026-05-18, Option A (second VDMA, MM2S-only) is the canonical Xilinx pattern (cf. XAPP792 which runs 16 streams across 8 VDMAs sharing DDR3). Specific recipe:

**Step 1 — switch from Dynamic Genlock to classic Genlock** in `axi_vdma_0`:
- `axi_vdma_0.S2MM` → **Genlock Master** (drives `s2mm_frame_ptr_out`)
- `axi_vdma_0.MM2S` → **Genlock Slave**, `FrmDly = 1` (reads N−1, "current" frame)

**Step 2 — add `axi_vdma_1`**, MM2S-only:
- `c_include_s2mm = 0`
- Set hidden parameter `c_mm2s_genlock_num_masters = 1` (exposes external `mm2s_frame_ptr_in` port)
- Genlock Slave mode with `FrmDly = 2` (reads N−2, "previous" frame)
- 5 framestores, **identical** start addresses to axi_vdma_0
- m_axi_mm2s on a separate HP port (HP2; HP0 already used by axi_vdma_0)

**Step 3 — wire fan-out** of `axi_vdma_0/s2mm_frame_ptr_out` to BOTH `axi_vdma_0/mm2s_frame_ptr_in` AND `axi_vdma_1/mm2s_frame_ptr_in`. Six-wire Gray-code bus; register-buffered if timing tight.

**Bandwidth budget:**
| Stream | Rate | Bandwidth |
|---|---|---|
| S2MM write (60p input) | 1920·1080·4·60 | ~498 MB/s |
| MM2S read VDMA-0 (24p output) | 1920·1080·4·24 | ~199 MB/s |
| MM2S read VDMA-1 (24p output) | 1920·1080·4·24 | ~199 MB/s |
| **Total** | | **~896 MB/s** |

DDR3 on Zynq-7020 delivers ~3.5-4.2 GB/s practical → ~22-25% utilization. Trivially fits.

**Resource cost (MM2S-only VDMA-1):** ~1.2k LUT, ~1.8k FF, 2 BRAM. Z7-20 has 53k LUT / 140 BRAM — negligible.

**Why classic Genlock instead of Dynamic:**
- Dynamic Master "skips frames the slave is on" — fine for one slave, but with two slaves at different FrmDly offsets, slot collisions become possible if S2MM races ahead. Classic Master never skips → both slaves get a stable, predictable view.
- Dynamic Slave has FrmDly **hardcoded** to "last completed" — can't position at N−2.
- Classic Genlock with 5 framestores absorbs the 5:2 ratio without master-stomping-slave.

**Open question (bench-only):** PG020 wording is slightly ambiguous about whether `FrmDly=1` and `FrmDly=2` actually land exactly one slot apart, or if there's an off-by-one in how "behind master" is counted. Plan one bench iter to confirm; worst case use FrmDly=2 and FrmDly=3.

**Rejected options:**
- (B) DDR3 line buffer for previous-pixel: doesn't fit at 1080p (would need full-frame BRAM).
- (C) `v_frmbuf_rd × 2`: no hardware genlock chain, forces firmware ISR per vsync. PG278 explicitly moved frame coordination to software — wrong tool.
- Cascaded Dynamic Genlock: both slaves would land on the same frame (Dynamic Slave is always "last completed").
- Park-mode + firmware PARK_PTR_REG writes per vsync: anti-pattern per [[schindler-vdma-dynamic-genlock]] memory; PG020 doesn't guarantee SOF-atomic latching.

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
- 2026-05-18 02:3X: HDL + Python golden complete; 3360 vectors pass bit-exact
- 2026-05-18 02:4X: research-driven revisions to algorithm authority + dual-VDMA section
