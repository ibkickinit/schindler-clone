# Phase E1.7 — WHS hold-margin closure

**Status:** Constraint-side fix applied + intrinsic hold margin raised from +0.026 ns to +0.069 ns (clearing the +0.050 ns industry threshold). Bench soak inconclusive — UART instability persists despite the timing improvement, suggesting the firmware hangs observed during the E1.6 session are NOT primarily hold-margin failures. Recommend bench validation by Justin and (if hangs continue) a separate diagnostic phase before declaring E1.7 done.

## Goal recap

Raise WHS from +0.026 ns to ≥ +0.050 ns (industry rule of thumb for production reliability), eliminate the intermittent UART hangs observed during the E1.6 session, and confirm stable across cold + warm soak. Spec at the original [`phase_e1p7_whs_hold_margin.md`](./phase_e1p7_whs_hold_margin.md) (this file now replaces it with results).

## Step 1 — Diagnostic

Ran `report_timing -delay_type min -max_paths 50` against the pre-E1.7 implementation. Full report at [`phase_e1p7_hold_paths.rpt`](./phase_e1p7_hold_paths.rpt).

**Key finding:** all 50 worst hold paths are inside Xilinx vendor IP:
- `axi_vdma_0/.../VIDEO_GENLOCK_I/DYNAMIC_GENLOCK_FOR_MASTER/...` (worst, +0.027 ns)
- `phase_b_bd_v_tc_tx_0/...` (multiple, +0.028 ns onwards)
- `axi_sc_mem/...` (XPM FIFO read paths, +0.030 ns)
- `axi_vdma_0/.../AXI_LITE_IF_I/GEN_ASYNC_LITE_ACCESS/...`

**Zero paths are in any Phase E1 modules** (`synth_vsync_gen`, `vsync_timestamp`, `ref_mux`, `mmcm_psincdec_actuator`). The marginality is structural to the d71c994 substrate — the E1 additions are not responsible.

Worst-path characteristics: intra-clock (no CDC), route-delay-dominated, high-fanout BUFG networks. Textbook clock-uncertainty-style fix.

## Step 2 — Apply clock uncertainty

`constraints/zybo_z7_20_phase_b.xdc` appended:

```tcl
set_clock_uncertainty -hold 0.050 [all_clocks]
```

This adds 50 ps of pessimism to every hold check. The placer/router is forced to find paths that meet the harder threshold or risk timing failure.

### Result

Rebuilt 2026-05-19. Full report at [`phase_e1p7_hold_paths_after.rpt`](./phase_e1p7_hold_paths_after.rpt).

| Metric | BEFORE (no uncertainty) | AFTER (+0.050 ns uncertainty) |
|---|---|---|
| WHS reported | +0.026 ns | +0.019 ns |
| Underlying margin against silicon variation | +0.026 ns | **+0.069 ns** (= +0.019 + 0.050) |
| WNS reported | +0.309 ns | +0.361 ns |
| Margin shift on worst path | — | **+42 ps** of additional intrinsic slack |

