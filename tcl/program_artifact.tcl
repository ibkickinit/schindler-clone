# program_artifact.tcl — program FPGA from a saved build artifact.
#
# Usage:
#   xsct tcl/program_artifact.tcl <tag-or-substring>
#
# Examples:
#   xsct tcl/program_artifact.tcl iter5-720p-scaler_top-enable-6e4bd80
#   xsct tcl/program_artifact.tcl 1080p30                         # substring match
#   xsct tcl/program_artifact.tcl                                   # list available
#
# Each saved build lives under build/artifacts/<tag>/ with:
#   phase_b.xsa      — Vivado hardware platform (.bit inside)
#   vdma_init.elf    — Vitis-built bare-metal firmware
#   manifest.txt     — build context (branch, commit, env vars, timestamp)
#
# This script programs the .bit and loads + runs the .elf. Same effect as
# tcl/program_phase_b_full.tcl but lets you pick any archived build instead
# of whatever happens to be at build/phase_b.xsa right now.

set project_root [file normalize [file join [file dirname [info script]] ..]]
set artifacts_dir [file join $project_root build artifacts]

if {![file isdirectory $artifacts_dir]} {
    puts "ERROR: $artifacts_dir does not exist."
    puts "Run a Vivado build first; archive will populate automatically."
    exit 1
}

set all_tags [lsort -dictionary [glob -nocomplain -tails -directory $artifacts_dir *]]
if {[llength $all_tags] == 0} {
    puts "ERROR: no archived builds in $artifacts_dir"
    exit 1
}

set arg [lindex $argv 0]

if {$arg eq ""} {
    puts "Available archived builds:"
    foreach t $all_tags {
        set mpath [file join $artifacts_dir $t manifest.txt]
        if {[file exists $mpath]} {
            set fh [open $mpath r]
            set built_at "?"
            while {[gets $fh line] >= 0} {
                if {[regexp {^built_at:\s+(.+)$} $line _ built_at]} { break }
            }
            close $fh
            puts "  $t   (built $built_at)"
        } else {
            puts "  $t"
        }
    }
    puts "\nUsage: xsct tcl/program_artifact.tcl <tag>"
    exit 0
}

# Match: exact, then unique substring
set match $arg
if {[lsearch -exact $all_tags $arg] == -1} {
    set candidates [lsearch -all -inline -glob $all_tags "*${arg}*"]
    if {[llength $candidates] == 0} {
        puts "ERROR: no archived build matches '$arg'"
        puts "Run with no args to list available tags."
        exit 1
    } elseif {[llength $candidates] > 1} {
        puts "ERROR: ambiguous match — '$arg' matches multiple builds:"
        foreach c $candidates { puts "  $c" }
        puts "Refine the substring to be unique."
        exit 1
    }
    set match [lindex $candidates 0]
}

set artifact_dir [file join $artifacts_dir $match]
set bit [file join $artifact_dir phase_b.bit]
set elf [file join $artifact_dir vdma_init.elf]
set ps7 [file join $artifact_dir ps7_init.tcl]

foreach f [list $bit $elf $ps7] {
    if {![file exists $f]} {
        puts "ERROR: $f missing from $artifact_dir"
        puts "       Was this build archived before tcl/build_phase_b_app.tcl"
        puts "       was updated to copy .bit + ps7_init.tcl? Re-archive by"
        puts "       running the build, or program manually via program_phase_b_full.tcl."
        exit 1
    }
}

puts "PROGRAMMING: $match"
if {[file exists [file join $artifact_dir manifest.txt]]} {
    set fh [open [file join $artifact_dir manifest.txt] r]
    puts "--- manifest ---"
    puts -nonewline [read $fh]
    close $fh
    puts "----------------"
}

# Canonical Zynq-7000 JTAG bring-up sequence — mirrors program_phase_b_full.tcl.
connect
targets -set -filter {name =~ "APU"}
rst -system
after 500
targets -set -filter {name =~ "ARM*#0"}
fpga -file $bit
puts "STAGE_OK: bitstream loaded"
source $ps7
ps7_init
ps7_post_config
dow $elf
con
puts "STAGE_OK: programmed FPGA + loaded ELF from artifact '$match'"
