# readengine_b_bd.tcl — route-B present-geometry read-engine BD integration.
# Sourced from build_phase_b.tcl just before assign_bd_address.
#
# ADDITIVE + MUX (protects the proven path): VDMA (S2MM+MM2S) is untouched.
# We add an AXI DataMover (MM2S) on HP1 reading the SAME DDR master, the
# pg_read_engine_top compositor, and a 2:1 AXIS mux before the color stack.
#   mux sel = 0 (boot default) → VDMA MM2S (today's exact passthrough)
#   mux sel = 1               → read-engine (runtime size/position/matte)
# Geometry + mux-sel come from 3 dual-channel AXI GPIOs (firmware-written).
#
# clk: read-engine + DataMover + mux all run on the output pixel clock
# (clk_wiz_pixclk_out/clk_out1), same domain as axis_to_vid_io. DataMover's
# M_AXI crosses to FCLK_CLK1/HP1 via its own smartconnect.

puts "READENGINE-B: integrating route-B read-engine (additive + mux)"

set pclk   [get_bd_pins clk_wiz_pixclk_out/clk_out1]
set prstn  [get_bd_pins rst_pixclk_out/peripheral_aresetn]

# ---------------------------------------------------------------------------
# AXI DataMover (MM2S only) — random-access DDR reader for the read-engine
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_datamover re_datamover
set_property -dict [list \
    CONFIG.c_include_mm2s {Full} \
    CONFIG.c_include_s2mm {Omit} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_addr_width {32} \
    CONFIG.c_include_mm2s_stsfifo {1} \
    CONFIG.c_enable_mm2s {1} \
] [get_bd_cells re_datamover]

# DataMover memory-path → its own smartconnect → PS S_AXI_HP1
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc_mem2
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_sc_mem2]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXI_MM2S] [get_bd_intf_pins axi_sc_mem2/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc_mem2/M00_AXI]     [get_bd_intf_pins zynq_ps/S_AXI_HP1]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins zynq_ps/S_AXI_HP1_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins axi_sc_mem2/aclk]
connect_bd_net $prstn                          [get_bd_pins axi_sc_mem2/aresetn]
# DataMover runs on the output pixel clock (single clock for cmd/data/M_AXI)
connect_bd_net $pclk  [get_bd_pins re_datamover/m_axi_mm2s_aclk]
connect_bd_net $pclk  [get_bd_pins re_datamover/m_axis_mm2s_cmdsts_aclk]
connect_bd_net $prstn [get_bd_pins re_datamover/m_axi_mm2s_aresetn]
connect_bd_net $prstn [get_bd_pins re_datamover/m_axis_mm2s_cmdsts_aresetn]
# smartconnect M_AXI clock = its slave clock (DataMover) — second aclk:
connect_bd_net $pclk  [get_bd_pins axi_sc_mem2/aclk1]

# ---------------------------------------------------------------------------
# Geometry GPIOs (3 dual-channel, output). Packed:
#   gpio_a ch1 = {4'b0, out_h[11:0], 4'b0, out_w[11:0]}   ch2 = {pos_y, pos_x}
#   gpio_b ch1 = {h_step_frac, h_step_int}                ch2 = {v_step_frac, v_step_int}
#   gpio_c ch1 = {8'b0, matte_rgb[23:0]}                  ch2 = {31'b0, mux_sel}
# ---------------------------------------------------------------------------
foreach {gname dflt1 dflt2} {
    axi_gpio_8 0x02D00500 0x00000000
    axi_gpio_9 0x00000001 0x00000001
    axi_gpio_10 0x00000000 0x00000000
} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio $gname
    set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
        CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_ALL_OUTPUTS_2 {1} CONFIG.C_IS_DUAL {1} \
        CONFIG.C_INTERRUPT_PRESENT {0} CONFIG.C_DOUT_DEFAULT $dflt1 \
        CONFIG.C_DOUT_DEFAULT_2 $dflt2] [get_bd_cells $gname]
}
# gpio_a default 0x02D00500 = out_h(0x2D0=720)<<16 | out_w(0x500=1280); pos 0
# gpio_b default step_int=1/frac=0 each (full-size: IN/out = 1) → identity

