# dual_engine_b_bd.tcl — DUAL-ENGINE validation: add Engine B (a SECOND read engine)
# to the proven V1 warp build. ADDITIVE ONLY — Engine A (warp -> HDMI) is untouched.
#
# Engine B = pg_read_engine_top (line-fetch FRC read engine) reading the SAME DDR
# frame buffer Engine A reads, on its OWN independent ~27 MHz PLL clock domain, via
# its OWN AXI DataMover on PS S_AXI_HP2 (HP0=VDMA, HP1=warp read -> HP2 is the free
# port; the task's "HP0" is occupied by the VDMA, so HP2 is the correct dedicated
# port and still validates DDR-controller contention between the two readers).
#
# Engine B geometry = IDENTITY 1:1 passthrough (all xlconstants). Output -> a free-
# running raster timing gen -> axis_to_vid_io -> pg_comp_out_mux (runtime GPIO-
# selectable composite-encode vs raw bypass) -> comp[7:0] -> 8-bit R-2R ladder on
# Pmod JC. Sourced from build_phase_b.tcl AFTER readengine_warp_bd.tcl.

puts "DUAL-ENGINE-B: integrating second read engine (pg_read_engine_top) on HP2 + independent 27 MHz PLL"

# ---------------------------------------------------------------------------
# Engine B independent clock: ~27 MHz, sourced from the PS FCLK_CLK0 (100 MHz).
# MMCM (not PLL): a PLL fed from the BUFG-routed FCLK_CLK0 fights the IO clock
# placer — ZHOLD needs a clock-capable IO pin (DRC REQP-1712), and Global_buffer
# mode then trips a BUFG-BUFG cascade the IO clock placer rejects (Place 30-120 ->
# 30-99 "IO Clock Placer failed"). An MMCM from FCLK_CLK0 is the PROVEN in-design
# pattern (clk_wiz_pixclk_out does exactly this and places cleanly). This uses the
# 4th/last MMCM (3 were used: pixclk_out, dvi2rgb, rgb2dvi -> now 4/4); still fits.
# sys_clk was avoided because it already drives clk_wiz_ref's IBUF (one IO port can
# feed only one IBUF -> Place 30-602) and is the Ethernet PHY refclk (can glitch).
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_engb
set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {27.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {true} \
] [get_bd_cells clk_wiz_engb]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0] [get_bd_pins clk_wiz_engb/clk_in1]
connect_bd_net [get_bd_ports btn_rst]          [get_bd_pins clk_wiz_engb/reset]
set bclk [get_bd_pins clk_wiz_engb/clk_out1]

# Engine B reset (proc_sys_reset synced to engb clock).
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_engb
connect_bd_net $bclk                                [get_bd_pins rst_engb/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_engb/locked]    [get_bd_pins rst_engb/dcm_locked]
connect_bd_net [get_bd_pins zynq_ps/FCLK_RESET0_N]  [get_bd_pins rst_engb/ext_reset_in]
set brstn [get_bd_pins rst_engb/peripheral_aresetn]

# ---------------------------------------------------------------------------
# Re-enable PS HP2 (build_phase_b.tcl disables it when RASTER_TO_TILE=0). Engine B
# reads DDR via HP2; the HP2 port runs on the stable FCLK_CLK1 (143 MHz).
# ---------------------------------------------------------------------------
set_property -dict [list CONFIG.PCW_USE_S_AXI_HP2 {1} CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {64}] [get_bd_cells zynq_ps]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins zynq_ps/S_AXI_HP2_ACLK]

# ---------------------------------------------------------------------------
# Engine B AXI DataMover (MM2S only, 64-bit) — entirely on the engb clock.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_datamover re_datamover_b
set_property -dict [list \
    CONFIG.c_include_mm2s {Full} CONFIG.c_enable_mm2s {1} CONFIG.c_enable_s2mm {0} \
    CONFIG.c_m_axi_mm2s_data_width {64} CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {256} CONFIG.c_m_axi_mm2s_addr_width {32} \
    CONFIG.c_include_mm2s_stsfifo {true} ] [get_bd_cells re_datamover_b]
connect_bd_net $bclk  [get_bd_pins re_datamover_b/m_axi_mm2s_aclk]
connect_bd_net $bclk  [get_bd_pins re_datamover_b/m_axis_mm2s_cmdsts_aclk]
connect_bd_net $brstn [get_bd_pins re_datamover_b/m_axi_mm2s_aresetn]
connect_bd_net $brstn [get_bd_pins re_datamover_b/m_axis_mm2s_cmdsts_aresetn]

