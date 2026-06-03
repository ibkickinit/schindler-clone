# capture_re_ila.tcl — capture the read-engine ILAs (ila_re_dbg + ila_re_beats)
# from a board already programmed + running (xsct programmed PL+PS, then released).
#
# Run AFTER programming the bitstream + ELF and engaging the engine (ghost on
# screen). Vivado hw_manager attaches read-only to the running target via the
# same hw_server, loads the debug probes, immediate-triggers both ILAs, and dumps
# CSVs to /tmp. The read-engine keeps running; this only reads the debug cores.
#
#   vivado -mode batch -source tcl/capture_re_ila.tcl
#
# ila_re_dbg probe0 (96-bit) bit layout (from hdl/pg_read_engine_top.v):
#   [11:0]  src_col   [23:12] src_row   [24] a_valid   [25] a_inwin
#   [26] a_newrow     [27] resident     [28] up_pvalid  [29] up_plast
#   [30] m_tvalid     [31] m_tready     [55:32] rd_data  [79:56] up_pdata  [95:80] pad

set ltx /home/justin/Dropbox/_PROJECTS/Schindler-2.0/build/phase-b-vdma-passthrough/phase-b-vdma-passthrough.runs/impl_1/phase_b_bd_wrapper.ltx

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target
set dev [lindex [get_hw_devices xc7z020*] 0]
current_hw_device $dev
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device $dev
refresh_hw_device $dev
puts "CAP: device = $dev"
# CELL_NAME is empty in this version; identify ILAs by their probe NAMES.
foreach h [get_hw_ilas -of_objects $dev] {
    set pnames {}
    foreach p [get_hw_probes -of_objects $h] { lappend pnames "[get_property NAME $p]:[get_property WIDTH $p]" }
    puts "CAP: $h probes = $pnames"
}

# Find the hw_ila that owns a probe whose NAME matches $pmatch.
proc find_ila_by_probe {dev pmatch} {
    foreach h [get_hw_ilas -of_objects $dev] {
        foreach p [get_hw_probes -of_objects $h] {
            if {[string match *$pmatch* [get_property NAME $p]]} { return $h }
        }
    }
    return ""
}

proc cap_ila {dev pmatch csv} {
    set ila [find_ila_by_probe $dev $pmatch]
    if {$ila eq ""} { puts "CAP: ILA with probe '$pmatch' NOT found"; return }
    puts "CAP: probe '$pmatch' -> $ila"
    # Default probe compares are all don't-care => trigger fires immediately on run.
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila
    run_hw_ila $ila
    if {[catch { wait_on_hw_ila -timeout 20 $ila } e]} { puts "CAP: $pmatch wait: $e" }
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -csv_file $csv -force $data
    puts "CAP: wrote $csv (status=[get_property CORE_STATUS $ila])"
}

cap_ila $dev "ila_re_dbg"   /tmp/ila_dbg.csv
cap_ila $dev "ila_re_beats" /tmp/ila_beats.csv

close_hw_target
disconnect_hw_server
puts "CAP: done"
