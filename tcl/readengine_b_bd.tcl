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
# MM2S-only: disable the S2MM (write) channel via c_enable_s2mm 0 (c_include_*
# is the channel TYPE and can't be "Omit" in this IP version; c_enable_* gates it).
set_property -dict [list \
    CONFIG.c_include_mm2s {Full} \
    CONFIG.c_enable_mm2s {1} \
    CONFIG.c_enable_s2mm {0} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {256} \
    CONFIG.c_m_axi_mm2s_addr_width {32} \
    CONFIG.c_include_mm2s_stsfifo {true} \
] [get_bd_cells re_datamover]

# DataMover memory-path → its own smartconnect → PS S_AXI_HP1
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc_mem2
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells axi_sc_mem2]
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
#   gpio_a ch1 = {4'b0, out_h[11:0], 4'b0, out_w[11:0]}   ch2 = {pos_y(s12), pos_x(s12)}  (SIGNED)
#   gpio_b ch1 = {h_step_frac, h_step_int}                ch2 = {v_step_frac, v_step_int}
#   gpio_c ch1 = {8'b0, matte_rgb[23:0]}
#            ch2 = {4'b0, filt_h@27, src_row0[11:0]@15, src_col0[11:0]@3, blend[1:0]@1, mux_sel@0}
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
        CONFIG.DOUT_WIDTH $w] [get_bd_cells $name]
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
re_slice sl_blend  axi_gpio_10 gpio2_io_o 2  1   ;# Mackin blend_mode (ch2 bits[2:1], 2-bit: 0/1/2)
re_slice sl_src_c  axi_gpio_10 gpio2_io_o 14 3   ;# DDA src_col0 seed (ch2 bits[14:3], 12-bit)
re_slice sl_src_r  axi_gpio_10 gpio2_io_o 26 15  ;# DDA src_row0 seed (ch2 bits[26:15], 12-bit)
re_slice sl_filt_h axi_gpio_10 gpio2_io_o 27 27  ;# read-side 2-tap H anti-alias enable (ch2 bit27)

# ---------------------------------------------------------------------------
# Read-engine compositor cell
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference pg_read_engine_top pg_re_0
# Full-master route-B: source master is the FULL 1920×1080 (input scaler
# bypassed → S2MM stores full frame), scaled into the 1280×720 output raster.
#   IN_W/IN_H   = master dims (1920×1080)
#   OUT_W/OUT_H = output raster (1280×720, default)
#   STRIDE      = 1920*3 = 5760 bytes/master-line
#   SLOT_STRIDE = FRAME_BYTES(5760*1080) + STRIDE guard = 6226560
set_property -dict [list CONFIG.IN_W {1920} CONFIG.IN_H {1080} \
    CONFIG.STRIDE {5760} CONFIG.SLOT_STRIDE {6226560} \
    CONFIG.NUM_FRAMES {7}] [get_bd_cells pg_re_0]
