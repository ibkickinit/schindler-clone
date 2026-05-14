# capture_dvi2rgb_lock.tcl — Program Phase B bitstream (with kDebug ILAs)
# and capture the moment dvi2rgb's aLocked signal falls.
#
# Goal: discriminate whether pLocked drops because:
#   (a) IDELAYCTRL RDY drops → rRdyRst='1' → aLocked forced to 0
#        (= 200 MHz refclk path failed)
# or
#   (b) the MMCM unlocks → rMMCM_Locked falls → aLocked follows it
#        (= TMDS clock / MMCM path failed)
#
# Both produce identical LD1 LED behavior; the ILA tells us which.
#
# Run: vivado -mode batch -source tcl/capture_dvi2rgb_lock.tcl

set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set bit          [file join $project_root build phase-b-vdma-passthrough \
                                            phase-b-vdma-passthrough.runs impl_1 \
                                            phase_b_bd_wrapper.bit]
set ltx          [file join $project_root build phase-b-vdma-passthrough \
                                            phase-b-vdma-passthrough.runs impl_1 \
                                            phase_b_bd_wrapper.ltx]
set out_dir      [file join $project_root build ila-capture]
file mkdir $out_dir

if {![file exists $bit]} { puts "ERROR: bitstream not found: $bit"; exit 1 }
if {![file exists $ltx]} { puts "WARN:  debug probes (.ltx) not found at $ltx" }

open_hw_manager
connect_hw_server
puts "TARGETS: [get_hw_targets]"
current_hw_target [lindex [get_hw_targets] 0]
open_hw_target

set zynq_pl [lindex [get_hw_devices xc7z020_1] 0]
if {$zynq_pl eq ""} { puts "ERROR: xc7z020_1 not found"; exit 1 }
set_property PROGRAM.FILE $bit $zynq_pl
if {[file exists $ltx]} { set_property PROBES.FILE $ltx $zynq_pl }
program_hw_devices $zynq_pl
refresh_hw_device $zynq_pl
puts "STAGE_OK: bitstream + probes loaded"

# Discover ILAs. dvi2rgb's kDebug bakes in ILA_RefClkx + ILA_PixClkx.
set ilas [get_hw_ilas]
puts "ILAS_FOUND: [llength $ilas]"
foreach ila $ilas {
    puts "  $ila"
}

# Find the refclk-domain ILA (the one that has probes for aLocked / aDlyLckd).
# Probe naming after .ltx load is typically:
#   phase_b_bd_i/dvi2rgb_0/U0/dbg_Clocking_aLocked    (= aLocked, what becomes pLocked)
#   phase_b_bd_i/dvi2rgb_0/U0/dbg_rRdyRst             (= IDELAYCTRL-RDY-lost reset, active hi)
#   phase_b_bd_i/dvi2rgb_0/U0/dbg_rMMCM_Locked        (= synced MMCM lock)
set ila_refclk ""
foreach ila $ilas {
    set probes [get_hw_probes -of_objects $ila]
    foreach p $probes {
        if {[regexp {dbg_Clocking_aLocked|dbg_rRdyRst|dbg_rMMCM_Locked} $p]} {
            set ila_refclk $ila
            break
        }
    }
    if {$ila_refclk ne ""} { break }
}
if {$ila_refclk eq ""} {
    puts "ERROR: could not locate refclk-domain ILA. All probes:"
    foreach ila $ilas {
        puts "  ILA $ila probes:"
        foreach p [get_hw_probes -of_objects $ila] { puts "    $p" }
    }
    exit 2
}
puts "REFCLK_ILA: $ila_refclk"

# List its probes so we can verify naming
set all_probes [get_hw_probes -of_objects $ila_refclk]
foreach p $all_probes { puts "  PROBE: $p" }

# Helper: find a probe by suffix match
proc find_probe {ila suffix} {
    foreach p [get_hw_probes -of_objects $ila] {
        if {[string match "*$suffix" $p]} { return $p }
    }
    return ""
}

set p_alocked [find_probe $ila_refclk "dbg_Clocking_aLocked"]
set p_rrdyrst [find_probe $ila_refclk "dbg_rRdyRst"]
set p_rmmcmlk [find_probe $ila_refclk "dbg_rMMCM_Locked"]
set p_rdlyrst [find_probe $ila_refclk "dbg_rDlyRst"]
set p_rmmrst  [find_probe $ila_refclk "dbg_rMMCM_Reset"]

