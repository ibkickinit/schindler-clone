set dcp [lindex [glob -nocomplain build/phase-b-vdma-passthrough/*.runs/impl_1/*_routed.dcp] 0]
open_checkpoint $dcp
set pclk [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clk_wiz_pixclk_out*clk_out1*}]]
puts "=== INTRA-pclk worst (real warp combinational, CDC excluded) @13.468 ==="
set p [get_timing_paths -from $pclk -to $pclk -max_paths 1 -nworst 1 -setup]
puts "WNS intra-pclk @74.25 = [get_property SLACK $p]"
report_timing -from $pclk -to $pclk -max_paths 1 -nworst 1 -setup
puts "=== the GPIO->engine coefficient CDC path (the -3.601) — is it cross-clock? ==="
report_timing -to [get_pins -hier -filter {NAME =~ *pg_re_0*b1_reg*/D}] -max_paths 1 -nworst 1 -setup
puts "=== now retime pclk to 6.734 (148.5) ==="
create_clock -name pclk_148 -period 6.734 [get_pins -hier -filter {NAME =~ *clk_wiz_pixclk_out*clk_out1*}]
set p2 [get_timing_paths -from [get_clocks pclk_148] -to [get_clocks pclk_148] -max_paths 1 -nworst 1 -setup]
puts "WNS intra-pclk @148.5 (real warp) = [get_property SLACK $p2]"
report_timing -from [get_clocks pclk_148] -to [get_clocks pclk_148] -max_paths 1 -nworst 1 -setup
exit 0