# #28: NUM_FRAMES 5->7 (MUST equal axi_vdma_0 c_num_fstores) so the cadence lag can
# reach 2 -> Mackin blend has a completed S+1 partner. 7x6226560 = 43.6MB from
# FRAME_BUF_BASE (0x10000000), well within the 1GB DDR.
connect_bd_net $pclk  [get_bd_pins pg_re_0/clk]
connect_bd_net $prstn [get_bd_pins pg_re_0/rstn]
# Tap S2MM's real framestore pointer (exposed even with internal genlock ON,
# so the VDMA genlock config is UNTOUCHED — passthrough unaffected). pg_genlock
# CDCs it (FCLK_CLK1 → pixel clock) and reads frame_ptr-READ_DELAY.
connect_bd_net [get_bd_pins axi_vdma_0/s2mm_frame_ptr_out] [get_bd_pins pg_re_0/frame_ptr]
connect_bd_net [get_bd_pins v_tc_tx/vsync_out]            [get_bd_pins pg_re_0/out_vsync]
connect_bd_net [get_bd_pins sl_out_w/Dout]  [get_bd_pins pg_re_0/out_w_win]
connect_bd_net [get_bd_pins sl_out_h/Dout]  [get_bd_pins pg_re_0/out_h_win]
connect_bd_net [get_bd_pins sl_pos_x/Dout]  [get_bd_pins pg_re_0/pos_x]
connect_bd_net [get_bd_pins sl_pos_y/Dout]  [get_bd_pins pg_re_0/pos_y]
connect_bd_net [get_bd_pins sl_src_c/Dout]  [get_bd_pins pg_re_0/src_col0]
connect_bd_net [get_bd_pins sl_src_r/Dout]  [get_bd_pins pg_re_0/src_row0]
connect_bd_net [get_bd_pins sl_filt_h/Dout] [get_bd_pins pg_re_0/filt_h]
connect_bd_net [get_bd_pins sl_hsi/Dout]    [get_bd_pins pg_re_0/h_step_int]
connect_bd_net [get_bd_pins sl_hsf/Dout]    [get_bd_pins pg_re_0/h_step_frac]
connect_bd_net [get_bd_pins sl_vsi/Dout]    [get_bd_pins pg_re_0/v_step_int]
connect_bd_net [get_bd_pins sl_vsf/Dout]    [get_bd_pins pg_re_0/v_step_frac]
connect_bd_net [get_bd_pins sl_matte/Dout]  [get_bd_pins pg_re_0/matte_rgb]
connect_bd_net [get_bd_pins sl_blend/Dout]  [get_bd_pins pg_re_0/blend_mode]
# DataMover command + data + status streams
connect_bd_intf_net [get_bd_intf_pins pg_re_0/m_axis_cmd] [get_bd_intf_pins re_datamover/S_AXIS_MM2S_CMD]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXIS_MM2S] [get_bd_intf_pins pg_re_0/s_axis_dm]
connect_bd_intf_net [get_bd_intf_pins re_datamover/M_AXIS_MM2S_STS] [get_bd_intf_pins pg_re_0/s_axis_sts]

# ---------------------------------------------------------------------------
# 2:1 AXIS mux before the color stack (sel default 0 = VDMA MM2S passthrough)
# ---------------------------------------------------------------------------
create_bd_cell -type module -reference axis_mux2 re_mux
connect_bd_net $pclk [get_bd_pins re_mux/clk]
connect_bd_net [get_bd_pins sl_sel/Dout] [get_bd_pins re_mux/sel]
# remove the MM2S debug ILA so its tap doesn't entangle the reroute
catch { delete_bd_cell [get_bd_cells ila_mm2s_out] }
# detach MM2S → color_saturation, reroute through the mux
delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins color_saturation_0/s_axis]]
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

# ---------------------------------------------------------------------------
# ILA instrumentation (2026-06-02) — pin the read-engine ghost: addressing vs
# beat-corruption vs aliasing. Both on the pixel clock ($pclk).
#   ila_re_dbg   : NATIVE 96-bit dbg_probe from pg_re_0 — src_col/src_row,
#                  a_valid/inwin/newrow, resident, up_pvalid/last, m_tvalid/ready,
#                  rd_data (buffer->out), up_pdata (unpack->buffer). Bit layout in
#                  hdl/pg_read_engine_top.v. Trigger on a_newrow to catch a row.
#   ila_re_beats : AXIS on the DataMover M_AXIS_MM2S (64-bit beats from DDR) —
#                  confirms the source data ARRIVES clean (separates "read wrong"
#                  from "process wrong").
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila ila_re_dbg
set_property CONFIG.C_MON_TYPE {NATIVE} [get_bd_cells ila_re_dbg]
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {1} \
    CONFIG.C_PROBE0_WIDTH  {192} \
    CONFIG.C_DATA_DEPTH    {2048} \
    CONFIG.C_ADV_TRIGGER   {true} \
] [get_bd_cells ila_re_dbg]
# Diagnostics: print the ACTUAL pin names so we stop guessing the probe pin name.
puts "ILA-DBG: pg_re_0 dbg pins  = [get_bd_pins -quiet pg_re_0/dbg*]"
puts "ILA-DBG: ila_re_dbg pins   = [get_bd_pins -quiet ila_re_dbg/*]"
set _dbg_ok 0
if {![catch { connect_bd_net [get_bd_pins pg_re_0/dbg_probe] [get_bd_pins ila_re_dbg/probe0] }]} {
    set _dbg_ok 1
}
if {$_dbg_ok} {
    connect_bd_net $pclk [get_bd_pins ila_re_dbg/clk]
    puts "ILA-DBG: dbg_probe -> ila_re_dbg/probe0 connected"
} else {
    # Probe pin name guess was wrong — remove the cell so the build still
    # completes (ila_re_beats stays). The pin dump above gives the real names.
    puts "ILA-DBG: probe0 connect failed; removing ila_re_dbg (see pin dump). Beats ILA retained."
    catch { delete_bd_cell [get_bd_cells ila_re_dbg] }
}

