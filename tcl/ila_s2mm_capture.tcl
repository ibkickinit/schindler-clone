# ila_s2mm_capture.tcl — iter4h: capture S2MM AXI writes to DDR3 with the
# new ila_s2mm_axi System ILA, save as CSV. Trigger on AWADDR matching slot 0
# row 700 (= 0x10290400). With storage qualifier on AWVALID=1, only AXI write
# transactions populate samples — extends the 4096-sample window to cover
# many frames' worth of writes, not just 40 µs.
#
# Purpose: settle the "single-write vs double-write" question for slot 0 rows
# 694-719. If the capture shows AWADDR 0x10290400 appearing TWICE within the
# window (= within one frame period), it's a double-write. If ONCE per frame,
# S2MM is mis-addressing the new-frame's first beats to slot 0's tail.
#
# Run:
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   vivado -mode batch -nojournal -nolog -source tcl/ila_s2mm_capture.tcl
#
# Output:
#   build/ila-capture/iter4h/s2mm_axi-N.csv  (N = 1..NCAPTURES)

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit_path     [file join $project_root build phase-b-vdma-passthrough \
                                          phase-b-vdma-passthrough.runs impl_1 \
                                          phase_b_bd_wrapper.bit]
set ltx_path     [file join $project_root build phase-b-vdma-passthrough \
                                          phase-b-vdma-passthrough.runs impl_1 \
                                          debug_nets.ltx]
set out_dir      [file join $project_root build ila-capture iter4h]
file mkdir $out_dir

set NCAPTURES 3

foreach f [list $bit_path $ltx_path] {
    if {![file exists $f]} { puts "ERROR: $f missing"; exit 1 }
}

open_hw_manager
connect_hw_server
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target

set zynq_pl [lindex [get_hw_devices xc7z020_1] 0]
set_property PROBES.FILE $ltx_path $zynq_pl
refresh_hw_device $zynq_pl
puts "STAGE_OK: probes attached"

set ila_s2mm [get_hw_ilas -filter {CELL_NAME =~ "*ila_s2mm_axi*"}]
if {$ila_s2mm eq ""} {
    puts "ERROR: ila_s2mm_axi not found. ILAs: [get_hw_ilas]"
    exit 1
}
puts "STAGE_OK: found ila_s2mm_axi"

# Dump all the probe names available so we know what to trigger on.
puts "Available probes on ila_s2mm_axi:"
foreach p [get_hw_probes -of $ila_s2mm] {
    puts "  [get_property NAME $p]"
}

# Trigger setup:
#   - AWVALID == 1 AND AWADDR == 0x10290400  (slot 0 row 700 start)
#   - Storage qualifier: only store cycles where AWVALID == 1
#   - Trigger position 2048 (middle) so we see pre and post events.
#
# Per Vivado's System ILA AXIMM probe naming convention:
#   phase_b_bd_i/ila_s2mm_axi/inst/net_slot_0_axi_awaddr
#   phase_b_bd_i/ila_s2mm_axi/inst/net_slot_0_axi_awvalid
#   phase_b_bd_i/ila_s2mm_axi/inst/net_slot_0_axi_awready
set probe_awaddr  [get_hw_probes -of $ila_s2mm -filter {NAME =~ "*awaddr"}]
set probe_awvalid [get_hw_probes -of $ila_s2mm -filter {NAME =~ "*awvalid"}]
set probe_wdata   [get_hw_probes -of $ila_s2mm -filter {NAME =~ "*wdata"}]

if {$probe_awaddr eq "" || $probe_awvalid eq ""} {
    puts "ERROR: could not find awaddr or awvalid probes"
    puts "Probes found: [get_hw_probes -of $ila_s2mm]"
    exit 1
}

# Trigger: AWADDR == 0x10290400 (slot 0 row 700) AND AWVALID == 1
set_property TRIGGER_COMPARE_VALUE eq32'h10290400 $probe_awaddr
set_property TRIGGER_COMPARE_VALUE eq1'b1         $probe_awvalid

# Storage qualifier: only capture when AWVALID = 1 (= an AXI write address handshake cycle).
# This makes each ILA sample = one AXI write transaction, covering many frames.
set_property CAPTURE_COMPARE_VALUE eq1'b1 $probe_awvalid
set_property CONTROL.CAPTURE_MODE BASIC $ila_s2mm

# Trigger position 2048 of 4096 — see pre and post.
set_property CONTROL.TRIGGER_POSITION 2048 $ila_s2mm

for {set i 1} {$i <= $NCAPTURES} {incr i} {
    puts "=== Capture $i / $NCAPTURES ==="
    run_hw_ila $ila_s2mm
    wait_on_hw_ila $ila_s2mm
    upload_hw_ila_data $ila_s2mm

    set csv [file join $out_dir "s2mm_axi-$i.csv"]
    write_hw_ila_data -csv_file -force $csv [current_hw_ila_data [lindex [get_hw_ila_datas] 0]]
    puts "  saved $csv"
    after 200
}

close_hw_target
disconnect_hw_server
puts "DONE: $NCAPTURES captures written to $out_dir"
exit 0
