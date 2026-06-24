#!/bin/bash
# Run the P2 PROJECTIVE faithful full-engine gate: pg_warp_engine#(PROJECTIVE=1) through the faithful
# DataMover + buffered sink, driven with keystone / corner-pin homographies, checked bit-exact against
# the Python golden (coords + output pixels). Proves the demand-fetch covers the foreshortened spread
# with NO wedge AND the output is bit-exact.
#   1) (re)generate the golden vectors + golden output pixels (.coef/.vec/.pix) at the TB dims
#   2) xvlog/xelab/xsim the projective faithful TB
# Usage: sim/run_warp_projective_faithful.sh
set -e
source /tools/Xilinx/2025.2/Vivado/settings64.sh
cd "$(dirname "$0")/.."

# 1) golden (64x48 out <- 96x72 in, matte 0x101010 to match the TB). --emit-pix adds the .pix files.
python3 tools/pg_projective_golden.py --emit sim/golden_proj --emit-pix \
        --out-w 64 --out-h 48 --in-w 96 --in-h 72 --matte 101010

# 2) compile + elaborate + run
WORK=sim/.xsim_proj_faithful
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
xvlog --nolog \
  ../../hdl/pg_affine.v ../../hdl/pg_projective.v ../../hdl/pg_skid.v ../../hdl/pg_tilecache_rt2.v \
  ../../hdl/pg_tile_dma.v ../../hdl/pg_warp_engine.v ../../sim/pg_warp_projective_faithful_tb.v \
  > xvlog.log 2>&1 || { cat xvlog.log; exit 1; }
xelab --nolog pg_warp_projective_faithful_tb -s pfsim > xelab.log 2>&1 || { cat xelab.log; exit 1; }
xsim --nolog pfsim -R 2>&1 | grep -E "PROJ-FAITHFUL|WATCHDOG|STALL|ERR"
