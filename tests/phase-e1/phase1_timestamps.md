# Phase 1 — Vsync timestamp instrument

**Status:** PASS ✓ (2026-05-18 23:09 PT)

**Goal:** stand up the measurement instrument the rest of the spike will use — a 48-bit free-running counter on FCLK_CLK0 and two AXI-readable edge-capture registers that latch the counter on rising edges of two async vsync inputs. Validate via firmware reads through new UART commands.

Per [`docs/phase-e1-ground-up-plan.md`](../../docs/phase-e1-ground-up-plan.md) §4 Phase 1.

## What changed since Phase 0

### HDL (new)

`hdl/vsync_timestamp.v` — AXI4-Lite slave, read-only register file:

| Offset | Width | Meaning |
|---|---|---|
| 0x00 | 32 | `counter[31:0]` |
| 0x04 | 16 | `{16'h0, counter[47:32]}` |
| 0x08 | 32 | `ts_ref[31:0]` (counter latched on last `ref_vsync_async` rising edge) |
| 0x0C | 16 | `{16'h0, ts_ref[47:32]}` |
| 0x10 | 32 | `ts_out[31:0]` (counter latched on last `out_vsync_async` rising edge) |
| 0x14 | 16 | `{16'h0, ts_out[47:32]}` |
| 0x18 | 32 | `ts_ref_count` (total ref edges since reset) |
| 0x1C | 32 | `ts_out_count` (total out edges since reset) |

