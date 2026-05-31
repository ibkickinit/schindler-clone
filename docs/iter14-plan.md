# iter14 plan — runtime scaler kernel-mode toggle

**Status:** DEFERRED. Plan only; no implementation in tree.
**Last updated:** 2026-05-30 (post-audit panel).
**Production substrate this targets:** `iter5-1080p-clean` @ `fcd722c`.

## Scope

Add 2-bit `scaler_mode_h` and `scaler_mode_v` runtime inputs to `hdl/scaler_h.v` and `hdl/scaler_v.v` selecting between four kernel modes per axis:

| Mode | Kernel | Per-pixel cost | Use |
|---|---|---|---|
| 0 | NN single-tap (`s_axis_tdata` / `tap3` only) | 0 add, 0 shift | Sharpest. Drops cols/rows at non-1:1 ratios — testing only. |
| 1 | 2-tap boxcar `(a+b)/2` **+ round-to-nearest** | 1 add, 1 shift, +1 constant | Current iter12/iter13 default. Production. |
| 2 | 4-tap boxcar `(a+b+c+d)/4` + round-to-nearest | 3 adds, 1 shift, +2 constant | Softer; for noisy / motion-content sources. |
| 3 | Reserved | — | Future: linear-phase polyphase via existing MAC + alternative coefficients. |

Independent H and V control because they have different perceptual costs (V boxcar at 1080→720 doubles line widths; H boxcar at 1920→1280 softens column edges). User can tune sharpness per axis at runtime.

## HDL changes

### `hdl/scaler_h.v`

- Add `input wire [1:0] mode_h` port. Plumb through `scaler_top.v` to a new AXI GPIO bit field.
- Replace the current `wire [7:0] out_r/out_g/out_b` block with a combinational mux:

```verilog
// iter14 mode mux. Round-to-nearest (+1) baked into modes 1 and 2.
wire [7:0] out_r_mode0 = s_axis_tdata[23:16];
wire [8:0] sum2_r = s_axis_tdata[23:16] + window[0][23:16] + 9'd1;
wire [7:0] out_r_mode1 = sum2_r[8:1];
wire [9:0] sum4_r = s_axis_tdata[23:16] + window[0][23:16]
                  + window[1][23:16] + window[2][23:16] + 10'd2;
wire [7:0] out_r_mode2 = sum4_r[9:2];
wire [7:0] out_r = (mode_h == 2'd0) ? out_r_mode0
                : (mode_h == 2'd1) ? out_r_mode1
                : (mode_h == 2'd2) ? out_r_mode2
                                   : out_r_mode1;  // mode 3 reserved; default to production
// repeat for out_g, out_b
```

### `hdl/scaler_v.v`

Analogous mux on `mac_r/mac_g/mac_b` using `tap3` (mode 0), `(tap2+tap3+1)>>1` (mode 1), `(tap0+tap1+tap2+tap3+2)>>2` (mode 2).

### iter13b absorbed into iter14

The HDL audit (2026-05-30) flagged a −0.5 LSB DC bias in the current iter12/iter13 boxcars (`(a+b)>>1` truncates instead of rounding). The mode-1 block above adds `+1` before `>>1`, fixing the bias as part of the same Vivado cycle. **Do not ship iter13b standalone**; bundle the fix into iter14.

## BD changes

Add one new AXI GPIO instance (or repurpose 4 bits of an existing one):
- bits [1:0] → `mode_h`
- bits [3:2] → `mode_v`

The CDC pattern matches the existing color-pipeline GPIOs 3/4/5/6 — see [[schindler_color_pipeline]] and `hdl/axi_sync_inputs.v` (widen if needed). Frame-atomic update via TUSER latch.

## Firmware changes

`sw/phase-b/src/main.c` UART command parser already has the framework. Add:

```c
case 'k': {
    int c2 = uart_recv_blocking_or_timeout(50000);
    if (c2 == 'h' || c2 == 'v') {
        char buf[8]; ... parse decimal 0..3 ...
        u32 cur = Xil_In32(KERNEL_GPIO);
        if (c2 == 'h') cur = (cur & ~0x3) | (n & 0x3);
        else           cur = (cur & ~0xC) | ((n & 0x3) << 2);
        Xil_Out32(KERNEL_GPIO, cur);
        xil_printf("[k%c] = %u\r\n", (char)c2, n);
    }
    break;
}
```

Help-text additions (`?` command):
```
k h <0|1|2|3> set H scaler kernel mode (0=NN, 1=2-tap, 2=4-tap, 3=rsv)
k v <0|1|2|3> set V scaler kernel mode
```

## Cost estimate

| Step | Time | Notes |
|---|---|---|
| HDL edits (both scalers + scaler_top) | 30 min | Mux + signal plumbing only |
| BD edit (one new AXI GPIO or repurpose) | 15 min | Match existing color-pipeline pattern |
| Firmware (parser + define + help text) | 15 min | Follow existing `s`/`m`/`b`/`w`/`a` patterns |
| Vivado rebuild | 25 min | One cycle covers everything |
| Vitis ELF rebuild | 30 s | |
| Bench A/B/C verify | 10 min | Cycle modes live, eyeball deltas |
| **Total** | **~95 min** | One bench session |

## Bench verification plan

Once programmed:
1. Boot, capture ImagePro static SMPTE bars + grid.
2. Cycle modes via `k h 0`, `k h 1`, `k h 2`. Eyeball: NN should show 3-col left margin (per iter8 archaeology); 2-tap should match current production; 4-tap should be visibly softer.
3. Same for `k v 0`, `k v 1`, `k v 2`.
4. Pick combination = (h=1, v=1) for default boot. Confirm matches current bench-clean baseline byte-for-byte via `F` UART command (DDR3 HEAD+TAIL dump).
5. Promote `iter5-1080p-clean` matrix Row 2 from ⚠️ → ✅ if 3-boot rule holds.

## Risks

- **AXI GPIO budget.** Per [[zynq7020_mmcm_budget]], 4 MMCMs are consumed; GPIO budget is less tight but worth confirming. Repurpose vs add depends on how many free bits remain on GPIO 6.
- **CDC sanity.** The `axi_sync_inputs.v` 48→64-bit fix from iter5b applies — verify the new mode bits pass through the existing CDC cleanly.
- **Mode 0 (NN) reintroduces every-3rd-row drop on V.** Reasonable as a "test only" mode; document clearly that mode 1 is the production default.

## Open questions

- Should mode 3 be reserved for **Mackin-coupled** scaler (using temporal info from Mackin blender to pick spatial coefficients)? Worth scoping if/when Mackin dual-VDMA wiring lands.
- Should there be a per-mode UART query (`k?`) reporting current settings? Yes — match the pattern of the color-pipeline `i` command.

## Related

- [[schindler_scaler_kernel_iter12_iter13]] — what iter14 builds on
- [[schindler_color_pipeline]] — AXI GPIO + CDC pattern to mimic
- [[schindler_uart_commands]] — UART command framework
- `docs/build-manifest.md` 2026-05-24 section — original iter14 sketch absorbed here
