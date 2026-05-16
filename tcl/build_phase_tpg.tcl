# build_phase_tpg.tcl — TPG -> rgb2dvi -> HDMI TX diagnostic build.
#
# Adapted from build_phase_a.tcl: same Zybo Z7-20, same rgb2dvi config,
# but no dvi2rgb / no HDMI RX. Builds at build/phase-tpg/.
#
# Run:
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
#   export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
#   vivado -mode batch -nojournal -log build_phase_tpg.log -source <repo>/tcl/build_phase_tpg.tcl

set project_name "phase-tpg"
set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set build_dir    [file join $project_root build]
set vivado_dir   [file join $build_dir $project_name]

file delete -force $vivado_dir
file mkdir $build_dir

if {[info exists ::env(BOARD_PARTS_REPO_PATHS)]} {
    set_param board.repoPaths $::env(BOARD_PARTS_REPO_PATHS)
}

if {[info exists ::env(DIGILENT_IP_REPO_PATH)]} {
    set digilent_ip_path $::env(DIGILENT_IP_REPO_PATH)
} else {
    set digilent_ip_path [file join $::env(HOME) fpga vivado-library ip]
}
if {![file isdirectory $digilent_ip_path]} {
    puts "ERROR: Digilent IP repo not found at $digilent_ip_path"
    exit 1
}
puts "DIGILENT IP REPO: $digilent_ip_path"

create_project $project_name $vivado_dir -part xc7z020clg400-1

set board [lindex [get_board_parts -filter {NAME =~ "*zybo-z7-20*"}] 0]
if {$board eq ""} {
    puts "ERROR: Zybo Z7-20 board file not found. Set BOARD_PARTS_REPO_PATHS."
    exit 1
}
set_property board_part $board [current_project]
puts "BOARD: $board"

set_property ip_repo_paths $digilent_ip_path [current_project]
update_ip_catalog
puts "IP CATALOG: rgb2dvi available"

# ---- HDL ----
add_files -norecurse [file join $project_root hdl top_phase_tpg.v]
puts "ADD HDL: top_phase_tpg.v"

# ---- Constraints ----
add_files -fileset constrs_1 -norecurse \
    [file join $project_root constraints zybo_z7_20_phase_tpg.xdc]
puts "ADD XDC: zybo_z7_20_phase_tpg.xdc"

# ---- rgb2dvi IP ----
# kClkRange=2 selects MULT_F=10 inside the IP's internal MMCM (range covers
# pixel clocks 60..120 MHz). At 74.25 MHz that gives VCO=742.5 MHz, comfortably
# in the MMCME2 600..1200 MHz spec. (kClkRange=1 would target 120..200 MHz
# pixel clocks and computes VCO=371 MHz at 74.25 — fails DRC at bitstream time.)
create_ip -name rgb2dvi -vendor digilentinc.com -library ip -version 1.4 \
    -module_name rgb2dvi_0
set_property -dict [list \
    CONFIG.kGenerateSerialClk {true} \
    CONFIG.kClkPrimitive      {MMCM} \
    CONFIG.kClkRange          {2} \
    CONFIG.kRstActiveHigh     {true} \
] [get_ips rgb2dvi_0]
puts "IP: rgb2dvi_0 instantiated"

set_property top top_phase_tpg [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: synth_1 did not reach 100% (status=[get_property STATUS [get_runs synth_1]])"
    exit 1
}
puts "STAGE_OK: synthesis complete"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: impl_1 did not reach 100% (status=[get_property STATUS [get_runs impl_1]])"
    exit 1
}
puts "STAGE_OK: implementation + bitstream complete"

set bitfiles [glob -nocomplain [file join $vivado_dir $project_name.runs impl_1 *.bit]]
if {[llength $bitfiles] == 0} {
    puts "ERROR: no .bit file produced"
    exit 1
}
set bit_path [lindex $bitfiles 0]
puts "BITSTREAM: $bit_path"

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "TIMING: WNS=$wns ns  WHS=$whs ns"

exit 0
