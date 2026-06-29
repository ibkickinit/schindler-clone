# zybo_z7_20_phase_b.xdc — Phase B constraints for Zybo Z7-20.
#
# Design top = BD wrapper (phase_b_bd_wrapper). Auto-generated port names match
# the BD's interface port names: hdmi_rx_tmds_clk_p, hdmi_rx_tmds_data_p[i], etc.
# DDR3 + FIXED_IO + MIO pins are constrained automatically by the Zynq PS IP
# using Zybo Z7-20 board file metadata — nothing to repeat here.

# ============================================================================
# Onboard 125 MHz oscillator (input to Clocking Wizard → 200 MHz refclk)
# ============================================================================
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports sys_clk]
create_clock -period 8.000 -name sys_clk_125mhz [get_ports sys_clk]

# Same BACKBONE workaround as Phase A — even more MMCMs present in Phase B
# (clk_wiz + dvi2rgb internal + rgb2dvi internal + Zynq PS), placer needs the
# longer route from K17's IBUF to the clk_wiz MMCM.
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets sys_clk_IBUF]

# ============================================================================
# BTN0 (reset)
# ============================================================================
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports btn_rst]

# ============================================================================
# HDMI RX TMDS pairs
# ============================================================================
set_property -dict { PACKAGE_PIN U18 IOSTANDARD TMDS_33 } [get_ports hdmi_rx_tmds_clk_p]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD TMDS_33 } [get_ports hdmi_rx_tmds_clk_n]
set_property -dict { PACKAGE_PIN V20 IOSTANDARD TMDS_33 } [get_ports {hdmi_rx_tmds_data_p[0]}]
set_property -dict { PACKAGE_PIN W20 IOSTANDARD TMDS_33 } [get_ports {hdmi_rx_tmds_data_n[0]}]
set_property -dict { PACKAGE_PIN T20 IOSTANDARD TMDS_33 } [get_ports {hdmi_rx_tmds_data_p[1]}]
set_property -dict { PACKAGE_PIN U20 IOSTANDARD TMDS_33 } [get_ports {hdmi_rx_tmds_data_n[1]}]
set_property -dict { PACKAGE_PIN N20 IOSTANDARD TMDS_33 } [get_ports {hdmi_rx_tmds_data_p[2]}]
set_property -dict { PACKAGE_PIN P20 IOSTANDARD TMDS_33 } [get_ports {hdmi_rx_tmds_data_n[2]}]

# HDMI RX HPD + DDC (IOBUF inferred at the iic_rtl bd intf boundary)
set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports hdmi_rx_hpd]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports hdmi_rx_ddc_scl_io]
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports hdmi_rx_ddc_sda_io]

# ============================================================================
# HDMI TX TMDS pairs
# ============================================================================
set_property -dict { PACKAGE_PIN H16 IOSTANDARD TMDS_33 } [get_ports hdmi_tx_tmds_clk_p]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD TMDS_33 } [get_ports hdmi_tx_tmds_clk_n]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_tmds_data_p[0]}]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_tmds_data_n[0]}]
set_property -dict { PACKAGE_PIN C20 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_tmds_data_p[1]}]
set_property -dict { PACKAGE_PIN B20 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_tmds_data_n[1]}]
set_property -dict { PACKAGE_PIN B19 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_tmds_data_p[2]}]
set_property -dict { PACKAGE_PIN A20 IOSTANDARD TMDS_33 } [get_ports {hdmi_tx_tmds_data_n[2]}]

set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports hdmi_tx_hpd]

# BANDWIDTH=HIGH override was tested 2026-05-13 — ILA capture identical to
# OPTIMIZED baseline (MMCM still unlocks the same way). Removed; if MMCM
# input clock is briefly disappearing entirely, filter bandwidth doesn't help.

# ============================================================================
# Status LEDs LD0..LD3
# ============================================================================
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {leds[0]}]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports {leds[1]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {leds[2]}]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {leds[3]}]

