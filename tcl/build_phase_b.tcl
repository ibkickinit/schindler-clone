# build_phase_b.tcl — Phase B HDMI passthrough through DDR3 frame buffer.
#
# Replaces the direct pixel wire from Phase A with an AXI4-Stream Video pipeline:
#   HDMI RX → dvi2rgb → Video In to AXI4-Stream → AXI VDMA (S2MM) → DDR3
#   DDR3 → AXI VDMA (MM2S) → AXI4-Stream to Video Out → rgb2dvi → HDMI TX
#
# Brings up the Zynq PS for DDR3 controller + VDMA register control. PS firmware
# (bare-metal app) lives separately in sw/phase-b/ — built and programmed via
# XSCT after the bitstream lands. This script only produces .bit + .xsa.
#
# Run from anywhere:
#   source /tools/Xilinx/2025.2/Vivado/settings64.sh
#   export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
#   export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
#   vivado -mode batch -nojournal -log build_phase_b.log -source <repo>/tcl/build_phase_b.tcl

set project_name "phase-b-vdma-passthrough"
set bd_name      "phase_b_bd"
set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set build_dir    [file join $project_root build]
set vivado_dir   [file join $build_dir $project_name]

file delete -force $vivado_dir
file mkdir $build_dir

if {[info exists ::env(BOARD_PARTS_REPO_PATHS)]} {
    set_param board.repoPaths $::env(BOARD_PARTS_REPO_PATHS)
}
# For Phase B we register the *parent* of ip/ + if/ so Vivado discovers both
# the IP cores (dvi2rgb, rgb2dvi) AND the Digilent interface definitions
# (digilentinc.com:interface:tmds_rtl:1.0). Phase A only needed the IPs because
# raw port pins were used; Phase B uses interface ports on the BD top.
if {[info exists ::env(DIGILENT_IP_REPO_PATH)]} {
    set digilent_ip_path $::env(DIGILENT_IP_REPO_PATH)
    set digilent_lib_path [file dirname $digilent_ip_path]
} else {
    set digilent_lib_path [file join $::env(HOME) fpga vivado-library]
    set digilent_ip_path  [file join $digilent_lib_path ip]
}
if {![file isdirectory $digilent_ip_path]} {
    puts "ERROR: Digilent IP repo not found at $digilent_ip_path"
    exit 1
}

create_project $project_name $vivado_dir -part xc7z020clg400-1
set board [lindex [get_board_parts -filter {NAME =~ "*zybo-z7-20*"}] 0]
if {$board eq ""} { puts "ERROR: Zybo Z7-20 board file not found"; exit 1 }
set_property board_part $board [current_project]
set_property ip_repo_paths $digilent_lib_path [current_project]
update_ip_catalog

# Add custom HDL sources used as module references inside the BD.
add_files -norecurse [file join $project_root hdl axis_to_vid_io.v]
add_files -norecurse [file join $project_root hdl scaler_passthrough.v]
add_files -norecurse [file join $project_root hdl scaler_crop_bypass.v]  ;# iter4h bisection
add_files -norecurse [file join $project_root hdl scaler_bypass_1080p.v] ;# iter5 1080p passthrough
add_files -norecurse [file join $project_root hdl scaler_top.v]
add_files -norecurse [file join $project_root hdl scaler_h.v]
add_files -norecurse [file join $project_root hdl scaler_v.v]
add_files -norecurse [file join $project_root hdl scaler_coeffs_h.v]
add_files -norecurse [file join $project_root hdl scaler_coeffs_v.v]
# Phase D iter-3 — firmware-side VTC alignment via AXI GPIO + 2-FF input sync
add_files -norecurse [file join $project_root hdl axi_sync_inputs.v]
# Coefficient hex files for $readmemh — Vivado adds them to source list so
# they're visible from the OOC synth working directory.
add_files -norecurse [file join $project_root hdl scaler_coeffs_h.hex]
add_files -norecurse [file join $project_root hdl scaler_coeffs_v.hex]
set_property FILE_TYPE "Memory Initialization Files" [get_files -all scaler_coeffs_h.hex]
set_property FILE_TYPE "Memory Initialization Files" [get_files -all scaler_coeffs_v.hex]
puts "ADD HDL: scaler_top.v + scaler_h.v + scaler_v.v + scaler_coeffs_{h,v}.v/.hex"

puts "STAGE_OK: project + board + IP catalog"

# =============================================================================
# Block Design
# =============================================================================
create_bd_design $bd_name
current_bd_design $bd_name

# ---- External ports on the BD top --------------------------------------------
create_bd_port -dir I -type clk -freq_hz 125000000 sys_clk
create_bd_port -dir I -type rst btn_rst
set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_ports btn_rst]

create_bd_intf_port -mode Slave  -vlnv digilentinc.com:interface:tmds_rtl:1.0 hdmi_rx_tmds
create_bd_intf_port -mode Master -vlnv digilentinc.com:interface:tmds_rtl:1.0 hdmi_tx_tmds
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:iic_rtl:1.0 hdmi_rx_ddc
create_bd_port -dir O hdmi_rx_hpd
create_bd_port -dir I hdmi_tx_hpd

# 4 status LEDs composed inside the BD (see xlconcat below)
create_bd_port -dir O -from 3 -to 0 leds

# =============================================================================
# Zynq PS — Zybo Z7-20 board preset wires DDR + FIXED_IO + standard clocks
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 zynq_ps
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config { make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable" } \
    [get_bd_cells zynq_ps]
set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {150} \
    CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {200} \
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_EN_CLK2_PORT {1} \
] [get_bd_cells zynq_ps]
puts "STAGE_OK: Zynq PS configured"

