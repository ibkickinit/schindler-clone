#!/bin/bash
# CORRECTED Phase A/B build: WARP_ENGINE=1 actually instantiates pg_warp_top (readengine_warp_bd.tcl)
# + the warp-specific timing-focused impl strategy. NO_ILA=1 frees slices/BRAM for the warp.
set -e
cd /home/justin/warp-timing-build
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export WARP_ENGINE=1
export OUTPUT_MODE=720p
export NO_ILA=1
echo "=== WARP BUILD START $(date) — WARP_ENGINE=1 OUTPUT_MODE=720p NO_ILA=1 ==="
vivado -mode batch -nojournal -nolog -source tcl/build_phase_b.tcl 2>&1
echo "=== WARP BUILD DONE $(date) ==="