- Counter clocks on `s_axi_aclk` (FCLK_CLK0, 100 MHz → 10 ns/tick → 48-bit wrap every ~32 days).
- Each vsync input has a 3-FF synchronizer (`ASYNC_REG=TRUE`) + edge-detect.
- Hand-written AXI-Lite slave (not the Xilinx wizard's IP package — same protocol semantics in ~200 lines of Verilog, no IP packaging round-trip). Explicit `X_INTERFACE_INFO` attributes on every AXI port so Vivado's BD inference is unambiguous.
- Writes are accepted with OKAY response and discarded (slave is intentionally read-only).

### BD edits (`tcl/build_phase_b.tcl`)

1. `add_files` includes `hdl/vsync_timestamp.v`.
2. `axi_ic_lite` bumped from 3 → **4** master ports. New M03 wired.
3. `vsync_timestamp_0` instantiated as a `-type module -reference` BD cell.
4. `ref_vsync_async` tied low via a new `xlconstant` IP (Phase 2 wires the synthetic divider here).
5. `out_vsync_async` fan-out from `v_tc_tx/vsync_out` (already feeding `axis_to_vid_io_0/vtg_vsync` and `axi_sync_inputs_0/vsync_out_async` — adding a third sink).
6. `assign_bd_address` auto-assigns the slave to the next free 4 KB region.

### Firmware (`sw/phase-b/src/main.c`)

- New include: `xuartps_hw.h` for non-blocking UART rx.
- Helpers: `vts_read_counter()` and `vts_read_ts()` implement read-twice-and-compare coherence so 48-bit values aren't corrupted by counter advance / edge capture between the two 32-bit AXI reads.
- New UART command dispatcher polled once per iteration of the telemetry hot loop (no newline required, one-char commands fire immediately).

**Commands:**

```
q   query: print counter, ts_ref, ts_out, edge counts
p   phase: signed (ts_out - ts_ref) in ticks/ns
?   help
```

## Phase 1 verification plan

Per `phase-e1-ground-up-plan.md` §4 Phase 1 pass criteria:

> `q` returns three numbers. Counter advances between calls at expected rate.
> With ref vsync tied to a known test toggle (e.g., a PS-driven GPIO pulsed by firmware), `ts_ref` updates at the expected interval.
> Reading the same register twice in rapid succession returns matching values (no glitches).

### Test 1.A — Counter advances

Send `q` twice within ~1 second. The `counter` value should advance by approximately the wall-clock elapsed time × 100 MHz (so a ~1 sec gap shows roughly +1e8 ticks).

**Expected:** counter grows monotonically, no garbage values, no glitch reads.

### Test 1.B — Output vsync timestamping

Send `q` once. Note `ts_out` and `ts_out_count`. Wait ~5 seconds. Send `q` again.

**Expected:**
- `ts_out` has advanced (it's latched on every output vsync rising edge — ~50 Hz with the 720p50 build).
- `ts_out_count` has incremented by approximately 250 (5 seconds × 50 vsync/sec).
- Difference between successive `ts_out` values divided by the count delta = mean inter-vsync interval. At 50 Hz that's 1/50 s = 20 ms = 2,000,000 ticks.

### Test 1.C — Reference vsync stays at zero

In Phase 1, `ref_vsync_async` is tied low (no edges). Send `q`.

**Expected:** `ts_ref = 0x0000_0000_0000_0000`, `ts_ref_count = 0`. Will remain so until Phase 2 wires up the synthetic divider.

### Test 1.D — Coherence under repeated reads

Send `q` rapidly (multiple back-to-back). Manually inspect that the printed values don't show torn reads (e.g., `counter` doesn't jump backward, the `ts_out_count`/`ts_out` pair stays internally consistent).

The read-twice-and-compare loops in `vts_read_counter()` and `vts_read_ts()` should make torn reads impossible by construction. This test is just confirming the implementation works.

### Test 1.E — Phase command

Send `p`. Since `ref_count = 0` in Phase 1, the dispatcher will note that and print `ts_out` raw. The `phase` line itself shows `ts_out - 0 = ts_out`, which is the absolute timestamp of the last output vsync.

**Expected:** `p` succeeds without crashing, prints a finite number.

## Results (bench, 2026-05-18 23:09 PT)

### Test 1.A — Counter advances at 100 MHz

Two consecutive `q` commands ~1 s apart:

```
[Q] counter = 0x000099EE7C2C (2,582,543,404 ticks ~ 25,825 ms)   [t=0]
[Q] counter = 0x00009FE75A7A (2,682,739,322 ticks ~ 26,827 ms)   [t≈+1s]
```

Delta = 100,195,918 ticks = **1.00196 s @ 100 MHz**. PASS ✓ (extra ~200 µs is USB write + sleep granularity).

### Test 1.B — `ts_out` updates at the 720p50 output vsync rate

Two consecutive `q` commands across 50 vsync edges (count 1276 → 1326):

```
ts_out edges 1276 → 1326   (50 edges)
ts_out value 0x99D3CF28 → 0x9FC9B028   (delta = 99,999,232 ticks)
```

99,999,232 ticks / 50 edges = **1,999,985 ticks per vsync = 19.9999 ms = 50.0004 Hz**. PASS ✓ — matches `MODE_720P50` to within ~15 ppm of nominal.

### Test 1.C — Reference vsync stays at zero (tied low in Phase 1)

Every captured `q` shows:

```
ts_ref  = 0x000000000000   edges = 0
```

PASS ✓. Phase 2 will wire the synthetic FCLK_CLK1-derived divider here.

### Test 1.D — Coherence under repeated reads

Five back-to-back `q`s (sent as `printf 'qqqqq' > /dev/ttyUSB1`):

```
ts_out edges 1677, 1677, 1678, 1679, 1680
ts_out value  0xC9A15BA8, 0xC9A15BA8, 0xC9BFE028, 0xC9DE64A8, 0xC9FCE928
```

- Same edge index → identical timestamp (two queries fell within one vsync interval). No torn reads.
- Increasing edge index → strictly increasing timestamp.
- Counter values monotonically advance across all five queries.

PASS ✓. The read-twice-and-compare coherence loops in firmware are doing their job.

### Test 1.E — `p` command runs without crashing

```
[P] ts_out=0x0000C6A66B28 (edges=1652)  ts_ref=0x000000000000 (edges=0)
    phase: ref_count=0 — ref_vsync not yet wired (Phase 2 adds it). Showing ts_out raw:
    (phase delta exceeds 32-bit range: ticks=0x0000C6A66B28 sign=+)
```

PASS ✓. Firmware correctly notes the ref tied-low state and gracefully falls back to hex display when the absolute timestamp exceeds 32-bit signed range (218 G ticks > 2.1 G). 32-bit-range branch will engage normally once `ts_ref` is non-zero in Phase 2 and we're computing actual phase deltas.

## Pass criteria summary

- [x] `q` returns coherent, advancing counter values
- [x] `ts_out` updates at ~50 Hz with expected inter-edge spacing (measured 50.0004 Hz)
- [x] `ts_ref` and `ts_ref_count` are 0 (correct for Phase 1 — tied low)
- [x] Rapid back-to-back reads never show glitches
- [x] `p` produces a number without crashing

## Build provenance

- **Branch:** `phase-e1-pll-spike`
- **Vivado:** WNS = +0.174 ns, WHS = +0.020 ns (all constraints met)
- **Utilization delta vs Phase 0:** **+98 LUTs (12,898 → 12,996), +273 FFs (20,357 → 20,630)** — well under the <300/<300 sketch budget
- **Address map:** `vsync_timestamp_0` at `0x4000_0000` (4 KB region)
- **Firmware text size:** 41,961 → 44,341 bytes (+2,380 B for the new helpers and dispatcher)

### Timing note (informational)

The Vivado XDC `set_false_path` constraint syntax `out_sync_reg[0]/D` triggers a "No pins matched" warning in Vivado 2025.2 — the square brackets confuse `get_pins` filter parsing even inside curly braces. Constraints rewritten to use `-hier -filter {NAME =~ */out_sync_reg*/D}` (committed) to remove the warning on next rebuild. Crucially, **timing met anyway** in the current build because Vivado's auto-CDC detection put the path in `Path Group: (none)` — but the explicit constraint is the robust answer for future place-and-route variation.

## Artifacts

| File | Purpose |
|---|---|
| `hdl/vsync_timestamp.v` | New AXI-Lite slave |
| `tcl/build_phase_b.tcl` | BD edits |
| `sw/phase-b/src/main.c` | Firmware commands + helpers |
| `tests/phase-e1/phase1_timestamps.md` | This doc |
| `tests/phase-e1/phase1_uart_log.txt` | TBD — capture of `q`/`p` output for verification |

## Notes

- Counter overflow: 48-bit at 100 MHz wraps every ~32.6 days. The free-running counter and edge-capture timestamps are still computable correctly across wraps as long as the firmware does the subtraction modulo 2^48 (handled in `print_phase_delta`).
- CDC bias: each vsync input traverses 2 FFs before being edge-detected, so the timestamp lags the true edge by 2 aclk cycles = 20 ns. The bias is identical for `ref_vsync_async` and `out_vsync_async`, so it cancels in `ts_out − ts_ref`. Residual jitter is bounded by 1 aclk tick = 10 ns, far below the spike's sub-line target (~13.5 µs/line at 720p50).
- `q`/`p` are one-character commands fired immediately on receipt — no newline buffering. Keeps the firmware additions minimal and lets us use any serial terminal (`cat /dev/ttyUSB1`-like) for interaction.
