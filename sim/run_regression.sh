#!/bin/bash
# sim/run_regression.sh — self-checking HDL unit regressions for the parts this repo actively
# changes. Each TB prints "<NAME>: PASS|FAIL (n)". Exit 0 iff every TB passes (CI-friendly).
#
# Coverage today:
#   pg_tsg          — TSG: R-B-G byte order, all 8 patterns, ramp multiply-fix, text banner.
#   pg_place_affine — STAGE-2 placement affine LOD-coord path (guards the A1/A2 pipeline-split).
# TODO (P2 owed): an end-to-end pg_warp_engine TB — sim/run_warp_real_1080.sh is STALE (drives the
#   old pure-affine ports, missing projective/pincushion/placement/runtime-dims). Un-rot + re-bless
#   its golden, then add it here.
source /tools/Xilinx/2025.2/Vivado/settings64.sh >/dev/null 2>&1 || true
set -u   # AFTER sourcing Vivado settings (its script trips on unset vars under -u)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

run() {  # name  top  src...
  local name="$1" top="$2"; shift 2
  local srcs=(); local f
  for f in "$@"; do srcs+=("$ROOT/$f"); done
  local W="$ROOT/sim/.reg/$name"; rm -rf "$W"; mkdir -p "$W"
  (
    cd "$W"
    if ! xvlog --nolog "${srcs[@]}" > xv.log 2>&1; then echo "$name: XVLOG-FAIL (see $W/xv.log)"; exit 2; fi
    if ! xelab --nolog "$top" -s s > xe.log 2>&1; then echo "$name: XELAB-FAIL (see $W/xe.log)"; exit 2; fi
    local line
    line=$(xsim --nolog s -R 2>&1 | grep -E ": (PASS|FAIL)" | tail -1)
    echo "$name: ${line:-NO-RESULT}"
    echo "$line" | grep -q "PASS" || exit 1
  )
  [ $? -ne 0 ] && fail=1
  return 0
}

echo "=== Schindler HDL unit regressions ==="
run pg_tsg          pg_tsg_tb          hdl/pg_tsg.v          sim/pg_tsg_tb.v
run pg_place_affine pg_place_affine_tb hdl/pg_place_affine.v sim/pg_place_affine_tb.v
echo "---------------------------------------"
if [ "$fail" -eq 0 ]; then echo "REGRESSION: ALL PASS"; else echo "REGRESSION: FAILURES ABOVE"; fi
exit $fail
