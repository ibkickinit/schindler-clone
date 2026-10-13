#!/usr/bin/env bash
# Runs the HD-SDI TX testbench with Icarus Verilog.
#   1) SMALL raster, HD and 3G-A payload IDs, 3 frames -> must PASS
#   2) SMALL raster + INJECT error                      -> must FAIL (proves the checker catches errors)
#   3) full 1080p30 HD-SDI and 1080p60 3G-A, 1 frame    -> must PASS   (skip with QUICK=1)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
hdl="$here/../../hdl/sdi_tx"
src=("$hdl"/sdi_crc18.v "$hdl"/sdi_hd_timing.v "$hdl"/sdi_bars_hd.v "$hdl"/sdi_hd_framer.v \
     "$hdl"/sdi_scrambler.v "$hdl"/sdi_hd_tx_top.v "$here"/tb_sdi_hd_tx.v)
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

run() {  # name, expect(PASS|FAIL), defines...
    local name=$1 expect=$2; shift 2
    iverilog -g2005 -Wall -o "$out/$name.vvp" "$@" "${src[@]}"
    local log; log="$(vvp -n "$out/$name.vvp")"
    echo "$log" | tail -n 3 | sed "s/^/[$name] /"
    if echo "$log" | grep -qx "$expect"; then echo "[$name] OK (expected $expect)"; else echo "[$name] UNEXPECTED"; exit 1; fi
}

run small_hd   PASS -DSMALL
run small_3ga  PASS -DSMALL -DG3A
run inject     FAIL -DSMALL -DINJECT
run inject_pid FAIL -DSMALL -DINJECT_PID
if [ "${QUICK:-0}" != "1" ]; then
    run full_hd_1080p30  PASS
    run full_3ga_1080p60 PASS -DG3A
fi
echo "ALL OK"