# ila_re_beats DROPPED for build #14: the 192-bit dbg_probe now carries up_pdata
# (data-in from DDR) + push_data (data-out), so the separate 64-bit beats ILA is
# redundant — and dropping it frees the BRAM the widened dbg_probe needs.

puts "READENGINE-B: integration block complete (+ILA: ila_re_dbg 192-bit prefetch-state)"

# ---------------------------------------------------------------------------
# δ-measurement diag (2026-06-03): route axis_to_vid_io_0/predrain_snap onto the
# DEAD scaler ch1 of axi_gpio_2 (gpio_io_i). In route-B the scaler is muxed out,
# so its {v_tlast,h_tlast} diag on ch1 reads garbage — free to repurpose. fp_mon
# stays on ch2 (gpio2_io_i) as the frame_ptr health bit. Firmware reads ch1:
#   ch1[15:0]  = δ  (active pixels before SOF emits = the per-line wrap offset)
#   ch1[31:16] = of those, stale beats discarded ("drain"); rest = starves.
# Confirms/quantifies the pixel-wrap diagnosis before we touch axis_to_vid_io RTL.
# ---------------------------------------------------------------------------
delete_bd_objs [get_bd_nets -of_objects [get_bd_pins axi_gpio_2/gpio_io_i]]
connect_bd_net [get_bd_pins axis_to_vid_io_0/predrain_snap] [get_bd_pins axi_gpio_2/gpio_io_i]
puts "READENGINE-B: predrain_snap (δ) -> axi_gpio_2 ch1 (scaler diag repurposed)"

# Blend telemetry (#27): route pg_re_0/dbg_blend_snap (16b, blended frames/sec) onto
# axi_gpio_2 ch2 (gpio2_io_i), replacing fp_mon — its Gray-monotonicity job is done.
# Zero-extend 16->32 via xlconcat. Firmware reads ch2[15:0] = BLEND frames/sec.
delete_bd_objs [get_bd_nets -of_objects [get_bd_pins axi_gpio_2/gpio2_io_i]]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat blend_tel_concat
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {16} CONFIG.IN1_WIDTH {16}] [get_bd_cells blend_tel_concat]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant blend_tel_zero
set_property -dict [list CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {0}] [get_bd_cells blend_tel_zero]
connect_bd_net [get_bd_pins pg_re_0/dbg_blend_snap] [get_bd_pins blend_tel_concat/In0]
connect_bd_net [get_bd_pins blend_tel_zero/dout]    [get_bd_pins blend_tel_concat/In1]
connect_bd_net [get_bd_pins blend_tel_concat/dout]  [get_bd_pins axi_gpio_2/gpio2_io_i]
puts "READENGINE-B: dbg_blend_snap -> axi_gpio_2 ch2 (fp_mon repurposed for blend telemetry)"
