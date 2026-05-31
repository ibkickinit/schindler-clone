# Firmware Interface

How firmware exposes runtime controls + telemetry. UART command reference + AXI GPIO map + DIAG print field meanings.

Source: `sw/phase-b/src/main.c` (~2000+ lines on iter5; smaller on other branches), memory `schindler_uart_commands`, `schindler_color_pipeline`.

## UART

`/dev/ttyUSB1` @ 115200 8N1, line-terminated (`\r` or `\n`). Non-blocking polled poll in telemetry loop.

```bash
# Listen:
picocom -b 115200 /dev/ttyUSB1
# or:
stty -F /dev/ttyUSB1 115200 cs8 -parenb -cstopb -echo raw
cat /dev/ttyUSB1

# Send:
printf 'i\r' > /dev/ttyUSB1
printf 'w 255 200 140\r' > /dev/ttyUSB1
```

### Command reference (iter5 / mackin)

Most commands available on all production branches; some branch-specific:

| Cmd | Description |
|---|---|
| `?` | Help |
| `i` | Color matrix → identity |
| `g` | Color matrix → Rec.601 grayscale |
| `s <pct>` | Saturation 0..200% |
| `m <pct>` | Matrix-derived saturation 0..200% |
| `b <r> <g> <b>` | Black levels per channel 0..255 |
| `w <r> <g> <b>` | White levels per channel 0..255 |
| `a <hex>` | Mackin alpha (Q1.15 hex, 0..0x8000; 0x8000 = curr only; 0x4000 = 50/50). **Visible only on mackin-impl-wip with dual-VDMA wiring** — placeholder makes alpha a no-op. |
| `r` | Reset color stack to defaults (identity, sat=100, black=(0,0,0), white=(255,255,255)) |
| `F` | (phase-e1 only) Dump DDR3 slot 0 rows 0..99 HEAD+TAIL (cols 0-9 + 1270-1279). iter12+13 verification format. |

Each command echoes `UART> <cmd>` then a readback line (`COLOR: …` or `MATRIX: …`) showing both intended values + GPIO register readback so writes are verified to land.

### Phase E1 extras (`phase-e1-pll-spike` branch)

Additional commands for MMCM tracking + reference selection:

| Cmd | Description |
|---|---|
| `q` / `Q` | Query: counter, ts_ref, ts_out, edge counts |
| `p` / `P` | Phase: signed (ts_out - ts_ref) in ticks/ns |
| `c` | Phase 2: capture 1000 ts_ref samples (CSV) |
| `C` | Phase 2: capture 100 samples (quick) |
| `d` | Phase 3: 3000 drift pairs (~60s) |
| `D` | Phase 3: 300 drift pairs (quick) |
| `m <ppm>` | Phase 4: nudge MMCM by signed ppm |
| `M` | Phase 4: zero the nudge |
| `L` | Phase 6: enable PI loop |
| `U` | Phase 6: disable loop, zero actuator |
| `S` | Phase 6: toggle per-frame CSV dump |
| `r <free\|sync\|src>` | Phase 7 / E2.1: ref selector |
| `s` | Phase 7: toggle ref-mask |
| `n <M> <N>` | E2.1: src_vsync_divider ratio (output = src × M/N) |
| `a` | E2.3: auto-FRC (measure source, set M/N, ref=src) |
| `o <snap\|smooth\|film>` | E2.2: lock mode selection |
| `i` | E2.4: info dump (source format + output + loop state) |
| `h` | Diag: error histogram |
| `t` | Diag: toggle iter-4a source (real vs synth 50 Hz) |
| `B <ppm>` | Phase 8: inject ref-rate bias |

## AXI GPIO map

| GPIO instance | Address | Use |
|---|---|---|
| `axi_gpio_diag_iter` | `XPAR_*` | Diagnostic iteration trigger (DDR3 dump etc.) |
| `axi_gpio_3` | `XPAR_*` | color_saturation Q1.15 + color_correct black levels |
| `axi_gpio_4` | `XPAR_*` | color_correct white + color_matrix coeffs (low) |
| `axi_gpio_5` | `XPAR_*` | color_matrix coeffs (mid) |
| `axi_gpio_6` | `XPAR_*` | color_matrix coeffs (high) + offsets |
| (phase-e1 adds) `axi_gpio_refsel` | `XPAR_*` | Phase E1 reference selector + ref-mask |
| (phase-e1 adds) AXI-Lite to clk_wiz DRP | `XPAR_*` | MMCM phase actuator |