# ============================================================================
# Phase D iter-4d-1: CDC false-paths into axi_sync_inputs 2-FF synchronizers.
# ASYNC_REG=TRUE handles metastability placement; this tells the timing
# engine the inter-clock paths are async and shouldn't be constrained. Before
# iter-4c the source vsync/plocked paths happened to meet timing because
# dvi2rgb's PixelClk was related to FCLK_CLK0; now both sides are fully async.
set_false_path -to [get_pins {phase_b_bd_i/axi_sync_inputs_0/inst/vsync_q1_reg/D}]
set_false_path -to [get_pins {phase_b_bd_i/axi_sync_inputs_0/inst/plocked_q1_reg/D}]
set_false_path -to [get_pins {phase_b_bd_i/axi_sync_inputs_0/inst/vsync_out_q1_reg/D}]
set_false_path -to [get_pins {phase_b_bd_i/axi_sync_inputs_0/inst/pclk_locked_q1_reg/D}]

# ============================================================================
# DUAL-ENGINE (Engine B) — composite/bypass output on Pmod JC = 8-bit R-2R ladder.
# Present only when DUAL_ENGINE=1 (the `comp` port exists only then); -quiet keeps
# these harmless in non-dual builds. Pin map identical to the proven TPG DAC pinout
# (zybo_z7_20.xdc). comp[7]=MSB=JC1 ... comp[0]=LSB=JC10. R-2R ladder wiring map:
#   comp[7] (MSB) = JC1  = V15
#   comp[6]       = JC2  = W15
#   comp[5]       = JC3  = T11
#   comp[4]       = JC4  = T10
#   comp[3]       = JC7  = W14
#   comp[2]       = JC8  = Y14
#   comp[1]       = JC9  = T12
#   comp[0] (LSB) = JC10 = U12
# Pmod JC GND = JC5/JC11, VCC(3V3) = JC6/JC12 (tie the ladder's reference to JC GND).
# ============================================================================
set_property -quiet -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports {comp[7]}]
set_property -quiet -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports {comp[6]}]
set_property -quiet -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports {comp[5]}]
set_property -quiet -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports {comp[4]}]
set_property -quiet -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {comp[3]}]
set_property -quiet -dict { PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 } [get_ports {comp[2]}]
set_property -quiet -dict { PACKAGE_PIN T12 IOSTANDARD LVCMOS33 } [get_ports {comp[1]}]
set_property -quiet -dict { PACKAGE_PIN U12 IOSTANDARD LVCMOS33 } [get_ports {comp[0]}]

# Engine B control GPIO (axi_gpio_20, FCLK_CLK0) -> pg_comp_out_mux 2-FF sync into
# the 27 MHz engb clock. Quasi-static brightness/comp_enable; ASYNC_REG handles
# metastability. Hierarchy-robust match (same rule as the route-B/warp CDC paths).
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ */br_q1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ */ce_q1_reg/D}]

# Color-correct GPIO-to-pclk_out CDC false-paths. ASYNC_REG handles
# metastability; these inform the timing engine the inter-clock paths are
# async and shouldn't be constrained. Without them Vivado tries to meet
# setup from clk_fpga_0 (100 MHz) to clk_out1_pclk_out (74.25 MHz) on
# the first-stage flops, fails badly (~-3.5 ns WNS).
#
# 2026-05-31 fix: hierarchical names include `/inst/` after the BD cell
# name because BD wraps custom modules in a generated wrapper. Previous
# constraints (without /inst/) silently failed with "No valid object(s)
# found" and the WNS chronic -3.5 ns came from these paths NOT being
# constrained. Confirmed via report_timing in build/.../impl_1/.
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/br_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/bg_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/bb_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/wr_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/wg_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/wb_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_saturation_0/inst/sat_q1_reg[*]/D}]

# Color-matrix GPIO-to-pclk_out CDC false-paths (added 2026-05-31).
# color_matrix.v has the same 2-FF ASYNC_REG pattern; same /inst/ rule.
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m00_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m01_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m02_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m10_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m11_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m12_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m20_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m21_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/m22_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/off_r_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/off_g_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_matrix_0/inst/off_b_q1_reg[*]/D}]

# gamma_lut load-field CDC (quasi-static axi_gpio_11 → pixel clock). Same 2-FF ASYNC_REG
# rule; without these the q1 sync regs show as real cross-domain paths (WNS ~ -3.5).
set_false_path -to [get_pins {phase_b_bd_i/gamma_lut_0/inst/t_q1_reg/D}]
set_false_path -to [get_pins {phase_b_bd_i/gamma_lut_0/inst/byp_q1_reg/D}]
set_false_path -to [get_pins {phase_b_bd_i/gamma_lut_0/inst/ch_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/gamma_lut_0/inst/ad_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/gamma_lut_0/inst/da_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/gamma_lut_0/inst/sw_q1_reg/D}]   ;# #114 double-buffer swap CDC