# =============================================================================
# Clocking Wizard — output pixel clock, FREE-RUNNING from PS FCLK_CLK0
# =============================================================================
# Phase D iter-4c: REVERT iter-1 genlock. Output PixelClk now sourced from
# PS FCLK_CLK0 (100 MHz, stable PS-derived) and multiplied to ~74.25 MHz
# for 720p output. This is the scaffolding required for actual frame-rate
# conversion (FRC) — output rate now INDEPENDENT of source rate, so the
# downstream FRC engine can insert/drop frames per cadence rules.
#
# Visible effect WITHOUT an FRC engine yet:
#   - Source==Output rate (60p→60Hz): ~30 ppm drift between source and
#     output crystals → picture rolls slowly (1 line per ~1.4 sec). Will
#     be eliminated by iter-4d's frame insert/drop logic.
#   - Source!=Output rate (24p/30p/50p sources): wholesale tearing or
#     stuttering. Expected — FRC engine is what handles those.
#
# MMCM auto-config for 100→74.25 MHz: clk_wiz IP picks MULT_F=11.875,
# DIVIDE=1, OUT_DIVIDE_F=16 → VCO=1187.5 MHz (in 600-1200 spec), output
# = 1187.5/16 = 74.21875 MHz (~30 ppm off exact 74.25 — well within
# HDMI/CEA-861 tolerance).
#
# Robustness benefit: output no longer dies when HDMI source disconnects
# (clk continues from PS regardless). VTC keeps generating sync, monitor
# stays locked (just shows whatever was last in VDMA's frame buffer).
#
# Hardcoded to 720p output. If we ever need to switch output resolution
# at runtime, clk_wiz needs dynamic-reconfig wiring + firmware.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_pixclk_out
set_property -dict [list \
    CONFIG.PRIMITIVE {MMCM} \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {74.250} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {true} \
] [get_bd_cells clk_wiz_pixclk_out]
# clk_in1 ← dvi2rgb_0/PixelClk is wired AFTER dvi2rgb_0 is created
# (search for "GENLOCK_WIRE" below).
# clk_wiz exposes 'reset' (active-high) when USE_RESET=true. Derive from
# btn_rst which is the PL-side reset button (also active-high).
connect_bd_net [get_bd_ports btn_rst] [get_bd_pins clk_wiz_pixclk_out/reset]

# =============================================================================
# Clocking Wizard — 125 MHz sys_clk → 200 MHz refclk for dvi2rgb's IDELAYCTRL
# =============================================================================
# Reverted to PL clk_wiz (PLL) for IDELAYCTRL refclk. Tried PS FCLK_CLK2 at
# 200 MHz — counterintuitively had MORE jitter than the PL PLL (PS FCLK
# goes through multiple division stages from IO_PLL), making dvi2rgb's
# pLocked even more intermittent than with the PL clk_wiz.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_ref
set_property -dict [list \
    CONFIG.PRIMITIVE {PLL} \
    CONFIG.PRIM_IN_FREQ {125.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.USE_LOCKED {true} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_HIGH} \
    CONFIG.RESET_PORT {reset} \
] [get_bd_cells clk_wiz_ref]
connect_bd_net [get_bd_ports sys_clk]  [get_bd_pins clk_wiz_ref/clk_in1]
connect_bd_net [get_bd_ports btn_rst]  [get_bd_pins clk_wiz_ref/reset]
connect_bd_net [get_bd_pins clk_wiz_ref/locked] [get_bd_ports hdmi_rx_hpd]

# =============================================================================
# dvi2rgb (HDMI RX)
# =============================================================================
create_bd_cell -type ip -vlnv digilentinc.com:ip:dvi2rgb dvi2rgb_0
set_property -dict [list \
    CONFIG.kEmulateDDC      {true} \
    CONFIG.kRstActiveHigh   {true} \
    CONFIG.kAddBUFG         {true} \
    CONFIG.kClkRange        {1} \
    CONFIG.kEdidFileName    {dgl_1080p_cea.data} \
] [get_bd_cells dvi2rgb_0]
# Re-enable kDebug=true here when ILA capture of dvi2rgb internals is needed
# (see tcl/capture_dvi2rgb_lock.tcl). The 2026-05-13 source-side flicker
# investigation used that feature to confirm pLocked was dropping because of
# upstream TMDS clock loss, not anything inside the FPGA.
# kClkRange=1 for 1080p60 (148.5 MHz pixel clock) — MMCM VCO = 742.5 MHz in
# spec. Was kClkRange=2 (VCO 1485 MHz) → over Artix-7 -1's 1200 MHz max →
# marginal recovered PixelClk → downstream rgb2dvi sees jittery input clock
# regardless of its own settings.

connect_bd_intf_net [get_bd_intf_ports hdmi_rx_tmds] [get_bd_intf_pins dvi2rgb_0/TMDS]
connect_bd_intf_net [get_bd_intf_ports hdmi_rx_ddc]  [get_bd_intf_pins dvi2rgb_0/DDC]
connect_bd_net [get_bd_pins clk_wiz_ref/clk_out1] [get_bd_pins dvi2rgb_0/RefClk]
connect_bd_net [get_bd_ports btn_rst]             [get_bd_pins dvi2rgb_0/aRst]

# dvi2rgb's PixelClk output advertises 100 MHz in BD metadata by default
# (IP-package default for kClkRange=2). With kClkRange=1 set above, the
# actual recovered clock is 148.5 MHz at 1080p60. Override the metadata
# so downstream clk_wiz_pixclk_out's clk_in1 FREQ_HZ check passes.
set_property CONFIG.FREQ_HZ 148500000 [get_bd_pins dvi2rgb_0/PixelClk]

# GENLOCK_WIRE — Phase D iter-4c: clk_wiz_pixclk_out's input is PS FCLK_CLK0
# (100 MHz, stable PS-derived), NOT dvi2rgb's recovered HDMI PixelClk. Output
# now free-runs at ~74.25 MHz independent of source. Scaffolding for FRC.
# See clk_wiz_pixclk_out block above for rationale.
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0] [get_bd_pins clk_wiz_pixclk_out/clk_in1]

# =============================================================================
# Video In to AXI4-Stream — parallel video → AXIS
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:v_vid_in_axi4s v_vid_in_axi4s_0
set_property -dict [list CONFIG.C_HAS_ASYNC_CLK {0}] [get_bd_cells v_vid_in_axi4s_0]
# Connect dvi2rgb → v_vid_in_axi4s signals individually. The connect_bd_intf_net
# version (dvi2rgb_0/RGB ↔ v_vid_in_axi4s_0/vid_io_in) only auto-wires vid_data;
# dvi2rgb's RGB interface bundle doesn't include the sync signals, so the
# vid_active_video / vid_hsync / vid_vsync inputs on v_vid_in_axi4s default to
# 0. Without sync, v_vid_in_axi4s never generates TLAST/TUSER → VDMA S2MM never
# advances its frame pointer → only slot 0 ever sees fresh data, stale data
# rotates on the output. (2026-05-14 — caught after Phase B "worked" but the
# image drifted visibly across slots.)
connect_bd_net [get_bd_pins dvi2rgb_0/vid_pData]  [get_bd_pins v_vid_in_axi4s_0/vid_data]
connect_bd_net [get_bd_pins dvi2rgb_0/vid_pVDE]   [get_bd_pins v_vid_in_axi4s_0/vid_active_video]
connect_bd_net [get_bd_pins dvi2rgb_0/vid_pHSync] [get_bd_pins v_vid_in_axi4s_0/vid_hsync]
connect_bd_net [get_bd_pins dvi2rgb_0/vid_pVSync] [get_bd_pins v_vid_in_axi4s_0/vid_vsync]

