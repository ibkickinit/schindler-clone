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