puts "PROBE.aLocked     = $p_alocked"
puts "PROBE.rRdyRst     = $p_rrdyrst"
puts "PROBE.rMMCM_Locked= $p_rmmcmlk"
puts "PROBE.rDlyRst     = $p_rdlyrst   (REPURPOSED: now drives CLKINSTOPPED from the MMCM)"
puts "PROBE.rMMCM_Reset = $p_rmmrst"
puts ""
puts "NOTE: column 'dbg_rDlyRst' in the CSV actually carries CLKINSTOPPED for"
puts "      this build (TMDS_Clocking.vhd modification 2026-05-13). When it"
puts "      goes HIGH near the unlock event, the MMCM saw its input TMDS clock"
puts "      stop. When it stays LOW through the unlock, the MMCM unlocked"
puts "      despite valid input clock — points to Vccint / analog disturbance."

if {$p_alocked eq ""} { puts "ERROR: no aLocked probe found"; exit 3 }

# Configure trigger: falling edge of aLocked.
# (CONTROL.TRIGGER_MODE is read-only in Vivado 2025.2; defaults to basic trigger.)
set_property CONTROL.DATA_DEPTH 1024 $ila_refclk
# Position trigger at 50% so we see what came before the lock drop
set_property CONTROL.TRIGGER_POSITION 512 $ila_refclk
# Set every probe to "don't care" first, then arm the trigger probe specifically.
foreach _p [get_hw_probes -of_objects $ila_refclk] {
    set_property TRIGGER_COMPARE_VALUE eq1'bX [get_hw_probes $_p]
}
set_property TRIGGER_COMPARE_VALUE eq1'bF [get_hw_probes $p_alocked]

# Arm the ILA (non-blocking)
run_hw_ila $ila_refclk
puts "ARMED: waiting for falling edge of $p_alocked (timeout 90 s)..."

# Wait for trigger to fire — up to 90 seconds. Per the bench observation,
# flicker happens every ~8-13 seconds, so 90 s is plenty.
if {[catch {wait_on_hw_ila -timeout 90 $ila_refclk} err]} {
    puts "ERROR: wait_on_hw_ila failed: $err"
    puts "Trigger did NOT fire in 90 s. Possible meanings:"
    puts "  - No HDMI source plugged in, so dvi2rgb never even tried to lock"
    puts "  - aLocked never falls (i.e., it's solid right now — not flickering)"
    puts "  - Wrong probe name; check 'PROBE: ...' lines above"
    close_hw_target
    disconnect_hw_server
    exit 4
}
puts "TRIGGERED: aLocked falling edge captured"

# Upload captured data and extract the values around the trigger
upload_hw_ila_data $ila_refclk
set ila_data [current_hw_ila_data]

# Write CSV out for off-line inspection
set csv_path [file join $out_dir "dvi2rgb_lockfall_[clock seconds].csv"]
write_hw_ila_data -force -csv_file $csv_path $ila_data
puts "CSV: $csv_path"

# Also pull the values of the key probes at the trigger and a few cycles
# before/after so we can answer the question right here in the log.
# get_hw_ila_data is the structured query API.
proc dump_probe {data probe label} {
    if {$probe eq ""} { puts "  $label: <no probe>"; return }
    set vals [get_hw_ila_data -window 0 $data -of_objects [get_hw_probes $probe]]
    puts "  $label : $vals"
}

puts ""
puts "=== Trigger captured. Probe values across the capture window ==="
puts "(sample 0 = oldest captured; trigger is at sample 2048 with DATA_DEPTH=4096)"
puts ""
# Pull values directly via the CSV — simpler than the structured API
# (which has different syntax across Vivado versions).
puts "Reading first 30 lines of CSV for quick inspection:"
set fp [open $csv_path r]
set i 0
while {[gets $fp line] >= 0 && $i < 30} {
    puts "  $line"
    incr i
}
close $fp

puts ""
puts "Window around trigger (samples 500-525, trigger @ 512):"
set fp [open $csv_path r]
set i 0
while {[gets $fp line] >= 0} {
    if {$i >= 500 && $i <= 525} { puts "  \[$i\] $line" }
    incr i
    if {$i > 525} { break }
}
close $fp

close_hw_target
disconnect_hw_server
puts "STAGE_OK: capture complete; see CSV at $csv_path"
exit 0
