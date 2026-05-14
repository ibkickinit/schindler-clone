# program_phase_b_full.tcl — Load Phase B.1 .bit + .elf onto Zybo Z7-20 via JTAG.
#
# XSCT-based load: connect → ps7_init → fpga → dow → con. Replaces the
# .bit-only program_phase_b.tcl for full Phase B.1 bring-up.
#
# Run:
#   source /tools/Xilinx/2025.2/Vitis/settings64.sh
#   xsct tcl/program_phase_b_full.tcl

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit  [file join $project_root build vitis-phase-b phase_b_pf hw phase_b.bit]
set elf  [file join $project_root build vitis-phase-b vdma_init Debug vdma_init.elf]
set ps7  [file join $project_root build vitis-phase-b phase_b_pf hw ps7_init.tcl]

foreach f [list $bit $elf $ps7] {
    if {![file exists $f]} { puts "ERROR: $f missing"; exit 1 }
}

connect
targets -set -filter {name =~ "APU"}
rst -system
after 500

# Canonical JTAG bring-up order for Zynq-7000 (per Xilinx SDK/Vitis):
#   1. fpga (load PL bitstream first — FCLK clocks come up with defined state)
#   2. source ps7_init.tcl from the XSA hardware dir
#   3. ps7_init        (clocks, MIO, DDR3 controller)
#   4. ps7_post_config (releases PS-PL resets + enables AXI bridges)
#   5. dow .elf into DDR3
#   6. con
#
# Loading the bitstream AFTER ps7_post_config leaves PL peripherals (VDMA, VTC)
# with their AXI resets in an ambiguous state. The bare-metal driver then
# writes the reset bit and waits forever for the IP to ack — confirmed in our
# bench debug (PC stuck in _exit, VDMA HSIZE/VSIZE=0, reset bit still asserted).
targets -set -filter {name =~ "ARM*#0"}
fpga -file $bit
puts "STAGE_OK: bitstream loaded"

# Re-select APU after fpga — XSCT 2025.2 loses target context post-program.
targets -set -filter {name =~ "ARM*#0"}
source $ps7
ps7_init
ps7_post_config

# Load bare-metal ELF into DDR3 and run
dow $elf
con
puts "STAGE_OK: vdma_init.elf running"
puts ""
puts "Expected after PS app starts:"
puts "  - PS UART (115200 8N1 on Zybo's USB-UART) prints 'VDMA running', etc."
puts "  - HDMI TX should now carry whatever the source pushes, via DDR3 frame buffer"
puts "  - LED state same as B.0 baseline but monitor displays the picture"
disconnect
exit 0
