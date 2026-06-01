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

## Build artifact archive — swap builds in 30 seconds

Every successful Vivado + Vitis build auto-archives its `phase_b.bit`, `phase_b.xsa`, `ps7_init.tcl`, `vdma_init.elf`, and a `manifest.txt` into `build/artifacts/<tag>/`. Tag scheme:

```
<branch>-<output_mode>-<scaler_module>-<color_pipeline>-<commit>
```

Examples:
- `iter5-1080p-clean-720p-scaler_top-enable-6e4bd80`
- `iter5-1080p-clean-1080p30-scaler_bypass_1080p-enable-083239a`
- `phase-e1-pll-spike-720p-scaler_top-enable-e0b62b7`

**Disk cost:** ~5.6 MB per saved build (`phase_b.bit` = 4 MB, `phase_b.xsa` = 1.3 MB, ELF = 305 KB, ps7_init.tcl = 35 KB, manifest = 0.5 KB). 100 saved builds ≈ 560 MB. `build/` is gitignored so this never pollutes the repo.

### Reprogram from a saved build (no rebuild)

```bash
source /tools/Xilinx/2025.2/Vitis/settings64.sh

# List available builds:
xsct tcl/program_artifact.tcl

# Program a specific one (substring match works if unique):
xsct tcl/program_artifact.tcl 1080p30
xsct tcl/program_artifact.tcl iter5-720p-scaler_top-enable-6e4bd80
```

Same canonical Zynq-7000 bring-up sequence as `program_phase_b_full.tcl`. ~30 seconds vs ~30 min rebuild.

**Caveat:** archive happens at successful end of build. If you run only Vivado without Vitis, the tag dir gets the XSA + manifest but not the `.bit`/`.elf`. Re-running Vitis backfills.

## Interacting with the running firmware

Two options, **mutually exclusive** because both want exclusive access to `/dev/ttyUSB1`:

### Option A — picocom (human-facing UART)

```bash
picocom -b 115200 /dev/ttyUSB1
```

Type `?` for the command list. See [FIRMWARE-INTERFACE](FIRMWARE-INTERFACE.md) for the full reference.

### Option B — schindlerd + browser (V0a control plane)

```bash
# One-time install
python3 -m venv /tmp/schindlerd-venv
/tmp/schindlerd-venv/bin/pip install -r control-plane/schindlerd/requirements.txt

# Run
/tmp/schindlerd-venv/bin/python control-plane/schindlerd/schindlerd.py -v
```

Then open [http://127.0.0.1:8080](http://127.0.0.1:8080). Daemon owns `/dev/ttyUSB1` while running; pkill it to switch back to picocom. See [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md) for troubleshooting + ports + flags.

## Makefile shortcuts

Top-level `Makefile` wraps the common operations:

```bash
make test          # pytest harness (53+ tests, ~1s, no bench)
make sim           # Python kernel-compare sim + sha256 diff vs golden
make ci            # test + sim
make build         # Vivado HDL build (Vivado env required)
make build-app     # Vitis ELF build (xsct env required)
make program       # JTAG program (xsct env required)
make sim-vivado    # xsim testbenches (Vivado env required)
make sim-bootstrap # regenerate sim/golden/ from a legitimate kernel change
make help          # one-line summary of every target
```

`make ci` is the recommended check before committing — fast, no bench, catches catalog/parser/daemon regressions plus kernel-sim divergence.

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
