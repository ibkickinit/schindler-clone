# build_blinky.tcl — non-project batch build of the AUBoard 15P first-light design.
#
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   cd <repo>/usbc-dual-sdi/fpga/auboard
#   vivado -mode batch -nojournal -log build/build_blinky.log -source tcl/build_blinky.tcl
#
# Output: build/auboard_blinky.bit (+ timing/utilization/io reports). No board files needed — pins are
# hand-constrained from the user guide (the Avnet BDF has a known missing-300 MHz-clock issue).

set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize [file join $script_dir ..]]
set build_dir  [file join $root build]
file mkdir $build_dir

set part xcau15p-ffvb676-2-e
set top  auboard_blinky_top

read_verilog [glob [file join $root hdl *.v]]
read_xdc     [file join $root constraints auboard_blinky.xdc]

synth_design -top $top -part $part

# ---- IOSTANDARD per bank, from the Tria UG v1.0 "Voltage Rails" table ----
# 64/65 = +VCCO_64_65 1.2 V · 84 = +VCCO_0_84 1.8 V · 85 = +VCCO_85 3.3 V · 66/86 = VADJ (1.2/1.8 V)
array set bank_std {64 LVCMOS12 65 LVCMOS12 84 LVCMOS18 85 LVCMOS33}
set unknown 0
foreach port [get_ports] {
    set pin [get_property PACKAGE_PIN $port]
    if {$pin eq ""} { continue }
    set bank [get_property BANK [get_package_pins $pin]]
    if {[string match "sys_clk_*" $port]} {
        # 300 MHz LVDS oscillator into a 1.2 V HP bank: use a 1.2 V differential input standard.
        set_property IOSTANDARD DIFF_SSTL12 $port
        puts "IOSTD: $port pin $pin bank $bank -> DIFF_SSTL12"
        continue
    }
    if {[info exists bank_std($bank)]} {
        set_property IOSTANDARD $bank_std($bank) $port
        puts "IOSTD: $port pin $pin bank $bank -> $bank_std($bank)"
    } else {
        puts "ERROR: $port pin $pin is in bank $bank (VADJ or unknown) — set its IOSTANDARD by hand"
        incr unknown
    }
}
if {$unknown} { exit 1 }

opt_design
place_design
route_design

report_timing_summary -file [file join $build_dir timing.rpt]
report_utilization    -file [file join $build_dir utilization.rpt]
report_io             -file [file join $build_dir io.rpt]
report_drc            -file [file join $build_dir drc.rpt]

write_bitstream -force [file join $build_dir auboard_blinky.bit]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "BUILD_OK: [file join $build_dir auboard_blinky.bit]  WNS=$wns"
exit 0
