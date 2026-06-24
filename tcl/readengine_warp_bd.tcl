# readengine_warp_bd.tcl — WARP read-engine BD integration (arbitrary-geometry / affine).
# Variant of readengine_b_bd.tcl: same DataMover + AXIS mux, but the compositor is pg_warp_top
# (pg_affine + tile cache + bilinear) instead of pg_read_engine_top, and geometry = 6 affine coeffs.
#
# GPIO map (firmware-written 32-bit each; the 3 existing dual GPIOs give exactly 6 channels):
#   axi_gpio_8 ch1 = m_a   ch2 = m_b      (signed Q20.12)
#   axi_gpio_9 ch1 = m_c   ch2 = m_d
#   axi_gpio_10 ch1 = m_e  ch2 = m_f
#   axi_gpio_12 ch1 bit0 = mux sel (default 1 = warp; write 0 for VDMA passthrough)
#   axi_gpio_12 ch2      = runtime per-geometry prefetch LEAD (20-bit; 0 = build LEAD; def 0x500) @ +0x08
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
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] [get_bd_cells axi_sc_mem2]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXI_MM2S] [get_bd_intf_pins axi_sc_mem2/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc_mem2/M00_AXI]     [get_bd_intf_pins zynq_ps/S_AXI_HP1]
# OPTION (b) 2026-06-23: run the WHOLE DataMover (M_AXI mem side + cmd/data/status stream side) at
# FCLK_CLK1 (142.86 MHz) -> ~1.92x read-issue rate vs pclk (the fetch-bandwidth wall behind 45deg
# scramble + 1080 underrun + the 0.8% starvation floor). rst_mem is the FCLK_CLK1-synced reset
# (created in build_phase_b.tcl). The 3 AXIS links to pg_re_0 (pclk) are clock-converted below.
set fclk1  [get_bd_pins zynq_ps/FCLK_CLK1]
set rst143 [get_bd_pins rst_mem/peripheral_aresetn]
connect_bd_net $fclk1  [get_bd_pins zynq_ps/S_AXI_HP1_ACLK]
connect_bd_net $fclk1  [get_bd_pins axi_sc_mem2/aclk]
connect_bd_net $rst143 [get_bd_pins axi_sc_mem2/aresetn]
connect_bd_net $fclk1  [get_bd_pins re_datamover/m_axi_mm2s_aclk]
connect_bd_net $fclk1  [get_bd_pins re_datamover/m_axis_mm2s_cmdsts_aclk]
connect_bd_net $rst143 [get_bd_pins re_datamover/m_axi_mm2s_aresetn]
connect_bd_net $rst143 [get_bd_pins re_datamover/m_axis_mm2s_cmdsts_aresetn]

