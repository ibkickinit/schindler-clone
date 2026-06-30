#!/bin/bash
# sim/run_regression.sh — self-checking HDL unit regressions for the parts this repo actively
# changes. Each TB prints "<NAME>: PASS|FAIL (n)". Exit 0 iff every TB passes (CI-friendly).
#
# Coverage today:
#   pg_tsg          — TSG: R-B-G byte order, all 8 patterns, ramp multiply-fix, text banner.
#   pg_place_affine — STAGE-2 placement affine LOD-coord path (guards the A1/A2 pipeline-split).
# TODO (P2 owed): an end-to-end pg_warp_engine TB. sim/pg_warp_real_1080_tb.v is STALE. Precise un-rot:
#   1. file list: add hdl/pg_projective.v hdl/pg_pincushion.v hdl/pg_place_affine.v (keep pg_affine.v,
#      pg_skid.v, pg_tilecache_rt2.v, pg_tile_dma.v).
#   2. instantiation: REMOVE the obsolete `.lod(...)`; ADD .hsel(0), .in_w_rt(IN_W),.in_h_rt(IN_H),
#      .out_w_rt(OUT_W),.out_h_rt(OUT_H), .m_g(0),.m_h(0), .kx(0),.ky(0), and identity placement
#      .pa(1<<20),.pb(0),.pc(0),.pd(0),.pe(1<<20),.pf(0)  (Q.FB, FB=20). With m_g=m_h=0 the projective
#      reduces to the m_a..m_f affine the existing golden models -> golden SHOULD still hold.
#   3. LIKELY DEBUG POINT: fill_blk is now [95:0] (pg_tile_pack64 / tilecache_rt2 format). Verify the
#      TB's fill-data generation matches the current tile packing, else golden pixels won't match.
#   Then add:  run pg_warp_engine pg_warp_real_1080_tb  <files...>  here.
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