# SmartConnect: DataMover M_AXI (engb clock) -> PS S_AXI_HP2 (FCLK_CLK1).
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc_memb
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells axi_sc_memb]
connect_bd_intf_net [get_bd_intf_pins re_datamover_b/M_AXI_MM2S] [get_bd_intf_pins axi_sc_memb/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc_memb/M00_AXI]       [get_bd_intf_pins zynq_ps/S_AXI_HP2]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1]          [get_bd_pins axi_sc_memb/aclk]
connect_bd_net [get_bd_pins rst_mem/peripheral_aresetn] [get_bd_pins axi_sc_memb/aresetn]
connect_bd_net $bclk                                    [get_bd_pins axi_sc_memb/aclk1]

# ---------------------------------------------------------------------------
# Engine B compositor — IDENTITY geometry (all xlconstants). Reads the SAME DDR
# master Engine A reads: IN/OUT = 1920x1080, STRIDE 5760, SLOT_STRIDE 6226560,
# NUM_FRAMES 7, FRAME_BUF_BASE 0x10000000 — identical layout so both engines read
# the identical ring slots written by the VDMA S2MM.
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference pg_read_engine_top pg_re_b
set_property -dict [list CONFIG.IN_W {1920} CONFIG.IN_H {1080} \
    CONFIG.OUT_W {1920} CONFIG.OUT_H {1080} \
    CONFIG.STRIDE {5760} CONFIG.SLOT_STRIDE {6226560} CONFIG.NUM_FRAMES {7}] [get_bd_cells pg_re_b]
connect_bd_net $bclk  [get_bd_pins pg_re_b/clk]
connect_bd_net $brstn [get_bd_pins pg_re_b/rstn]
# Genlock to the SAME S2MM write pointer Engine A follows (frame-follow; pg_genlock CDCs it).
connect_bd_net [get_bd_pins axi_vdma_0/s2mm_frame_ptr_out] [get_bd_pins pg_re_b/frame_ptr]

# Free-running raster timing generator on the engb clock (active region == OUT_W x OUT_H
# so identity passthrough is a clean 1:1 to the DAC). Drives out_vsync + axis_to_vid_io.
create_bd_cell -type module -reference engb_timing engb_timing_0
connect_bd_net $bclk  [get_bd_pins engb_timing_0/clk]
connect_bd_net $brstn [get_bd_pins engb_timing_0/rstn]
connect_bd_net [get_bd_pins engb_timing_0/frame_vsync] [get_bd_pins pg_re_b/out_vsync]

# IDENTITY geometry constants (full source, step=1.0, pos=0, NN filter, no blend).
proc engb_const {name w val} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant $name
    set_property -dict [list CONFIG.CONST_WIDTH $w CONFIG.CONST_VAL $val] [get_bd_cells $name]
}
engb_const c_outw  12 1920
engb_const c_outh  12 1080
engb_const c_zero12 12 0
engb_const c_one12  12 1
engb_const c_matte 24 0x000000
engb_const c_filt   2 0
engb_const c_inv0  16 0
engb_const c_dir0   1 0
engb_const c_blend  2 0
connect_bd_net [get_bd_pins c_outw/dout]   [get_bd_pins pg_re_b/out_w_win]
connect_bd_net [get_bd_pins c_outh/dout]   [get_bd_pins pg_re_b/out_h_win]
connect_bd_net [get_bd_pins c_zero12/dout] [get_bd_pins pg_re_b/pos_x]
connect_bd_net [get_bd_pins c_zero12/dout] [get_bd_pins pg_re_b/pos_y]
connect_bd_net [get_bd_pins c_zero12/dout] [get_bd_pins pg_re_b/src_col0]
connect_bd_net [get_bd_pins c_zero12/dout] [get_bd_pins pg_re_b/src_row0]
connect_bd_net [get_bd_pins c_one12/dout]  [get_bd_pins pg_re_b/h_step_int]
connect_bd_net [get_bd_pins c_zero12/dout] [get_bd_pins pg_re_b/h_step_frac]
connect_bd_net [get_bd_pins c_one12/dout]  [get_bd_pins pg_re_b/v_step_int]
connect_bd_net [get_bd_pins c_zero12/dout] [get_bd_pins pg_re_b/v_step_frac]
connect_bd_net [get_bd_pins c_matte/dout]  [get_bd_pins pg_re_b/matte_rgb]
connect_bd_net [get_bd_pins c_filt/dout]   [get_bd_pins pg_re_b/filt_mode]
connect_bd_net [get_bd_pins c_inv0/dout]   [get_bd_pins pg_re_b/inv_w]
connect_bd_net [get_bd_pins c_inv0/dout]   [get_bd_pins pg_re_b/inv_h]
connect_bd_net [get_bd_pins c_dir0/dout]   [get_bd_pins pg_re_b/h_dir]
connect_bd_net [get_bd_pins c_dir0/dout]   [get_bd_pins pg_re_b/v_dir]
connect_bd_net [get_bd_pins c_blend/dout]  [get_bd_pins pg_re_b/blend_mode]

