# tsg_place_pre.tcl — STEPS.PLACE_DESIGN.TCL.PRE hook (armed only for TSG_BUILD).
#
# Runs inside the impl_1 run AFTER opt_design (design fully flattened) and BEFORE
# place_design. These constraints CANNOT live in the project XDC: that XDC is read at
# opt_design START, when the OOC-synthesized dvi2rgb IP and clk_wiz_tsg PLL are still
# black boxes, so get_nets on their internal nets returns empty -> the build would then
# die at place_design on the 30-120 BUFG-BUFG cascade. By opt completion the IP is
# flattened and the nets resolve here.
#
# HARDENED 2026-06-29: every lookup HARD-ERRORS if it finds nothing (was a silent -quiet
# skip). If a future dvi2rgb/clk_wiz IP rev renames an internal net, this aborts loudly
# at place-pre with a clear message instead of dying mysteriously at place_design.

# Resolve a single net by name/pattern or abort. get_nets treats the arg as a pattern
# (wildcards ok), so the literal path doubles as a match; error if 0 (renamed) hits.
proc _tsg_cdr {desc pat} {
    set n [get_nets -quiet $pat]
    if {[llength $n] == 0} {
        error "TSG-PRE FATAL: clock-mux net for $desc not found (pattern: $pat).\
               The dvi2rgb/clk_wiz_tsg IP was likely revved and renamed its internal net --\
               update tcl/tsg_place_pre.tcl. (Demoting the 30-120 BUFG cascade needs this.)"
    }
    set_property CLOCK_DEDICATED_ROUTE FALSE [lindex $n 0]
    puts "TSG-PRE: CDR FALSE on $desc ([lindex $n 0])"
}

# (1) Demote the write-clock-mux BUFG->BUFGCTRL cascade (Place 30-120) on the two DRIVER
#     nets (I0 = dvi2rgb PixelClk BUFG, I1 = TSG PLL clk_out1 BUFG). The rule evaluates the
#     driver side, NOT the IP-local load segment (tsg_clkmux_0/inst/clk0).
_tsg_cdr "clk0 (dvi2rgb PixelClk -> BUFGCTRL.I0)" {phase_b_bd_i/dvi2rgb_0/U0/GenerateBUFG.ResyncToBUFG_X/CLK}
_tsg_cdr "clk1 (TSG PLL -> BUFGCTRL.I1)"          {phase_b_bd_i/clk_wiz_tsg_clk_out1}

# (2) The TSG PLL clock is ASYNCHRONOUS to FCLK (clk_fpga_0). The PLL is DERIVED from
#     clk_fpga_0, so its output is a RELATED generated clock and the timer would tightly
#     time every FCLK->TSG crossing (the write-path switch reset into v_vid_in's sync FIFO;
#     the quasi-static pattern GPIO) -> WNS ~ -3.9. Those crossings are all genuinely async.
set _tsgclk [get_clocks -quiet clk_out1_phase_b_bd_clk_wiz_tsg_0]
if {[llength $_tsgclk] == 0} {
    error "TSG-PRE FATAL: TSG generated clock clk_out1_phase_b_bd_clk_wiz_tsg_0 not found --\
           clk_wiz_tsg renamed? update the FCLK<->TSG async clock-group."
}
set_clock_groups -asynchronous -group [get_clocks clk_fpga_0] -group $_tsgclk
puts "TSG-PRE: clock group FCLK(clk_fpga_0) <-> TSG PLL async"

# (3) physically_exclusive between the two write-clock-mux SOURCE clocks: investigated
#     2026-06-30, found NOT APPLICABLE to this netlist (and not needed). The dvi2rgb mux input
#     (BUFGCTRL/I0) has NO propagated clock object -- the dvi2rgb RX recovered PixelClk does not
#     reach the mux as a named clock in the implemented design; only the TSG PLL clock (I1)
#     propagates, and the BUFGCTRL OUTPUT carries that single clock. A phantom cross-path needs
#     TWO clocks meeting on a register; with only one clock on the muxed domain there are none to
#     exclude. Confirmed by clean timing (WNS +0.128, 0 failing endpoints) with no PixelClk<->TSG
#     paths. At the shipping config (1080p30) the TSG and dvi2rgb rates are both 74.25 MHz, so the
#     single modeled clock is correct-rate in BOTH mux positions. Left as a documented no-op below
#     (it self-skips); do NOT keep chasing this -- it is correct as-is, not an unfinished TODO.
set _ck0 [get_clocks -quiet -of_objects [get_nets -quiet phase_b_bd_i/dvi2rgb_0/U0/GenerateBUFG.ResyncToBUFG_X/CLK]]
set _ck1 [get_clocks -quiet -of_objects [get_nets -quiet phase_b_bd_i/clk_wiz_tsg_clk_out1]]
if {[llength $_ck0] && [llength $_ck1] && [lindex $_ck0 0] ne [lindex $_ck1 0]} {
    set_clock_groups -physically_exclusive -group $_ck0 -group $_ck1
    puts "TSG-PRE: physically_exclusive $_ck0 <-> $_ck1"
} else {
    puts "TSG-PRE: physically_exclusive N/A (only one clock on the muxed domain -- documented, expected)"
}