# =============================================================================
# AXI VDMA — frame buffer through DDR3
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma axi_vdma_0
set_property -dict [list \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_num_fstores {3} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {24} \
    CONFIG.c_m_axis_mm2s_tdata_width {24} \
    CONFIG.c_include_sg {0} \
    CONFIG.c_s2mm_genlock_mode {2} \
    CONFIG.c_mm2s_genlock_mode {3} \
    CONFIG.c_mm2s_genlock_src {0} \
    CONFIG.c_include_internal_genlock {1} \
    CONFIG.c_mm2s_genlock_repeat_en {1} \
    CONFIG.c_use_mm2s_fsync {1} \
    CONFIG.c_flush_on_fsync {0} \
] [get_bd_cells axi_vdma_0]
# iter4h Path 2 result (2026-05-17): VSIZE over-allocate in firmware
# (VSIZE=747 instead of 720) eliminates the bottom-bars artifact without
# needing s2mm_fsync wiring. fsync wiring was tested and merely shifted
# the bug by 1 row, not fixed it. S2MM uses TUSER on AXIS for frame
# boundary detection (default Xilinx video pipeline pattern). Keep
# c_use_s2mm_fsync=0 (default for axi_vdma_v6_3).
set_property -dict [list CONFIG.c_use_s2mm_fsync {0}] [get_bd_cells axi_vdma_0]
# iter5 (2026-05-17): c_num_fstores 3 → 5. Drift headroom per
# [[xilinx-vdma-drift-limits]]. At 1080p RGB this is ~14 MB extra DDR3;
# well within Zybo's 1 GB. FrameDelay=1 + 3 framestores was brittle under
# sustained drift; 5 buys ~3× margin without changing the genlock model.
# Phase D iter-4d-3 step 2 (2026-05-16): upgrade from plain to Dynamic Genlock.
#   c_s2mm_genlock_mode 0->2  (Master -> Dynamic Master)
#   c_mm2s_genlock_mode 1->3  (Slave  -> Dynamic Slave)
# Mapping verified in /tools/Xilinx/.../axi_vdma_v6_3/component.xml:
#   0=Master, 1=Slave, 2=Dynamic Master, 3=Dynamic Slave.
# IP defaults are exactly S2MM=2 / MM2S=3 — the canonical FRC pairing.
# Dynamic Master "skips the frame buffers that Dynamic Slave is working on"
# (PG020); Slave follows by skipping/repeating per FrameDelay. This is what
# Xilinx's documented FRC path uses. Step 1's plain genlock (mode 0/1) left
# the slave with a static FB offset that drifted into S2MM under the 0.2%
# rate delta between source and free-running output, producing 1-2 tear
# lines per frame.
# repeat_en=1 makes the slave repeat the last good frame if it catches up
# to the master (S2MM completed faster than MM2S consumed) rather than
# tearing — important when output rate < source rate.
# AXIS widths set to 24 bits to match v_vid_in_axi4s (RGB888, 1 pixel/clock)
# and the adapter. Without these, MM2S defaults to 32-bit AXIS and you get
# TDATA_NUM_BYTES mismatch at the adapter — colors get scrambled via
# Vivado's auto pad/truncate.
# c_use_mm2s_fsync=1 exposes the mm2s_fsync input port. Wire VTC's fsync_out
# to it so MM2S's SOF aligns with VTC's frame start — this is what
# v_axi4s_vid_out's lock state machine needs: AXIS SOF arriving during VTC
# vblank. (S2MM stays free-running on the dvi2rgb side.)
# fsync wiring moved below — needs v_tc_tx cell to exist first
# =============================================================================
# Phase C.1 — polyphase scaler (8-tap H × 4-tap V, 1920×1080 → 1280×720)
# =============================================================================
# Replaces the C.0 scaler_passthrough placeholder. Sits between v_vid_in_axi4s_0
# and VDMA S2MM. Downscales 1080p to 720p before storage. DDR3 stores 1280×720
# frames; MM2S reads them at the 74.25 MHz output pixel clock.
# SCALER_MODULE selects the AXIS module instantiated as scaler_0 in the BD:
#   - scaler_top           — production: polyphase 1080→720 downscale.
#   - scaler_crop_bypass   — iter4h diagnostic: crops top-left 1280×720.
#   - scaler_bypass_1080p  — iter5 substrate test: full 1080p identity
#                            passthrough (NO scaling, NO cropping). Pairs
#                            with firmware FRAME_W=1920 FRAME_H=1080 and
#                            VTC TX MODE_1080P24 for 60→24 FRC validation.
# Default is iter5's bypass — current branch is iter5-wip. Override via env:
#   SCALER_MODULE=scaler_top vivado -mode batch -source <this>
if {[info exists ::env(SCALER_MODULE)]} { set SCALER_MODULE $::env(SCALER_MODULE) }
if {![info exists SCALER_MODULE]} { set SCALER_MODULE scaler_bypass_1080p }
puts "BUILD: using SCALER_MODULE=$SCALER_MODULE"
create_bd_cell -type module -reference $SCALER_MODULE scaler_0
connect_bd_intf_net [get_bd_intf_pins v_vid_in_axi4s_0/video_out] [get_bd_intf_pins scaler_0/s_axis]

# iter5-bisect-iter4d3: bypass AXIS FIFO — connect scaler directly to S2MM
# as in iter4d-3 (which shipped visually clean). FIFO is one of three iter4h
# additions being bisected to isolate the scroll cause.
connect_bd_intf_net [get_bd_intf_pins scaler_0/m_axis] [get_bd_intf_pins axi_vdma_0/S_AXIS_S2MM]

# =============================================================================
# Video Timing Controller — generates output sync timing
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:v_tc v_tc_tx
# Phase C.1 pivot — output is 720p (CEA-861 1280×720 progressive, 1650×750 frame).
# (iter4c-test1 tried V_TOTAL=1500 for 720p30 to test if MS2109 lock failure was
# rate-related — confirmed it wasn't, reverted to 720p60.)
set_property -dict [list \
    CONFIG.enable_detection {false} \
    CONFIG.enable_generation {true} \
    CONFIG.VIDEO_MODE {720p} \
    CONFIG.MAX_CLOCKS_PER_LINE {4096} \
    CONFIG.MAX_LINES_PER_FRAME {4096} \
    CONFIG.GEN_HACTIVE_SIZE {1280} \
    CONFIG.GEN_VACTIVE_SIZE {720} \
    CONFIG.GEN_HFRAME_SIZE {1650} \
    CONFIG.GEN_F0_VFRAME_SIZE {750} \
] [get_bd_cells v_tc_tx]

