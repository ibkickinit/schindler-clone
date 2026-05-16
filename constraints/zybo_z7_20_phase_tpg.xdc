# zybo_z7_20_phase_tpg.xdc — Constraints for top_phase_tpg.v.
#
# Diagnostic-only TPG -> rgb2dvi -> HDMI TX bitstream. Slim subset of
# zybo_z7_20_phase_a.xdc — drops all HDMI RX pins (no dvi2rgb in this build).

# ============================================================================
# Onboard 125 MHz oscillator -> top-level MMCM (74.25 MHz pixel clock)
# ============================================================================
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports sys_clk]
create_clock -period 8.000 -name sys_clk_125mhz [get_ports sys_clk]

# rgb2dvi instantiates an MMCM in a different clock region than sys_clk's IBUF;
# allow the dedicated-clock route through the backbone (same rationale as the
# Phase A constraint).
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets sys_clk_IBUF]

# ============================================================================
# BTN0 (reset)
# ============================================================================
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports btn_rst]

# ============================================================================
# HDMI TX port (TMDS OUT to external monitor)
# ============================================================================
set_property -dict { PACKAGE_PIN H16 IOSTANDARD TMDS_33 } [get_ports TMDS_OUT_clk_p]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD TMDS_33 } [get_ports TMDS_OUT_clk_n]

set_property -dict { PACKAGE_PIN D19 IOSTANDARD TMDS_33 } [get_ports {TMDS_OUT_data_p[0]}]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD TMDS_33 } [get_ports {TMDS_OUT_data_n[0]}]
set_property -dict { PACKAGE_PIN C20 IOSTANDARD TMDS_33 } [get_ports {TMDS_OUT_data_p[1]}]
set_property -dict { PACKAGE_PIN B20 IOSTANDARD TMDS_33 } [get_ports {TMDS_OUT_data_n[1]}]
set_property -dict { PACKAGE_PIN B19 IOSTANDARD TMDS_33 } [get_ports {TMDS_OUT_data_p[2]}]
set_property -dict { PACKAGE_PIN A20 IOSTANDARD TMDS_33 } [get_ports {TMDS_OUT_data_n[2]}]

set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports hdmi_tx_hpd]

# ============================================================================
# Status LEDs (Zybo 4x user LEDs LD0-LD3)
# ============================================================================
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {leds[0]}]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports {leds[1]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {leds[2]}]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {leds[3]}]
