#!/bin/bash
# Run the pg_warp_dma_tb sweep gate. Usage: sim/run_warp_sweep.sh
set -e
source /tools/Xilinx/2025.2/Vivado/settings64.sh
cd "$(dirname "$0")/.."
WORK=sim/.xsim_warp
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
xvlog --nolog \
  ../../hdl/pg_affine.v ../../hdl/pg_skid.v ../../hdl/pg_tilecache_rt2.v \
  ../../hdl/pg_tile_dma.v ../../hdl/pg_warp_engine.v ../../sim/pg_warp_dma_tb.v > xvlog.log 2>&1 || { cat xvlog.log; exit 1; }
xelab --nolog pg_warp_dma_tb -s wsim > xelab.log 2>&1 || { cat xelab.log; exit 1; }
xsim --nolog wsim -R 2>&1 | grep -E "SWEEP|ERR|WATCHDOG"
