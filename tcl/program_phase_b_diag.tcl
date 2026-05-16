# program_phase_b_diag.tcl — Load the rebuild bitstream + existing ELF.
#
# Used by the Phase D iter-2 chroma-noise bisect: programs the freshly built
# diagnostic bitstream from build/phase-b-vdma-passthrough/.../impl_1/ without
# overwriting the cached working bitstream at
# build/vitis-phase-b/phase_b_pf/hw/phase_b.bit.
# The ELF (vdma_init.elf) is unchanged across diagnostic builds — we just
# program registers to start VDMA + VTC, which doesn't depend on HDL.

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit  [file join $project_root build phase-b-vdma-passthrough \
                                  phase-b-vdma-passthrough.runs impl_1 phase_b_bd_wrapper.bit]
set elf  [file join $project_root build vitis-phase-b vdma_init Debug vdma_init.elf]
set ps7  [file join $project_root build vitis-phase-b phase_b_pf hw ps7_init.tcl]

foreach f [list $bit $elf $ps7] {
    if {![file exists $f]} { puts "ERROR: $f missing"; exit 1 }
}

connect
targets -set -filter {name =~ "APU"}
rst -system
after 500

targets -set -filter {name =~ "ARM*#0"}
fpga -file $bit
puts "STAGE_OK: diag bitstream loaded ($bit)"

targets -set -filter {name =~ "ARM*#0"}
source $ps7
ps7_init
ps7_post_config

dow $elf
con
puts "STAGE_OK: vdma_init.elf running"
disconnect
exit 0
