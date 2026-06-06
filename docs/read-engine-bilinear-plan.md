# Read-engine bilinear resampling (#107) — implementation plan

Scoped 2026-06-05 (agent a7fdfe66). Phase it: **#107a H-bilinear first**, **#107b V-bilinear** after.

## Load-bearing facts
- `pg_addrgen` exposes only integer `o_src_col/o_src_row` (`pg_addrgen.v:63-65,143-144`); the
  fractional accumulators `h_frac/v_frac` (`:77,79`) are internal. **Must add frac outputs.**
- The DDA fraction is already `numerator/win_w` form — bilinear weight `f = h_frac/win_w`. Avoid a
  hardware divider via a **firmware reciprocal** `inv_w = round((1<<16)/w)` (Q0.16), then HW
  `fw = (h_frac*inv_w)>>8` → Q0.8 weight 0..255.
- H col+1 neighbour is FREE (`rd_data_h1`, `pg_linefetch.v:150-160`); 2-tap box `avg2` at
  `pg_compose.v:186-192` already consumes the two taps → replace 50/50 with f-weighted lerp.
- **V row+1 is RESIDENT** in the ring (tagged whole rows, `pg_linefetch.v:84,112-117,176`;
  prefetch LOOKAHEAD=NBUF-3 keeps row+1 ahead) → V needs a 2nd READ PORT, NOT a 2nd fetch.
  1 output-pixel/clk preserved → no throughput regression; cost is BRAM read-port duplication.
- Latency: carry the precomputed weight IN the skid word (rides with rd_col), latch into a
  `c1_*` reg at pop → lands in the S1 blend cycle with `A_in`. No separate frac FIFO.
- Free control bits: GEO_C ch2 [31:30] → a 2-bit `filt_mode` (0=NN 1=box 2=Hbilin 3=H+Vbilin).
  Reciprocals need a new GPIO (axi_gpio_? dual: inv_w/inv_h) — GEO_A/B full.

## Blend math (per channel, reuse the Mackin diff/mult/add 3-stage split for timing)
`out = clamp( a + (((b-a)*fw + 128) >>> 8) )`, fw = Q0.8. Timing: the Mackin single-cycle lerp
already blew WNS −3.5 (`pg_compose.v:234-236`) → PIPELINE each lerp into its own stage (R, R2),
bump the `ospace` reserve (`:137`) per added stage; FIFO_DEPTH=64 absorbs it.

## #107a (H bilinear) files
- pg_addrgen.v: add `o_h_frac[11:0]` (+ `o_v_frac` for #107b), registered with o_src_col.
- pg_compose.v: `inv_w` input; carry h_frac (or precomputed fw_h) in skid; `filt_mode` mux for
  A_in/B_in (0=NN exact-zero-regression, 1=box, 2=Hbilin lerp); pipeline the lerp; bump ospace.
- pg_read_engine_top.v: `filt_mode[1:0]` + `inv_w[15:0]` ports (replace filt_h) + extend GW CDC.
- tcl/readengine_b_bd.tcl: filt_mode slice [31:30]; new GPIO for inv_w/inv_h.
- sw/phase-b/src/main.c: re_write_geometry computes inv_w/inv_h + filt_mode; UART `F 0|1|2|3`.
- sim/pg_read_engine_top_tb.v: bilinear golden (EXACT fixed-point: same inv, *fw, +128, >>8, clamp)
  + zoom case (128,96,-32,-24) where frac sweeps. filt_mode=0 over all cases = zero-regression guard.

## #107b (V bilinear) files (after #107a benches)
- pg_linefetch.v: 2nd read port (rd_row1=rd_row+1) → rd_data_v1[_h1] + rd_resident1; edge-clamp at
  last row; A-only V-interp in v1 (halve ports). Gate head_servable on row+1 residency (NBUF>=4).
- pg_compose.v: R2 vertical-lerp stage; filt_mode==3.

## Risks
1. Fixed-point golden MUST match HW exactly (top risk). 2. Latency align via skid-carry (no off-by-one).
3. Timing → pipeline each lerp. 4. V 2nd-port BRAM cost (A-only). 5. Edge clamp (last col/row).
