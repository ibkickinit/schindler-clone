# readengine_warp_bd.tcl — WARP read-engine BD integration (arbitrary-geometry / affine).
# Variant of readengine_b_bd.tcl: same DataMover + AXIS mux, but the compositor is pg_warp_top
# (pg_affine + tile cache + bilinear) instead of pg_read_engine_top, and geometry = 6 affine coeffs.
#
# GPIO map (firmware-written 32-bit each; the 3 existing dual GPIOs give exactly 6 channels):
#   axi_gpio_8 ch1 = m_a   ch2 = m_b      (signed Q20.12)
#   axi_gpio_9 ch1 = m_c   ch2 = m_d
#   axi_gpio_10 ch1 = m_e  ch2 = m_f
#   axi_gpio_12 bit0 = mux sel (default 1 = warp; write 0 for VDMA passthrough)
# Default coeffs = fit-scale 1920x1080 -> 1280x720: a=e=1.5 (0x1800), b=c=d=f=0 -> boots to a scaled frame.
# matte = constant 0x101010 (runtime matte GPIO deferred).

puts "READENGINE-WARP: integrating affine/warp read-engine (additive + mux)"

set pclk   [get_bd_pins clk_wiz_pixclk_out/clk_out1]
set prstn  [get_bd_pins rst_pixclk_out/peripheral_aresetn]

# ---- AXI DataMover (MM2S) — identical to route-B ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_datamover re_datamover
set_property -dict [list \
    CONFIG.c_include_mm2s {Full} CONFIG.c_enable_mm2s {1} CONFIG.c_enable_s2mm {0} \
    CONFIG.c_m_axi_mm2s_data_width {64} CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {256} CONFIG.c_m_axi_mm2s_addr_width {32} \
    CONFIG.c_include_mm2s_stsfifo {true} ] [get_bd_cells re_datamover]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc_mem2
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells axi_sc_mem2]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXI_MM2S] [get_bd_intf_pins axi_sc_mem2/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc_mem2/M00_AXI]     [get_bd_intf_pins zynq_ps/S_AXI_HP1]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins zynq_ps/S_AXI_HP1_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins axi_sc_mem2/aclk]
connect_bd_net $prstn                          [get_bd_pins axi_sc_mem2/aresetn]
connect_bd_net $pclk  [get_bd_pins re_datamover/m_axi_mm2s_aclk]
connect_bd_net $pclk  [get_bd_pins re_datamover/m_axis_mm2s_cmdsts_aclk]
connect_bd_net $prstn [get_bd_pins re_datamover/m_axi_mm2s_aresetn]
connect_bd_net $prstn [get_bd_pins re_datamover/m_axis_mm2s_cmdsts_aresetn]
connect_bd_net $pclk  [get_bd_pins axi_sc_mem2/aclk1]

# ---- coeff GPIOs (3 dual-channel = 6 coeffs). Defaults = fit-scale affine ----
foreach {gname dflt1 dflt2} {
    axi_gpio_8  0x00001800 0x00000000
    axi_gpio_9  0x00000000 0x00000000
    axi_gpio_10 0x00001800 0x00000000
} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio $gname
    set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
        CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_ALL_OUTPUTS_2 {1} CONFIG.C_IS_DUAL {1} \
        CONFIG.C_INTERRUPT_PRESENT {0} CONFIG.C_DOUT_DEFAULT $dflt1 \
        CONFIG.C_DOUT_DEFAULT_2 $dflt2] [get_bd_cells $gname]
}

# matte constant
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant warp_matte
set_property -dict [list CONFIG.CONST_WIDTH {24} CONFIG.CONST_VAL {0x101010}] [get_bd_cells warp_matte]

