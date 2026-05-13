# build_phase_a.tcl — Phase A HDMI passthrough build script.
#
# Builds a separate Vivado project at build/phase-a-hdmi-passthrough/ targeting
# the Zybo Z7-20. Pure-PL design (no Zynq PS) — bitstream loads via JTAG.
#
# Adds Digilent's dvi2rgb + rgb2dvi IP cores from ~/fpga/vivado-library/ip/.
#
# Run from anywhere:
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
#   export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
#   vivado -mode batch -nojournal -log build_phase_a.log -source <repo>/tcl/build_phase_a.tcl

set project_name "phase-a-hdmi-passthrough"
set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set build_dir    [file join $project_root build]
set vivado_dir   [file join $build_dir $project_name]

file delete -force $vivado_dir
file mkdir $build_dir

# Set board files repo
if {[info exists ::env(BOARD_PARTS_REPO_PATHS)]} {
    set_param board.repoPaths $::env(BOARD_PARTS_REPO_PATHS)
}

# Default Digilent IP location if env var not set
if {[info exists ::env(DIGILENT_IP_REPO_PATH)]} {
    set digilent_ip_path $::env(DIGILENT_IP_REPO_PATH)
} else {
    set digilent_ip_path [file join $::env(HOME) fpga vivado-library ip]
}
if {![file isdirectory $digilent_ip_path]} {
    puts "ERROR: Digilent IP repo not found at $digilent_ip_path"
    puts "       Clone https://github.com/Digilent/vivado-library to ~/fpga/vivado-library"
    exit 1
}
puts "DIGILENT IP REPO: $digilent_ip_path"

create_project $project_name $vivado_dir -part xc7z020clg400-1

# Apply Zybo Z7-20 board preset
set board [lindex [get_board_parts -filter {NAME =~ "*zybo-z7-20*"}] 0]
if {$board eq ""} {
    puts "ERROR: Zybo Z7-20 board file not found. Set BOARD_PARTS_REPO_PATHS."
    exit 1
}
set_property board_part $board [current_project]
puts "BOARD: $board"

# Register Digilent IP repository so dvi2rgb / rgb2dvi are discoverable
set_property ip_repo_paths $digilent_ip_path [current_project]
update_ip_catalog
puts "IP CATALOG: dvi2rgb + rgb2dvi available"

# ---- HDL sources ----
# Phase A only uses top_phase_a.v. Phase 2 HDL (top.v, vid_timing.v, etc.) is
# excluded from this build — it has its own project at build/schindler-2.0/.
add_files -norecurse [file join $project_root hdl top_phase_a.v]
puts "ADD HDL: top_phase_a.v"

# ---- Constraints ----
add_files -fileset constrs_1 -norecurse \
    [file join $project_root constraints zybo_z7_20_phase_a.xdc]
puts "ADD XDC: zybo_z7_20_phase_a.xdc"

# ---- Instantiate Digilent IPs ----
# dvi2rgb — packaged as a Vivado IP; instantiated as an IP in the project so
# Vivado pulls in the IP's bundled constraints, scripts, and OOC synthesis.
create_ip -name dvi2rgb -vendor digilentinc.com -library ip -version 2.0 \
    -module_name dvi2rgb_0
set_property -dict [list \
    CONFIG.kEmulateDDC      {true} \
    CONFIG.kRstActiveHigh   {true} \
    CONFIG.kAddBUFG         {true} \
    CONFIG.kClkRange        {2} \
    CONFIG.kEdidFileName    {dgl_720p_cea.data} \
    CONFIG.kDebug           {false} \
] [get_ips dvi2rgb_0]
puts "IP: dvi2rgb_0 instantiated"

create_ip -name rgb2dvi -vendor digilentinc.com -library ip -version 1.4 \
    -module_name rgb2dvi_0
# kGenerateSerialClk=true: rgb2dvi generates its own 5×PixelClk internally via
# PLL. dvi2rgb's IP wrapper doesn't expose SerialClk as an output port (the
# underlying VHDL flagged it "advanced use only"), so each direction needs its
# own clocking. One extra MMCM/PLL resource; trade-off accepted for clean port
# matching with the IP wrappers.
set_property -dict [list \
    CONFIG.kGenerateSerialClk {true} \
    CONFIG.kClkPrimitive      {PLL} \
    CONFIG.kClkRange          {2} \
    CONFIG.kRstActiveHigh     {true} \
] [get_ips rgb2dvi_0]
puts "IP: rgb2dvi_0 instantiated"

# Lock top + compile order
set_property top top_phase_a [current_fileset]
update_compile_order -fileset sources_1

# ---- Synthesis ----
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: synth_1 did not reach 100% (status=[get_property STATUS [get_runs synth_1]])"
    exit 1
}
puts "STAGE_OK: synthesis complete"

# ---- Implementation + bitstream ----
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
