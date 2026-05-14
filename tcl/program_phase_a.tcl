# program_phase_a.tcl — Flash Phase A HDMI passthrough bitstream to the Zybo Z7-20 PL.

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit          [file join $project_root build phase-a-hdmi-passthrough \
                                            phase-a-hdmi-passthrough.runs impl_1 top_phase_a.bit]

if {![file exists $bit]} {
    puts "ERROR: Phase A bitstream not found at $bit"
    puts "       Run tcl/build_phase_a.tcl first."
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

puts "STAGE_OK: Phase A bitstream programmed"
puts ""
puts "Expected LED state with NO HDMI cables connected:"
puts "  LD0 (M14) = ON solid    (MMCM locked, 200 MHz refclk valid)"
puts "  LD1 (M15) = OFF         (no HDMI RX lock yet)"
puts "  LD2 (G14) = OFF         (no active video yet)"
puts "  LD3 (D18) = OFF or ON   (depends on whether HDMI-OUT monitor cable is plugged in)"
puts ""
puts "Plug in source HDMI:  LD1 turns ON, LD2 starts flickering."
puts "Plug in monitor HDMI: LD3 turns ON. Monitor should show source pixels."

close_hw_target
disconnect_hw_server
exit 0
