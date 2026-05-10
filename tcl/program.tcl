# program.tcl — Flash build/schindler-2.0/.../top.bit to the Zybo Z7-20 PL.

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit          [file join $project_root build schindler-2.0 schindler-2.0.runs impl_1 top.bit]

if {![file exists $bit]} {
    puts "ERROR: bitstream not found at $bit — run build.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server
puts "TARGETS: [get_hw_targets]"

current_hw_target [lindex [get_hw_targets] 0]
open_hw_target

set zynq_pl [lindex [get_hw_devices xc7z020_1] 0]
if {$zynq_pl eq ""} {
    puts "ERROR: xc7z020_1 not found in JTAG chain"
    exit 1
}
puts "PROGRAMMING: $zynq_pl with $bit"

set_property PROGRAM.FILE $bit $zynq_pl
program_hw_devices $zynq_pl

puts "STAGE_OK: bitstream programmed"
puts "Watch the board: LD0 should light (MMCM locked at 54 MHz)."

close_hw_target
disconnect_hw_server
exit 0
