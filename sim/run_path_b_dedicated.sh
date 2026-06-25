#!/bin/bash
# run_path_b_dedicated.sh — Path B dedicated-DMA sim suite (cmd-gen, packer roundtrip, end-to-end).
set -e
source /tools/Xilinx/2025.2/Vivado/settings64.sh
cd "$(dirname "$0")/.."
WORK=sim/.xsim_path_b_dedicated
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

run() {  # <top> <sources...>
  local top=$1; shift
  echo "==================== $top ===================="
  xvlog --nolog "$@" > xvlog_$top.log 2>&1 || { echo "XVLOG FAIL"; cat xvlog_$top.log; exit 1; }
  xelab --nolog $top -s sim_$top > xelab_$top.log 2>&1 || { echo "XELAB FAIL"; cat xelab_$top.log; exit 1; }
  xsim --nolog sim_$top -R 2>&1 | grep -E "TB:|PASS|FAIL|ERR|WATCHDOG|CAPTURE|frame |roundtrip|RT:|completion"
}

H=../../hdl; S=../../sim

# 0) 24b->64b packer: byte-exact contiguous stream under back-pressure on both sides
run pg_tile_pack64_tb             $H/pg_tile_pack64.v $S/pg_tile_pack64_tb.v

# 1) command generator + ring slot + gray frame_ptr
run pg_tile_s2mm_cmd_tb            $H/pg_tile_s2mm_cmd.v $S/pg_tile_s2mm_cmd_tb.v

# 2) original tiled roundtrip (regression: producer/consumer contract still bit-exact)
run pg_tiled_roundtrip_tb         $H/pg_raster_to_tile.v $H/pg_tile_dma.v $S/pg_tiled_roundtrip_tb.v

# 3) fsync alignment (regression: m_sof drives the command exactly once/frame)
run pg_raster_to_tile_fsync_tb    $H/pg_raster_to_tile.v $S/pg_raster_to_tile_fsync_tb.v

# 3b) TLAST-misalignment immunity (dest-res 640-seam fix): rows with extra beats past in_w must NOT drift
run pg_raster_to_tile_misalign_tb $H/pg_raster_to_tile.v $S/pg_raster_to_tile_misalign_tb.v

# 4) DEDICATED-DMA end-to-end: raster->tile->pack64->[S2MM model]->TILED read, multi-frame, slot advance
run pg_dedicated_dma_roundtrip_tb $H/pg_raster_to_tile.v $H/pg_tile_pack64.v $H/pg_tile_s2mm_cmd.v \
                                  $H/pg_tile_dma.v $S/pg_dedicated_dma_roundtrip_tb.v
