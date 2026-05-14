# Phase B — DDR3 Frame Buffer Passthrough

**Goal:** replace Phase A's direct dvi2rgb→rgb2dvi pixel wire with an AXI4-Stream Video pipeline going through DDR3 via AXI VDMA. Foundation for the polyphase scaler (Phase C) and FRC (Phase D), both of which need full-frame storage.

Phase B has two sub-steps:

- **B.0 — Hardware platform.** Block Design with Zynq PS + AXI VDMA + Video In/Out adapters + VTC. Builds to .bit + .xsa. **Done.**
- **B.1 — PS firmware.** Bare-metal C app that initializes VDMA at boot + sets up VTC timing. Loaded via XSCT alongside the .bit. **Done — VDMA + VTC fully configured, but `v_axi4s_vid_out` not locking; no picture on monitor yet.**

## Architecture

Block Design `phase_b_bd` ([`tcl/build_phase_b.tcl`](../tcl/build_phase_b.tcl)):

```
sys_clk (125 MHz) ──► Clocking Wizard (PLL) ──► refclk_200 ──► dvi2rgb IDELAYCTRL

HDMI RX TMDS ──► dvi2rgb ──► RGB (vid_io) ──► Video In to AXI4-Stream
                                                  │ AXIS (24-bit RGB)
                                                  ▼
                              AXI VDMA (S2MM ch) ──► DDR3 frame store (3-frame ring)
                                                  ▲
                                                  │ AXIS (24-bit RGB)
                              AXI VDMA (MM2S ch) ──┘
                                                  │
                                                  ▼
                                          AXI4-Stream to Video Out
                                                  ▲ vtiming_in
                                                  │
                                              v_tc (TX timing generator, 1080p60)
                                                  │
                                                  ▼
                                              rgb2dvi ──► HDMI TX TMDS
```

Everything runs on a single clock domain — the dvi2rgb-recovered **PixelClk** (74.25 MHz at 720p60, 148.5 MHz at 1080p60). The PS app waits for source-side lock before VDMA + VTC init so PixelClk is stable when their reset state machines run.

PS interconnect:
- **M_AXI_GP0** (100 MHz axi-lite) → AXI Interconnect → VDMA registers + VTC registers
- **S_AXI_HP0** (150 MHz axi-mm, 64-bit) ← SmartConnect ← VDMA S2MM + MM2S memory ports → DDR3

## Build / load flow

```bash
cd ~/Dropbox/_PROJECTS/Schindler-2.0
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
vivado -mode batch -source tcl/build_phase_b.tcl      # → .bit + phase_b.xsa

source /tools/Xilinx/2025.2/Vitis/settings64.sh
xsct tcl/build_phase_b_app.tcl                        # → vdma_init.elf
xsct tcl/program_phase_b_full.tcl                     # JTAG: fpga + ps7_init + dow elf + con
```

