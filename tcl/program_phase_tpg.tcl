# program_phase_tpg.tcl — Flash the TPG diagnostic bitstream to the Zybo Z7-20.

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit          [file join $project_root build phase-tpg phase-tpg.runs impl_1 top_phase_tpg.bit]

if {![file exists $bit]} {
    puts "ERROR: TPG bitstream not found at $bit"
    puts "       Run tcl/build_phase_tpg.tcl first."
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

puts "STAGE_OK: TPG bitstream programmed"
puts ""
puts "Expected:"
puts "  LD0 = solid ON  (MMCM locked, 74.25 MHz pixel clock valid)"
puts "  LD2 = blinking ~4 Hz (pix_clk heartbeat — confirms PL is alive)"
puts "  LD3 = solid ON  (HDMI TX monitor cable plugged in)"
puts "  HDMI TX should drive 1280x720@60Hz with 75% color bars (top) +"
puts "  gray gradient (bottom) — independent of any HDMI input."

close_hw_target
disconnect_hw_server
exit 0
