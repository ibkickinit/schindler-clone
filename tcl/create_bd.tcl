# create_bd.tcl — Creates a PS-only block design ("system") containing a
# single Zynq processing_system7 configured for the Zybo Z7-20 via Digilent
# board preset. Generates the Verilog wrapper that top.v instantiates.
#
# Called from build.tcl after create_project; assumes the project is current
# and board_part has been set to digilentinc.com:zybo-z7-20:part0:*.

create_bd_design "system"

# Instantiate Zynq PS
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 processing_system7_0

# Apply Zybo Z7-20 board preset → configures MIO, DDR, peripherals, clocks
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" \
             apply_board_preset "1" \
             Master "Disable" \
             Slave "Disable"} \
    [get_bd_cells processing_system7_0]

# The PS still exposes M_AXI_GP0_ACLK (an input) even when the master is
# disabled. With nothing on the PL driving it, BD validation fails. Standard
# fix: tie FCLK_CLK0 (output) back to M_AXI_GP0_ACLK (input). This is purely
# a dangling-pin tie-off — no real interconnect occurs.
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK]

validate_bd_design
save_bd_design

# Generate the Verilog wrapper Vivado will use as a synthesizable module
set bd_file [get_files system.bd]
make_wrapper -files $bd_file -top -import
puts "BD: system.bd created, wrapper generated and imported"
