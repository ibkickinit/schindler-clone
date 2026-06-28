#!/bin/bash
# P5: projective (keystone + corner-pin) bitstream build @ 720p. WARP_ENGINE=1 selects the warp BD +
# the timing-focused impl strategy; PROJECTIVE_BUILD=1 instantiates pg_projective (FB=20) + g/h GPIOs.
set -e
cd /home/justin/warp-timing-build
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export WARP_ENGINE=1
export PROJECTIVE_BUILD=1
export OUTPUT_MODE=720p
export NO_ILA=1
echo "=== PROJECTIVE BUILD START $(date) — WARP_ENGINE=1 PROJECTIVE_BUILD=1 720p NO_ILA=1 ==="
vivado -mode batch -nojournal -nolog -source tcl/build_phase_b.tcl 2>&1
echo "=== PROJECTIVE BUILD DONE $(date) ==="
