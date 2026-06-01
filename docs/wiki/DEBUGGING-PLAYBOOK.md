# Debugging Playbook

When-X-happens-do-Y. Hard-won project rules distilled from memory entries and incidents.

## Core rules (non-negotiable)

### No-coin-flip rule

If output differs across cold-boots, **STOP**. Do not bench-test other features on a coin-flipping build — fix root cause or revert.

Memory: `schindler_no_coin_flip_rule`. Originated 2026-05-21 after a vsync-phase coin-flip masked a different bug for hours.

### MS2109 trap

**Never** use the HDMI capture stick for motion-artifact verification. It has its own framebuffer that absorbs FRC drift / tearing / vertical wrap. Use only for static-content reference.

Memory: `schindler_ms2109_verification_trap`. All pre-2026-05-21 PASS claims that relied on MS2109 are suspect.

### Build provenance

Every claim of "this works" must reference:
- Specific commit hash
- Reboot count
- Symptom (or lack thereof)

Memory: `schindler_build_provenance_rule`.

### Equipment first

When you observe something architecturally impossible (e.g., scaler is bypassed but image is still scaled), **suspect bench equipment before assuming an FPGA bug**: monitor, cable, source, switcher.

Memory: `schindler_bench_equipment_confounder`. Faulty monitor cost ~4 hours on 2026-05-21.

### Source first

When dvi2rgb's `pLocked` flickers (LD1 cycles), **swap the HDMI source before investigating FPGA placement/clocking**. Source-side noise causes most pLocked instability.

Memory: `schindler_source_first`.

### No diagnostic Heisenbugs

If a symptom only appears with debug instrumentation on (printfs, mid-transaction register reads), **suspect the debug code is causing the bug**. Especially in tight I²C transactions.

Memory: `bench_diagnostic_heisenbug`.

## Common symptoms → root causes

### Picture rolls or scrolls

| Sub-symptom | Likely cause | Reference |
|---|---|---|
| Deterministic offset same per boot | Firmware vtc_setup() alignment math off | `build-manifest.md` §2026-05-21 |
| Random offset per boot | Vsync-phase coin-flip | `schindler_phase_d_vsync_phase` memory |
| 1-row-per-frame drift | S2MM VSIZE over-allocate (iter4h class) | `schindler_iter5_bisect_findings` memory |
| Slow scroll under FRC | MMCM tracking out-of-pull or PLL not configured | `phase-e1-pll-spike` branch + memory |

### Horizontal shift / misaligned cols

| Sub-symptom | Likely cause |
|---|---|
| 2-3 pixels per line, last cols of row N appear at start of row N+1 | Scaler kernel carryover (FIXED iter12; see `iter6-h-shift-analysis.md` for forensics) |
| Whole frame shifted by N cols | Firmware DMA address calc off |

### Vertical line dropping / wrong line count

| Sub-symptom | Likely cause |
|---|---|
| Every 3rd horizontal line missing | V scaler NN bypass dropping rows (FIXED iter13) |
| Random line dropouts | Source signal issue OR EOLLate trap |

### EOLLate / SOFLate flags

| Flag | Real meaning | Notes |
|---|---|---|
| `S2MM_SR bit 15` = EOLLate | TLAST arrived after expected end-of-line | Per `xilinx_vdma_dmasr_bits` memory: bit 12 is FrmCnt_Irq (BENIGN), bit 15 is the real EOLLate |
| `SOFLate` | TUSER arrived after start-of-frame expected | Cosmetic post-iter6; see [KNOWN-BUGS](KNOWN-BUGS.md) |

### I²C NAK / multi-byte writes failing

Memory chain: `axi_iic_dynsend_pattern` → `axi_iic_dynamic_mode_atomicity` → `i2c_pullup_rule` → `si5351_sys_init_poll`.

**Quick checklist:**
1. External 2.2kΩ pull-ups on SDA/SCL (NEVER rely on FPGA internals)
2. Check for missing RESTART (Si5351 chip class issue per `si5351_chip_missing_restart`)
3. For SYS_INIT-gated chips: poll reg 0 bit 7 == 0 before any RAM write
4. AXI IIC dynamic mode: do NOT insert delays between TX_FIFO byte pushes (premature STOP)
5. Bench diagnostic Heisenbug: if turning on per-byte debug snapshots makes it worse, suspect the debug code

### Picture freezes mid-row

**Suspect AXIS tready combinational loop.** When AXIS slaves have N>1 inputs, never make `tready` depend on incoming `tvalid` — creates closed combinational loops in fan-out topologies that synth-pass but deadlock in silicon.

Memory: `axis_tready_independence`. Cost ~30 min debug on Mackin 2026-05-18.

### Counter / register reads return wrong upper bits

**Suspect CDC width mismatch.** Internal sync regs must match declared port widths. Memory: `axi_sync_inputs_cdc_width`. Cost iter5b ~30 min when `out_tlast_snap` upper bits read zero.

### Scope shows the event, firmware doesn't

Could be (a) Heisenbug from debug instrumentation perturbing timing, or (b) `XPAR_VTC_0` aliasing trap — adding a second VTC silently re-aliases the first. Always use explicit `XPAR_V_TC_TX_BASEADDR` / `XPAR_V_TC_RX_BASEADDR` in firmware. Memory: `xilinx_xpar_vtc_aliasing`.

### Sims pass but bench-test fails

Most likely: stale Vitis source copy. Memory: `vitis_importsources_stale_copy`. Re-run full Vitis tcl to force re-copy, not incremental.

### "Why is my new counter always zero?"

CDC width truncation — see `axi_sync_inputs_cdc_width`.

### Scaler kernel produces wrong-tap pixels

If you change the scaler kernel and see row-shift / column-shift artifacts, **check window-clear-on-TLAST** (iter7 lesson). Old row's tail bleeds into new row's first pixels. Memory: `schindler_scaler_kernel_iter12_iter13`.

## Diagnostic tools at hand

### DDR3 byte dump

UART-triggered (see [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md)). Reads the framebuffer slot directly bypassing the rest of the pipeline. Decisive for "what did S2MM actually write?"

### Boundary-col DDR3 dump (HEAD+TAIL)

First 10 + last 10 cols of N rows. Localizes row-boundary artifacts. Used in iter6→iter12 H-shift work.

### UART telemetry stream

Per-frame counters: `S2MM_SR`, `MM2S_SR`, `RDSTORE`, `WRSTORE`, `src=X/Y out=Z`. See [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md).

### scaler_v out_tlast_count_snap

Counter for emitted TLAST per frame. If = 720, scaler is healthy; if < 720, scaler aborting emits. Disambiguates A2-scaler from A2-S2MM.

### scaler_crop_bypass module

Drop-in 1280×720 crop replacing scaler_top, picked via `SCALER_MODULE` env var. Useful for bisecting scaler vs. downstream. Memory: `schindler_scaler_crop_bypass`.

### Bench-debug instrumentation preference

When stuck in a long debug session, **build diagnostic infrastructure (UART dumps, register probes) before guessing.** Memory: `schindler_bench_debug`.

<!-- AGENT_TASK[fw-2]: Make boundary-col dump_slot_head_pixels available via UART command on iter5-1080p-clean and mackin-impl-wip (currently only diag_iter-triggered; phase-e1 has it on `F`). Consistency. -->

## When all else fails

Re-read the manifest's "How to recreate the cleanest known build" footer. Reset to known-good. Bisect from there.
