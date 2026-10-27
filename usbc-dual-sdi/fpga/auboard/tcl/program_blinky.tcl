# program_blinky.tcl — JTAG-program the AUBoard 15P (volatile; lost on power cycle).
#
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   cd <repo>/usbc-dual-sdi/fpga/auboard
#   vivado -mode batch -nojournal -log build/program.log -source tcl/program_blinky.tcl
#
# Board: 12 V on J51, SW1 on (D18 green), micro-USB in J9, J11 = 1-2 (FPGA only in the chain).

set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ..]]
set bit        [file join $root build auboard_blinky.bit]

if {![file exists $bit]} {
    puts "ERROR: bitstream not found at $bit — run tcl/build_blinky.tcl first"
    exit 1
}

open_hw_manager
connect_hw_server
puts "TARGETS: [get_hw_targets]"
if {[llength [get_hw_targets]] == 0} {
    puts "ERROR: no JTAG target — check the J9 USB cable and that the cable driver is installed"
    puts "       (Vivado: <install>/data/xicom/cable_drivers/lin64/install_script/install_drivers)"
    exit 1
}
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target

set dev [lindex [get_hw_devices xcau15p*] 0]
if {$dev eq ""} {
    puts "ERROR: xcau15p not found in the JTAG chain. Devices seen: [get_hw_devices]"
    puts "       If an FMC card is fitted, set J11 to 1-2."
    exit 1
}
puts "PROGRAMMING: $dev with $bit"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "STAGE_OK: bitstream programmed — D19 (blue DONE) should be lit, LED1-4 counting,"
puts "          RGB1 cycling, UART banner once a second at 115200 8N1."
close_hw_target
disconnect_hw_server
exit 0