# scaler_top runtime IN_W/IN_H CDC false-paths (axi clock → pclk_in domain).
# Same /inst/ rule.
set_false_path -to [get_pins {phase_b_bd_i/scaler_0/inst/in_w_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/scaler_0/inst/in_h_q1_reg[*]/D}]
# iter14 kernel_mode CDC (axi clock → pclk_in): 4-bit ASYNC_REG synchronizer
# in scaler_top.v line 80. Same chronic-WNS class that 1ec218c just closed for
# color_matrix — flagged by 2026-05-31 HDL re-audit before next impl run.
set_false_path -to [get_pins {phase_b_bd_i/scaler_0/inst/km_q1_reg[*]/D}]

# Route-B read-engine CDC false-paths (AXI GPIO FCLK_CLK0 → output pixel clock).
# Geometry bus 2-FF sync (g_q1) + genlock source-vsync 2-FF sync (sv_q1).
# Quasi-static + frame-atomic latch; ASYNC_REG handles metastability. Same
# /inst/ hierarchy rule as the scaler/color CDC paths. -quiet so the constraint
# is harmless when the read-engine cell is absent (READENGINE_B=0 builds).
# Hierarchy-robust matching: the BD wraps -reference modules in a generated
# wrapper whose inst level varies, so match the sync FF's D pin anywhere in the
# hierarchy by name (a fixed phase_b_bd_i/.../inst/ path silently misses — same
# trap the scaler in_w/km false-paths hit).
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ */g_q1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ */fp_q1_reg[*]/D}]
# axis_mux2 select 2-FF sync (AXI GPIO FCLK_CLK0 → output pixel clock).
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ */sel_q1_reg/D}]
# pg_cadence blend_mode 2-FF sync (Mackin dual-fetch enable; task #103). Was the
# only route-B async CDC left unconstrained → build #25 WNS -3.428 on exactly this
# pin (axi_gpio_10 -> u_cadence/bm_q1_reg/D). ASYNC_REG handles metastability.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ */bm_q1_reg[*]/D}]

# Warp read-engine (pg_warp_top) affine-coefficient + matte CDC (AXI GPIO FCLK_CLK0 → output pixel clock).
# pg_warp_top has the standard 2-FF ASYNC_REG sync: a1/b1/c1/d1/e1/f1 (+mt1) are the q1 capture regs,
# a2..f2/mt2 the q2 feeding the engine. Coeffs are frame-atomic (firmware writes them in vblank); ASYNC_REG
# handles metastability. This was the WNS=-3.601 path (axi_gpio_8 -> pg_re_0/inst/b1_reg/D) after the
# prefetch issue cone was pipelined out. Scoped to *pg_re_0* (verified: 32 pins each / mt1 24) so a stray
# a1_reg elsewhere can't be caught. Same hierarchy-robust -hier rule as the route-B/scaler CDC paths.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/a1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/b1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/c1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/d1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/e1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/f1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/mt1_reg[*]/D}]
# runtime per-geometry LEAD GPIO CDC (axi_gpio_12 ch2 FCLK_CLK0 -> pixel clock), same 2-FF ASYNC_REG capture reg.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/lr1_reg[*]/D}]
# task-57 per-angle set-hash select CDC (lead_cfg[27:24] FCLK_CLK0 -> pixel clock); quasi-static. Same 2-FF.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/hs1_reg[*]/D}]
# task-58 frame-align ENABLE CDC (lead_cfg[28] FCLK_CLK0 -> pixel clock); quasi-static. Same 2-FF as lr1/sr1.
# WITHOUT this the timer chases the unconstrained GPIO->fa1 path (-3.37) and collaterally wrecks placement.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/fa1_reg/D}]
# telemetry dbg_sel CDC (lead_cfg[23:20] FCLK_CLK0 -> pixel clock); quasi-static (fw sets+waits+reads).
# WITHOUT this, the timer chases the unconstrained GPIO->dsel1 path (-3.35) and collaterally wrecks the
# real datapath placement (+0.212 -> -0.435). Same 2-FF ASYNC_REG capture reg as lr1.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/dsel1_reg[*]/D}]
# telemetry dbg readback (registered dbg_r in pixel clock -> FCLK_CLK0 axi_gpio_2 input sampler).
# Quasi-static readback; false-path FROM dbg_r so the pclk->FCLK_CLK0 crossing isn't timed.
set_false_path -quiet -from [get_pins -hier -filter {NAME =~ *pg_re_0*/dbg_r_reg[*]/C}]
# soft-reset CDC (lead_cfg[31] FCLK_CLK0 -> pixel clock); quasi-static, firmware-pulsed. Same 2-FF capture
# reg as lr1/dsel1 — without this the timer chases the unconstrained GPIO->sr1 path and wrecks placement.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/sr1_reg/D}]