# ---- coeff GPIOs (3 dual-channel = 6 coeffs). Defaults = fit-scale affine ----
# Default coeffs = IDENTITY (centered 1:1 crop) so the pre-firmware boot phase is the gentlest cache case
# and matches the firmware's boot geometry (no shrink-boot wedge, no geometry transition). m_a=m_e=4096
# (1.0, 0x1000); m_c=320*4096=0x140000, m_f=180*4096=0xB4000 (center 1920x1080 source in 1280x720 raster).
foreach {gname dflt1 dflt2} {
    axi_gpio_8  0x00001000 0x00000000
    axi_gpio_9  0x00140000 0x00000000
    axi_gpio_10 0x00001000 0x000B4000
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
# Warp OUTPUT raster follows OUTPUT_MODE: 1080p30/60 -> emit full 1920x1080; else 720p. SOURCE (IN_W/IN_H,
# SLOT_STRIDE) is always the 1920x1080 DDR master regardless of output mode.
set WARP_OUT_W 1280; set WARP_OUT_H 720
if {[info exists OUTPUT_MODE] && ($OUTPUT_MODE eq "1080p30" || $OUTPUT_MODE eq "1080p60" || $OUTPUT_MODE eq "1080p")} {
    set WARP_OUT_W 1920; set WARP_OUT_H 1080
}
puts "BUILD: warp pg_re_0 OUT = ${WARP_OUT_W}x${WARP_OUT_H} (OUTPUT_MODE=[expr {[info exists OUTPUT_MODE]?$OUTPUT_MODE:{unset}}])"
set_property -dict [list CONFIG.IN_W {1920} CONFIG.IN_H {1080} CONFIG.OUT_W $WARP_OUT_W CONFIG.OUT_H $WARP_OUT_H \
    CONFIG.SLOT_STRIDE {6226560} CONFIG.NUM_FRAMES {7} \
    CONFIG.NTILE {512} CONFIG.WAY {4} CONFIG.PD {64} CONFIG.DREQ {64} CONFIG.LEAD {4096}] [get_bd_cells pg_re_0]

# ---- PROJECTIVE front-end (P3, env PROJECTIVE_BUILD=1). DEFAULT OFF -> the affine BD is byte-identical.
# When set: pg_re_0 runs the full projective address generator (keystone / corner-pin homography).
#   CONFIG.PROJECTIVE {1}  -> instantiate pg_projective's divide path (vs the affine subset)
#   CONFIG.FB {24}         -> numerator coeffs a..f are Q8.24 (P1 budget); the 6 coeff GPIOs are unchanged
#                            (still 32-bit each on axi_gpio_8/9/10) but the firmware emits Q.24, not Q.12.
#   GCW=40 / GFB=36 are the pg_warp_top defaults (Q4.36 perspective) and need no override.
# The perspective coeffs m_g/m_h are NEW 40-bit ports -> wired from new GPIOs below (search PROJ_GH).
set PROJECTIVE_BUILD 0
if {[info exists ::env(PROJECTIVE_BUILD)] && $::env(PROJECTIVE_BUILD) ne "0"} { set PROJECTIVE_BUILD 1 }
puts "BUILD: PROJECTIVE_BUILD=$PROJECTIVE_BUILD (warp front-end = [expr {$PROJECTIVE_BUILD?{projective keystone/corner-pin}:{affine}}])"
if {$PROJECTIVE_BUILD} {
    set_property -dict [list CONFIG.PROJECTIVE {1} CONFIG.FB {24} CONFIG.GCW {40} CONFIG.GFB {36}] [get_bd_cells pg_re_0]
}
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
# m_g/m_h: perspective coeffs (40-bit each, PROJECTIVE only). In the AFFINE build they are LEFT
# UNCONNECTED exactly as in the pre-P3 BD (pg_warp_top defaults unconnected inputs to 0 -> w=1 -> affine);
# this keeps the affine wrapper/netlist byte-identical (no extra xlconstant cell). The PROJECTIVE build
# drives them from the new GPIOs (search PROJ_GH below).
# DataMover streams — CLOCK-CONVERTED between pg_re_0 (pclk 74.25) and the 143 MHz DataMover.
# Widths/sidebands propagate from each connected master: cmd=72b (pclk->143), data=64b+tlast (143->pclk),
# status=8b+tlast+tkeep (143->pclk).
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter cc_cmd
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter cc_dat
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter cc_sts
# cmd: pg_re_0 (pclk, master) -> DataMover S_AXIS_MM2S_CMD (143)
connect_bd_net $pclk  [get_bd_pins cc_cmd/s_axis_aclk];  connect_bd_net $prstn  [get_bd_pins cc_cmd/s_axis_aresetn]
connect_bd_net $fclk1 [get_bd_pins cc_cmd/m_axis_aclk];  connect_bd_net $rst143 [get_bd_pins cc_cmd/m_axis_aresetn]
connect_bd_intf_net [get_bd_intf_pins pg_re_0/m_axis_cmd] [get_bd_intf_pins cc_cmd/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins cc_cmd/M_AXIS]      [get_bd_intf_pins re_datamover/S_AXIS_MM2S_CMD]
# data: DataMover M_AXIS_MM2S (143, master) -> pg_re_0 s_axis_dm (pclk)
connect_bd_net $fclk1 [get_bd_pins cc_dat/s_axis_aclk];  connect_bd_net $rst143 [get_bd_pins cc_dat/s_axis_aresetn]
connect_bd_net $pclk  [get_bd_pins cc_dat/m_axis_aclk];  connect_bd_net $prstn  [get_bd_pins cc_dat/m_axis_aresetn]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXIS_MM2S] [get_bd_intf_pins cc_dat/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins cc_dat/M_AXIS]           [get_bd_intf_pins pg_re_0/s_axis_dm]
# status: DataMover M_AXIS_MM2S_STS (143, master) -> pg_re_0 s_axis_sts (pclk)
connect_bd_net $fclk1 [get_bd_pins cc_sts/s_axis_aclk];  connect_bd_net $rst143 [get_bd_pins cc_sts/s_axis_aresetn]
connect_bd_net $pclk  [get_bd_pins cc_sts/m_axis_aclk];  connect_bd_net $prstn  [get_bd_pins cc_sts/m_axis_aresetn]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXIS_MM2S_STS] [get_bd_intf_pins cc_sts/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins cc_sts/M_AXIS]               [get_bd_intf_pins pg_re_0/s_axis_sts]

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

