#!/bin/bash
# Run the pg_projective P1 self-checking testbench (affine-equivalence + projective bit-exact).
#   - (re)generates the Python golden vectors first (so HDL is validated against the live golden)
#   - then xvlog/xelab/xsim the TB.
# Usage: sim/run_pg_projective.sh
set -e
source /tools/Xilinx/2025.2/Vivado/settings64.sh
cd "$(dirname "$0")/.."

# 1) golden vectors (small 64x48 -> 96x72 frame, chosen Q-format) — must match TB dims.
python3 tools/pg_projective_golden.py --emit sim/golden_proj --out-w 64 --out-h 48 --in-w 96 --in-h 72

# 2) compile + elaborate + run
WORK=sim/.xsim_proj
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
xvlog --nolog \
  ../../hdl/pg_affine.v ../../hdl/pg_projective.v ../../sim/pg_projective_tb.v \
  > xvlog.log 2>&1 || { cat xvlog.log; exit 1; }
xelab --nolog pg_projective_tb -s psim > xelab.log 2>&1 || { cat xelab.log; exit 1; }
xsim --nolog psim -R 2>&1 | grep -E "CASE|RESULT|ERR"