# ---- warp compositor ----
create_bd_cell -type module -reference pg_warp_top pg_re_0
# Device-fitting config (docs/warp-engine-real-geometry-findings.md §Fit):
# 8-way/NTILE=1024 (the single-global-LEAD real-time config) needs 192 RAMB36 > 140 on the 7020 (dev AND
# production TE0720). With PER-GEOMETRY LEAD (firmware sets a shallow lead for rotation, deep for
# downscale) every transform is real-time at a lead where worst-set-live <= 4, so 4-way/NTILE=512 (~96
# RAMB36) fits. LEAD here is the placeholder default; real-time requires the firmware to set it per
# geometry (deep for downscale). PD/DREQ=64 (feed depth) is independent of associativity.
set_property -dict [list CONFIG.IN_W {1920} CONFIG.IN_H {1080} CONFIG.OUT_W {1280} CONFIG.OUT_H {720} \
    CONFIG.SLOT_STRIDE {6226560} CONFIG.NUM_FRAMES {7} \
    CONFIG.NTILE {512} CONFIG.WAY {4} CONFIG.PD {64} CONFIG.DREQ {64} CONFIG.LEAD {4096}] [get_bd_cells pg_re_0]
connect_bd_net $pclk  [get_bd_pins pg_re_0/clk]
connect_bd_net $prstn [get_bd_pins pg_re_0/rstn]
connect_bd_net [get_bd_pins axi_vdma_0/s2mm_frame_ptr_out] [get_bd_pins pg_re_0/frame_ptr]
connect_bd_net [get_bd_pins v_tc_tx/vsync_out]            [get_bd_pins pg_re_0/out_vsync]
# 6 affine coeffs wired DIRECTLY (full 32-bit, no slices)
connect_bd_net [get_bd_pins axi_gpio_8/gpio_io_o]   [get_bd_pins pg_re_0/m_a]
connect_bd_net [get_bd_pins axi_gpio_8/gpio2_io_o]  [get_bd_pins pg_re_0/m_b]
connect_bd_net [get_bd_pins axi_gpio_9/gpio_io_o]   [get_bd_pins pg_re_0/m_c]
connect_bd_net [get_bd_pins axi_gpio_9/gpio2_io_o]  [get_bd_pins pg_re_0/m_d]
connect_bd_net [get_bd_pins axi_gpio_10/gpio_io_o]  [get_bd_pins pg_re_0/m_e]
connect_bd_net [get_bd_pins axi_gpio_10/gpio2_io_o] [get_bd_pins pg_re_0/m_f]
connect_bd_net [get_bd_pins warp_matte/dout]        [get_bd_pins pg_re_0/matte_rgb]
# DataMover streams
connect_bd_intf_net [get_bd_intf_pins pg_re_0/m_axis_cmd] [get_bd_intf_pins re_datamover/S_AXIS_MM2S_CMD]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXIS_MM2S] [get_bd_intf_pins pg_re_0/s_axis_dm]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXIS_MM2S_STS] [get_bd_intf_pins pg_re_0/s_axis_sts]

# ---- 2:1 AXIS mux (sel default 1 = warp) ----
create_bd_cell -type module -reference axis_mux2 re_mux
connect_bd_net $pclk [get_bd_pins re_mux/clk]
catch { delete_bd_cell [get_bd_cells ila_mm2s_out] }
delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins color_saturation_0/s_axis]]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins re_mux/s0]
connect_bd_intf_net [get_bd_intf_pins pg_re_0/m_axis]         [get_bd_intf_pins re_mux/s1]
connect_bd_intf_net [get_bd_intf_pins re_mux/m]              [get_bd_intf_pins color_saturation_0/s_axis]

# ---- AXI-Lite: coeff GPIOs at M11/M12/M13 ----
set_property -dict [list CONFIG.NUM_MI {14}] [get_bd_cells axi_ic_lite]
foreach {slot gname} {11 axi_gpio_8 12 axi_gpio_9 13 axi_gpio_10} {
    set mp "M[format %02d $slot]"
    connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/${mp}_AXI] [get_bd_intf_pins ${gname}/S_AXI]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite/${mp}_ACLK]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_ic_lite/${mp}_ARESETN]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins ${gname}/s_axi_aclk]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins ${gname}/s_axi_aresetn]
}

