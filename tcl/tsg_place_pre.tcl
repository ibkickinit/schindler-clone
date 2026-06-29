# tsg_place_pre.tcl — STEPS.PLACE_DESIGN.TCL.PRE hook (armed only for TSG_BUILD).
#
# Runs inside the impl_1 run AFTER opt_design (design fully flattened) and BEFORE
# place_design. These two constraints CANNOT live in the project XDC: that XDC is read
# at opt_design START, when the OOC-synthesized dvi2rgb IP and clk_wiz_tsg PLL are still
# black boxes, so get_nets on their internal nets returns empty and a -quiet guard
# silently no-ops -> the build then dies at place_design on the 30-120 BUFG-BUFG cascade
# we are trying to demote. By opt completion the IP is flattened and the nets resolve.
# (Verified on phase_b_bd_wrapper_opt.dcp: with these applied, place_design SUCCEEDS and
# the FCLK->TSG reset crossing drops from WNS -3.9 out of the worst-path set.)

# (1) Demote the glitch-tolerant write-clock-mux BUFG->BUFGCTRL cascade (Place 30-120).
#     The rule evaluates the DRIVER nets: I0 = dvi2rgb PixelClk BUFG output, I1 = the
#     TSG PLL (clk_wiz_tsg) clk_out1 BUFG output.
set _i0 [get_nets -quiet phase_b_bd_i/dvi2rgb_0/U0/GenerateBUFG.ResyncToBUFG_X/CLK]
if {$_i0 ne ""} {
    set_property CLOCK_DEDICATED_ROUTE FALSE $_i0
    puts "TSG-PRE: CDR FALSE on clk0 (dvi2rgb PixelClk -> BUFGCTRL.I0)"
} else {
    puts "TSG-PRE WARN: dvi2rgb clk0 net NOT FOUND (cascade will not be demoted)"
}
set _i1 [get_nets -quiet phase_b_bd_i/clk_wiz_tsg_clk_out1]
if {$_i1 ne ""} {
    set_property CLOCK_DEDICATED_ROUTE FALSE $_i1
    puts "TSG-PRE: CDR FALSE on clk1 (TSG PLL -> BUFGCTRL.I1)"
} else {
    puts "TSG-PRE WARN: TSG clk1 net NOT FOUND"
}

# (2) The TSG PLL clock is ASYNCHRONOUS to FCLK (clk_fpga_0). The PLL is DERIVED from
#     clk_fpga_0, so its output is a RELATED generated clock and the timer would tightly
#     time every FCLK->TSG crossing (the write-path switch reset into v_vid_in's sync
#     FIFO; the quasi-static pattern GPIO) -> WNS ~ -3.9. Those crossings are all genuinely
#     async (reset held ~10 us; pattern quasi-static). dvi2rgb's PixelClk is an unrelated
#     recovered clock that was already loosely timed (HDMI path closed fine pre-TSG).
set _tsgclk [get_clocks -quiet clk_out1_phase_b_bd_clk_wiz_tsg_0]
if {$_tsgclk ne ""} {
    set_clock_groups -asynchronous -group [get_clocks clk_fpga_0] -group $_tsgclk
    puts "TSG-PRE: clock group FCLK(clk_fpga_0) <-> TSG PLL async"
} else {
    puts "TSG-PRE WARN: TSG generated clock NOT FOUND"
}