# ---- mux-sel + LEAD GPIO (axi_gpio_12 @ M15, DUAL), ch1=mux sel (def 1=warp), ch2=lead_cfg (def 0x500) ----
# DUAL (not a 17th MI): the classic axi_interconnect maxes at 16 master ports and M00..M15 are all used, so
# the runtime per-geometry LEAD rides axi_gpio_12's second channel instead of a new GPIO. ch1 (0x00)=mux,
# ch2 (0x08)=lead. lead_cfg=0 -> engine uses build LEAD; default ch2 to a deadlock-safe 0x500 (1280) so a
# pre-firmware boot can't wedge a gentle geometry. See pg_tilecache_rt2 LEAD note + readengine_warp top comment.
set_property -dict [list CONFIG.NUM_MI {16}] [get_bd_cells axi_ic_lite]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_12
set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
    CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_ALL_OUTPUTS_2 {1} CONFIG.C_IS_DUAL {1} \
    CONFIG.C_INTERRUPT_PRESENT {0} CONFIG.C_DOUT_DEFAULT {0x00000001} \
    CONFIG.C_DOUT_DEFAULT_2 {0x00000500}] [get_bd_cells axi_gpio_12]
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M15_AXI] [get_bd_intf_pins axi_gpio_12/S_AXI]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite/M15_ACLK]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_ic_lite/M15_ARESETN]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_gpio_12/s_axi_aclk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins axi_gpio_12/s_axi_aresetn]
re_slice sl_sel axi_gpio_12 gpio_io_o 0 0
connect_bd_net [get_bd_pins sl_sel/Dout] [get_bd_pins re_mux/sel]
# ch2 = runtime per-geometry prefetch LEAD -> pg_warp_top lead_cfg (full 32-bit; top uses [19:0]).
connect_bd_net [get_bd_pins axi_gpio_12/gpio2_io_o] [get_bd_pins pg_re_0/lead_cfg]

# BRING-UP DIAG: route the warp engine's activity counters to axi_gpio_2 (firmware readback)
# instead of predrain_snap. dbg={sts_err,cmd_valid,ovalid_cnt[9:0],fill_cnt[9:0],fetch_cnt[9:0]}.
# fetch=0 -> prefetch dead; fill=0 -> DataMover returns nothing; ovalid=0 -> consumer never produces.
delete_bd_objs [get_bd_nets -of_objects [get_bd_pins axi_gpio_2/gpio_io_i]]
connect_bd_net [get_bd_pins pg_re_0/dbg] [get_bd_pins axi_gpio_2/gpio_io_i]

