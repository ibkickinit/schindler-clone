# zybo_analog.xdc — Engine-B analog leg (G1+) pin constraints. Added to the build ONLY when
# ANALOG_BUILD=1 (the ports it references exist only when the BD adds the axi_iic + clock-in + reset).
# Pin map from the prior Phase-E2 (Si5351) + Phase-G iter1.5 (ADV7393) bench work — verified by Justin.
#
# Si5351 (0x60) + ADV7393 (0x2A) share ONE I2C bus. Si5351 27 MHz CLK0 -> Y7 (the MRCC clock-capable
# pin proven in Phase-C-lite to drive an FPGA PLL) -> BUFG -> engine-B clock + freq counter. NO clk_wiz.

# ---- I2C bus (shared, both chips). PULLUP TRUE is a float-defeat only — the REAL pull-ups are external
#      2.2k on SDA/SCL (Si5351 breakout has NONE; ADV7393 breakout has 2.2k onboard). i2c_pullup_rule. ----
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports { iic_sda_io }]  ;# Pmod JD7
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports { iic_scl_io }]  ;# Pmod JD8

# ---- Si5351 27 MHz CLK0 INPUT -> Y7 = Pmod JB Pin 7 = MRCC bank 13 (clock-capable -> BUFG, no CMT) ----
set_property -dict { PACKAGE_PIN Y7  IOSTANDARD LVCMOS33 } [get_ports { si5351_clk_in }]
# 27 MHz period (37.037 ns). Created in the BD as an input clock on this pin; constrain it:
create_clock -name si5351_27m -period 37.037 [get_ports { si5351_clk_in }]

# ---- ADV7393 RESET (active-low). Prior work used JE6, BUT Zybo Pmod JE is wired to PS MIO (not PL) —
#      so either drive RESET via PS EMIO/MIO, OR (simpler for a PL GPIO) reassign to a free PL Pmod pin.
#      *** PIN TBD: verify the exact JE6 MIO# OR pick a free JB/JD PL pin against the Zybo master XDC. ***
#      Breakout has NO series resistor: add 1k between the FPGA pin and chip RESET (else grounding shorts 3.3V).
# set_property -dict { PACKAGE_PIN <TBD> IOSTANDARD LVCMOS33 } [get_ports { adv7393_reset_n }]

# ---- (G3+) ADV7393 8-bit data P0..P7 + HSYNC/VSYNC come later on JA[7:0] + JB[1:0]. Added at G3. ----
