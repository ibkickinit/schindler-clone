# ila_capture.tcl — Capture ILA traces from running bitstream, save as CSV.
#
# Phase D iter-3n bench tool. Loads the iter3n bitstream's .ltx probes file,
# arms both ILAs (ila_scaler_out + ila_mm2s_out), triggers on m_axis_tuser
# (start of frame for the scaler / first AXIS-valid pixel for MM2S), captures
# 2048 samples each, repeats N times, saves each to CSV. Compare CSVs to find
# whether scaler output varies per frame or only MM2S output does.
#
# Run:
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   vivado -mode batch -nojournal -nolog -source tcl/ila_capture.tcl
#
# Output:
#   build/ila-capture/iter3n/scaler-N.csv  (N = 1..NCAPTURES)
#   build/ila-capture/iter3n/mm2s-N.csv
# Then run python/analyze_ila.py to diff captures.

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit_path     [file join $project_root build phase-b-vdma-passthrough \
                                          phase-b-vdma-passthrough.runs impl_1 \
                                          phase_b_bd_wrapper.bit]
set ltx_path     [file join $project_root build phase-b-vdma-passthrough \
                                          phase-b-vdma-passthrough.runs impl_1 \
                                          debug_nets.ltx]
set out_dir      [file join $project_root build ila-capture iter3n]
file mkdir $out_dir

set NCAPTURES 5

foreach f [list $bit_path $ltx_path] {
    if {![file exists $f]} { puts "ERROR: $f missing"; exit 1 }
}

open_hw_manager
connect_hw_server
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target

set zynq_pl [lindex [get_hw_devices xc7z020_1] 0]
# Probes-only: do NOT re-program the bitstream here (would wipe the ELF that
# tcl/program_phase_b_full.tcl loaded to start the VDMA pipeline). Just attach
# the debug-probes file so ILA cores become introspectable.
set_property PROBES.FILE $ltx_path $zynq_pl
refresh_hw_device $zynq_pl
puts "STAGE_OK: probes attached to running bitstream"

set ila_scaler [get_hw_ilas -filter {CELL_NAME =~ "*ila_scaler_out*"}]
set ila_mm2s   [get_hw_ilas -filter {CELL_NAME =~ "*ila_mm2s_out*"}]
if {$ila_scaler eq "" || $ila_mm2s eq ""} {
    puts "ERROR: ILA cores not found. ILAs in hw: [get_hw_ilas]"
    exit 1
}
puts "STAGE_OK: found ILAs"

# Configure triggers using System ILA's actual probe names (queried 2026-05-15):
#   phase_b_bd_i/ila_scaler_out/inst/net_slot_0_axis_tuser  — TUSER rising = SOF
#   phase_b_bd_i/ila_mm2s_out/inst/net_slot_0_axis_tvalid   — first valid pixel
set_property TRIGGER_COMPARE_VALUE eq1'b1 \
    [get_hw_probes phase_b_bd_i/ila_scaler_out/inst/net_slot_0_axis_tuser -of $ila_scaler]
set_property TRIGGER_COMPARE_VALUE eq1'b1 \
    [get_hw_probes phase_b_bd_i/ila_mm2s_out/inst/net_slot_0_axis_tvalid -of $ila_mm2s]
# Capture trigger position: 0 means trigger sample is the first sample
set_property CONTROL.TRIGGER_POSITION 0 $ila_scaler
set_property CONTROL.TRIGGER_POSITION 0 $ila_mm2s

for {set i 1} {$i <= $NCAPTURES} {incr i} {
    puts "=== Capture $i / $NCAPTURES ==="
    run_hw_ila $ila_scaler
    run_hw_ila $ila_mm2s
    wait_on_hw_ila $ila_scaler
    wait_on_hw_ila $ila_mm2s
    upload_hw_ila_data $ila_scaler
    upload_hw_ila_data $ila_mm2s

    set csv_scaler [file join $out_dir "scaler-$i.csv"]
    set csv_mm2s   [file join $out_dir "mm2s-$i.csv"]
    write_hw_ila_data -csv_file -force $csv_scaler [current_hw_ila_data [lindex [get_hw_ila_datas] 0]]
    write_hw_ila_data -csv_file -force $csv_mm2s   [current_hw_ila_data [lindex [get_hw_ila_datas] 1]]
    puts "  saved $csv_scaler"
    puts "  saved $csv_mm2s"
    after 200
}

close_hw_target
disconnect_hw_server
puts "DONE: $NCAPTURES captures written to $out_dir"
exit 0
