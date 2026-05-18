# Mackin Dual-VDMA Recipe — next iter

Step-by-step recipe to replace the current placeholder (axis_clone fan-out) with a real second VDMA instance that gives mackin_blender_0 a true 1-frame-old "previous" stream.

**Pre-requisite:** the placeholder build is already on `mackin-impl-wip` and bench-verified (firmware UART `a <hex>` roundtrips, GPIO readback correct, no visual regression from iter5).

## Overview

Current pipeline (placeholder):
```
axi_vdma_0/M_AXIS_MM2S → axis_clone_0 → mackin_blender_0 (s_curr + s_prev identical) → color pipeline
```

Target pipeline (real):
```
axi_vdma_0/M_AXIS_MM2S ────→ mackin_blender_0/s_curr
axi_vdma_1/M_AXIS_MM2S ────→ mackin_blender_0/s_prev   ← reads 1 framestore behind
                              ↓
                          color pipeline
```

`axi_vdma_0` and `axi_vdma_1` share the same DDR3 framestore ring. Classic Genlock chain ensures `axi_vdma_1.MM2S.RdFrmStore` always trails `axi_vdma_0.S2MM.WrFrmStore` by exactly 2 slots (vs. 1 slot for `axi_vdma_0.MM2S`).

## Step 1 — switch axi_vdma_0 from Dynamic to classic Genlock

In `tcl/build_phase_b.tcl`, find the `axi_vdma_0` config block. Currently:
```tcl
CONFIG.c_s2mm_genlock_mode {0}  ;# Dynamic Master
CONFIG.c_mm2s_genlock_mode {3}  ;# Dynamic Slave
```

Change to:
```tcl
CONFIG.c_s2mm_genlock_mode {0}  ;# Genlock Master (was Dynamic Master, but values match — verify in IP GUI)
CONFIG.c_mm2s_genlock_mode {1}  ;# Genlock Slave
CONFIG.c_mm2s_frame_delay {1}   ;# 1 slot behind master
CONFIG.c_include_internal_genlock {0}  ;# expose mm2s_frame_ptr_in
```

Then connect: `axi_vdma_0/s2mm_frame_ptr_out` → `axi_vdma_0/mm2s_frame_ptr_in`.

**Validate on bench at this checkpoint** — same iter5 behavior should hold. If it doesn't, fix here before adding axi_vdma_1.

## Step 2 — add axi_vdma_1 (MM2S-only Genlock Slave)

Add after the axi_vdma_0 block:
```tcl
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma axi_vdma_1
set_property -dict [list \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_num_fstores {5} \
    CONFIG.c_mm2s_genlock_mode {1}   ;# Genlock Slave
    CONFIG.c_mm2s_frame_delay {2}    ;# 2 slots behind master (1 behind axi_vdma_0/MM2S)
    CONFIG.c_mm2s_genlock_num_masters {1}  ;# expose mm2s_frame_ptr_in
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {24} \
    CONFIG.c_include_internal_genlock {0} \
] [get_bd_cells axi_vdma_1]
```

## Step 3 — wire fan-out of s2mm_frame_ptr_out

Replace the single connection from step 1 with:
```tcl
# Fan out master's frame_ptr_out to BOTH slaves
connect_bd_net [get_bd_pins axi_vdma_0/s2mm_frame_ptr_out] \
               [get_bd_pins axi_vdma_0/mm2s_frame_ptr_in] \
               [get_bd_pins axi_vdma_1/mm2s_frame_ptr_in]
```

If timing complains, add a 1-stage register slice on the fan-out (Gray code tolerates a clock of latency).

## Step 4 — wire axi_vdma_1 M_AXI_MM2S to HP2

