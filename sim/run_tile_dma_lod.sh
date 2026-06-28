#!/bin/bash
# Run the Phase-1 LOD pg_tile_dma addressing testbench (per-LOD DDR fetch_addr proof; pure HDL).
# Usage: sim/run_tile_dma_lod.sh
set -e
source /tools/Xilinx/2025.2/Vivado/settings64.sh
cd "$(dirname "$0")/.."

WORK=sim/.xsim_lod
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
xvlog --nolog ../../hdl/pg_tile_dma.v ../../sim/pg_tile_dma_lod_tb.v > xvlog.log 2>&1 || { cat xvlog.log; exit 1; }
xelab --nolog pg_tile_dma_lod_tb -s lsim > xelab.log 2>&1 || { cat xelab.log; exit 1; }
xsim --nolog lsim -R 2>&1 | grep -E "===|L[0-9]|RESULT|FAIL|TIMEOUT|constants|WATCHDOG"
