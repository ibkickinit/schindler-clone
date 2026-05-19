# Phase 2 — Synthetic 50 Hz reference

**Status:** PASS ✓ (2026-05-19 00:06 PT)

## Rate target: 50 Hz, not 60 Hz

The ground-up plan §4 Phase 2 used "60 Hz" as a stand-in for "any stable reference." First Phase 2 build (DIVISOR=2,500,000) produced a perfectly-stable 57.143 Hz signal — confirming FCLK_CLK1 actually runs at 1000/7 = 142.857 MHz, not the requested 150 MHz (the Zynq IO-PLL's 1000 MHz output is divisible only by integer N, and 1000/N never lands on 150). 57 Hz ref vs 50 Hz output (the d71c994 720p50 default) gave a ~140,000 ppm rate gap — way outside the MMCM's ±500 ppm pull range and unworkable for Phase 4–6's loop.

DIVISOR rebuilt at **2,857,143**, targeting **49.999999... Hz** (sub-ppm offset from a perfect 50 Hz, matching the 720p50 output rate). Tests redone on this build.

**Goal:** generate a stable reference vsync signal at nominal 60 Hz that doesn't depend on HDMI, doesn't depend on TPG, and doesn't share a clock domain with the pixel-clock MMCM the spike will modulate. Wire it into Phase 1's `vsync_timestamp_0/ref_vsync_async` input. Validate via the firmware's `q` and `c` commands.

Per [`docs/phase-e1-ground-up-plan.md`](../../docs/phase-e1-ground-up-plan.md) §4 Phase 2.

## What changed since Phase 1

### HDL (new)

`hdl/synth_vsync_gen.v` — integer-divider on `FCLK_CLK1` (150 MHz). Default `DIVISOR=2,500,000` produces a 50%-duty-cycle square wave at exactly 60.000 Hz (assuming the PS PLL achieves exactly 150 MHz on FCLK_CLK1 — typically within <100 ppm of nominal).

Why 50% duty (rather than a one-cycle pulse): a 6.67 ns FCLK_CLK1 pulse is shorter than the 10 ns sample interval of the 100 MHz consumer-side synchronizer, so a single-cycle pulse risks being missed entirely. A 50% duty signal has each transition guaranteed-visible to the 2-FF sync.

### BD edits (`tcl/build_phase_b.tcl`)

1. `add_files` includes `hdl/synth_vsync_gen.v`.
2. The Phase 1 `xlconstant ref_vsync_tielow` cell **removed** — no longer needed; `ref_vsync_async` is now driven by the new divider.
3. `synth_vsync_gen_0` instantiated as a `-type module -reference` BD cell.
4. Wired:
   - `clk` ← `zynq_ps/FCLK_CLK1` (150 MHz)
   - `aresetn` ← `rst_mem/peripheral_aresetn` (the same reset that already serves the FCLK_CLK1 domain for VDMA memory-side traffic)
   - `vsync_out` → `vsync_timestamp_0/ref_vsync_async`
5. The Phase 1 `set_false_path -to */vsync_timestamp_0/inst/ref_sync_reg*/D` constraint now matches a real path (was optimized away when ref was tied low).

### Firmware (`sw/phase-b/src/main.c`)

New UART command:

- `c` — capture **1000** consecutive `ts_ref` edges as CSV, blocking the telemetry loop until done (~16 s at 60 Hz).
- `C` — quick-check, captures **100** samples (~1.7 s).

CSV format (one capture block per invocation):

```
# phase2_capture N=<n> base_count=<x>
idx,ref_count,ts_ref_lo32,ts_ref_hi16
0,<count>,<lsb>,<msb>
...
# phase2_capture done N=<n>
```

The `?` help command updated to list `c` / `C`.

### Analyzer (new)

`scripts/analyze_phase2_reference.py` — parses the UART log, computes per-period statistics, writes a clean CSV to disk. Pure-Python (no numpy). Reports:

- mean / stdev / min / max period in counter ticks (and equivalent Hz/ns)
- peak-to-peak jitter
- Phase 2 pass verdict: p2p < 100 ticks

## Phase 2 verification plan

### Test 2.A — Sanity check via `q`

Send `q` once. `ts_ref_count` should now be non-zero and advancing at ~60 Hz (vs. Phase 1 where it stayed at 0).

### Test 2.B — Period-statistics capture via `c`

Send `c`, wait ~16 s, capture the UART output. Run:

```
python3 scripts/analyze_phase2_reference.py tests/phase-e1/phase2_uart.txt \
    tests/phase-e1/phase2_reference.csv
```

**Expected output:**
- 1000 samples captured
- Mean period ≈ **2,000,000 ticks** (= 1/50 s at 100 MHz, given DIVISOR=2,857,143 at FCLK_CLK1=142.857 MHz)
- Peak-to-peak jitter: with FCLK_CLK0 (counter) and FCLK_CLK1 (divider source) both descending from the same PS IO-PLL via integer divisors, the period in counter ticks is determined by an exact rational ratio and should be **bit-identical every cycle** (or off by exactly 1 tick in some cycles, depending on how the CDC sample lands). First Phase 2 build (DIVISOR=2,500,000 → 57.143 Hz) measured **0 ticks peak-to-peak** across 99 periods, confirming this. Anything >5 ticks p2p in this rebuild would be surprising.

## Results (bench, 2026-05-19 00:06 PT, DIVISOR=2,857,143 build)

### Test 2.A — `q` shows `ts_ref` non-zero and advancing

Two `q` commands ~1 s apart:

```
[Q] ts_ref = 0x00004A25EF30   edges = 623
[Q] ts_ref = 0x0000501BD035   edges = 673   ← +50 edges in 1 s = 50 Hz
```

PASS ✓. (In Phase 1 with `ref_vsync_async` tied low, this was `edges = 0` forever.)

### Test 2.B — Period-statistics capture via `c` (1000 samples)

```
samples: 1000 (999 periods)
period stats (counter ticks @ 10 ns/tick):
  mean    =     2000000.100 ticks  =  20000001.0 ns  =   50.0000 Hz
  stdev   =           0.300 ticks  =         3.0 ns
  min     =         2000000 ticks  =  20000000.0 ns
  max     =         2000001 ticks  =  20000010.0 ns
  peak-to-peak = 1 tick  =  10 ns
```

PASS ✓ on every dimension:

- **Mean: exactly 50.0000 Hz** (matches the synth_vsync_gen.v header comment's predicted 49.999999... Hz — first 4 decimal places exact, 5th decimal lost to printf rounding).
- **Peak-to-peak jitter: 1 tick** (= 10 ns). Spec ceiling was 100 ticks; we're 100× under.
- **Stdev: 0.3 ticks.** Most periods are exactly 2,000,000; ~10% pick up an extra tick (2,000,001) to absorb the 0.1-tick-per-period quantization residual from `2,857,143 × 7 ns = 20,000,001 ns` not being a clean integer in 100 MHz counter ticks.

vs the output vsync rate measured in Phase 1 (50.0004 Hz / 1,999,985 ticks per period): synthetic ref is **0.0004 Hz / 8 ppm** slower than output. Well inside MMCM ±500 ppm pull range — Phase 4–6's loop has comfortable headroom.

### Pass criteria summary (per §4 Phase 2)

- [x] `q` shows `ts_ref_count` advancing at the configured rate (50 Hz)
- [x] `c` capture parses cleanly with the analyzer (1000/1000 rows)
- [x] Mean period at the intended rate (exactly 50.0000 Hz)
- [x] Peak-to-peak period jitter < 100 ticks (got 1 tick)

## Build provenance

- **Branch:** `phase-e1-pll-spike`
- **Vivado:** WNS = +0.306 ns, WHS = +0.020 ns
- **Address map:** unchanged from Phase 1 (`vsync_timestamp_0` still at `0x4000_0000`)

### First-attempt log (DIVISOR=2,500,000 → 57.143 Hz)

Saved at `tests/phase-e1/phase2_uart_initial_57hz.txt` for the record. That capture was the empirical proof FCLK_CLK1 actually runs at 1000/7 MHz, which informed the DIVISOR=2,857,143 fix.

## Artifacts

| File | Purpose |
|---|---|
| `hdl/synth_vsync_gen.v` | New 60 Hz divider |
| `tcl/build_phase_b.tcl` | BD edits (replaces tied-low with divider output) |
| `sw/phase-b/src/main.c` | New `c` / `C` capture commands |
| `scripts/analyze_phase2_reference.py` | CSV analysis tool |
| `tests/phase-e1/phase2_reference.md` | This doc |
| `tests/phase-e1/phase2_reference.csv` | TBD — 1000-sample capture |
| `tests/phase-e1/phase2_uart.txt` | TBD — raw UART capture |

## Notes (physics caveat)

Both the synthetic ref (FCLK_CLK1 / 2.5M) and the output pixel clock (FCLK_CLK0 → MMCM) descend from the TE0720's onboard ~33.333 MHz `PS_REF_CLK` crystal via the same PS PLL. They are therefore *rationally related* at zero ppm drift — any apparent "drift" Phase 3 will measure is the constant offset from the divider/MMCM ratios not landing on exactly 60.000 Hz against exactly 60.000 Hz vsync.

This was explicitly accepted in the planning phase: the spike validates the loop *topology* against any deterministic reference. The actual real-crystal-vs-real-crystal drift number is deferred until the Si5351 reference hardware is on the bench (per user direction, ground-up plan §4 Phase 2 footnote re-interpreted).