```tcl
# axi_vdma_1's memory-map AXI master → SmartConnect → HP2
# HP0 already used by axi_vdma_0 via axi_sc_mem
# Create a second SmartConnect to HP2
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_sc_mem2
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_sc_mem2]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_1/M_AXI_MM2S] [get_bd_intf_pins axi_sc_mem2/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc_mem2/M00_AXI]   [get_bd_intf_pins zynq_ps/S_AXI_HP2]
# Clock + reset for sc_mem2
connect_bd_net [get_bd_pins zynq_ps/FCLK_CLK1] [get_bd_pins axi_sc_mem2/aclk]
connect_bd_net [get_bd_pins rst_mem/peripheral_aresetn] [get_bd_pins axi_sc_mem2/aresetn]
# Enable HP2 on the PS
set_property -dict [list CONFIG.PCW_USE_S_AXI_HP2 {1}] [get_bd_cells zynq_ps]
```

## Step 5 — wire axi_vdma_1 control via axi_ic_lite

Bump `axi_ic_lite` from NUM_MI=11 to 12. Add M11 connection to `axi_vdma_1/S_AXI_LITE`:
```tcl
set_property -dict [list CONFIG.NUM_MI {12}] [get_bd_cells axi_ic_lite]
connect_bd_intf_net [get_bd_intf_pins axi_ic_lite/M11_AXI] [get_bd_intf_pins axi_vdma_1/S_AXI_LITE]
# Plus M11_ACLK and M11_ARESETN connections matching the others.
```

## Step 6 — replace axis_clone with direct wiring

In `tcl/build_phase_b.tcl`, delete the `axis_clone_0` creation + connections, and replace with:
```tcl
connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] [get_bd_intf_pins mackin_blender_0/s_curr]
connect_bd_intf_net [get_bd_intf_pins axi_vdma_1/M_AXIS_MM2S] [get_bd_intf_pins mackin_blender_0/s_prev]
```

Also delete `hdl/axis_clone.v` from `add_files`.

## Step 7 — firmware

Extend `vdma_init()` in `sw/phase-b/src/main.c`:
```c
/* Initialize axi_vdma_1 MM2S only.
 * Same framestore base addresses as axi_vdma_0 — shared DDR3 ring.
 * Genlock Slave mode, FrameDelay=2 means RdFrmStore lags master by 2 slots. */
static void vdma1_init(void)
{
    UINTPTR base = XPAR_AXI_VDMA_1_BASEADDR;
    // Configure circular_park = 0, repeat_en = 1, GenlockEn = 1, etc.
    // Write framestore base addresses (same 5 slots as axi_vdma_0).
    // Start the channel.
}
```

Call from `main()` after the existing `vdma_init()`.

## Step 8 — bench validation checklist

1. Boot, observe video. Should still come up clean — alpha=0x8000 means out=curr, identical to iter5 visual.
2. Send `a 0000` over UART. Output should switch to "previous frame" — visible as a 1-frame delayed copy. On a static image, no change; on moving content, you'll see a clear lag.
3. Send `a 4000`. Output should be 50/50 blend of current + previous. On motion, you'll see "motion smear" — confirms blending math works.
4. Send `a 7fff`. Should look almost identical to `a 8000` (just under full curr).
5. Confirm DIAG counters show both VDMAs advancing in lockstep (RDSTORE values for both should track).
6. Try various FRC ratios (60→24, 60→30, 60→59.94) and verify no scrolling or tearing.

## Open questions for bench

- **FrmDly off-by-one:** Does `FrmDly=2` produce N−2 vs N−1, or N−1 vs N? PG020 is slightly ambiguous. If `axi_vdma_0.MM2S` and `axi_vdma_1.MM2S` produce the SAME frame, change `axi_vdma_1.FrmDly` from 2 to 3.
- **Gray-code fan-out timing:** If WNS regresses on the `s2mm_frame_ptr_out` net, add a register slice.
- **HP2 enable in PS configuration:** ensure `CONFIG.PCW_USE_S_AXI_HP2 {1}` propagates correctly. Check that XSDK/Vitis sees XPAR_AXI_VDMA_1_BASEADDR after rebuild.

## When this is done

Update [[schindler-mackin-implementation]] memory: bench-validated, dual-VDMA complete. Move on to Phase E1 (MMCM tracking, task #24) to absorb the slow drift that bare Genlock can't.
