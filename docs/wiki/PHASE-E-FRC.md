# Phase E — FRC Sub-Phases

The Phase E roadmap delivers production-grade FRC: MMCM tracking + Si5351 actuator + Mackin temporal blend + Triple Buffer + Phase E4 scaler reposition.

Source corpus: memories `schindler_phase_e_roadmap`, `schindler_phase_e1_state`, `schindler_phase_e2_si5351_state`, `schindler_mackin_implementation`, `frc_mackin_virtual_shutter_blend`, `xilinx_mmcm_psincdec_tracking`, `si5351_*` (4 entries), `jessinie_si5351_breakout`.

## Sub-phase status

| Phase | Title | Status | Branch |
|---|---|---|---|
| **E1** | MMCM `psincdec` tracking | ✅ Spike shipped 2026-05-19 | `phase-e1-pll-spike` |
| **E2** | Si5351 actuator + Mackin blender | 🟡 Both partial; both blocked | (Si5351 on `phase-g-iter1`; Mackin on `mackin-impl-wip`) |
| **E3** | Triple Buffer / Async Ring (RT4K compat mode) | 🔲 Not started | — |
| **E4** | Scaler reposition to output side (enables upscaling) | 🔲 Not started | — |

## Phase E1 — MMCM tracking ("Gen Lock")

**Status:** shipped on `phase-e1-pll-spike` (commit `42fe057` per `schindler_phase_e1_state`; later commits added experiments). Bench-clean 60→60 matched-rate motion as of 2026-05-30 (`fcd722c`).

**Design:** firmware measures vsync delta between source and output; PI controller computes per-frame phase step; applies via clk_wiz DRP to nudge `clk_wiz_pixclk_out`.

**Range:** ±500 ppm pull. MMCM `psincdec` hardware floor. Sufficient for NTSC 1000/1001 drift; insufficient for large FRC ratios (5:2 etc.). For those, drop down to Method D (Dynamic Genlock).

**Scope constraint (2026-05-30 doc-only):** the commit message `fcd722c` declared phase-e1 "out of scope" for large FRC ratios. **2026-05-30 Test Methodology Auditor flagged:** this is a documentation-only constraint with no supporting failure test. Should be validated or relaxed.

**Open work:** iter13b backport (rounding fix) from iter5-1080p-clean. Pure cherry-pick + Vivado rebuild.

<!-- AGENT_TASK[hdl-10]: Backport iter13b (+1 round-to-nearest) from iter5-1080p-clean. ~30 min wall-clock. -->

<!-- AGENT_TASK[bench-5]: Validate or relax the ±500 ppm scope constraint in fcd722c. Either run a stress test pushing phase-e1 toward 5:2 and document the failure mode, OR remove the constraint and let auto-FRC engage Method D when E1 saturates. -->

## Phase E2 — Si5351 + Mackin

### Si5351 (the actuator)

External programmable clock generator. Extends pull range beyond MMCM's ±500 ppm — to several thousand ppm. Required for ugly-ratio FRC when MMCM alone can't track.

**Status per `schindler_phase_e2_si5351_state` memory:**
- **Phase A** (chip alive at 0x60) — PASS 2026-05-20
- **Phase B** (10 MHz on CLK0 verified) — PASS 2026-05-20
- **Phase C-lite** (Si5351 drives FPGA PLL via Pmod JB Pin 7) — PASS 2026-05-20
- **Phase C** (MRCC pin Y7 selected) — PASS 2026-05-20
- **Phase D Stage 1** (`si5351_set_freq_hz` + UART + scope smoke) — **🔴 BLOCKED 2026-05-20 evening**

**Phase D blocker:** multi-byte I²C writes NAK probabilistically. Single-byte probe ACKs reliably. Multi-agent research 2026-05-21 identified **3 reinforcing root causes**:

1. **Wrong AXI IIC prologue.** Firmware uses `CR=0x03→0x01` error-recovery sequence as a prologue instead of `XIic_DynSend` happy-path. The CR transitions half-arm the FSM and the TX_FIFO never drains. See `axi_iic_dynsend_pattern` memory.
2. **SYS_INIT not polled.** Si5351 requires polling reg 0 bit 7 == 0 before any RAM write. Probe ACKs before SYS_INIT clears; writes during SYS_INIT silently fail. See `si5351_sys_init_poll` memory.
3. **JESSINIE breakout decoupling marginal.** "Transactions worse with longer gaps" = supply-droop fingerprint. Piggyback 0.1 µF cap + 1 kΩ pull-ups recommended. See `si5351_jessinie_breakout` memory.

