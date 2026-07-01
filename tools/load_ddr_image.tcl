# load_ddr_image.tcl — write a raw framebuffer .bin into the Schindler DDR slot ring over JTAG.
# args: <file.bin> <nslots>   (writes slots 0..nslots-1). Board must be flashed + (ideally) frozen (O z 1).
if {$argc < 1} { puts "usage: xsct load_ddr_image.tcl <file.bin> \[nslots\]"; exit 1 }
set FILE [lindex $argv 0]
set NSLOTS [expr {$argc > 1 ? [lindex $argv 1] : 7}]
set BASE        0x10000000
set SLOT_STRIDE 6226560
set FRAME_BYTES 6220800
set WORDS       [expr {$FRAME_BYTES/4}]     ;# 1,555,200
connect
# APU target for AXI memory access (non-intrusive; PL warp keeps displaying)
targets -set -filter {name =~ "*Cortex-A9*#0"}
for {set s 0} {$s < $NSLOTS} {incr s} {
    set addr [expr {$BASE + $s*$SLOT_STRIDE}]
    puts "slot $s @ [format 0x%08X $addr] ..."
    mwr -bin -file $FILE $addr $WORDS
}
puts "DONE: wrote $NSLOTS slot(s)"
