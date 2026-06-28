#!/bin/bash
# Phase A timing gate: in-context warp-engine build @ 74.25 MHz (720p60), then
# extract the intra-pclk WNS (the definitive number per docs/warp-cache-timing.md).
set -e
cd /home/justin/warp-timing-build
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export OUTPUT_MODE=720p
echo "=== PHASE A BUILD START $(date) — OUTPUT_MODE=$OUTPUT_MODE (74.25 MHz) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_phase_b.tcl 2>&1
echo "=== PHASE A BUILD DONE $(date) ==="
