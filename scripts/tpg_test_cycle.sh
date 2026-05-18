#!/bin/bash
# tpg_test_cycle.sh — full test cycle: build firmware → program → switch to TPG → capture → analyze
#
# Assumes Vivado build already complete (.bit + .xsa present).
# Usage: ./tpg_test_cycle.sh
# Exit codes:
#   0 = TPG aligned
#   1 = TPG offset detected
#   2 = TPG not visible (capture stick fallback or board state issue)
#   3 = build/program error

set -e
ROOT=/home/justin/Dropbox/_PROJECTS/Schindler-2.0
cd "$ROOT"

echo "===== firmware build ====="
source /tools/Xilinx/2025.2/Vitis/settings64.sh
xsct tcl/build_phase_b_app.tcl 2>&1 | grep -E "STAGE_OK|error:" | tail -3

echo "===== programming board ====="
xsct tcl/program_phase_b_full.tcl 2>&1 | tail -2
sleep 2

echo "===== UART boot capture ====="
timeout 8 cat /dev/ttyUSB1 > /tmp/uart_iter_boot.log 2>&1 &
sleep 1
wait || true
grep -E "VTC_RX|TPG:|Pipeline live|ADV7393" /tmp/uart_iter_boot.log | head -8

echo "===== switch to TPG ====="
sleep 0.5
printf 't 1\r' > /dev/ttyUSB1
sleep 1
timeout 2 cat /dev/ttyUSB1 > /tmp/uart_iter_t1.log 2>&1 || true
grep -E "TPG:" /tmp/uart_iter_t1.log | head -2

echo "===== HDMI capture ====="
sleep 1
bash scripts/capture_hdmi.sh /tmp/tpg_iter.jpg

echo "===== analyze ====="
python3 scripts/analyze_tpg_capture.py /tmp/tpg_iter.jpg
EXIT=$?
echo "analyze exit=$EXIT  capture saved: /tmp/tpg_iter.jpg"
exit $EXIT