# helper: make an xlslice {name src_gpio port hi lo}
proc re_slice {name gpio port hi lo} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice $name
    set w [expr {$hi - $lo + 1}]
    set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM $hi CONFIG.DIN_TO $lo \
        CONFIG.DIN_WIDTH_TO $w] [get_bd_cells $name]
    connect_bd_net [get_bd_pins ${gpio}/${port}] [get_bd_pins ${name}/Din]
}
re_slice sl_out_w  axi_gpio_8 gpio_io_o  11 0
re_slice sl_out_h  axi_gpio_8 gpio_io_o  27 16
re_slice sl_pos_x  axi_gpio_8 gpio2_io_o 11 0
re_slice sl_pos_y  axi_gpio_8 gpio2_io_o 27 16
re_slice sl_hsi    axi_gpio_9 gpio_io_o  11 0
re_slice sl_hsf    axi_gpio_9 gpio_io_o  27 16
re_slice sl_vsi    axi_gpio_9 gpio2_io_o 11 0
re_slice sl_vsf    axi_gpio_9 gpio2_io_o 27 16
re_slice sl_matte  axi_gpio_10 gpio_io_o  23 0
re_slice sl_sel    axi_gpio_10 gpio2_io_o 0  0

# ---------------------------------------------------------------------------
# Read-engine compositor cell
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference pg_read_engine_top pg_re_0
connect_bd_net $pclk  [get_bd_pins pg_re_0/clk]
connect_bd_net $prstn [get_bd_pins pg_re_0/rstn]
connect_bd_net [get_bd_pins dvi2rgb_0/vid_pVSync] [get_bd_pins pg_re_0/src_vsync]
connect_bd_net [get_bd_pins v_tc_tx/vsync_out]    [get_bd_pins pg_re_0/out_vsync]
connect_bd_net [get_bd_pins sl_out_w/Dout]  [get_bd_pins pg_re_0/out_w_win]
connect_bd_net [get_bd_pins sl_out_h/Dout]  [get_bd_pins pg_re_0/out_h_win]
connect_bd_net [get_bd_pins sl_pos_x/Dout]  [get_bd_pins pg_re_0/pos_x]
connect_bd_net [get_bd_pins sl_pos_y/Dout]  [get_bd_pins pg_re_0/pos_y]
connect_bd_net [get_bd_pins sl_hsi/Dout]    [get_bd_pins pg_re_0/h_step_int]
connect_bd_net [get_bd_pins sl_hsf/Dout]    [get_bd_pins pg_re_0/h_step_frac]
connect_bd_net [get_bd_pins sl_vsi/Dout]    [get_bd_pins pg_re_0/v_step_int]
connect_bd_net [get_bd_pins sl_vsf/Dout]    [get_bd_pins pg_re_0/v_step_frac]
connect_bd_net [get_bd_pins sl_matte/Dout]  [get_bd_pins pg_re_0/matte_rgb]
# DataMover command + data streams
connect_bd_intf_net [get_bd_intf_pins pg_re_0/m_axis_cmd] [get_bd_intf_pins re_datamover/S_AXIS_MM2S_CMD]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXIS_MM2S] [get_bd_intf_pins pg_re_0/s_axis_dm]

# ---------------------------------------------------------------------------
# 2:1 AXIS mux before the color stack (sel default 0 = VDMA MM2S passthrough)
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference axis_mux2 re_mux
connect_bd_net $pclk [get_bd_pins re_mux/clk]
connect_bd_net [get_bd_pins sl_sel/Dout] [get_bd_pins re_mux/sel]
# remove the MM2S debug ILA so its tap doesn't entangle the reroute
catch { delete_bd_cell [get_bd_cells ila_mm2s_out] }
# detach MM2S → color_saturation, reroute through the mux
delete_bd_intf_net [get_bd_intf_nets -of_objects [get_bd_intf_pins color_saturation_0/s_axis]]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins re_mux/s0]
connect_bd_intf_net [get_bd_intf_pins pg_re_0/m_axis]         [get_bd_intf_pins re_mux/s1]
connect_bd_intf_net [get_bd_intf_pins re_mux/m]              [get_bd_intf_pins color_saturation_0/s_axis]

# ---------------------------------------------------------------------------
# AXI-Lite: expand interconnect for the 3 geometry GPIOs (M11/M12/M13)
# (NUM_MI was 11 → 14; the kernel GPIO stays at its slot)
# ---------------------------------------------------------------------------
set_property -dict [list CONFIG.NUM_MI {14}] [get_bd_cells axi_ic_lite]
foreach {slot gname} {11 axi_gpio_8 12 axi_gpio_9 13 axi_gpio_10} {
    set mp "M[format %02d $slot]"
    connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/${mp}_AXI] [get_bd_intf_pins ${gname}/S_AXI]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite/${mp}_ACLK]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_ic_lite/${mp}_ARESETN]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins ${gname}/s_axi_aclk]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins ${gname}/s_axi_aresetn]
}

puts "READENGINE-B: integration block complete"
