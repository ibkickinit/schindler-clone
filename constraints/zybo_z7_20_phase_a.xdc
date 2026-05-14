# zybo_z7_20_phase_a.xdc — Phase A constraints for Zybo Z7-20 HDMI passthrough.
#
# Sources: Digilent Zybo Z7-20 master XDC + board file part0_pins.xml.
# Only the pins used by top_phase_a.v are constrained.

# ============================================================================
# Onboard 125 MHz oscillator (input to MMCM that generates the 200 MHz refclk)
# ============================================================================
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports sys_clk]
create_clock -period 8.000 -name sys_clk_125mhz [get_ports sys_clk]

# Allow sys_clk's IBUF → top-level MMCM (mmcm_inst) to use the clock backbone.
# With 3 MMCMs in the design (top-level refclk gen + dvi2rgb internal + rgb2dvi
# internal), the placer can no longer keep sys_clk's IBUF and our MMCM in the
# same clock region — dvi2rgb's MMCM needs to be near the HDMI RX IO bank, and
# rgb2dvi's MMCM eats another region. BACKBONE adds ~hundreds of ps of clock
# insertion delay (negligible here; the MMCM filters jitter regardless) but
# satisfies the clock placer rule. See UG472 / Place 30-575.
set_property CLOCK_DEDICATED_ROUTE BACKBONE [get_nets sys_clk_IBUF]

# ============================================================================
# BTN0 (reset)
# ============================================================================
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports btn_rst]

# ============================================================================
# HDMI RX port (TMDS IN from external HDMI source)
# ============================================================================
set_property -dict { PACKAGE_PIN U18 IOSTANDARD TMDS_33 } [get_ports TMDS_IN_clk_p]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD TMDS_33 } [get_ports TMDS_IN_clk_n]

set_property -dict { PACKAGE_PIN V20 IOSTANDARD TMDS_33 } [get_ports {TMDS_IN_data_p[0]}]
set_property -dict { PACKAGE_PIN W20 IOSTANDARD TMDS_33 } [get_ports {TMDS_IN_data_n[0]}]
set_property -dict { PACKAGE_PIN T20 IOSTANDARD TMDS_33 } [get_ports {TMDS_IN_data_p[1]}]
set_property -dict { PACKAGE_PIN U20 IOSTANDARD TMDS_33 } [get_ports {TMDS_IN_data_n[1]}]
set_property -dict { PACKAGE_PIN N20 IOSTANDARD TMDS_33 } [get_ports {TMDS_IN_data_p[2]}]
set_property -dict { PACKAGE_PIN P20 IOSTANDARD TMDS_33 } [get_ports {TMDS_IN_data_n[2]}]

set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports hdmi_rx_hpd]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports hdmi_in_ddc_scl]
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports hdmi_in_ddc_sda]

# ============================================================================
# HDMI TX port (TMDS OUT to external monitor)
#
# Note: pin file lists IOSTANDARD LVCMOS33 for TMDS_OUT — Zybo HDMI TX uses
# OSERDESE2 + OBUFDS at LVCMOS33 differential to synthesize TMDS levels. The
# rgb2dvi IP handles this internally. TMDS_33 standard isn't supported for
# outputs on the Z-7020 IO banks; LVCMOS33 with the IP's serialization is the
# Digilent-blessed pattern.
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
# Status LEDs (Zybo 4× user LEDs LD0-LD3)
# ============================================================================
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {leds[0]}]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports {leds[1]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {leds[2]}]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {leds[3]}]

# ============================================================================
# Timing — let dvi2rgb's own constraints handle the TMDS clock recovery
# ============================================================================
# dvi2rgb ships its own dvi2rgb.xdc with create_clock on the recovered pixel
# clock + IDELAYCTRL constraints. Vivado picks those up automatically when the
# IP is added via add_files (the IP's bundled XDC is set as a child constraint
# of the IP instance). No additional clock constraints needed here.
