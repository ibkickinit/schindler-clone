#!/bin/bash
# DECIMATE-ON-WRITE build (D1-D3): scaler_top G1 runtime-output + sub-window S2MM
# scale. Same env as the proven pivot (137b13d): WARP+PROJECTIVE+scaler_top+
# RASTER_TO_TILE=0 -> DEST_RES_LOD firmware gate. Produces phase_b.xsa + the
# vdma_init.elf (with the 'Z <pct>' scale command).
set -e
cd /home/justin/warp-timing-build
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export WARP_ENGINE=1
export PROJECTIVE_BUILD=1
export SCALER_MODULE=scaler_top
export RASTER_TO_TILE=0
export OUTPUT_MODE=720p
export NO_ILA=1

echo "=== DECIMATE BITSTREAM START $(date) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_phase_b.tcl 2>&1
echo "=== DECIMATE BITSTREAM DONE $(date) ==="

echo "=== DECIMATE FIRMWARE START $(date) ==="
xsct tcl/build_phase_b_app.tcl 2>&1
echo "=== DECIMATE FIRMWARE DONE $(date) ==="
echo "ALL_BUILD_OK"