# =============================================================================
# iter4e: Video Timing Controller — DETECTOR — measures source dimensions
# =============================================================================
# Reads timing signals out of v_vid_in_axi4s_0/vtiming_out (which is itself
# driven by dvi2rgb's vid_p{VSync,HSync,VDE}) and exposes detected
# HACTIVE/VACTIVE/HTOTAL/VTOTAL via AXI-Lite registers (DASIZE @ 0x020,
# DVSIZE @ 0x034, DPOL @ 0x02C, DTSTAT @ 0x024). Firmware reads these to
# program scaler_0's runtime IN_W/IN_H via axi_gpio_1 below — eliminates
# hardcoded IN_W=1920/IN_H=1080 assumption.
#
# Detector clock = pclk_in (148.5 MHz) — same clock as v_vid_in_axi4s_0.
create_bd_cell -type ip -vlnv xilinx.com:ip:v_tc v_tc_rx
set_property -dict [list \
    CONFIG.enable_detection {true} \
    CONFIG.enable_generation {false} \
    CONFIG.MAX_CLOCKS_PER_LINE {4096} \
    CONFIG.MAX_LINES_PER_FRAME {4096} \
] [get_bd_cells v_tc_rx]
connect_bd_intf_net [get_bd_intf_pins v_vid_in_axi4s_0/vtiming_out] \
                    [get_bd_intf_pins v_tc_rx/vtiming_in]
# Detector clk wired to pclk_in alongside v_vid_in_axi4s_0/aclk below
# (s_axi_aclk + resetn also wired below alongside the other AXI-Lite cells)

# =============================================================================
# Custom AXIS → vid_io adapter (replaces v_axi4s_vid_out)
# =============================================================================
# v_axi4s_vid_out wouldn't reach LOCKED in our pipeline despite the AXIS and
# VTC vtiming both being valid. The custom adapter (hdl/axis_to_vid_io.v) is
# stateless — outputs an AXIS pixel during VTC active-video, zero otherwise,
# passing VTC's sync through unchanged. enable=pLocked gates the whole thing.
create_bd_cell -type module -reference axis_to_vid_io axis_to_vid_io_0
# Dual-clock refactor 2026-05-14: adapter is on the OUTPUT clock (clk_wiz_pixclk_out).
# Sync comes from VTC (also on output clock — no CDC needed for vtg_* inputs).
# enable comes from the output-clock MMCM's locked signal (output-clock-domain ready).
# The mm2s_fsync_pulse output is unused now; MM2S takes fsync from VTC's fsync_out
# (both on output clock domain).
connect_bd_net [get_bd_pins clk_wiz_pixclk_out/locked] [get_bd_pins axis_to_vid_io_0/enable]
connect_bd_net [get_bd_pins v_tc_tx/active_video_out] [get_bd_pins axis_to_vid_io_0/vtg_active_video]
connect_bd_net [get_bd_pins v_tc_tx/hsync_out]        [get_bd_pins axis_to_vid_io_0/vtg_hsync]
connect_bd_net [get_bd_pins v_tc_tx/vsync_out]        [get_bd_pins axis_to_vid_io_0/vtg_vsync]
connect_bd_net [get_bd_pins v_tc_tx/hblank_out]       [get_bd_pins axis_to_vid_io_0/vtg_hblank]
connect_bd_net [get_bd_pins v_tc_tx/vblank_out]       [get_bd_pins axis_to_vid_io_0/vtg_vblank]
# AXIS in from VDMA MM2S → adapter (both on output clock)
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins axis_to_vid_io_0/s_axis]
# fsync: VTC's frame-start pulse → VDMA MM2S so MM2S SOF aligns with VTC frame.
# VTC is free-running on output clock — output frame rate is exactly
# clk_wiz_pixclk_out/(2200*1125) = 60.000 Hz. Slow walk vs source is
# acceptable; Phase D (FRC) will handle proper rate-matching.
connect_bd_net [get_bd_pins v_tc_tx/fsync_out] [get_bd_pins axi_vdma_0/mm2s_fsync]
# S2MM fsync was tested in iter4h and rejected — over-allocating S2MM VSIZE
# in firmware (747 instead of 720) is the actual fix for the bottom-bars
# artifact. S2MM uses TUSER on AXIS for frame boundary, no fsync needed.
# See memory: schindler-bottom-bars-artifact.

# =============================================================================
# rgb2dvi (HDMI TX) — same MMCM/kClkRange=2 lessons as Phase A
# =============================================================================
create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi rgb2dvi_0
set_property -dict [list \
    CONFIG.kGenerateSerialClk {true} \
    CONFIG.kClkPrimitive      {MMCM} \
    CONFIG.kClkRange          {2} \
    CONFIG.kRstActiveHigh     {true} \
] [get_bd_cells rgb2dvi_0]
# Phase C.1 pivoted to 720p output (74.25 MHz). rgb2dvi only accepts
# kClkRange = 1, 2, 3 — 480p (27 MHz) is below its supported pixel-clock
# range. kClkRange=2 → MULT_F=10 → VCO=742.5 MHz ✓ for 74.25 MHz pixel clock.
# Proper Phase B pipeline: dvi2rgb → v_vid_in_axi4s → VDMA S2MM → DDR3 →
# VDMA MM2S → axis_to_vid_io adapter → rgb2dvi. Both data and sync come from
# the adapter, which gates AXIS data on VTC's active_video and registers all
# outputs on PixelClk.
connect_bd_net [get_bd_pins axis_to_vid_io_0/vid_data]         [get_bd_pins rgb2dvi_0/vid_pData]
connect_bd_net [get_bd_pins axis_to_vid_io_0/vid_active_video] [get_bd_pins rgb2dvi_0/vid_pVDE]
connect_bd_net [get_bd_pins axis_to_vid_io_0/vid_hsync]        [get_bd_pins rgb2dvi_0/vid_pHSync]
connect_bd_net [get_bd_pins axis_to_vid_io_0/vid_vsync]        [get_bd_pins rgb2dvi_0/vid_pVSync]
connect_bd_intf_net [get_bd_intf_pins rgb2dvi_0/TMDS] [get_bd_intf_ports hdmi_tx_tmds]
# rgb2dvi.aRst wiring is deferred until after rst_pixclk_out is created
# (search for "iter-4c-test2 rgb2dvi reset hookup" below).

