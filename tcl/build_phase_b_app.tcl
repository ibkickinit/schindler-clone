# build_phase_b_app.tcl — XSCT build for the Phase B.1 bare-metal VDMA init app.
#
# Consumes build/phase_b.xsa (exported by tcl/build_phase_b.tcl), creates a
# Vitis platform + standalone domain, builds the .elf from sw/phase-b/src/.
#
# Run:
#   source /tools/Xilinx/2025.2/Vitis/settings64.sh
#   xsct tcl/build_phase_b_app.tcl
#
# OUTPUT_MODE env var (2026-05-31): mirrors tcl/build_phase_b.tcl. When set
# to 1080p30 or 1080p60, the build passes -DOUTPUT_1080P=1 to gcc so
# sw/phase-b/src/main.c picks up FRAME_W=1920 / FRAME_H=1080. Default is
# the 720p60 production substrate.
#
# Output:
#   build/vitis-phase-b/vdma_init/Debug/vdma_init.elf  (loadable via XSCT)

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set workspace    [file join $project_root build vitis-phase-b]
set xsa          [file join $project_root build phase_b.xsa]
set src_dir      [file join $project_root sw phase-b src]

# Read OUTPUT_MODE env var to decide whether to pass OUTPUT_1080P compile define.
if {[info exists ::env(OUTPUT_MODE)]} { set OUTPUT_MODE $::env(OUTPUT_MODE) }
if {![info exists OUTPUT_MODE]} { set OUTPUT_MODE 720p }
set FW_OUTPUT_1080P 0
if {$OUTPUT_MODE eq "1080p30" || $OUTPUT_MODE eq "1080p60" || $OUTPUT_MODE eq "1080p"} {
    set FW_OUTPUT_1080P 1
}
puts "FW BUILD: OUTPUT_MODE=$OUTPUT_MODE → OUTPUT_1080P=$FW_OUTPUT_1080P"

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

# Inject OUTPUT_1080P compile define if env var requested it. Vitis xsct
# uses `app config -add define-compiler-symbols` for preprocessor defines.
if {$FW_OUTPUT_1080P == 1} {
    app config -name vdma_init -add define-compiler-symbols OUTPUT_1080P=1
    puts "FW BUILD: added -DOUTPUT_1080P=1 to vdma_init compile flags"
}

app build -name vdma_init

set elf [file join $workspace vdma_init Debug vdma_init.elf]
if {![file exists $elf]} {
    puts "ERROR: build did not produce $elf"
    exit 1
}
puts "STAGE_OK: built $elf"

# =============================================================================
# Auto-archive ELF alongside the corresponding XSA (2026-05-31). Mirrors the
# tag scheme in tcl/build_phase_b.tcl so XSA + ELF + manifest sit together.
# =============================================================================
proc archive_elf {project_root elf} {
    set branch [exec git -C $project_root rev-parse --abbrev-ref HEAD]
    set commit [exec git -C $project_root rev-parse --short HEAD]
    set output_mode [expr {[info exists ::env(OUTPUT_MODE)] ? $::env(OUTPUT_MODE) : "720p"}]
    set scaler_module [expr {[info exists ::env(SCALER_MODULE)] ? $::env(SCALER_MODULE) : "scaler_top"}]
    set color_pipeline [expr {[info exists ::env(COLOR_PIPELINE)] ? $::env(COLOR_PIPELINE) : "enable"}]
    set tag "${branch}-${output_mode}-${scaler_module}-${color_pipeline}-${commit}"
    set dst [file join $project_root build artifacts $tag]
    file mkdir $dst
    file copy -force $elf [file join $dst vdma_init.elf]
    # Also copy the .bit + ps7_init.tcl extracted by the Vitis platform from
    # the XSA, so tcl/program_artifact.tcl can program without re-extracting.
    set bit [file join $project_root build vitis-phase-b phase_b_pf hw phase_b.bit]
    set ps7 [file join $project_root build vitis-phase-b phase_b_pf hw ps7_init.tcl]
    if {[file exists $bit]} { file copy -force $bit [file join $dst phase_b.bit] }
    if {[file exists $ps7]} { file copy -force $ps7 [file join $dst ps7_init.tcl] }
    puts "ARCHIVED ELF + bit + ps7_init: $dst"
}
if {[catch {archive_elf $project_root $elf} archive_err]} {
    puts "WARN: archive_elf failed: $archive_err  (ELF still at default location)"
}
exit 0