# ============================================================================================
# PROJ_GH — PROJECTIVE perspective coeffs m_g / m_h (P3). Only built when PROJECTIVE_BUILD=1.
# ============================================================================================
# WHY a new AXI master path: the classic axi_ic_lite (axi_interconnect) is at NUM_MI=16 (M00..M15 all
# used by the affine warp build) — the IP HARD-CAPS at 16 master ports, so there is no free slot to add
# the g/h GPIOs there. Instead the projective build enables the Zynq PS's SECOND GP master (M_AXI_GP1),
# unused in the affine design, and hangs a small 2-port interconnect (axi_ic_lite2) off it. This leaves
# axi_ic_lite and the entire affine build untouched.
#
# g/h GPIO PACKING (firmware in P4 MUST match this exactly):
#   m_g / m_h are signed Q4.36 in a 40-bit word (GCW=40, GFB=36). A 32-bit GPIO channel can't hold 40
#   bits, so each coeff is split LOW 32 + HIGH 8 across two dual-channel GPIOs:
#     axi_gpio_13 (DUAL):  ch1 (gpio_io_o,  @+0x00) = m_g[31:0]     ch2 (gpio2_io_o, @+0x08) = m_h[31:0]
#     axi_gpio_14 (DUAL):  ch1 (gpio_io_o,  @+0x00) = {24'b0, m_g[39:32]}   (only bits [7:0] used)
#                          ch2 (gpio2_io_o, @+0x08) = {24'b0, m_h[39:32]}   (only bits [7:0] used)
#   Reassembled here:  m_g = { axi_gpio_14.ch1[7:0], axi_gpio_13.ch1[31:0] }  (40 bits)
#                      m_h = { axi_gpio_14.ch2[7:0], axi_gpio_13.ch2[31:0] }
#   Defaults = 0 (g=h=0 -> w=1 -> the engine boots to a pure-affine geometry; matches the firmware boot
#   identity which writes g=h=0).
if {$PROJECTIVE_BUILD} {
    puts "PROJ_GH: wiring m_g/m_h (Q4.36, 40-bit) via axi_gpio_13/14 on M_AXI_GP1/axi_ic_lite2"
    # Enable PS second GP master (active-high reset already exists as rst_axi on FCLK_CLK0).
    set_property -dict [list CONFIG.PCW_USE_M_AXI_GP1 {1}] [get_bd_cells zynq_ps]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0] [get_bd_pins zynq_ps/M_AXI_GP1_ACLK]

    # Small 1->2 AXI-Lite interconnect off GP1.
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_lite2
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells axi_ic_lite2]
    connect_bd_intf_net [get_bd_intf_pins zynq_ps/M_AXI_GP1] [get_bd_intf_pins axi_ic_lite2/S00_AXI]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite2/ACLK]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite2/S00_ACLK]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite2/M00_ACLK]
    connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins axi_ic_lite2/M01_ACLK]
    connect_bd_net [get_bd_pins rst_axi/interconnect_aresetn] [get_bd_pins axi_ic_lite2/ARESETN]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite2/S00_ARESETN]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite2/M00_ARESETN]
    connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite2/M01_ARESETN]

    # Two dual-channel all-output GPIOs (default 0 -> g=h=0 -> affine boot).
    foreach {gname mp} {axi_gpio_13 M00 axi_gpio_14 M01} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio $gname
        set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
            CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_ALL_OUTPUTS_2 {1} CONFIG.C_IS_DUAL {1} \
            CONFIG.C_INTERRUPT_PRESENT {0} CONFIG.C_DOUT_DEFAULT {0x00000000} \
            CONFIG.C_DOUT_DEFAULT_2 {0x00000000}] [get_bd_cells $gname]
        connect_bd_intf_net [get_bd_intf_pins axi_ic_lite2/${mp}_AXI] [get_bd_intf_pins ${gname}/S_AXI]
        connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]          [get_bd_pins ${gname}/s_axi_aclk]
        connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn] [get_bd_pins ${gname}/s_axi_aresetn]
    }

    # Slice the HIGH 8 bits out of axi_gpio_14's two channels.
    re_slice sl_g_hi axi_gpio_14 gpio_io_o  7 0
    re_slice sl_h_hi axi_gpio_14 gpio2_io_o 7 0

    # Concat: Dout = {In1, In0} -> In0 = LOW 32 (axi_gpio_13), In1 = HIGH 8 (axi_gpio_14 slice) -> 40 bits.
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat gh_g_cat
    set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {32} CONFIG.IN1_WIDTH {8}] [get_bd_cells gh_g_cat]
    connect_bd_net [get_bd_pins axi_gpio_13/gpio_io_o] [get_bd_pins gh_g_cat/In0]
    connect_bd_net [get_bd_pins sl_g_hi/Dout]          [get_bd_pins gh_g_cat/In1]
    connect_bd_net [get_bd_pins gh_g_cat/dout]         [get_bd_pins pg_re_0/m_g]

    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat gh_h_cat
    set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {32} CONFIG.IN1_WIDTH {8}] [get_bd_cells gh_h_cat]
    connect_bd_net [get_bd_pins axi_gpio_13/gpio2_io_o] [get_bd_pins gh_h_cat/In0]
    connect_bd_net [get_bd_pins sl_h_hi/Dout]           [get_bd_pins gh_h_cat/In1]
    connect_bd_net [get_bd_pins gh_h_cat/dout]          [get_bd_pins pg_re_0/m_h]
}

puts "READENGINE-WARP: integration block complete (pg_warp_top + 6-coeff GPIO + sel)"
