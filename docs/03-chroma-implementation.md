# Chroma subcarrier implementation — Phase 2 notes

**Status:** Module written, integration changes BANKED but not yet applied to `top.v`.
**Owner:** Claude writes HDL, Justin operates bench. See `01-spec.md` revision 4 for workflow rules.

This doc covers the chroma_gen module added in the 2026-05-10 PM session and the
to-do items for wiring it into `top.v`. Once the to-do list is applied and the
project rebuilds, the bench scope should show a clean ~9-cycle 3.58 MHz sine
burst on the back porch of every line, riding on the blanking level.

---

## Files added this session

- **`hdl/chroma_gen.v`** — NCO + burst-window subcarrier generator. Outputs
  signed 11-bit chroma_offset. Active-video chroma hooks present but currently
  output zero (no chroma patterns yet — that's a follow-up).
- **`hdl/chroma_lut_cos.hex`** — 256-entry signed 10-bit cosine LUT loaded by
  `$readmemh` inside chroma_gen.v. Peak amplitude ±255 codes.
- **`python/encoder/gen_chroma_lut.py`** — generator script for the hex LUT.
  Reproducible: run from `python/encoder/` and it writes back to `hdl/`.
  Parameters are configurable (entry count, peak, bit width) for future
  experiments.

## Math summary (for cross-reference with HDL parameters)

| Quantity | Value | Source |
|---|---|---|
| f_sc (NTSC subcarrier) | 3.579545 MHz (= 5 MHz × 63/88, exact) | SMPTE 170M |
| f_pix (pixel clock) | 54.000 MHz | `top.v` MMCM |
| Pixels per subcarrier cycle | 15.0857 | f_pix / f_sc |
| 32-bit phase increment | 284,704,272 (0x10F83E10) | round(2³² × f_sc / f_pix) |
| Frequency error vs ideal | 0.002 ppm | round-off only, essentially exact |
| Sync trailing edge | pixel 335 | H_FRONT + H_SYNC = 81 + 254 |
| Burst start | pixel 368 | sync_leading + 19 × pix_per_cycle |
| Burst end | pixel 504 | start + 9 × pix_per_cycle (9-cycle burst) |
| Active video start | pixel 589 | ACTIVE_START in sample_gen.v |
| Burst amplitude | 146 DAC codes | ±20 IRE = 40 IRE p-p, 7.31 codes/IRE |

---

## TO-DO: `top.v` integration (BANKED, not applied)

These edits are needed to actually use chroma_gen. Each is a small, mechanical
change. Reviewed once and they should drop in cleanly — no architectural
surprises expected.

### 1. Widen `pattern_sel` to 3 bits

```diff
 module top (
     input  wire        sys_clk,
     input  wire        btn_rst,
-    input  wire [1:0]  pattern_sel,
+    input  wire [2:0]  pattern_sel,
     output wire [7:0]  dac_pmod,
```

**Constraint file change** (`constraints/*.xdc`): add a third switch pin for
`pattern_sel[2]`. Zybo Z7-20 has 4 user switches (SW0–SW3); SW2 is at
`W13` on the standard Digilent constraints file. Pick the next available
pin.

### 2. Add chroma_gen wires and instance

Insert after the existing `sample_gen sample_inst (...)` block:

```verilog
    // ------------------------------------------------------------
    // Chroma subcarrier — produces burst on back porch (Phase 2)
    // ------------------------------------------------------------
    wire signed [10:0] chroma_offset;

    chroma_gen chroma_inst (
        .clk           (pixel_clk),
        .rst           (pixel_rst),
        .pixel_count   (pixel_count),
        .line_count    (line_count),
        .active        (active),
        .pattern_sel   (pattern_sel),
        .chroma_offset (chroma_offset)
    );
```

### 3. Modify the DAC output stage to sum luma + chroma with clamping

The existing `assign dac_pmod = dac[9:2];` line needs to be replaced with a
combiner that sums sample_gen's `dac` (unsigned 10-bit) with chroma_gen's
`chroma_offset` (signed 11-bit), clamps to 0..1023, then drops the bottom 2
bits for the Pmod.

```diff
-    // 10-bit DAC code → 8-bit Pmod (drop 2 LSBs; coarser steps but full range).
-    // Bit ordering: dac_pmod[7] is MSB → JC1; dac_pmod[0] is LSB → JC10.
-    assign dac_pmod = dac[9:2];
+    // Sum luma + chroma with saturation, then truncate for 8-bit Pmod.
+    // Bit ordering: dac_pmod[7] is MSB → JC1; dac_pmod[0] is LSB → JC10.
+    // (Sample_gen already handles sync→SYNC_TIP and blanking→CODE_BLANKING,
+    // so during sync chroma_offset is also zero and the sum is sync_tip.)
+    wire signed [11:0] dac_sum = $signed({2'b00, dac}) + $signed({chroma_offset[10], chroma_offset});
+    wire        [9:0]  dac_final = (dac_sum < 0)         ? 10'd0
+                                 : (dac_sum > 12'sd1023) ? 10'd1023
+                                 : dac_sum[9:0];
+    assign dac_pmod = dac_final[9:2];
```

**Note:** because `sample_gen` already drives `dac` to `CODE_SYNC_TIP` (=0)
during sync, and `chroma_gen` outputs `chroma_offset` = 0 during sync (it's
not the burst window and `active` is low), the sum during sync is 0+0 = 0 =
sync tip. Clamping is needed during burst window because BLANKING (293) +
burst (±146) is in range [147, 439] — comfortably inside 0..1023 — but
once active-video chroma is added, clamping will protect against legitimate
overflow at the bright/saturated edges of color bars.

---

## Bench verification plan (next session)

Once these edits are applied, rebuilt, and loaded onto the Zybo:

1. Confirm the gray pattern (pattern_sel = 3'b000) still looks identical to the
   pre-chroma version. Should be unchanged.
2. Scope the back porch at tight zoom (1 µs/div). Should see:
   - About 9 cycles of 3.58 MHz sine wave (~280 ns period per cycle)
   - Centered on the blanking level (~1 V on the bench scope, after op-amp)
   - Amplitude approximately ±140 mV at the BNC = ±19.6 IRE = 39.2 IRE p-p —
     basically on the NTSC 40 IRE spec.
     (Math: chroma_offset peak ±146 codes at 10-bit → ±36 codes at 8-bit Pmod
     after dropping 2 LSBs → ±36 × 3.9 mV/step at BNC ≈ ±140 mV. The 7-step
     resolution within each peak gives a visibly clean-enough sine on scope.)
3. Verify burst position: should sit roughly 0.6 µs after sync trailing edge,
   ending about 1.5 µs before active video starts.
4. Frequency-check: burst period should be ~280 ns (3.58 MHz).
5. Once burst is verified, this is the milestone. Next phase adds chroma
   modulation during active video for actual color bars (uses pattern_sel = 3'b011
   per the spec).

## Future work (not in this session)

- Active-video chroma modulation (I/Q quadrature) for proper SMPTE color bars
- Field-1/field-2 burst phase alternation (Schindler playbook Ch. 5)
- Subcarrier coherent vs non-coherent mode toggle (Schindler playbook Ch. 4)
- Burst suppression on lines that don't need it (NTSC standard: no burst on
  VBI lines 1–9 and 263–272, but for Schindler the rule may be relaxed)
