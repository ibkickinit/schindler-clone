#!/bin/bash
# test_iter3e_alignment.sh — End-to-end post-rebuild verification for Phase D iter-3e.
#
# Steps:
#   1. Verify Vivado output exists (.bit + .xsa)
#   2. Run Vitis platform/BSP/app rebuild (xsct tcl/build_phase_b_app.tcl)
#   3. Loop 4×: program with xsct + capture frame via gstreamer
#   4. Run python/analyze_capture.py on the captured frames
#
# Run from repo root.

set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

BIT="build/phase-b-vdma-passthrough/phase-b-vdma-passthrough.runs/impl_1/phase_b_bd_wrapper.bit"
XSA="build/phase_b.xsa"

if [ ! -f "$BIT" ]; then
    echo "ERROR: bitstream not at $BIT — run vivado build first"
    exit 1
fi
if [ ! -f "$XSA" ]; then
    echo "ERROR: XSA not at $XSA — run vivado build first"
    exit 1
fi

echo "=== Step 1/4: Vitis platform/BSP/app rebuild ==="
source /tools/Xilinx/2025.2/Vitis/settings64.sh
xsct tcl/build_phase_b_app.tcl 2>&1 | grep -E "STAGE_OK|ERROR|FAIL" | tail -10

ELF="build/vitis-phase-b/vdma_init/Debug/vdma_init.elf"
if [ ! -f "$ELF" ]; then
    echo "ERROR: ELF not at $ELF — Vitis build failed"
    exit 2
fi
echo "ELF built: $ELF"

# Copy fresh bitstream to the Vitis platform hw path so program_phase_b_full
# picks up the new one (the .GOOD backup from yesterday remains intact).
cp "$BIT" build/vitis-phase-b/phase_b_pf/hw/phase_b.bit

echo
echo "=== Step 2/4: Multi-boot alignment test (4 reprograms) ==="
mkdir -p build/ila-capture/phase-d
for i in 1 2 3 4; do
    echo "--- Boot $i ---"
    xsct tcl/program_phase_b_full.tcl 2>&1 | grep -E "STAGE_OK|ERROR" | head -2
    sleep 4
    rm -rf /tmp/cap_iter3e_b$i
    mkdir -p /tmp/cap_iter3e_b$i
    timeout 9 gst-launch-1.0 -q v4l2src device=/dev/video4 num-buffers=120 \
        ! videoconvert ! jpegenc quality=95 ! multifilesink \
        location="/tmp/cap_iter3e_b$i/f_%03d.jpg" 2>&1 | tail -1 || true
    LATEST=$(ls /tmp/cap_iter3e_b$i/ 2>/dev/null | tail -1)
    if [ -n "$LATEST" ]; then
        cp "/tmp/cap_iter3e_b$i/$LATEST" "build/ila-capture/phase-d/iter3e-boot$i.jpg"
        echo "saved iter3e-boot$i.jpg ($LATEST)"
    else
        echo "WARN: boot $i produced no frames"
    fi
done

echo
echo "=== Step 3/4: Alignment + edge analysis ==="
python3 python/analyze_capture.py \
    build/ila-capture/phase-d/iter3e-boot1.jpg \
    build/ila-capture/phase-d/iter3e-boot2.jpg \
    build/ila-capture/phase-d/iter3e-boot3.jpg \
    build/ila-capture/phase-d/iter3e-boot4.jpg

echo
echo "=== Step 4/4: Comparison to pre-iter3e baseline ==="
python3 python/analyze_capture.py \
    build/ila-capture/phase-d/baseline-lanczos-pre-iter3e.jpg \
    build/ila-capture/phase-d/iter3e-boot1.jpg
