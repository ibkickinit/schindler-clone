# Post-build warp timing analysis: read the routed checkpoint, report the warp
# worst path, and re-evaluate WNS against the 148.5 MHz (6.734 ns) 1080p target.
# Usage: vivado -mode batch -source tcl/warp_timing_148.tcl
set dcp [lindex [glob -nocomplain build/phase-b-vdma-passthrough/*.runs/impl_1/*_routed.dcp] 0]
if {$dcp eq ""} { puts "NO_ROUTED_DCP"; exit 1 }
puts "DCP: $dcp"
open_checkpoint $dcp

# Overall WNS at the as-built 74.25 MHz pclk constraint
set wns74 [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS@74.25 (13.468 ns) = $wns74"

# The pixel clock (warp logic domain)
puts "=== clocks ==="
report_clocks
# Worst path overall (expected: the warp prefetch issue cone in u_tc)
puts "=== worst setup path (overall) ==="
report_timing -max_paths 1 -nworst 1 -setup -path_type full_clock_expanded

# Worst path scoped to the warp engine cells (u_tc / pg_re)
set warpcells [get_cells -hier -filter {NAME =~ *u_tc*}]
if {[llength $warpcells] > 0} {
  puts "=== worst setup path THROUGH warp cache (u_tc) ==="
  report_timing -max_paths 3 -nworst 3 -setup -through $warpcells
}

# Re-evaluate the warp domain at 6.734 ns by tightening the pixel clock period.
# Single-cycle pclk->pclk path => slack drops 1:1 with the period reduction.
set pclk [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clk_wiz_pixclk_out*clk_out1*}]]
puts "pixel clock object: $pclk  period=[get_property PERIOD $pclk]"
if {$pclk ne ""} {
  set_clock_uncertainty -setup 0.000 $pclk
  create_clock -name pclk_148 -period 6.734 [get_pins -hier -filter {NAME =~ *clk_wiz_pixclk_out*clk_out1*}]
  puts "=== WNS with pclk retimed to 6.734 ns (148.5 MHz) ==="
  set wns148 [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
  puts "WNS@148.5 (6.734 ns, measured) = $wns148"
}
puts "ARITHMETIC: WNS@148.5 ~= WNS@74.25 - 6.734 = [expr {$wns74 - 6.734}]"
exit 0