# =============================================================================
# Clock domain wiring — single PixelClk domain for the entire video pipeline.
#
# Earlier we split AXIS to FCLK_CLK1 to avoid a VDMA-reset hang at boot when
# PixelClk wasn't yet running. That fixed VDMA init, but the resulting AXIS
# (150 MHz) vs vid_io_out (148.5 MHz) rate mismatch prevented v_axi4s_vid_out
# from reaching a stable lock — the FIFO drift breaks the IP's expected timing
# alignment between AXIS SOF and vtiming_in SOF.
#
# Single-clock alternative: everything on the recovered PixelClk. Resolves the
# rate mismatch. The VDMA-reset-hang issue is sidestepped by gating PS-side
# init until dvi2rgb has reported pLocked (PS app sleeps before VDMA init).
# =============================================================================
# Dual-clock video pipeline:
#   INPUT side  (dvi2rgb_0/PixelClk, source-recovered ~148.5 MHz, locked to source):
#       dvi2rgb → v_vid_in_axi4s → VDMA S2MM AXIS → [VDMA CDC] → DDR3
#   OUTPUT side (clk_wiz_pixclk_out/clk_out1 = 148.5 MHz, PS-derived, source-independent):
#       DDR3 → [VDMA CDC] → VDMA MM2S AXIS → axis_to_vid_io → rgb2dvi
#       VTC also on output clock, free-running at 60 Hz exact
# VDMA handles the AXIS CDC internally (S2MM and MM2S AXIS clocks may differ
# from each other and from M_AXI clock — VDMA's frame buffer mediates).
set pclk_in  [get_bd_pins dvi2rgb_0/PixelClk]
set pclk_out [get_bd_pins clk_wiz_pixclk_out/clk_out1]
# Input side
connect_bd_net $pclk_in  [get_bd_pins v_vid_in_axi4s_0/aclk]
connect_bd_net $pclk_in  [get_bd_pins axi_vdma_0/s_axis_s2mm_aclk]
connect_bd_net $pclk_in  [get_bd_pins scaler_0/aclk]
# iter5-bisect-iter4d3: AXIS FIFO removed — clock wire not needed
connect_bd_net $pclk_in  [get_bd_pins v_tc_rx/clk]  ;# iter4e: detector on pclk_in
# Output side
connect_bd_net $pclk_out [get_bd_pins axi_vdma_0/m_axis_mm2s_aclk]
connect_bd_net $pclk_out [get_bd_pins axis_to_vid_io_0/clk]
connect_bd_net $pclk_out [get_bd_pins v_tc_tx/clk]
connect_bd_net $pclk_out [get_bd_pins rgb2dvi_0/PixelClk]

# =============================================================================
# Reset infrastructure
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_axi
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_mem
# proc_sys_reset for output clock domain (148.5 MHz from clk_wiz_pixclk_out).
# Used by VTC's resetn (gen-clock side) and any other output-clock-domain
# components that need a sync'd reset.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pixclk_out
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]     [get_bd_pins rst_axi/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1]     [get_bd_pins rst_mem/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_pixclk_out/clk_out1] [get_bd_pins rst_pixclk_out/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ps/FCLK_RESET0_N] [get_bd_pins rst_axi/ext_reset_in]
connect_bd_net [get_bd_pins zynq_ps/FCLK_RESET0_N] [get_bd_pins rst_mem/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_pixclk_out/locked] [get_bd_pins rst_pixclk_out/dcm_locked]
connect_bd_net [get_bd_pins zynq_ps/FCLK_RESET0_N]     [get_bd_pins rst_pixclk_out/ext_reset_in]

# iter-4c-test2 rgb2dvi reset hookup: hold rgb2dvi in reset until
# clk_wiz_pixclk_out has locked, so its internal MMCM doesn't race against an
# unstable PixelClk at boot. Previous wiring (btn_rst) deasserted at PL config,
# before the new PS-derived pixel clock had stabilized — rgb2dvi MMCM would
# try to lock during the unstable window and stay unlocked thereafter (no
# auto-retrigger). Output looked permanently dead to the HDMI capture stick
# (MS2109 fell back to internal bars test pattern). peripheral_reset is the
# active-high companion to peripheral_aresetn from the same proc_sys_reset; it
# stays high until dcm_locked (= clk_wiz_pixclk_out/locked) goes high.
connect_bd_net [get_bd_pins rst_pixclk_out/peripheral_reset] [get_bd_pins rgb2dvi_0/aRst]

# =============================================================================
# AXI-Lite control path: PS GP0 → 1×2 Interconnect → VDMA, VTC
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_ic_lite
# 6 master ports (iter4g expanded 5->6):
#   M00 = VDMA, M01 = VTC tx (generator), M02 = GPIO 0 (status inputs)
#   M03 = VTC rx (detector), M04 = GPIO 1 (scaler dim outputs)
#   M05 = GPIO 2 (iter4g diagnostic counters, new)
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6}] [get_bd_cells axi_ic_lite]
connect_bd_intf_net [get_bd_intf_pins zynq_ps/M_AXI_GP0]     [get_bd_intf_pins axi_ic_lite/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M00_AXI]   [get_bd_intf_pins axi_vdma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M01_AXI]   [get_bd_intf_pins v_tc_tx/ctrl]
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M03_AXI]   [get_bd_intf_pins v_tc_rx/ctrl]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins zynq_ps/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_ic_lite/ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_ic_lite/S00_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_ic_lite/M00_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_ic_lite/M01_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_ic_lite/M02_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_ic_lite/M03_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_ic_lite/M04_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_ic_lite/M05_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins axi_vdma_0/s_axi_lite_aclk]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins v_tc_tx/s_axi_aclk]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]    [get_bd_pins v_tc_rx/s_axi_aclk]
connect_bd_net [get_bd_pins rst_axi/interconnect_aresetn] [get_bd_pins axi_ic_lite/ARESETN]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite/S00_ARESETN]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite/M00_ARESETN]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite/M01_ARESETN]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite/M02_ARESETN]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite/M03_ARESETN]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite/M04_ARESETN]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_ic_lite/M05_ARESETN]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins axi_vdma_0/axi_resetn]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins v_tc_tx/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]   [get_bd_pins v_tc_rx/s_axi_aresetn]
# Pixel-side reset wiring.
# VTC's gen-clk side now runs on the OUTPUT clock — use the output-clock
# proc_sys_reset so the reset is synchronous to VTC's clk.
# v_vid_in_axi4s is on the input (dvi2rgb) PixelClk; rst_axi (FCLK_CLK0) is
# async to it but the IP handles its own internal reset synchronization.
connect_bd_net [get_bd_pins rst_pixclk_out/peripheral_aresetn] [get_bd_pins v_tc_tx/resetn]
# VTC_rx detector also on pclk_in — reset comes from axi (input-side IP)
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]        [get_bd_pins v_tc_rx/resetn]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]        [get_bd_pins v_vid_in_axi4s_0/aresetn]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]        [get_bd_pins scaler_0/aresetn]
# iter5-bisect-iter4d3: AXIS FIFO removed — reset wire not needed

