# auboard_blinky.xdc — AUBoard 15P (XCAU15P-2FFVB676E) pins for the first-light design.
# Source: Tria AUB-15P-DK-UG v1.0 tables (clock sources, user LEDs/DIP/buttons, UART).
#
# IOSTANDARDs are NOT set here: tcl/build_blinky.tcl looks up each pin's bank and applies the bank's
# VCCO from the UG (bank 64/65 = 1.2 V, 84 = 1.8 V, 85 = 3.3 V, 66/86 = VADJ). That avoids guessing
# which bank a pin is in. If the build reports a bank it doesn't know, stop and check the schematic.

# ---- 300 MHz system clock (X1, bank 64) ----
set_property PACKAGE_PIN AD21 [get_ports sys_clk_p]
set_property PACKAGE_PIN AE21 [get_ports sys_clk_n]
create_clock -name sys_clk -period 3.333 [get_ports sys_clk_p]

# ---- PL reset push button (active low) ----
set_property PACKAGE_PIN V19 [get_ports rst_n]

# ---- user DIP switch SW2 ----
set_property PACKAGE_PIN P19 [get_ports {dip[0]}]
set_property PACKAGE_PIN N19 [get_ports {dip[1]}]
set_property PACKAGE_PIN P23 [get_ports {dip[2]}]
set_property PACKAGE_PIN N23 [get_ports {dip[3]}]

# ---- user push buttons PB4..PB7 ----
set_property PACKAGE_PIN R21 [get_ports {pb[0]}]
set_property PACKAGE_PIN R20 [get_ports {pb[1]}]
set_property PACKAGE_PIN P21 [get_ports {pb[2]}]
set_property PACKAGE_PIN P20 [get_ports {pb[3]}]

# ---- red user LEDs D31..D34 (active high) ----
set_property PACKAGE_PIN A10 [get_ports {led[0]}]
set_property PACKAGE_PIN B10 [get_ports {led[1]}]
set_property PACKAGE_PIN B11 [get_ports {led[2]}]
set_property PACKAGE_PIN C11 [get_ports {led[3]}]

# ---- RGB LEDs (active high): rgbN[0] = R, [1] = G, [2] = B ----
set_property PACKAGE_PIN AE15 [get_ports {rgb1[0]}]
set_property PACKAGE_PIN AD15 [get_ports {rgb1[1]}]
set_property PACKAGE_PIN AF13 [get_ports {rgb1[2]}]
set_property PACKAGE_PIN U26  [get_ports {rgb2[0]}]
set_property PACKAGE_PIN P24  [get_ports {rgb2[1]}]
set_property PACKAGE_PIN N24  [get_ports {rgb2[2]}]

# ---- USB-UART bridge U21 (J9) ----
set_property PACKAGE_PIN AF15 [get_ports uart_tx]
set_property PACKAGE_PIN AF14 [get_ports uart_rx]

# ---- asynchronous I/O: no timing paths worth analysing ----
set_false_path -from [get_ports {rst_n dip[*] pb[*] uart_rx}]
set_false_path -to   [get_ports {led[*] rgb1[*] rgb2[*] uart_tx}]

# ---- configuration (bank 0 = 1.8 V, Master SPI x4 QSPI) ----
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
