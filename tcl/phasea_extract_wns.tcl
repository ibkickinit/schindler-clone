# Phase A gate: extract the INTRA-pclk WNS from the 74.25 MHz in-context warp build.
# Per docs/warp-cache-timing.md the meaningful number is the intra-pixel-clock combinational
# path (CDC paths excluded — those are async coeff/frame_ptr handshakes, not the datapath).
set dcp build/phase-b-vdma-passthrough/phase-b-vdma-passthrough.runs/impl_1/phase_b_bd_wrapper_routed.dcp
if {![file exists $dcp]} { puts "PHASEA: NO ROUTED DCP at $dcp"; exit 2 }
open_checkpoint $dcp
set pclk [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clk_wiz_pixclk_out*clk_out1*}]]
puts "PHASEA: pixel clock = [get_property NAME $pclk]  period = [get_property PERIOD $pclk] ns"

puts "=== overall design WNS (all clocks) ==="
set wns_all [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "PHASEA: design-wide WNS = $wns_all"

puts "=== INTRA-pclk WNS (the warp datapath, CDC excluded) @74.25 ==="
set p [get_timing_paths -from $pclk -to $pclk -max_paths 1 -nworst 1 -setup]
puts "PHASEA: intra-pclk WNS @74.25 = [get_property SLACK $p]"
report_timing -from $pclk -to $pclk -max_paths 1 -nworst 1 -setup

puts "=== top 5 intra-pclk worst paths (where the critical cone lives) ==="
foreach tp [get_timing_paths -from $pclk -to $pclk -max_paths 5 -nworst 1 -setup] {
    puts [format "  slack=%-8s  %s -> %s" [get_property SLACK $tp] \
        [get_property STARTPOINT_PIN $tp] [get_property ENDPOINT_PIN $tp]]
}

puts "=== utilization (fit check: LUT/BRAM/REG) ==="
report_utilization -hierarchical -hierarchical_depth 1 | grep -iE "warp|tilecache|pg_re"
puts "PHASEA: extraction done"
exit 0
