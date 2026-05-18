#!/bin/bash
# run_sim.sh — sweep all 4 colorimetry modes through rgb_to_ycbcr HDL.
set -e
cd "$(dirname "$0")"
ROOT=$(pwd)
HDL_RGB=$ROOT/../../hdl/rgb_to_ycbcr.v

if [ ! -f vectors/mode_0.txt ]; then
    echo "ERROR: run python3 gen_vectors.py first"
    exit 1
fi

if ! command -v xvlog >/dev/null 2>&1; then
    echo "ERROR: xvlog not on PATH. Source Vivado settings64.sh first."
    exit 1
fi

echo "=== Compiling ==="
xvlog -nolog "$HDL_RGB" rgb_to_ycbcr_tb.v 2>&1 | grep -v "^INFO:" | head -3 || true
xelab -nolog -top rgb_to_ycbcr_tb -snapshot rgb_ycc_tb --timescale 1ns/1ps 2>&1 | grep -v "^INFO:" | head -3 || true

OVERALL_FAIL=0
for m in 0 1 2 3; do
    echo ""
    echo "=== Mode $m ==="
    OUT=$(xsim -nolog rgb_ycc_tb -R \
              -testplusarg "mode=${m}" \
              -testplusarg "vecfile=vectors/mode_${m}.txt" 2>&1)
    echo "$OUT" | grep -E "^\[TB\]"
    if echo "$OUT" | grep -q "FAIL_TOTAL"; then
        OVERALL_FAIL=$((OVERALL_FAIL+1))
    fi
done

echo ""
echo "================================================================"
if [ "$OVERALL_FAIL" -eq 0 ]; then
    echo "ALL PASS — rgb_to_ycbcr bit-exact vs Python golden, 4 modes × 416 pixels"
    exit 0
else
    echo "OVERALL FAIL: $OVERALL_FAIL modes had mismatches"
    exit 1
fi
