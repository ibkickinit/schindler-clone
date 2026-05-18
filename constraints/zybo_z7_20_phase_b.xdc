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

# Color GPIO-to-pclk_out CDC false-paths. ASYNC_REG handles metastability;
# these inform the timing engine the inter-clock paths are async and shouldn't
# be constrained. Without them Vivado tries to meet setup from clk_fpga_0
# (100 MHz) to clk_out1_pclk_out (74.25 MHz) on the first-stage flops, fails
# badly (~-3.5 ns WNS).
#
# NOTE the `/inst/` level in the hierarchical path. BD module-reference cells
# (-type module -reference foo) get an inner `inst` wrapper around the user
# HDL inside the bd_wrapper. The pre-2026-05-18 patterns omitted this and
# silently matched nothing; WNS stayed at -3.5ns until 2026-05-18.
#
# color_correct: 6 channels (black + white per RGB)
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/br_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/bg_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/bb_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/wr_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/wg_q1_reg[*]/D}]
set_false_path -to [get_pins {phase_b_bd_i/color_correct_0/inst/wb_q1_reg[*]/D}]
# color_saturation: single 16-bit alpha
set_false_path -to [get_pins {phase_b_bd_i/color_saturation_0/inst/sat_q1_reg[*]/D}]
# color_matrix: 9 × 16-bit coefs + 3 × 8-bit offsets
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
# mackin_blender: alpha
set_false_path -to [get_pins {phase_b_bd_i/mackin_blender_0/inst/alpha_q1_reg[*]/D}]