# DataMover command + data + status streams (single engb domain — no clock converters).
connect_bd_intf_net [get_bd_intf_pins pg_re_b/m_axis_cmd]            [get_bd_intf_pins re_datamover_b/S_AXIS_MM2S_CMD]
connect_bd_intf_net [get_bd_intf_pins re_datamover_b/M_AXIS_MM2S]    [get_bd_intf_pins pg_re_b/s_axis_dm]
connect_bd_intf_net [get_bd_intf_pins re_datamover_b/M_AXIS_MM2S_STS] [get_bd_intf_pins pg_re_b/s_axis_sts]

# ---------------------------------------------------------------------------
# Output stage: pg_re_b/m_axis -> axis_to_vid_io_b -> pg_comp_out_mux -> comp[7:0].
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference axis_to_vid_io axis_to_vid_io_b
connect_bd_net $bclk [get_bd_pins axis_to_vid_io_b/clk]
connect_bd_net [get_bd_pins clk_wiz_engb/locked] [get_bd_pins axis_to_vid_io_b/enable]
connect_bd_intf_net [get_bd_intf_pins pg_re_b/m_axis] [get_bd_intf_pins axis_to_vid_io_b/s_axis]
connect_bd_net [get_bd_pins engb_timing_0/active_video] [get_bd_pins axis_to_vid_io_b/vtg_active_video]
connect_bd_net [get_bd_pins engb_timing_0/hsync]        [get_bd_pins axis_to_vid_io_b/vtg_hsync]
connect_bd_net [get_bd_pins engb_timing_0/vsync]        [get_bd_pins axis_to_vid_io_b/vtg_vsync]
connect_bd_net [get_bd_pins engb_timing_0/hblank]       [get_bd_pins axis_to_vid_io_b/vtg_hblank]
connect_bd_net [get_bd_pins engb_timing_0/vblank]       [get_bd_pins axis_to_vid_io_b/vtg_vblank]

create_bd_cell -type module -reference pg_comp_out_mux comp_out_mux_0
connect_bd_net $bclk  [get_bd_pins comp_out_mux_0/clk]
connect_bd_net $brstn [get_bd_pins comp_out_mux_0/rstn]
connect_bd_net [get_bd_pins axis_to_vid_io_b/vid_data]         [get_bd_pins comp_out_mux_0/vid_rgb]
connect_bd_net [get_bd_pins axis_to_vid_io_b/vid_active_video] [get_bd_pins comp_out_mux_0/vid_active]
connect_bd_net [get_bd_pins axis_to_vid_io_b/vid_hsync]        [get_bd_pins comp_out_mux_0/vid_hsync]
connect_bd_net [get_bd_pins axis_to_vid_io_b/vid_vsync]        [get_bd_pins comp_out_mux_0/vid_vsync]

# 8-bit composite/bypass output port -> XDC Pmod JC (R-2R ladder).
create_bd_port -dir O -from 7 -to 0 comp
connect_bd_net [get_bd_pins comp_out_mux_0/comp] [get_bd_ports comp]

# ---------------------------------------------------------------------------
# Engine B control GPIO (axi_gpio_20) on GP1/axi_ic_lite2 (axi_ic_lite is full):
#   ch1 [15:0] = brightness (Q8.8, default 0x0100 = 1.0)
#   ch1 [16]   = comp_enable (1 = composite-encoded out, 0 = raw bypass; default 1)
# Named axi_gpio_20 (next free index) so XPAR_AXI_GPIO_* enumeration for the existing
# firmware GPIOs (0..19) is unchanged — no re-aliasing.
# ---------------------------------------------------------------------------
if {[llength [get_bd_cells -quiet axi_ic_lite2]] == 0} {
    puts "ERROR: DUAL_ENGINE requires the PROJECTIVE warp build (axi_ic_lite2 on GP1). Set PROJECTIVE_BUILD=1."
    exit 1
}
set _cur_mi [get_property CONFIG.NUM_MI [get_bd_cells axi_ic_lite2]]
set _slot   $_cur_mi
set _mp     "M[format %02d $_slot]"
set_property CONFIG.NUM_MI [expr {$_cur_mi + 1}] [get_bd_cells axi_ic_lite2]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite2/${_mp}_ACLK]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_ic_lite2/${_mp}_ARESETN]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_20
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_IS_DUAL {0} \
    CONFIG.C_INTERRUPT_PRESENT {0} CONFIG.C_DOUT_DEFAULT {0x00010100}] [get_bd_cells axi_gpio_20]
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite2/${_mp}_AXI] [get_bd_intf_pins axi_gpio_20/S_AXI]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_gpio_20/s_axi_aclk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_gpio_20/s_axi_aresetn]
puts "DUAL-ENGINE-B: axi_gpio_20 (brightness+comp_enable) on axi_ic_lite2/${_mp}"

