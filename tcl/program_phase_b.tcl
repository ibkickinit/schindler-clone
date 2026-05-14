# program_phase_b.tcl — Load Phase B bitstream onto the Zybo Z7-20 PL via JTAG.
#
# This script ONLY loads the .bit. Without PS firmware (Phase B.1), the VDMA
# channels stay disabled at their register defaults — no video flows through
# DDR3. To exercise the full pipeline, follow up with the bare-metal VDMA-init
# .elf via XSCT (planned for Phase B.1, sw/phase-b/).

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit          [file join $project_root build phase-b-vdma-passthrough \
                                            phase-b-vdma-passthrough.runs impl_1 \
                                            phase_b_bd_wrapper.bit]

if {![file exists $bit]} {
    puts "ERROR: Phase B bitstream not found at $bit"
    puts "       Run tcl/build_phase_b.tcl first."
    exit 1
}

open_hw_manager
connect_hw_server
puts "TARGETS: [get_hw_targets]"
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target

set zynq_pl [lindex [get_hw_devices xc7z020_1] 0]
if {$zynq_pl eq ""} { puts "ERROR: xc7z020_1 not found in JTAG chain"; exit 1 }
puts "PROGRAMMING: $zynq_pl with $bit"
set_property PROGRAM.FILE $bit $zynq_pl
program_hw_devices $zynq_pl
puts "STAGE_OK: Phase B bitstream programmed"
puts ""
puts "Expected LED state WITHOUT PS firmware (Phase B.0 baseline):"
puts "  LD0 = ON          (clk_wiz PLL locked, 200 MHz refclk valid)"
puts "  LD1 = ON          (dvi2rgb pixel-clock recovery locked once source plugged in)"
puts "  LD2 = ~ON         (vid_pVDE high during active video — looks solid at 60 fps)"
puts "  LD3 = ON          (HDMI TX HPD sensed from connected monitor)"
puts ""
puts "  Monitor will show NO SIGNAL — VDMA channels are at default-disabled state."
puts "  Picture comes back after Phase B.1 loads the bare-metal VDMA-init .elf via XSCT."

close_hw_target
disconnect_hw_server
exit 0
