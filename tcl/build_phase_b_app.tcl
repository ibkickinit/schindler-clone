# build_phase_b_app.tcl — XSCT build for the Phase B.1 bare-metal VDMA init app.
#
# Consumes build/phase_b.xsa (exported by tcl/build_phase_b.tcl), creates a
# Vitis platform + standalone domain, builds the .elf from sw/phase-b/src/.
#
# Run:
#   source /tools/Xilinx/2025.2/Vitis/settings64.sh
#   xsct tcl/build_phase_b_app.tcl
#
# Output:
#   build/vitis-phase-b/vdma_init/Debug/vdma_init.elf  (loadable via XSCT)

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set workspace    [file join $project_root build vitis-phase-b]
set xsa          [file join $project_root build phase_b.xsa]
set src_dir      [file join $project_root sw phase-b src]

if {![file exists $xsa]} {
    puts "ERROR: $xsa not found. Run tcl/build_phase_b.tcl first."
    exit 1
}

file delete -force $workspace
file mkdir $workspace
setws $workspace
puts "STAGE_OK: workspace at $workspace"

# Platform: maps XSA → platform project + BSP
platform create -name phase_b_pf -hw $xsa -no-boot-bsp
platform write
domain create -name standalone_ps7 -proc ps7_cortexa9_0 -os standalone
domain active standalone_ps7

# Pull in the standard standalone drivers (xaxivdma, xvtc, etc.) — already
# present in the standalone BSP for any IP that appears in the XSA.
platform generate
puts "STAGE_OK: platform + BSP generated"

# Application
app create -name vdma_init \
    -template "Empty Application(C)" \
    -platform phase_b_pf \
    -domain standalone_ps7
importsources -name vdma_init -path $src_dir
app build -name vdma_init

set elf [file join $workspace vdma_init Debug vdma_init.elf]
if {![file exists $elf]} {
    puts "ERROR: build did not produce $elf"
    exit 1
}
puts "STAGE_OK: built $elf"
exit 0