**Plus** a fourth issue identified 2026-05-21: Si5351 chip treats reads as malformed writes when SDA rise time is too slow during RESTART. Fix bus signal integrity (1 kΩ pull-ups, decoupling) before more firmware debug. See `si5351_chip_missing_restart` memory.

**Resume plan:** apply all four fixes in one bench session. Per `schindler_phase_e2_si5351_state`, plan inline in `tests/phase-e1/si5351_phase_d_session_2026-05-20_evening.md` (NOT in repo — informal session notes; treat as historical reference, not a file to open).

Branch: `phase-g-iter1` (Si5351 driver lives alongside ADV7393 BD on this branch).

<!-- AGENT_TASK[fw-6]: Apply the 4-cause Si5351 multi-byte fix. (a) Replace error-recovery prologue with XIic_DynSend happy-path; (b) Add SYS_INIT poll before writes; (c) Order JESSINIE bus-SI fixes (1kΩ pull-ups, 0.1µF cap piggyback); (d) Verify SDA rise time is fast enough during RESTART. -->

### Mackin temporal blender (the algorithm)

HDL + Python golden + 3360-vector sim suite complete on `mackin-impl-wip` branch (`aff2c43` + iter6/iter12+13 backports). Sim PASS 100% bit-exact.

**Bench wiring is placeholder `axis_clone`** — both VDMA paths feed the same frame so `a <hex>` alpha command has no visible effect. Real temporal blending requires:
- Reconfigure `axi_vdma_0` from Dynamic Genlock → classic Genlock
- Add a second MM2S-only VDMA on HP2
- Wire slot fan-out so MM2S #1 reads N-1 and MM2S #2 reads N
- Feed both into Mackin's blend math

~1 day of BD work. Deferred for substrate stability. Memory: `schindler_mackin_implementation`.

<!-- AGENT_TASK[hdl-11]: Replace AXIS clone with dual-VDMA + classic-Genlock wiring on mackin-impl-wip. Detailed plan in schindler_mackin_implementation memory. ~1 day BD work. -->

## Phase E3 — Triple Buffer ("Compatibility")

Free-running output + 5-slot framestore ring + firmware hysteresis. Pickiest-sink fallback mode. Accepts visible drop/repeat.

Not started. Documented in `schindler_phase_e_roadmap` memory + `frc-architecture` page.

## Phase E4 — Scaler reposition to output side

Required for upscaling (currently downscale-only). Move polyphase scaler from input-side (post-dvi2rgb) to output-side (post-MM2S, pre-axis_to_vid_io). Enables:
- 480p60 → 720p60 (matrix row 17)
- 720p60 → 1080p60 (row 20)
- Any "SD up to HD" path

Not started.

<!-- AGENT_TASK[hdl-12]: Phase E4 — design upscaling path. Move polyphase scaler to output side. Major architectural change. -->

## Phase E roadmap dependencies

```
Phase E1 (MMCM tracking)   ──┬──► Phase E2 (Si5351 + Mackin) ──┬──► Phase E3 (Triple Buffer)
   shipped on phase-e1       │      Si5351 BLOCKED              │       not started
                             │      Mackin sim-only             │
                             └──► Phase E4 (Scaler reposition)  │
                                    not started                 │
                                                                │
                                                                └──► full FRC method auto-selection
                                                                       (operator-facing UI)
```

## Compass: where this is going

Memory `schindler_frc_architecture_compass` documents the long-term FRC vision:
- VDMA Dynamic Genlock stays as the substrate (v_frmbuf has no drop/repeat, so we can't change)
- Long-term: **RT4K three-mode UX + Mackin virtual-shutter blend**
- Operator picks Frame Lock / Gen Lock / Triple Buffer at runtime; Mackin auto-engages within Gen Lock at ugly drift ratios

See [FRC-ARCHITECTURE](FRC-ARCHITECTURE.md) for the method codes (A/B/C/D/E) and current shipping subset.
