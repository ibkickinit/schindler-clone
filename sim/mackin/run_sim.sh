#!/bin/bash
# run_sim.sh — drive mackin_blender_tb.v through all alpha values in manifest
#
# Requires Vivado/xsim available on PATH (source settings64.sh first).

set -e

cd "$(dirname "$0")"
ROOT=$(pwd)
HDL=$ROOT/../../hdl/mackin_blender.v

if [ ! -f vectors/manifest.txt ]; then
    echo "ERROR: vectors/manifest.txt not found. Run python3 gen_vectors.py first."
    exit 1
fi

if ! command -v xvlog >/dev/null 2>&1; then
    echo "ERROR: xvlog not on PATH. Source /tools/Xilinx/2025.2/Vivado/settings64.sh first."
    exit 1
fi

# Compile HDL + TB once, elaborate once. Then run xsim per alpha with plusargs.
echo "=== Compiling HDL + TB ==="
xvlog -nolog "$HDL" mackin_blender_tb.v 2>&1 | grep -v "^INFO:" || true
xelab -nolog -top mackin_blender_tb -snapshot mb_tb --timescale 1ns/1ps 2>&1 | grep -v "^INFO:" || true

OVERALL_FAIL=0

while read alpha vecfile nvec; do
    if [ -z "$alpha" ]; then continue; fi
    echo ""
    echo "=== Run: alpha=$alpha vec=$vecfile ($nvec vectors) ==="
    OUT=$(xsim -nolog mb_tb -R \
              -testplusarg "alpha=${alpha#0x}" \
              -testplusarg "vecfile=vectors/${vecfile}" 2>&1)
    echo "$OUT" | grep -E "^\[TB\]"
    if echo "$OUT" | grep -q "FAIL_TOTAL"; then
        OVERALL_FAIL=$((OVERALL_FAIL+1))
    fi
done < vectors/manifest.txt

echo ""
echo "================================================================"
if [ "$OVERALL_FAIL" -eq 0 ]; then
    echo "ALL PASS — HDL bit-exact vs Python golden across all alpha values"
    exit 0
else
    echo "OVERALL FAIL: $OVERALL_FAIL alpha values had mismatches"
    exit 1
fi