iter14 plans to add 1 more GPIO (4 bits, 2 for `mode_h` + 2 for `mode_v`) for kernel-mode toggle. See `docs/iter14-plan.md`.

## DIAG telemetry print format

Each frame, firmware prints one line summarizing pipeline state. Iter5 example:

```
DIAG: px=1920 lines=1080 maxpx=1920 mm2s=0  S2MM_SR=0x00011100[EOLEarly FrmCnt frmcnt=1] MM2S_SR=0x00011000[FrmCnt frmcnt=1] RDSTORE=0..4 cycling WRSTORE=0 src=119/150 out=60
```

Field meanings:
- `px=X lines=Y maxpx=Z` — scaler input counters (px per row, total rows, max px observed)
- `mm2s=N` — MM2S read iteration counter
- `S2MM_SR` / `MM2S_SR` — VDMA status register bits decoded. Per memory `xilinx_vdma_dmasr_bits`:
  - Bit 12 = `FrmCnt_Irq` (BENIGN — frame-count interrupt request)
  - Bit 15 = `EOLLate` (real EOLLate)
  - Bit 14 = `EOLEarly`
  - Bit 11 = `SOFLate` (set every frame post-iter6; cosmetic only — see [KNOWN-BUGS](KNOWN-BUGS.md))
- `RDSTORE=N..M` — MM2S framestore index cycling through ring
- `WRSTORE=N` — S2MM framestore. In `include_internal_genlock=1` builds, this reads-as-0 (per `xilinx_vdma_dmasr_bits`)
- `src=A/B` — source frame counter / output frame counter ratio
- `out=N` — output frame counter

## Telemetry-loop architecture

`telemetry_loop()` in main.c. Polls UART every iteration (~few ms), prints DIAG one-shot per source vsync. UART poll uses direct `Xil_In32` against UART CHANNEL_SR (`STDIN_BASEADDRESS + 0x2C`, RXEMPTY = bit 1) + FIFO (`+0x30`) because xuartps.h driver macros (`XUartPs_IsReceiveData`) aren't in this BSP's xuartps_hw.h.

## Triggered DDR3 dump

On iter5 / mackin: writing to `axi_gpio_diag_iter` triggers a slot-0 byte dump in the next telemetry iteration. Used during iter12+13 verification.

On phase-e1: `F` UART command triggers the same dump synchronously.

## VTC_RX live readback

Iter5 firmware reads VTC_RX detector registers during telemetry to confirm source format:

```c
u32 dtstat = Xil_In32(VTC_RX_BASEADDR + 0x024);
u32 dasize = Xil_In32(VTC_RX_BASEADDR + 0x020);  // HACTIVE (low) + VACTIVE (high)
u32 dhsize = Xil_In32(VTC_RX_BASEADDR + 0x030);  // HTOTAL
u32 dvsize = Xil_In32(VTC_RX_BASEADDR + 0x034);  // VTOTAL
u32 dpol   = Xil_In32(VTC_RX_BASEADDR + 0x02C);  // polarity bits
```

If `DTSTAT & 1 == 0` → no lock; investigate source side first per [DEBUGGING-PLAYBOOK](DEBUGGING-PLAYBOOK.md#source-first).

## Important firmware traps to avoid

- **XPAR_VTC_0 aliasing**: adding a second VTC silently re-aliases the first. Always use explicit `XPAR_V_TC_TX_BASEADDR` / `XPAR_V_TC_RX_BASEADDR`. Memory: `xilinx_xpar_vtc_aliasing`.
- **VTC REG_UPDATE bit**: VTC CTL bit 1 (RU) must be set or shadow-reg writes never reach the generator. Symptom: monitor "No Signal" with downstream LEDs solid. Memory: `xilinx_vtc_register_update`.
- **PARK_PTR_REG anti-pattern**: don't have firmware write the VDMA park pointer per vsync. PG020 doesn't promise SOF-atomic latching. Use hardware Dynamic Genlock instead. Memory: `schindler_vdma_dynamic_genlock`.

<!-- AGENT_TASK[fw-4]: Add UART command for kernel-mode toggle (iter14): `k h <0|1|2|3>` and `k v <0|1|2|3>`. See docs/iter14-plan.md. -->

<!-- AGENT_TASK[fw-5]: Unify the DDR3 dump trigger mechanism across branches. Currently iter5/mackin use diag_iter GPIO; phase-e1 uses `F` UART. Pick one and propagate. -->
