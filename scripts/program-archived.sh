#!/usr/bin/env bash
# program-archived.sh — re-flash a previously archived build by tag, NO rebuild (~30 s).
#
#   scripts/program-archived.sh <tag>     e.g.  scripts/program-archived.sh 34-720p60
#
# Copies the archived .bit/.elf back into the build/ paths the JTAG loader expects,
# then runs the full program (rst -system → fpga → dow → con).
# NOTE: stop the control daemon first (free /dev/ttyUSB1) or the HDMI input won't
# re-lock after the config reset — see the JTAG-reflash gotcha in the format matrix log.
set -euo pipefail
ROOT="/home/justin/Dropbox/_PROJECTS/Schindler-2.0"
TAG="${1:?usage: program-archived.sh <tag>}"
SRC="$ROOT/artifacts/$TAG"
[ -d "$SRC" ] || { echo "no archive at artifacts/$TAG (list: ls artifacts/)"; exit 1; }
cp -f "$SRC/phase_b.bit"   "$ROOT/build/vitis-phase-b/phase_b_pf/hw/phase_b.bit"
cp -f "$SRC/vdma_init.elf" "$ROOT/build/vitis-phase-b/vdma_init/Debug/vdma_init.elf"
echo "restored artifacts/$TAG → build/  ($(cat "$SRC/INFO.txt" | sed -n 2p))"
source /tools/Xilinx/2025.2/Vitis/settings64.sh 2>/dev/null || source /tools/Xilinx/2025.2/Vivado/settings64.sh 2>/dev/null
xsct "$ROOT/tcl/program_phase_b_full.tcl"
