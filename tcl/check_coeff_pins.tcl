set dcp [lindex [glob -nocomplain build/phase-b-vdma-passthrough/*.runs/impl_1/*_routed.dcp] 0]
open_checkpoint $dcp
foreach r {a1 b1 c1 d1 e1 f1 mt1} {
  set pins [get_pins -quiet -hier -filter "NAME =~ *pg_re_0*/${r}_reg\[*\]/D"]
  puts "FILTER *pg_re_0*/${r}_reg\[*\]/D  -> [llength $pins] pins"
}
puts "=== sanity: does the bare */a1_reg pattern catch anything OUTSIDE pg_re? ==="
set all_a1 [get_pins -quiet -hier -filter {NAME =~ */a1_reg[*]/D}]
puts "bare */a1_reg[*]/D total = [llength $all_a1]"
foreach p [lrange $all_a1 0 5] { puts "   $p" }
exit 0