create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice sl_brightness
set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {15} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {16}] [get_bd_cells sl_brightness]
connect_bd_net [get_bd_pins axi_gpio_20/gpio_io_o] [get_bd_pins sl_brightness/Din]
connect_bd_net [get_bd_pins sl_brightness/Dout]    [get_bd_pins comp_out_mux_0/brightness_async]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice sl_compen
set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {16} CONFIG.DIN_TO {16} CONFIG.DOUT_WIDTH {1}] [get_bd_cells sl_compen]
connect_bd_net [get_bd_pins axi_gpio_20/gpio_io_o] [get_bd_pins sl_compen/Din]
connect_bd_net [get_bd_pins sl_compen/Dout]        [get_bd_pins comp_out_mux_0/comp_enable_async]

# ---------------------------------------------------------------------------
# TSG (internal test signal generator) control — reuse spare axi_gpio_20 bits:
#   [17]    = tsg_enable (0 = HDMI input, 1 = internal pattern; default 0)
#   [19:18] = pattern    (0 bars / 1 h-ramp / 2 v-ramp / 3 gray; default 0)
# Fans tsg_enable out to the write-side clock mux + source mux + switch reset
# (cells created in build_phase_b.tcl), and pattern to pg_tsg.
# ---------------------------------------------------------------------------
if {[info exists TSG_BUILD] && $TSG_BUILD} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice sl_tsg_en
    set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {17} CONFIG.DIN_TO {17} CONFIG.DOUT_WIDTH {1}] [get_bd_cells sl_tsg_en]
    connect_bd_net [get_bd_pins axi_gpio_20/gpio_io_o] [get_bd_pins sl_tsg_en/Din]
    connect_bd_net [get_bd_pins sl_tsg_en/Dout] [get_bd_pins tsg_clkmux_0/sel]
    connect_bd_net [get_bd_pins sl_tsg_en/Dout] [get_bd_pins tsg_srcsel_0/sel_async]
    connect_bd_net [get_bd_pins sl_tsg_en/Dout] [get_bd_pins tsg_switch_rst_0/sel_async]

    create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice sl_tsg_pat
    set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {21} CONFIG.DIN_TO {18} CONFIG.DOUT_WIDTH {4}] [get_bd_cells sl_tsg_pat]
    connect_bd_net [get_bd_pins axi_gpio_20/gpio_io_o] [get_bd_pins sl_tsg_pat/Din]
    connect_bd_net [get_bd_pins sl_tsg_pat/Dout] [get_bd_pins pg_tsg_0/pattern]
    puts "DUAL-ENGINE-B: TSG control wired — axi_gpio_20\[17\]=tsg_enable, \[19:18\]=pattern"

    # OSD-0 runtime banner text load: a dedicated GPIO (axi_gpio_20 spare bits are too few for the
    # 14-bit {strobe,idx,char} word). New master port on axi_ic_lite2, gpio_io_o[13:0] -> pg_tsg_0/osd_load.
    set _osd_mi [get_property CONFIG.NUM_MI [get_bd_cells axi_ic_lite2]]
    set _osd_mp "M[format %02d $_osd_mi]"
    set_property CONFIG.NUM_MI [expr {$_osd_mi + 1}] [get_bd_cells axi_ic_lite2]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite2/${_osd_mp}_ACLK]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_ic_lite2/${_osd_mp}_ARESETN]
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_21
    set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_IS_DUAL {0} \
        CONFIG.C_INTERRUPT_PRESENT {0} CONFIG.C_DOUT_DEFAULT {0x00000000}] [get_bd_cells axi_gpio_21]
    connect_bd_intf_net [get_bd_intf_pins axi_ic_lite2/${_osd_mp}_AXI] [get_bd_intf_pins axi_gpio_21/S_AXI]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_gpio_21/s_axi_aclk]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_gpio_21/s_axi_aresetn]
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice sl_osd_load
    set_property -dict [list CONFIG.DIN_WIDTH {32} CONFIG.DIN_FROM {13} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {14}] [get_bd_cells sl_osd_load]
    connect_bd_net [get_bd_pins axi_gpio_21/gpio_io_o] [get_bd_pins sl_osd_load/Din]
    connect_bd_net [get_bd_pins sl_osd_load/Dout] [get_bd_pins pg_tsg_0/osd_load]
    puts "DUAL-ENGINE-B: OSD-0 banner-text load on axi_gpio_21 (\[13\]=strobe \[12:8\]=idx \[7:0\]=char) via axi_ic_lite2/${_osd_mp}"
}

puts "DUAL-ENGINE-B: integration block complete (pg_re_b identity 1:1 on HP2, comp[7:0] -> Pmod JC)"
