# Build and Program

How to go from source code to a board with running firmware.

## Toolchain (pinned)

| Tool | Version | Path |
|---|---|---|
| Vivado | 2025.2 | `/tools/Xilinx/2025.2/Vivado` |
| Vitis | 2025.2 | `/tools/Xilinx/2025.2/Vitis` |
| Digilent board files | `36f34ab687b7fa9c778b779d027f3bce63b3ace9` (2025-07-15) | `~/fpga/vivado-boards/new/board_files` |
| Digilent IP library | `f4613fff005b098065fd5d619a2b88e55720a423` (2024-05-16) | `~/fpga/vivado-library/ip` |

Re-verify Phase A passthrough + iter5-1080p-clean 720p60 build after any tool/board/IP update. See `../build-manifest.md` Reproduction footer for the canonical list.

## Vivado build

```bash
cd /home/justin/Dropbox/_PROJECTS/Schindler-2.0

source /tools/Xilinx/2025.2/Vivado/settings64.sh

export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip

# Default scaler module (production):
SCALER_MODULE=scaler_top vivado -mode batch -nojournal \
    -log build/build_iter5_$(date +%s).log \
    -source tcl/build_phase_b.tcl
```

`SCALER_MODULE` env var picks the scaler. Options:
- `scaler_top` — production (iter12+iter13+iter13b 2-tap boxcar)
- `scaler_crop_bypass` — iter4h-era diagnostic: 1280×720 crop, no scaling. Useful for bisection.
- `scaler_bypass_1080p` — 1080p substrate diagnostic

Vivado build time: ~25-30 min on typical workstation. Output: `build/phase_b.xsa`.

## Vitis ELF build

```bash
source /tools/Xilinx/2025.2/Vitis/settings64.sh
xsct tcl/build_phase_b_app.tcl
```

~30 seconds. Output: `build/vitis-phase-b/vdma_init/Debug/vdma_init.elf`.

**Stale-copy gotcha:** Vitis `importsources` copies source into the project tree. Subsequent edits to the original do NOT propagate to incremental builds. **Solution:** after editing `sw/phase-b/src/*.c`, force re-copy by re-running the full Vitis tcl, not just an incremental rebuild. Cost us 3 lost iterations on 2026-05-14; see memory `vitis_importsources_stale_copy`.

## Program the board (JTAG)

```bash
source /tools/Xilinx/2025.2/Vitis/settings64.sh
xsct tcl/program_phase_b_full.tcl
```

Programs the .bit then loads + starts the .elf. ~30 seconds.

**Verify it worked:** open serial on `/dev/ttyUSB1 @ 115200 8N1`. Should see VDMA init + telemetry within a few seconds.

```bash
picocom -b 115200 /dev/ttyUSB1
```

## Common pitfalls

### IP version sensitivity

Memory `digilent_rgb2dvi_kclkrange_limit`: Digilent's rgb2dvi only accepts `kClkRange={1,2,3}` → blocks 480p over HDMI. The patch lives in `~/fpga/vivado-library/ip/dvi2rgb/component.xml` — if you re-pull vivado-library upstream, the patch is gone.

### Pin naming confusion

Memory `pmod_pin_naming`: ALWAYS reference "Pmod JB Pin 7" (physical pin), never "JB5" (Digilent signal-index). The two conventions don't agree and miswiring is easy.

### MMCM budget

Memory `zynq7020_mmcm_budget`: Zynq-7020 has only 4 MMCMs. iter5-1080p-clean uses 2 (`clk_wiz_pixclk_out`, `clk_wiz_ref`); the dvi2rgb IP may consume one or two internally. Any 5th clock generator must be `PRIMITIVE=PLL`.

phase-g-iter1 is at the budget ceiling (4 clk_wiz cells active). See `schindler_phase_g_clkwiz_zombie` memory.

### Async-CDC WNS soft fail

Vivado will report WNS=-3.5 ns (or thereabouts) on color-pipeline paths. This is a known issue — the timing-ignore constraints don't match Vivado's hierarchical names. Functional via `ASYNC_REG`. Documented for fix; not blocking.

<!-- AGENT_TASK[hdl-4]: Fix the async-CDC false-path constraint pattern so WNS reports clean. Currently functional via ASYNC_REG but Vivado complains every build. -->

## Building other branches

Same workflow; just `git checkout <branch>` first. Each branch is self-contained (no submodule indirection). Vivado will pick up whatever `tcl/build_phase_b.tcl` is at the checked-out tip.

See [BRANCHES](BRANCHES.md) for what each branch produces.

## CI / automation

**There is no CI.** The 2026-05-30 Risk Auditor flagged this as a structural risk. All build verification is manual.

<!-- AGENT_TASK[test-1]: Build a minimum-viable CI pipeline. Vivado batch + Vitis batch + Python sim suite (`python/` directory) on push to iter5-1080p-clean. Skip programming step (no bench). -->
