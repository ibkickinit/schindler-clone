## Zybo Z7-20 — Schindler 2.0 first-light constraints
## Pin assignments derived from Digilent vivado-boards (board file A.0)

## ---------- System clock (125 MHz) ----------
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports { sys_clk }]
create_clock -add -name sys_clk_pin -period 8.000 -waveform {0 4} [get_ports { sys_clk }]

## ---------- BTN0 = reset ----------
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { btn_rst }]

## ---------- SW0, SW1 = pattern select (gray / ramp / bars) ----------
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports { pattern_sel[0] }]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { pattern_sel[1] }]

## ---------- LD0 = MMCM lock indicator ----------
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { mmcm_locked_led }]

## ---------- Pmod JC = 8-bit DAC output ----------
## MSB first: dac_pmod[7]=JC1 ... dac_pmod[0]=JC10
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { dac_pmod[7] }]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports { dac_pmod[6] }]
set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports { dac_pmod[5] }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { dac_pmod[4] }]
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports { dac_pmod[3] }]
set_property -dict { PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 } [get_ports { dac_pmod[2] }]
set_property -dict { PACKAGE_PIN T12 IOSTANDARD LVCMOS33 } [get_ports { dac_pmod[1] }]
set_property -dict { PACKAGE_PIN U12 IOSTANDARD LVCMOS33 } [get_ports { dac_pmod[0] }]