# PROJECTIVE build (env PROJECTIVE_BUILD=1) only: perspective-coeff CDC g1/h1 (axi_gpio_13/14 FCLK_CLK0
# -> pixel clock). Same 2-FF ASYNC_REG capture-reg trap as a1..f1/lr1/sr1 — false-path the first stage D
# so the unconstrained GPIO->g1/h1 path can't wreck the datapath placement. -quiet keeps these HARMLESS
# in the affine build (g1/h1 regs still exist in pg_warp_top but are fed by the m_g/m_h xlconstant tie-0,
# so the pins-not-found / already-constant case is a no-op). 40-bit each.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/g1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/h1_reg[*]/D}]

# BITE1 (2026-06-26): PLACEMENT-coeff CDC pa1..pf1 (axi_gpio_15/16/17 FCLK_CLK0 -> pixel clock). Same
# 2-FF ASYNC_REG capture-reg trap as a1..f1/g1/h1/lr1/sr1 -> false-path the first stage D so the
# unconstrained GPIO->pa1..pf1 crossing can't wreck the datapath placement. -quiet keeps these HARMLESS
# in the affine build (pa1..pf1 regs exist in pg_warp_top but are fed by the identity xlconstant tie).
# 32 bits each (Q12.20). Same hierarchy-robust *pg_re_0* scoping as the numerator coeffs.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/pa1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/pb1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/pc1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/pd1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/pe1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/pf1_reg[*]/D}]

# BITE2 (2026-06-26): PINCUSHION-coeff CDC (axi_gpio_19 FCLK_CLK0 -> pixel clock). Same 2-FF
# ASYNC_REG capture-reg trap as the placement/numerator coeffs -> false-path the first stage D.
# -quiet keeps it harmless in the affine build (fed by the kx/ky=0 xlconstant tie). 32 bits each.
# 2026-06-28: split into per-axis kpx1 (kx) / kpy1 (ky) — dual-channel GPIO; false-path both.
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/kpx1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/kpy1_reg[*]/D}]

# DYNAMIC RING (2026-06-26): runtime source-dim CDC (axi_gpio_1 ch2 = scaler
# out_w/out_h slices, FCLK_CLK0 -> output pixel clock) into pg_warp_top's 2-FF
# ASYNC_REG sync inw_q1/inh_q1. SAME capture-reg trap as a1..f1/lr1/sr1: without
# the false-path the timer chases the unconstrained GPIO->inw_q1/inh_q1 crossing
# (bench: WNS=-3.486, axi_gpio_1/gpio2_Data_Out -> pg_re_0/inst/inh_q1_reg/D,
# Requirement 0.034ns) and wrecks the datapath placement. Quasi-static (firmware
# writes the dim then pulses srst). 12 bits each (in_w_rt/in_h_rt[11:0]).
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/inw_q1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/inh_q1_reg[*]/D}]

# RUNTIME OUTPUT (2026-06-26): warp output-raster CDC (axi_gpio_12 ch1 spare bits
# FCLK_CLK0 -> pixel clock) into pg_warp_top's 2-FF sync outw_q1/outh_q1. Same
# capture-reg trap as inw_q1/inh_q1/a1..f1/lr1/sr1 -> false-path the first stage.
# Quasi-static (firmware writes on a 720<->1080 mode switch only).
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/outw_q1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/outh_q1_reg[*]/D}]
