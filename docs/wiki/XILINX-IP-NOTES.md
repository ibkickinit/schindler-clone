# Xilinx IP Notes

Gotchas per Xilinx + Digilent IP block. Each one cost us hours; documented here so future agents skip the trap.

## Zynq-7020 silicon constraints

Memory: `zynq7020_mmcm_budget`.

| Resource | Count | Notes |
|---|---|---|
| MMCMs | **4** | All in use on iter5-1080p-clean (2 explicit clk_wiz + 2 inside dvi2rgb) |
| PLLs (PLLE2_ADV) | 4 | Any 5th clock generator must use these. ≥19 MHz input required |
| LUT | ~17,600 | Phase A = 6%; full Phase B + color stack uses ~30-40% |
| LUT-as-RAM | ~35,000 | Plenty of headroom |
| BRAM tiles (36Kb each) | 140 | VDMA alone uses 5 |
| DSP slices | 220 | color_matrix uses several; scaler uses few (boxcar is add-only) |

## axi_vdma v6.3 (Xilinx)

### iter6 hardware fsync

Per `schindler_vdma_dynamic_genlock` + iter6 docs: TUSER-driven slot transition is pipeline-deep (~27 rows of internal pipeline). **Enable `c_use_s2mm_fsync=1` + `c_flush_on_fsync=1`** and drive `s2mm_fsync` with a 1-cycle pulse on rising edge of source vsync. Bypasses the pipeline lag.

### DMASR bit map

Memory: `xilinx_vdma_dmasr_bits`. **DO NOT trust the obvious bit indices.**

| Bit | Real meaning | Trap |
|---|---|---|
| 12 | `FrmCnt_Irq` | **BENIGN** — frame-count interrupt request. Set every frame. Not an error. |
| 15 | `EOLLate` | **Real** EOLLate. Genuine error. |
| 14 | `EOLEarly` | Set every frame on iter5 substrate; investigate if/when format changes |
| 11 | `SOFLate` | Cosmetic on iter6+ (TUSER timing) |

**FrameDelay reads-as-0** in Genlock Master mode (and in our `include_internal_genlock=1` build, also locks for Slave). Don't try to read it; trust the register write.

**WRSTORE reads-as-0** in our build (`include_internal_genlock=1`). Use S2MM_SR to infer write activity instead.

### Dynamic Genlock recipe

`S2MM mode=2` (Dynamic Master) + `MM2S mode=3` (Dynamic Slave) + `FrameDelay=1` + `repeat_en=1`. 5 framestores recommended (3 is too brittle).

Firmware **PARK_PTR_REG writes per vsync are anti-pattern** — PG020 does not promise SOF-atomic latching for those.

## v_tc (Xilinx Video Timing Controller)

### REG_UPDATE bit

Memory: `xilinx_vtc_register_update`. **VTC CTL register bit 1 (RU) MUST be set** or shadow-register writes never reach the generator. Symptom: monitor "No Signal" with downstream LEDs solid.

### XPAR_VTC aliasing trap

Memory: `xilinx_xpar_vtc_aliasing`. Adding a second `v_tc` instance silently re-aliases `XPAR_VTC_0` to the new IP. **Always use explicit `XPAR_V_TC_TX_BASEADDR` / `XPAR_V_TC_RX_BASEADDR`** in firmware. Saved 30+ min on iter5 when adding VTC_RX detector.

## v_vid_in_axi4s (Xilinx)

### Sync wires must be explicit

Memory: `xilinx_v_vid_in_axi4s_sync`. `connect_bd_intf_net` from dvi2rgb's RGB interface **only wires data, not syncs.** vid_hsync_in, vid_vsync_in, vid_active_video_in must be connected explicitly or VDMA S2MM never advances frame buffers. Cost us hours on Phase A→B transition.

## dvi2rgb (Digilent)

### CLK125 quirk

Memory: `zybo_z7_clk125_phy`. Pin K17's 125 MHz on the Zybo Z7 is the Ethernet PHY's refclk, not a crystal. Stops when the PHY is reset and may glitch when the PHY has no link. Don't use it as a primary clock source for the video pipeline.

### pLocked instability

Memory: `schindler_source_first`. When pLocked flickers (LD1 cycles), **swap the HDMI source before debugging FPGA placement/clocking**. Most pLocked instability is source-side.

## rgb2dvi (Digilent)

### kClkRange limit

Memory: `digilent_rgb2dvi_kclkrange_limit`. The IP only accepts `kClkRange={1,2,3}` → pixel clock floor ~40 MHz → blocks 480p over HDMI. **Underlying VHDL supports higher; just patch `component.xml`.**

**The patch lives in `~/fpga/vivado-library/ip/dvi2rgb/component.xml`** — if you re-pull vivado-library upstream, the patch is gone. The pinned commit (`f4613ff`, 2024-05-16) per `../build-manifest.md` Reproduction footer is what we use today.

## AXI IIC (Xilinx)

### XIic_DynSend pattern

Memory: `axi_iic_dynsend_pattern`. The happy-path per-transaction sequence has **zero CR (Control Register) writes.** Using `CR=0x03→0x01` as a prologue is the **error-recovery code**, not happy-path. This half-arms the FSM and TX_FIFO never drains. Caused Si5351 Phase D's multi-byte writes to NAK.

### Dynamic mode atomicity

Memory: `axi_iic_dynamic_mode_atomicity`. **Never insert delays between TX_FIFO byte pushes** in dynamic mode. The IP emits premature STOP and breaks the burst. Per-byte debug snapshots will cause the very NAK they're hunting.

## CDC (custom + Xilinx)

### axi_sync_inputs.v width rule

Memory: `axi_sync_inputs_cdc_width`. **CDC internal regs must match declared port widths.** iter5b bug: 48-bit regs on 64-bit port silently truncated upper 16 bits. Surfaced only when iter5 reused the upper bits for `out_tlast_snap`. Cost ~30 min.

### vsync_cdc_pulse.v

Custom module: 2-FF synchronizer + edge detector. Generates 1-cycle pulse on rising edge of async input. Pre-existing; used as-is by iter6 fsync wiring.

## Color pipeline async-CDC WNS soft fail

Vivado reports WNS=-3.5 ns (sometimes -3.72) on color-pipeline CDC paths. Functional via `ASYNC_REG` attribute. **Open issue**: the XDC `set_false_path` patterns don't match Vivado's hierarchical names.

See [KNOWN-BUGS](KNOWN-BUGS.md) and [BUILD-AND-PROGRAM](BUILD-AND-PROGRAM.md).

## Vitis-specific traps

### importsources stale-copy

Memory: `vitis_importsources_stale_copy`. `importsources` copies into the project tree. **Subsequent edits to the original source don't propagate to incremental builds.** Re-run full Vitis tcl to force re-copy. Cost us 3 lost iterations on 2026-05-14.

## Pmod connectors

### Pin naming

Memory: `pmod_pin_naming`. At bench, **ALWAYS use "Pmod JB Pin 7" (physical pin), never "JB5"/"jb[4]"** (Digilent signal-index naming maps "JB5" → physical pin 7). Mis-wires to GND are very easy.

## I²C bus signal integrity

Memory: `i2c_pullup_rule`. **NEVER rely on FPGA internal ~50 kΩ pull-ups for I²C bus operation.** Always wire external 2.2 kΩ from SDA/SCL → 3.3V. Cost ~45 min debug on Phase C-lite 2026-05-20.

<!-- AGENT_TASK[docs-11]: When a new Xilinx IP gotcha is discovered, add to this page AND create a memory entry. Pattern: page is reference; memory is point-in-time. -->