# =============================================================================
# Memory path: VDMA M_AXI ports → SmartConnect → PS S_AXI_HP0
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc_mem
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells axi_sc_mem]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_S2MM] [get_bd_intf_pins axi_sc_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_MM2S] [get_bd_intf_pins axi_sc_mem/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc_mem/M00_AXI]    [get_bd_intf_pins zynq_ps/S_AXI_HP0]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins zynq_ps/S_AXI_HP0_ACLK]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins axi_vdma_0/m_axi_s2mm_aclk]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins axi_vdma_0/m_axi_mm2s_aclk]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins axi_sc_mem/aclk]
connect_bd_net [get_bd_pins rst_mem/peripheral_aresetn] [get_bd_pins axi_sc_mem/aresetn]

# =============================================================================
# LED composition: leds = {hdmi_tx_hpd, vid_out_locked, rx_locked, mmcm_locked}
#
# LD2 now shows v_axi4s_vid_out's `locked` status — high when the TX-side AXIS-
# to-pixel adapter has aligned to both the AXIS data stream from VDMA and the
# vtiming_in strobes from the VTC. This is the most diagnostic single signal
# for "is the AXIS pipeline producing valid video to rgb2dvi" — without it,
# we're blind to whether the pipeline is alive end-to-end.
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat led_concat
set_property -dict [list \
    CONFIG.NUM_PORTS {4} \
    CONFIG.IN0_WIDTH {1} \
    CONFIG.IN1_WIDTH {1} \
    CONFIG.IN2_WIDTH {1} \
    CONFIG.IN3_WIDTH {1} \
] [get_bd_cells led_concat]
connect_bd_net [get_bd_pins clk_wiz_ref/locked]    [get_bd_pins led_concat/In0]
connect_bd_net [get_bd_pins dvi2rgb_0/pLocked]    [get_bd_pins led_concat/In1]
connect_bd_net [get_bd_pins v_tc_tx/active_video_out] [get_bd_pins led_concat/In2]
connect_bd_net [get_bd_ports hdmi_tx_hpd]         [get_bd_pins led_concat/In3]
connect_bd_net [get_bd_pins led_concat/dout]      [get_bd_ports leds]

# =============================================================================
# Phase D iter-3 — firmware-side VTC alignment via AXI GPIO + CDC
# =============================================================================
# Earlier iters (3a/b/c/d) tried hardware gating of VTC's fsync_in or gen_clken.
# Neither produced deterministic alignment because the VTC generator's counter
# start is governed by firmware's CTL register write (SW=0->1 + RU=1 propagates
# shadow regs), and firmware boot timing varies per power-on. Approach: expose
# dvi2rgb's pLocked and vid_pVSync via an AXI GPIO so firmware can poll for a
# source vsync rising edge, then immediately write CTL — aligning CTL-write
# timing to source vsync within a few microseconds.
#
# 2-FF CDC of the two source-domain signals into FCLK_CLK0 domain. Pure-level
# signals, slow-changing — 2 FFs with ASYNC_REG=TRUE on q1 is plenty.
create_bd_cell -type module -reference axi_sync_inputs axi_sync_inputs_0
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]              [get_bd_pins axi_sync_inputs_0/axi_clk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]     [get_bd_pins axi_sync_inputs_0/axi_rstn]
connect_bd_net [get_bd_pins dvi2rgb_0/vid_pVSync]           [get_bd_pins axi_sync_inputs_0/vsync_async]
connect_bd_net [get_bd_pins dvi2rgb_0/pLocked]              [get_bd_pins axi_sync_inputs_0/plocked_async]
# Phase D iter-4d-1: output-side observability for FRC cadence engine
connect_bd_net [get_bd_pins v_tc_tx/vsync_out]              [get_bd_pins axi_sync_inputs_0/vsync_out_async]
connect_bd_net [get_bd_pins clk_wiz_pixclk_out/locked]      [get_bd_pins axi_sync_inputs_0/pclk_locked_async]
# iter4g DIAG: 64-bit counter bus = scaler_0/diag_counts (48-bit, low) +
# axis_to_vid_io_0/mm2s_tlast_snap (16-bit, high). CDC'd in axi_sync_inputs.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat diag_concat
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {48} CONFIG.IN1_WIDTH {16}] \
    [get_bd_cells diag_concat]
connect_bd_net [get_bd_pins scaler_0/diag_counts]               [get_bd_pins diag_concat/In0]
connect_bd_net [get_bd_pins axis_to_vid_io_0/mm2s_tlast_snap]   [get_bd_pins diag_concat/In1]
connect_bd_net [get_bd_pins diag_concat/dout]                   [get_bd_pins axi_sync_inputs_0/diag_counts_async]

# AXI GPIO — input-only, 4 bits:
#   bit 0 = plocked_sync       (dvi2rgb source HDMI lock)
#   bit 1 = vsync_sync         (dvi2rgb source vsync)
#   bit 2 = vsync_out_sync     (VTC output vsync — new in iter-4d-1)
#   bit 3 = pclk_locked_sync   (clk_wiz_pixclk_out MMCM lock — new in iter-4d-1)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_0
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH    {4} \
    CONFIG.C_ALL_INPUTS    {1} \
    CONFIG.C_IS_DUAL       {0} \
    CONFIG.C_INTERRUPT_PRESENT {0} \
] [get_bd_cells axi_gpio_0]

# Pack {pclk_locked, vsync_out, vsync, plocked} into the 4-bit GPIO input
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat gpio_in_concat
set_property -dict [list \
    CONFIG.NUM_PORTS {4} \
    CONFIG.IN0_WIDTH {1} \
    CONFIG.IN1_WIDTH {1} \
    CONFIG.IN2_WIDTH {1} \
    CONFIG.IN3_WIDTH {1} \
] [get_bd_cells gpio_in_concat]
connect_bd_net [get_bd_pins axi_sync_inputs_0/plocked_sync]     [get_bd_pins gpio_in_concat/In0]
connect_bd_net [get_bd_pins axi_sync_inputs_0/vsync_sync]       [get_bd_pins gpio_in_concat/In1]
connect_bd_net [get_bd_pins axi_sync_inputs_0/vsync_out_sync]   [get_bd_pins gpio_in_concat/In2]
connect_bd_net [get_bd_pins axi_sync_inputs_0/pclk_locked_sync] [get_bd_pins gpio_in_concat/In3]
connect_bd_net [get_bd_pins gpio_in_concat/dout]                [get_bd_pins axi_gpio_0/gpio_io_i]

# AXI-Lite connection to the GPIO via the expanded interconnect
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M02_AXI] [get_bd_intf_pins axi_gpio_0/S_AXI]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]             [get_bd_pins axi_gpio_0/s_axi_aclk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]    [get_bd_pins axi_gpio_0/s_axi_aresetn]