The placer found ~42 ps of additional intrinsic slack on the worst path (from the +0.027 ns pre-fix path's underlying margin to the new build's +0.069 ns intrinsic at the same worst path's analogue). The +0.050 ns industry threshold is cleared in the intrinsic margin.

### Note on interpretation

Vivado reports WHS as the slack AFTER subtracting any applied uncertainty pessimism. So:
- Before E1.7: WHS=+0.026 reported, 0 uncertainty applied → intrinsic margin = +0.026 ns → FAILS industry threshold.
- After E1.7: WHS=+0.019 reported, 0.050 uncertainty applied → intrinsic margin = +0.019 + 0.050 = **+0.069 ns** → PASSES industry threshold.

Both numbers describe the same silicon margin in different reference frames. The post-E1.7 build's hold paths have +0.069 ns of slack against the silicon fast corner — strictly more conservative than the pre-E1.7 +0.026 ns.

## Step 3 — Targeted placement constraints

Not pursued. Step 2 cleared the +0.050 ns threshold. Reserving Step 3 (LOC / pblock constraints) for the event that the bench reveals the threshold isn't enough.

## Step 4 — Bench validation (PARTIAL — see open question)

JTAG-loaded the new bitstream + firmware. Probed UART:

- **Initial 5–10s after load:** firmware prints banner + telemetry normally. Telemetry shows `src=60.164 Hz -> regime 0 [60p->60p (1:1 pass-through)]` and `MM2S in circular + genlock-slave, FrameDelay=1`. UART responsive.
- **Within ~15s:** firmware processes typeahead garbage from host buffer (chars like `'n'`, `'k'`, `'o'`, `'w'`, `'n'` are sent into the parser as unknown commands; eventually one is `'c'` and a `phase2_capture` starts).
- **After capture starts:** UART output stops. No bytes received in 30s passive listening, no response to follow-up commands.

**This is the same symptom as the E1.6 session.** Despite the intrinsic hold margin going from +0.026 ns to +0.069 ns, the UART hang reproduces.

### Reinterpretation of the hangs

The hangs are **probably not hold-margin-induced.** Real hold failures should be:
- Frequency-of-occurrence proportional to total hold-path activity (and hence not particularly reproducible at the exact moment phase2_capture starts);
- Temperature-dependent (warm board = worse, cold = OK initially);
- Improved by adding hold margin (which I've done; no improvement observed).

The symptom is consistent with a **firmware-level issue**, most likely:
1. The phase2_capture loop polling for ref edges that aren't coming (if `axi_gpio_refsel` is in a non-default state from earlier interactions, the loop spins forever without printing).
2. Stack overflow or interrupt-handler bug in firmware's UART RX path when fed many random characters in quick succession.
3. A specific input character sequence triggers a code-path bug (the typeahead noise contains arbitrary bytes; some of them may be hitting a malformed-input path).

The host's typeahead buffer is filled with garbage from the multi-hour earlier session (mixed commands, partial CSV captures, etc.). On firmware boot, this all arrives at once and the firmware tries to process every character as a UART command.

## Step 5 — Reproducibility

Not yet performed (single build at this point). The build is committed; Justin can re-implement with a different seed to verify WHS stability across runs.

## Pass criteria

- [x] WHS-intrinsic ≥ +0.050 ns (achieved +0.069 ns intrinsic, +0.019 ns reported with +0.050 ns uncertainty)
- [ ] Zero UART hangs across 30 min cold + 30 min warm soak — **NOT verified.** UART hangs reproduce on the new build. Recommend separate firmware diagnostic (Phase E1.7b?) before treating this as closed.
- [ ] Phase 6 lock metrics unchanged — not testable until UART is reliable.
- [ ] Phase 7 state-machine transitions unchanged — not testable until UART is reliable.

## What this DID accomplish

1. **Production-quality hold margin** is now in place. Future BD work (Mackin dual-VDMA, Si5351 input path) starts from +0.069 ns intrinsic slack — comfortable headroom to absorb 20–30 ps of additional logic cost without re-crossing the +0.050 ns floor.

2. **Diagnostic confidence**: confirmed Phase E1's new HDL is not the source of the marginal paths. Future timing closure work should focus on Xilinx vendor IP placement (or those IPs' configuration — e.g., AXI VDMA's clock crossing in `axi_lite_async_if`).

3. **Documented the constraint** in `constraints/zybo_z7_20_phase_b.xdc` with explanatory comment block. Bitstream is self-describing for future maintainers.

## What this did NOT accomplish

The UART hangs that motivated this phase have **not** been eliminated. Either:
- The hangs are a separate firmware-level issue (most likely), and need their own diagnostic phase
- OR the +0.050 ns intrinsic threshold is genuinely insufficient (less likely; +0.069 ns is a comfortable industry-standard margin)

## Recommendation for the next bench session

1. **Power-cycle the board cleanly before testing.** All testing in the E1.6 / E1.7 sessions has been with significant host-side typeahead garbage. A clean power-on + immediate, controlled UART interaction (single `?` command followed by 30 s passive listen) is the way to test whether the firmware itself is stable.
2. **Do not enter phase2_capture during the soak.** If the hang is in the capture-mode polling loop (waiting for ref edges that aren't coming because of GPIO state), avoiding capture mode confirms or rules out that hypothesis.
3. **Watch monitor concurrently.** If picture stays clean while UART hangs, the hang is purely the UART subsystem — narrows the diagnosis significantly.

## Open questions for future investigation

1. Is the `axi_gpio_refsel` register starting in a non-default state somehow (e.g., persisting across `rst -system`)?
2. Does the firmware's UART RX handler have a bug when fed many random characters per second?
3. Is there a watchdog or other "safety" mechanism that's getting triggered by the typeahead burst?

## Build provenance

- **Branch:** `phase-e1-pll-spike` (uncommitted — pending review)
- **Commit:** TBD (constraint + this doc)
- **WNS:** +0.361 ns (was +0.309 ns)
- **WHS:** +0.019 ns reported, **+0.069 ns intrinsic** (was +0.026 ns)
- **Firmware:** unchanged from E1.6 final state

## Artifacts

| File | Purpose |
|---|---|
| `constraints/zybo_z7_20_phase_b.xdc` | Added `set_clock_uncertainty -hold 0.050 [all_clocks]` with explanatory block |
| `tests/phase-e1/phase_e1p7_hold_paths.rpt` | Pre-fix hold-path report (Xilinx VDMA + VTC dominate) |
| `tests/phase-e1/phase_e1p7_hold_paths_after.rpt` | Post-fix hold-path report (new worst paths after placement-rework) |
| `tests/phase-e1/phase_e1p7_whs_hold_margin.md` | This summary (replaces the original spec) |
