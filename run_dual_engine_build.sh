#!/bin/bash
# DUAL-ENGINE validation build (v1-dual-engine): the proven V1 warp engine (Engine A
# -> HDMI) PLUS Engine B (pg_read_engine_top, identity 1:1) reading the SAME DDR on an
# independent 27 MHz PLL domain + HP2 DataMover, output -> FPGA composite encoder ->
# 8-bit R-2R ladder on Pmod JC. Same env as run_decimate_1080_build.sh + DUAL_ENGINE=1.
set -e
cd /home/justin/warp-timing-build
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export WARP_ENGINE=1
export PROJECTIVE_BUILD=1
export SCALER_MODULE=scaler_top
export RASTER_TO_TILE=0
export OUTPUT_MODE=1080p30
export NO_ILA=1
export DUAL_ENGINE=1

echo "=== DUAL-ENGINE BITSTREAM START $(date) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_phase_b.tcl 2>&1
echo "=== DUAL-ENGINE BITSTREAM DONE $(date) ==="

echo "=== DUAL-ENGINE FIRMWARE START $(date) ==="
xsct tcl/build_phase_b_app.tcl 2>&1
echo "=== DUAL-ENGINE FIRMWARE DONE $(date) ==="
echo "ALL_BUILD_OK"