# ---- gamma GPIO (axi_gpio_11 @ M14) — unchanged from route-B ----
set_property -dict [list CONFIG.NUM_MI {15}] [get_bd_cells axi_ic_lite]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_11
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {0} CONFIG.C_INTERRUPT_PRESENT {0} CONFIG.C_DOUT_DEFAULT {0x00000001}] [get_bd_cells axi_gpio_11]
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M14_AXI] [get_bd_intf_pins axi_gpio_11/S_AXI]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite/M14_ACLK]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_ic_lite/M14_ARESETN]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_gpio_11/s_axi_aclk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_gpio_11/s_axi_aresetn]
proc re_slice {name gpio port hi lo} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice $name
    set w [expr {$hi - $lo + 1}]
    set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM $hi CONFIG.DIN_TO $lo CONFIG.DOUT_WIDTH $w] [get_bd_cells $name]
    connect_bd_net [get_bd_pins ${gpio}/${port}] [get_bd_pins ${name}/Din]
}
re_slice sl_g_byp  axi_gpio_11 gpio_io_o 0  0
re_slice sl_g_tog  axi_gpio_11 gpio_io_o 1  1
re_slice sl_g_ch   axi_gpio_11 gpio_io_o 3  2
re_slice sl_g_addr axi_gpio_11 gpio_io_o 11 4
re_slice sl_g_data axi_gpio_11 gpio_io_o 19 12
re_slice sl_g_swap axi_gpio_11 gpio_io_o 20 20
connect_bd_net [get_bd_pins sl_g_byp/Dout]  [get_bd_pins gamma_lut_0/bypass]
connect_bd_net [get_bd_pins sl_g_tog/Dout]  [get_bd_pins gamma_lut_0/lut_tog]
connect_bd_net [get_bd_pins sl_g_ch/Dout]   [get_bd_pins gamma_lut_0/lut_ch]
connect_bd_net [get_bd_pins sl_g_addr/Dout] [get_bd_pins gamma_lut_0/lut_addr]
connect_bd_net [get_bd_pins sl_g_data/Dout] [get_bd_pins gamma_lut_0/lut_data]
connect_bd_net [get_bd_pins sl_g_swap/Dout] [get_bd_pins gamma_lut_0/swap]

# ---- mux-sel GPIO (axi_gpio_12 @ M15), default 1 = warp ----
set_property -dict [list CONFIG.NUM_MI {16}] [get_bd_cells axi_ic_lite]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_12
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {0} CONFIG.C_INTERRUPT_PRESENT {0} CONFIG.C_DOUT_DEFAULT {0x00000001}] [get_bd_cells axi_gpio_12]
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M15_AXI] [get_bd_intf_pins axi_gpio_12/S_AXI]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite/M15_ACLK]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_ic_lite/M15_ARESETN]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_gpio_12/s_axi_aclk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_gpio_12/s_axi_aresetn]
re_slice sl_sel axi_gpio_12 gpio_io_o 0 0
connect_bd_net [get_bd_pins sl_sel/Dout] [get_bd_pins re_mux/sel]

# BRING-UP DIAG: route the warp engine's activity counters to axi_gpio_2 (firmware readback)
# instead of predrain_snap. dbg={sts_err,cmd_valid,ovalid_cnt[9:0],fill_cnt[9:0],fetch_cnt[9:0]}.
# fetch=0 -> prefetch dead; fill=0 -> DataMover returns nothing; ovalid=0 -> consumer never produces.
delete_bd_objs [get_bd_nets -of_objects [get_bd_pins axi_gpio_2/gpio_io_i]]
connect_bd_net [get_bd_pins pg_re_0/dbg] [get_bd_pins axi_gpio_2/gpio_io_i]

puts "READENGINE-WARP: integration block complete (pg_warp_top + 6-coeff GPIO + sel)"
