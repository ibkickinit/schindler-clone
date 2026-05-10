# build.tcl — Create Schindler 2.0 Vivado project from sources, synth, impl,
# write bitstream. Idempotent: deletes any existing build dir first so the
# script can always start from a known state.
#
# Run from anywhere:
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   vivado -mode batch -nojournal -log build.log -source <repo>/tcl/build.tcl

set project_name "schindler-2.0"
set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set build_dir    [file join $project_root build]
set vivado_dir   [file join $build_dir $project_name]

file delete -force $vivado_dir
file mkdir $build_dir

create_project $project_name $vivado_dir -part xc7z020clg400-1

# HDL sources
foreach f [glob [file join $project_root hdl *.v]] {
    add_files -norecurse $f
    puts "ADD HDL: $f"
}

# Constraints
foreach f [glob [file join $project_root constraints *.xdc]] {
    add_files -fileset constrs_1 -norecurse $f
    puts "ADD XDC: $f"
}

# Simulation sources
foreach f [glob -nocomplain [file join $project_root sim *.v]] {
    add_files -fileset sim_1 -norecurse $f
    puts "ADD SIM: $f"
}

set_property top top [current_fileset]
update_compile_order -fileset sources_1
if {[llength [get_files -of [get_filesets sim_1]]] > 0} {
    update_compile_order -fileset sim_1
}

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
puts "BITSTREAM: [lindex $bitfiles 0]"

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "TIMING: WNS=$wns ns  WHS=$whs ns"

exit 0