# =============================================================================
# iter4e: AXI GPIO 1 — output-only, 32 bits, drives scaler_0/in_w_async +
# in_h_async. Firmware writes detected source dimensions from v_tc_rx detector.
#   bits [15:0]  = IN_W (source active H)
#   bits [31:16] = IN_H (source active V)
# Output goes through xlslice cells to split into two 16-bit fields for
# scaler_0's two 16-bit input ports.
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_1
# Default to 1920x1080 packed (0x0438 << 16 | 0x0780 = 0x04380780) so the
# scaler has valid dimensions from the first source TUSER, even before
# firmware programs the detected source value. Without this, in_w_runtime
# stays at 0 until firmware writes, scaler's emit_now = (accum >= 0) is
# always true, scaler hangs in emit-storm and HDMI output dies before
# firmware can recover.
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH    {32} \
    CONFIG.C_ALL_OUTPUTS   {1} \
    CONFIG.C_IS_DUAL       {0} \
    CONFIG.C_INTERRUPT_PRESENT {0} \
    CONFIG.C_DOUT_DEFAULT  {0x04380780} \
] [get_bd_cells axi_gpio_1]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice slice_in_w
set_property -dict [list \
    CONFIG.DIN_WIDTH {32} \
    CONFIG.DIN_FROM  {15} \
    CONFIG.DIN_TO    {0} \
    CONFIG.DOUT_WIDTH {16} \
] [get_bd_cells slice_in_w]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice slice_in_h
set_property -dict [list \
    CONFIG.DIN_WIDTH {32} \
    CONFIG.DIN_FROM  {31} \
    CONFIG.DIN_TO    {16} \
    CONFIG.DOUT_WIDTH {16} \
] [get_bd_cells slice_in_h]
connect_bd_net [get_bd_pins axi_gpio_1/gpio_io_o] [get_bd_pins slice_in_w/Din]
connect_bd_net [get_bd_pins axi_gpio_1/gpio_io_o] [get_bd_pins slice_in_h/Din]
connect_bd_net [get_bd_pins slice_in_w/Dout]      [get_bd_pins scaler_0/in_w_async]
connect_bd_net [get_bd_pins slice_in_h/Dout]      [get_bd_pins scaler_0/in_h_async]

# AXI-Lite connection
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M04_AXI] [get_bd_intf_pins axi_gpio_1/S_AXI]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]             [get_bd_pins axi_gpio_1/s_axi_aclk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]    [get_bd_pins axi_gpio_1/s_axi_aresetn]

# =============================================================================
# iter4g: AXI GPIO 2 — dual-channel, input-only, exposes scaler_top counters
# CDC'd to FCLK_CLK0. Firmware reads + prints per frame to identify the
# pipeline stage that drops/adds rows.
#   Channel 1 (32-bit): bits [15:0]=scaler_h_in_tlast, [31:16]=scaler_v_in_tlast
#   Channel 2 (32-bit): bits [15:0]=scaler_v_emit
# =============================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_2
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH    {32} \
    CONFIG.C_GPIO2_WIDTH   {32} \
    CONFIG.C_ALL_INPUTS    {1} \
    CONFIG.C_ALL_INPUTS_2  {1} \
    CONFIG.C_IS_DUAL       {1} \
    CONFIG.C_INTERRUPT_PRESENT {0} \
] [get_bd_cells axi_gpio_2]

# Slice the 64-bit diag_counts_sync into 4 16-bit fields
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice slice_diag_h_tlast
set_property -dict [list CONFIG.DIN_WIDTH {64} CONFIG.DIN_FROM {15}  CONFIG.DIN_TO {0}  CONFIG.DOUT_WIDTH {16}] [get_bd_cells slice_diag_h_tlast]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice slice_diag_v_tlast
set_property -dict [list CONFIG.DIN_WIDTH {64} CONFIG.DIN_FROM {31}  CONFIG.DIN_TO {16} CONFIG.DOUT_WIDTH {16}] [get_bd_cells slice_diag_v_tlast]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice slice_diag_v_emit
set_property -dict [list CONFIG.DIN_WIDTH {64} CONFIG.DIN_FROM {47}  CONFIG.DIN_TO {32} CONFIG.DOUT_WIDTH {16}] [get_bd_cells slice_diag_v_emit]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice slice_diag_mm2s
set_property -dict [list CONFIG.DIN_WIDTH {64} CONFIG.DIN_FROM {63}  CONFIG.DIN_TO {48} CONFIG.DOUT_WIDTH {16}] [get_bd_cells slice_diag_mm2s]
connect_bd_net [get_bd_pins axi_sync_inputs_0/diag_counts_sync] [get_bd_pins slice_diag_h_tlast/Din]
connect_bd_net [get_bd_pins axi_sync_inputs_0/diag_counts_sync] [get_bd_pins slice_diag_v_tlast/Din]
connect_bd_net [get_bd_pins axi_sync_inputs_0/diag_counts_sync] [get_bd_pins slice_diag_v_emit/Din]
connect_bd_net [get_bd_pins axi_sync_inputs_0/diag_counts_sync] [get_bd_pins slice_diag_mm2s/Din]

# Channel 1 (gpio_io_i) = {v_tlast, h_tlast}
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat gpio2_ch1_concat
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {16} CONFIG.IN1_WIDTH {16}] \
    [get_bd_cells gpio2_ch1_concat]
connect_bd_net [get_bd_pins slice_diag_h_tlast/Dout] [get_bd_pins gpio2_ch1_concat/In0]
connect_bd_net [get_bd_pins slice_diag_v_tlast/Dout] [get_bd_pins gpio2_ch1_concat/In1]
connect_bd_net [get_bd_pins gpio2_ch1_concat/dout]   [get_bd_pins axi_gpio_2/gpio_io_i]

# Channel 2 (gpio2_io_i) = {mm2s_tlast, v_emit}
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat gpio2_ch2_concat
set_property -dict [list CONFIG.NUM_PORTS {2} CONFIG.IN0_WIDTH {16} CONFIG.IN1_WIDTH {16}] \
    [get_bd_cells gpio2_ch2_concat]
connect_bd_net [get_bd_pins slice_diag_v_emit/Dout]  [get_bd_pins gpio2_ch2_concat/In0]
connect_bd_net [get_bd_pins slice_diag_mm2s/Dout]    [get_bd_pins gpio2_ch2_concat/In1]
connect_bd_net [get_bd_pins gpio2_ch2_concat/dout]   [get_bd_pins axi_gpio_2/gpio2_io_i]

