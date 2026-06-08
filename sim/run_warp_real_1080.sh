#!/bin/bash
# Run pg_warp_real_1080_tb (1920x1080 out) at a given LEAD. Usage: sim/run_warp_real_1080.sh <LEADV> [tag]
set -e
source /tools/Xilinx/2025.2/Vivado/settings64.sh
cd "$(dirname "$0")/.."
LEADV=${1:-32768}; TAG=${2:-$LEADV}
WORK=sim/.xsim_1080_$TAG
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
xvlog --nolog -d LEADV=$LEADV \
  ../../hdl/pg_affine.v ../../hdl/pg_skid.v ../../hdl/pg_tilecache_rt2.v \
  ../../hdl/pg_tile_dma.v ../../hdl/pg_warp_engine.v ../../sim/pg_warp_real_1080_tb.v > xvlog.log 2>&1 || { cat xvlog.log; exit 1; }
xelab --nolog pg_warp_real_1080_tb -s rsim > xelab.log 2>&1 || { cat xelab.log; exit 1; }
xsim --nolog rsim -R 2>&1 | grep -E "REAL|WATCHDOG|ERROR"