UART terminal: `/dev/ttyUSB1` at 115200 8N1 (PS's UART1 via Zybo USB-UART, second channel after JTAG).

## Status (2026-05-13, end of long session)

**Working:**
- Phase A (pure-PL passthrough) is rock-solid at 1080p60 with `kClkRange=1` on dvi2rgb + rgb2dvi. (Earlier "kClkRange=2 also works at 1080p60" was marginal luck — the MMCM VCO is over-spec at 1485 MHz; with the more-loaded Phase B design it consistently fails to maintain lock.)
- Phase B.0 platform builds clean. WNS / WHS positive.
- Phase B.1 PS firmware fully configures VDMA + VTC. Both channels run, registers verified, S2MM writes real pixel frames to DDR3, frame pointers cycle.
- Custom `axis_to_vid_io.v` adapter replaces v_axi4s_vid_out (which wouldn't lock); proved that adapter works by getting the monitor to recognize 1920×1080 timing.
- **Phase A architecture inside Phase B's BD shows real desktop video on the monitor** — briefly. The pipeline goes end-to-end. The remaining problem is reliability.

**Not stable:**
- dvi2rgb's `pLocked` (LD1) flickers off intermittently. Pattern: ~3 seconds locked, 5–10 seconds dropped. Monitor follows: brief lock when LD1 holds, "No Signal" when LD1 drops.
- The pLocked instability is independent of:
  - clk_wiz primitive (PLL vs MMCM — both intermittent)
  - PS FCLK_CLK2 as IDELAYCTRL refclk (also intermittent)
  - PixelClk fanout (1 sink vs 5 sinks)
  - PS firmware activity (with vs without firmware)
  - Custom adapter (Phase A-direct-wiring still flickers in Phase B's BD)
- Phase A's bitstream (same dvi2rgb/rgb2dvi, no PS, no VDMA, no VTC, no extra IPs) does NOT exhibit the flicker. So the cause is something specific to Phase B's overall BD complexity — likely **dvi2rgb's internal MMCM placement / routing pressure**, which we can't diagnose without ILA visibility.

## Gotchas resolved during bringup

Useful to know if/when we revisit this:

1. **Digilent interface defs live separately from the IP cores.** Need to register `~/fpga/vivado-library` (parent of both `ip/` and `if/`) as `ip_repo_paths`, not just `ip/`. Without `if/`, `digilentinc.com:interface:tmds_rtl:1.0` doesn't resolve and BD interface ports fail.
2. **Clocking Wizard `PRIMITIVE = PLL`, not MMCM.** With dvi2rgb + rgb2dvi each needing an MMCM near their HDMI IO bank, a third MMCM here over-subscribes the clock region and the placer fails rgb2dvi's `MMCM↔BUFR/BUFIO` same-region rule.
3. **`CLOCK_DEDICATED_ROUTE BACKBONE`** on `sys_clk_IBUF` still required (carried from Phase A).
4. **`Xil_DCacheDisable()`** before VDMA init so the PS sees coherent DDR3 from the VDMA writes without explicit flush/invalidate.
5. **JTAG load order matters:** `connect → rst -system → fpga → source ps7_init.tcl → ps7_init → ps7_post_config → dow .elf → con`. `ps7_post_config` *must* come after `fpga` — it releases the PS-PL bridges and they need the PL to be present.
6. **PS app must sleep before touching VDMA + VTC** to let dvi2rgb finish locking. VDMA's reset state machine waits for all clock domains to ack; VTC's AXI-Lite slave needs its gen-clock alive to respond to register writes — both run on the recovered PixelClk, which doesn't exist until dvi2rgb locks to the source. Without the sleep, VDMA init times out (`XAxiVdma_CfgInitialize` returns `XST_FAILURE`) or VTC writes trigger Data Abort.
7. **`XVtc_SetGenerator` is broken in this BSP.** `OriginMode=0` applies an off-by-one transform that writes `HTotal+1` to GASIZE (e.g., 2201 instead of 1920). `OriginMode=1` reads GFENC + writes GVSYNC_F1, one of which triggers Data Abort on our setup. Workaround: skip the driver entirely and write VTC's registers directly via `Xil_Out32` (`sw/phase-b/src/main.c`).
8. **`xvidc.h` is not in the standalone BSP for Vivado/Vitis 2025.2.** Don't use `XVtc_ConvVideoMode2Signal` / `XVIDC_VM_*` constants — hardcode the timing struct.
9. **AXIS data width = 24 bits** out of `v_vid_in_axi4s` (RGB888, 1 pixel per clock, no padding). Memory stride must therefore use **3 bytes per pixel**, not 4. Using 4 silently corrupts the per-line byte count and triggers VDMA framing errors.

## Final state (2026-05-14): Phase B fully working through DDR3, genlocked to source

After resolving the source-side flicker (next section), a small pile of FPGA-side bugs that the diagnostic short-circuit had been hiding, **and** a genlock fix on top, the **proper VDMA pipeline now passes live 1080p60 video through DDR3 end-to-end with the output frame phase-locked to the input**: Mac → dvi2rgb → v_vid_in_axi4s → VDMA S2MM → DDR3 frame ring → VDMA MM2S → axis_to_vid_io adapter → rgb2dvi → monitor. Mac desktop visible on the monitor, picture updates frame-by-frame, all four status LEDs lit, VDMA error bits clean, **no vertical seam regardless of when the board is reset relative to the source's frame phase** (confirmed via three consecutive reset cycles).

### The five real bugs (any one would have shown "No Signal")

1. **Upstream HDMI source briefly dropping its TMDS clock.** Old source (PC-side) → dvi2rgb's MMCM unlocked every few seconds. MacBook source → solid. Caught with `CLKINSTOPPED` probe via dvi2rgb's `kDebug` ILA (`tcl/capture_dvi2rgb_lock.tcl`). Recorded in [Lessons](#lessons-for-next-time) below.

2. **`v_tc_tx/resetn` unwired.** Vivado BD defaults unconnected reset pins to 0 (asserted). The gen-side reset stayed asserted forever and VTC's counters didn't run. Fixed by wiring `rst_axi/peripheral_aresetn → v_tc_tx/resetn` (and the same for `v_vid_in_axi4s_0/aresetn`).

3. **VTC IP-time `VIDEO_MODE` left at default 720p preset.** With the GUI gating, `GEN_HACTIVE_SIZE`/`GEN_VACTIVE_SIZE` writes were silently dropped at IP-customize time ("modification ignored" warning). Fixed by setting `CONFIG.VIDEO_MODE {1080p}` plus `MAX_CLOCKS_PER_LINE`/`MAX_LINES_PER_FRAME=4096`.

4. **VDMA AXIS widths defaulted to 32-bit (4 BPP).** v_vid_in_axi4s outputs 24-bit but VDMA's S2MM/MM2S AXIS widths defaulted to 32, mismatch with the 24-bit adapter input → "TDATA_NUM_BYTES does not match" critical warning, garbled pixels even when the pipeline ran. Fixed by `c_s_axis_s2mm_tdata_width=24` and `c_m_axis_mm2s_tdata_width=24` on the VDMA.

5. **Firmware never set VTC's `RU` (Register Update) bit.** The CTL value `0x04 | 0x01 | 0x07F7EF00` (SW|GE|source-selects) was being written, but `RU` (bit 1) was missing — so all the runtime timing register writes stayed in shadow registers and never propagated to the active generator. VTC's `GTSTAT` and pin outputs stayed at boot defaults (mostly zero), producing no usable sync. Fixed in `sw/phase-b/src/main.c:vtc_setup_1080p60()` by writing `0x01 | 0x02 | 0x04 | 0x07F7EF00` to CTL. The earlier comment mislabeling "bit 0 = REG_UPDATE" had hidden this for two sessions.

6. **No genlock — VTC frame phase random across resets.** After the five fixes above, picture worked but had a fixed vertical seam at a random row (60% down the first morning) — VTC's free-running frame counter starts at a random phase relative to source's frame phase. Solved by having the adapter source its sync from `dvi2rgb_0/vid_pVDE/HSync/VSync` (source-recovered) instead of from VTC, and by generating a 1-cycle pulse on rising edge of `vid_pVSync` from inside the adapter to drive `axi_vdma_0/mm2s_fsync`. MM2S frame boundary now always = source frame boundary, output sync = source sync. Verified across three reset cycles — picture aligned every time. VTC stays instantiated (drives LD2, available for Phase C/D output retiming) but is no longer in the data/sync path.

7. **`v_vid_in_axi4s_0` sync inputs never connected.** Latent bug present since the first Phase B build. The `connect_bd_intf_net dvi2rgb_0/RGB → v_vid_in_axi4s_0/vid_io_in` only auto-wired `vid_data`; dvi2rgb's RGB interface bundle doesn't include the sync signals, so `vid_active_video`, `vid_hsync`, `vid_vsync` defaulted to `1'b0`. Without sync, v_vid_in_axi4s couldn't generate valid `TLAST`/`TUSER` AXIS framing markers, so VDMA S2MM never recognized frame boundaries and kept writing to a single slot. The display visibly cycled between one fresh slot and two stale slots after the genlock fix made the alternation regular and visible (Justin's "skewing diagonally and jittering" observation). Fixed by replacing the interface-net with four explicit `connect_bd_net` lines wiring `dvi2rgb_0/vid_pData/pVDE/pHSync/pVSync → v_vid_in_axi4s_0/vid_data/active_video/hsync/vsync`. The earlier builds happened to produce plausible-looking pictures because S2MM was still writing pixel data linearly to memory — just without proper frame demarcation, which the genlock fix then exposed.

Diagnostic that revealed #5: read VTC CTL via XSCT after firmware boot — it read `0x00000000` instead of the expected `0x07F7EF05`, immediately exposing that the active generator state was wrong. Setting CTL to `0x07F7EF07` (with RU) via XSCT made the monitor go from "No Signal" to a solid white screen at 1080p60 within milliseconds. Confirmation: rebuild firmware with the fix → automatic white screen on boot → restore proper pipeline wiring → full Mac desktop on monitor.

### The pipeline in pictures

`build/webcam/` (not in repo) holds capture frames from the laptop webcam, taken during bringup via `gst-launch-1.0 v4l2src device=/dev/video0 ... ! jpegenc ! multifilesink`. The "white screen + all LEDs lit" capture was the moment-of-truth that proved VTC sync was finally valid.

## Resolution (2026-05-13): the flicker was **source-side**

After two long debug sessions blaming FPGA placement / clocking / Vccint, ILA capture inside dvi2rgb's MMCM finally caught the real cause: the upstream HDMI source was briefly stopping its TMDS clock output. dvi2rgb's MMCM correctly detected the dropout via CLKINSTOPPED, unlocked, and couldn't relock fast enough to hide the gap — producing the visible ~3-sec-on / 5-10-sec-off LD1 flicker.

**Swapping to a MacBook as the HDMI source: solid lock, no flicker.** Phase B's pipeline (Zynq PS + VDMA + VTC + adapter → DDR3 frame buffer → HDMI TX) works as built once dvi2rgb has a clean input.

### Why the previous-session investigation chased the wrong rabbit

Both potential failure modes — IDELAYCTRL RDY loss (200 MHz refclk path) and MMCM unlock (TMDS clock path) — produce identical `aLocked` behavior at LD1:
```
-- TMDS_Clocking.vhd
aLocked <= '0' when rRdyRst='1'          -- IDELAYCTRL RDY lost (200 MHz refclk side)
       else rMMCM_Locked_q(0);            -- MMCM lost lock (TMDS clock side)
```
Every experiment the previous session ran (clk_wiz PLL vs MMCM, FCLK vs PL refclk, fanout, kClkRange, firmware on/off, custom adapter…) gave the same LED behavior because *none of them discriminated which subsystem was failing*. So the team kept iterating on remedies for what turned out to be the wrong subsystem entirely. And the eventually-recommended LOC-constraint plan (move MMCMs to other clock regions) was based on a UG472 misreading — placement was already correct in both Phase A and Phase B (verified from `report_clock_utilization` against both routed `.dcp`s — identical MMCM/BUFR/BUFIO sites).

### How we caught it in one ILA capture

`tcl/capture_dvi2rgb_lock.tcl` programs Phase B, arms the ILA on falling edge of `aLocked`, captures pre/post. With `CONFIG.kDebug {true}` on dvi2rgb, the IP bakes in a 6-probe ILA exposing aLocked, rRdyRst, rMMCM_Locked, etc. — enough to discriminate IDELAYCTRL-path vs MMCM-path failure.

First capture: **rRdyRst stayed 0 throughout the unlock event, rMMCM_Locked dropped first.** 200 MHz refclk innocent; MMCM is the failure point.

But that still left two MMCM-side hypotheses (TMDS input clock dropping vs MMCM disturbed despite valid input). Discriminator: route the MMCM's `CLKINSTOPPED` output to one of the existing ILA probes (a 3-line edit in `~/fpga/vivado-library/ip/dvi2rgb/src/TMDS_Clocking.vhd` — already reverted after diagnosis). Second capture: **CLKINSTOPPED rose 2 cycles BEFORE rMMCM_Locked dropped, then cleared after the MMCM reset state machine fired.** Definitive — the TMDS clock at the MMCM input is briefly stopping. No FPGA-internal cause could produce that signature; the source side is responsible.

### Lessons for next time

1. **For dvi2rgb lock flicker, suspect the source first.** Hours of FPGA debugging started with an assumption that the FPGA design was at fault. The bench-side counter-evidence (Phase A works with the same source) was misleading — it just meant Phase A's simpler design relocked fast enough to hide the dropout, not that the FPGA was solely responsible. Try a known-good source like a MacBook before deep diving on placement/constraints.
2. **When pLocked flickers, instrument both `rRdyRst` and `CLKINSTOPPED` before tweaking anything.** Both failure paths produce identical LED behavior. Without ILA, every experiment is a guess.
3. **Capture artifact reference:** `build/ila-capture/dvi2rgb_lockfall_*.csv`. First capture proved MMCM-path failure; third capture (with CLKINSTOPPED on the dbg_rDlyRst probe) showed source-side TMDS dropout.

### State at end of session

- IP source restored to vendor-original (CLKINSTOPPED probe revert).
- `tcl/build_phase_b.tcl`: `kDebug {true}` removed from dvi2rgb. Re-enable when next ILA capture is needed.
- `constraints/zybo_z7_20_phase_b.xdc`: no MMCM LOC / BANDWIDTH overrides — design uses placer's natural placement (which is correct).
- Phase B bitstream + ELF produce stable 1080p60 desktop video on the monitor with a MacBook source.
- Ready for Phase C (polyphase scaler) work.

### Current best Phase B state (saved in build artifacts)

- Bitstream: `build/phase-b-vdma-passthrough/.../phase_b_bd_wrapper.bit`
- ELF: `build/vitis-phase-b/vdma_init/Debug/vdma_init.elf`
- Behavior: dvi2rgb intermittently locks (~3 sec on / 5-10 off), monitor follows. Real desktop video when LD1 holds.
- Configuration: clk_wiz PLL (200 MHz refclk), dvi2rgb kClkRange=1, rgb2dvi kClkRange=1, all sync wiring goes dvi2rgb → rgb2dvi directly (custom adapter and VTC sync paths disconnected in this diagnostic state).

## (Earlier session work — v_axi4s_vid_out lock issue, now resolved by custom adapter)

Pipeline is at this state at end of 2026-05-13 session:
- VDMA running clean. Both channels free-running master mode (`c_mm2s_genlock_mode=0`, `c_s2mm_genlock_mode=0`, both `c_use_*_fsync=0`).
- S2MM writes real pixel frames into DDR3 (`FB0` contents update as source changes).
- MM2S delivers AXIS to `v_axi4s_vid_out`.
- VTC fully configured (1080p60 timing, generator enabled).
- All register-level checks pass.
- `v_axi4s_vid_out.locked` stays low → no pixels to rgb2dvi → monitor "No Signal."

### Concrete next-session plan

1. **Re-enable fsync wiring with correct VTC fsync register programming:**
   - In `tcl/build_phase_b.tcl`: set `c_use_mm2s_fsync {1}` on the VDMA, set `FRAME_SYNCS {1}` on the VTC, uncomment the `connect_bd_net /v_tc_tx/fsync_out → /axi_vdma_0/mm2s_fsync` line. Cell-order matters — fsync `connect_bd_net` must come AFTER `v_tc_tx` creation (i.e., in the VTC section, not the VDMA section).
   - In `sw/phase-b/src/main.c` `vtc_setup_1080p60()`: after the existing VTC reg writes, add direct writes to the VTC's fsync config registers — **`0xC0` (FSYNC_HSTART0) ← 0** and **`0xC4` (FSYNC_VSTART0) ← 1080**. These tell VTC's generator to pulse `fsync_out` at line 1080 column 0 (start of vblank, just after active video ends). VTC IP-gen-time `CONFIG.FSYNC_HSTART0`/`FSYNC_VSTART0` do NOT populate these runtime registers — runtime PS writes are required. This is why our earlier fsync attempt saw MM2S's `FrmCntIrq` never assert: VTC's fsync output sat at 0 because its HSTART/VSTART were 0/0 (which doesn't generate a pulse-per-frame).
2. **Reorder in `main.c`: VTC setup *before* VDMA init** so by the time VDMA's `XAxiVdma_CfgInitialize` runs, the fsync is actively pulsing. (Last session's attempt at this hit a Data Abort, but that was with a different bitstream — should work with the cleaner fsync register programming.)
3. **Verify via UART diag loop:** MM2S's `SR` bit 12 (`FrmCntIrq`) should toggle every ~16.7 ms. If it doesn't, fsync isn't reaching MM2S — investigate VTC fsync register state.
4. **If `v_axi4s_vid_out.locked` still doesn't assert with proper fsync alignment:** fall back to writing a small Verilog adapter (~50 lines) to replace v_axi4s_vid_out. AXIS in + VTC vtiming strobes → vid_io_out. No internal lock state machine. Outputs an AXIS pixel during VTC's active video, outputs 0 during blanking. Backpressure to MM2S via TREADY. This sidesteps whatever locking criteria v_axi4s_vid_out has that we couldn't satisfy.

### Gotchas to know going in

- VTC pins are discoverable via `get_bd_pins /v_tc_tx/*` (absolute path glob) but NOT via `get_bd_pins -of [get_bd_cells v_tc_tx]` (returned empty in 2025.2 — Vivado quirk).
- Vitis 2025.2 BSP doesn't ship `xvidc.h`; can't use `XVtc_ConvVideoMode2Signal` / `XVIDC_VM_*`. Hardcode timing; direct register writes work fine.
- `xil_printf("%lx", ptr)` is buggy on this BSP — output looks garbled, but underlying values are correct. Verify register-by-register via XSCT, not printf.
- JTAG bring-up order is critical: `connect → rst -system → fpga → ps7_init → ps7_post_config → dow .elf → con`. The `program_phase_b_full.tcl` does this correctly.

### Diagnostic infrastructure (already in place)

- UART diag loop in `main.c` — dumps `MM2S CR/SR`, `S2MM CR/SR`, decoded error bits, `PARK`, FB0 first 4 pixels every 1 sec.
- XSCT register-probe scripts work directly via `mrd -force <addr> <count>` — VDMA at 0x43000000, VTC at 0x43C00000.
- `arm-none-eabi-addr2line -fie .../vdma_init.elf <pc>` resolves PC values from XSCT's `rrd pc` after `stop`.
- Serial terminal: `stty -F /dev/ttyUSB1 115200 raw -echo` then `cat /dev/ttyUSB1` (or use a real terminal program).

## Files

- [`tcl/build_phase_b.tcl`](../tcl/build_phase_b.tcl) — BD construction + synth/impl/bit + XSA export
- [`tcl/build_phase_b_app.tcl`](../tcl/build_phase_b_app.tcl) — Vitis platform + BSP + app build via XSCT
- [`tcl/program_phase_b_full.tcl`](../tcl/program_phase_b_full.tcl) — JTAG load (.bit + .elf via XSCT)
- [`tcl/program_phase_b.tcl`](../tcl/program_phase_b.tcl) — .bit-only load (B.0 baseline, no firmware)
- [`constraints/zybo_z7_20_phase_b.xdc`](../constraints/zybo_z7_20_phase_b.xdc) — pin constraints
- [`sw/phase-b/src/main.c`](../sw/phase-b/src/main.c) — bare-metal VDMA + VTC init + UART diag loop
- `build/phase_b.xsa` — exported hardware platform
- `build/vitis-phase-b/vdma_init/Debug/vdma_init.elf` — built bare-metal app