# AXI-Lite — needs axi_ic_lite NUM_MI expanded 5 -> 6 (handled in earlier edit)
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M05_AXI] [get_bd_intf_pins axi_gpio_2/S_AXI]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK0]             [get_bd_pins axi_gpio_2/s_axi_aclk]
connect_bd_net [get_bd_pins rst_axi/peripheral_aresetn]    [get_bd_pins axi_gpio_2/s_axi_aresetn]

# =============================================================================
# Phase D iter-3n — ILA instrumentation on scaler_top output and axis_to_vid_io
#                   input, to characterize the dynamic edge-speckle artifact.
# =============================================================================
# Two ILAs probe the AXIS pixel stream at two stages of the output pipeline:
#   - ila_scaler_out  : what scaler_top emits (on pclk_in / 148.5 MHz)
#   - ila_mm2s_out    : what VDMA MM2S delivers to axis_to_vid_io (on pclk_out)
#
# If captured scaler_out pixel values at a fixed column near a color-bar edge
# are IDENTICAL across multiple ILA acquisitions, the scaler MAC is stable.
# If mm2s_out pixel values then VARY across the same captures, VDMA / DDR3 /
# CDC is introducing the per-frame variation.
#
# 2048-sample depth covers > one output row (1280 pixels) so we can trigger
# on TUSER and capture the entire first row of an output frame.

# System ILA on the scaler output AXIS interface (pclk_in domain, 148.5 MHz).
# Monitors all standard AXIS signals (tdata, tvalid, tready, tlast, tuser) by
# attaching to the interface bundle — no manual signal peel-off, which is the
# pattern that caused width-mismatch / unconnected-pin errors with native ILA.
create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila ila_scaler_out
set_property -dict [list \
    CONFIG.C_NUM_MONITOR_SLOTS  {1} \
    CONFIG.C_SLOT_0_INTF_TYPE   {xilinx.com:interface:axis_rtl:1.0} \
    CONFIG.C_DATA_DEPTH         {2048} \
    CONFIG.C_EN_STRG_QUAL       {1} \
    CONFIG.C_ADV_TRIGGER        {true} \
] [get_bd_cells ila_scaler_out]
connect_bd_intf_net [get_bd_intf_pins scaler_0/m_axis] [get_bd_intf_pins ila_scaler_out/SLOT_0_AXIS]
connect_bd_net [get_bd_pins dvi2rgb_0/PixelClk] [get_bd_pins ila_scaler_out/clk]
connect_bd_net [get_bd_pins rst_pixclk_out/peripheral_aresetn] [get_bd_pins ila_scaler_out/resetn]

# System ILA on the MM2S output AXIS (pclk_out domain, 74.25 MHz).
create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila ila_mm2s_out
set_property -dict [list \
    CONFIG.C_NUM_MONITOR_SLOTS  {1} \
    CONFIG.C_SLOT_0_INTF_TYPE   {xilinx.com:interface:axis_rtl:1.0} \
    CONFIG.C_DATA_DEPTH         {2048} \
    CONFIG.C_EN_STRG_QUAL       {1} \
    CONFIG.C_ADV_TRIGGER        {true} \
] [get_bd_cells ila_mm2s_out]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins ila_mm2s_out/SLOT_0_AXIS]
connect_bd_net [get_bd_pins clk_wiz_pixclk_out/clk_out1] [get_bd_pins ila_mm2s_out/clk]
connect_bd_net [get_bd_pins rst_pixclk_out/peripheral_aresetn] [get_bd_pins ila_mm2s_out/resetn]

# =============================================================================
# iter4h System ILA on S2MM's AXI-MM write port to DDR3 (FCLK_CLK1 domain).
# Captures every AXI4 write transaction VDMA issues to DDR3:
#   awaddr, awlen, awsize, awvalid/awready, wdata, wlast, wvalid/wready, bresp.
# Goal: confirm by AXI address whether VDMA writes the artifact rows
# (slot 0 rows 694-719 = byte addrs 0x10290800..0x102A2C00) once or twice
# per frame, and what data is on the bus at those addresses. Settles the
# "double write vs never-updated by current frame" question definitively.
# 4096 sample depth = ~40 µs of capture at FCLK_CLK1 = 100 MHz; deep enough
# to capture a complete frame-end + frame-start AXI write burst sequence
# when triggered on AWADDR matching the artifact zone.
create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila ila_s2mm_axi
set_property -dict [list \
    CONFIG.C_NUM_MONITOR_SLOTS  {1} \
    CONFIG.C_SLOT_0_INTF_TYPE   {xilinx.com:interface:aximm_rtl:1.0} \
    CONFIG.C_DATA_DEPTH         {4096} \
    CONFIG.C_EN_STRG_QUAL       {1} \
    CONFIG.C_ADV_TRIGGER        {true} \
] [get_bd_cells ila_s2mm_axi]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_S2MM] [get_bd_intf_pins ila_s2mm_axi/SLOT_0_AXI]
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1]              [get_bd_pins ila_s2mm_axi/clk]
connect_bd_net [get_bd_pins rst_mem/peripheral_aresetn]     [get_bd_pins ila_s2mm_axi/resetn]

# =============================================================================
# Address map + validate + wrapper
# =============================================================================
assign_bd_address
validate_bd_design
save_bd_design
puts "STAGE_OK: Block Design validated"

set bd_path [get_files $bd_name.bd]
make_wrapper -files $bd_path -top -import
puts "STAGE_OK: BD wrapper generated"

# (Plan B wrapper was unnecessary — scaler_0 OOC issue resolved by Vivado
# caching the .dcp from a previous build run. Plan B file kept for reference.)

# =============================================================================
# Constraints — BD wrapper is the design top, so the XDC references the BD
# wrapper's auto-generated port names.
# =============================================================================
add_files -fileset constrs_1 -norecurse \
    [file join $project_root constraints zybo_z7_20_phase_b.xdc]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

# =============================================================================
# Synth + impl + bit
# =============================================================================
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "ERROR: synth_1 did not reach 100% (status=[get_property STATUS [get_runs synth_1]])"
    exit 1
}
puts "STAGE_OK: synthesis complete"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: impl_1 did not reach 100% (status=[get_property STATUS [get_runs impl_1]])"
    exit 1
}
puts "STAGE_OK: implementation + bitstream complete"

set bit [glob -nocomplain [file join $vivado_dir $project_name.runs impl_1 *.bit]]
if {[llength $bit] == 0} { puts "ERROR: no .bit"; exit 1 }
puts "BITSTREAM: [lindex $bit 0]"
puts "TIMING: WNS=[get_property STATS.WNS [get_runs impl_1]]  WHS=[get_property STATS.WHS [get_runs impl_1]]"

write_hw_platform -fixed -include_bit -force \
    -file [file join $build_dir phase_b.xsa]
puts "XSA: [file join $build_dir phase_b.xsa]"
exit 0

# Probe section moved into build context
