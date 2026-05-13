# Phase A — Bench Test Instructions

**Goal:** validate HDMI passthrough on the Zybo Z7-20. Computer HDMI → Zybo HDMI-IN → FPGA fabric → Zybo HDMI-OUT → external monitor. No processing — just pixel-domain pass-through. First milestone of the HD pipeline development arc per [`dev-roadmap.md`](dev-roadmap.md) Phase A.

## What's built

- **Top-level HDL:** [`hdl/top_phase_a.v`](../hdl/top_phase_a.v) — pure-PL design (no Zynq PS), instantiates Digilent's `dvi2rgb_0` (TMDS RX) and `rgb2dvi_0` (TMDS TX) IP cores.
- **Constraints:** [`constraints/zybo_z7_20_phase_a.xdc`](../constraints/zybo_z7_20_phase_a.xdc) — Zybo Z7-20 pin assignments for both HDMI ports + LEDs + clock + reset.
- **Build script:** [`tcl/build_phase_a.tcl`](../tcl/build_phase_a.tcl) — Vivado Tcl batch build, independent of the Phase 2 project at `build/schindler-2.0/`.
- **Bitstream:** `build/phase-a-hdmi-passthrough/phase-a-hdmi-passthrough.runs/impl_1/top_phase_a.bit` (~4 MB).

## Build status (2026-05-13)

- Vivado 2025.2 + Digilent vivado-library `dvi2rgb` v2.0 + `rgb2dvi` v1.4
- Synthesis: ✅ clean
- Implementation: ✅ clean (2 IP-Flow critical warnings about ILA debug-core packaging — harmless, `kDebug=false` means no ILAs are actually in the netlist)
- Timing: **WNS +1.36 ns, WHS +0.12 ns** — met. Hold is tight but positive; worth monitoring in Phase B+.

## To rebuild

```bash
cd ~/Dropbox/_PROJECTS/Schindler-2.0
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
vivado -mode batch -nojournal -log build_phase_a.log -source tcl/build_phase_a.tcl
```

Build takes ~2–3 minutes on this laptop. The Tcl deletes the build dir first so each run is clean.

## Bench test procedure

### 1. Cable setup

- **Zybo Z7-20** → USB cable to Linux laptop (provides JTAG + UART + power; jumper JP5 on Zybo should be on USB pins).
- **Source laptop HDMI → Zybo "HDMI RX" port.** That's the port closest to the USB connector — labeled `Source` on the silkscreen.
- **Zybo "HDMI TX" port → external monitor HDMI.** The other HDMI port — labeled `Sink` on the silkscreen.

### 2. Load bitstream

Option A — Vivado Hardware Manager (GUI):

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh
vivado
```

Then `Open Hardware Manager` → `Open Target` → `Auto Connect` → right-click the FPGA device → `Program Device` → browse to `build/phase-a-hdmi-passthrough/phase-a-hdmi-passthrough.runs/impl_1/top_phase_a.bit` → `Program`.

Option B — Command line:

```bash
cd ~/Dropbox/_PROJECTS/Schindler-2.0
source /tools/Xilinx/2025.2/Vivado/settings64.sh
vivado -mode batch -nojournal -source tcl/program.tcl  # reuses existing program script
```

(If `tcl/program.tcl` is wired to the Phase 2 build, may need to edit the bit path or copy that script to a Phase A variant.)

### 3. Validate the LEDs first (before HDMI)

After programming, even with no HDMI cables connected:

- **LD0 (M14)** = `mmcm_locked` — should be **ON solid** within a fraction of a second. If OFF, the 125 MHz onboard oscillator isn't being detected (check BTN0 isn't held).
- **LD1 (M15)** = `rx_locked` (HDMI source detected + pixel clock recovered) — should be **OFF** when no source connected.
- **LD2 (G14)** = active-video heartbeat — should be **OFF** when no source connected (no `vid_pVDE`).
- **LD3 (D18)** = `hdmi_tx_hpd` (monitor plugged into HDMI TX port) — should be **ON solid** when the monitor cable is connected.

### 4. Connect source laptop HDMI

Plug the source laptop's HDMI cable into the Zybo HDMI-IN port.

Expected within ~1–2 seconds:

- Laptop should detect a new display (the dvi2rgb IP emulates a 720p EDID). Laptop may mirror or extend its desktop to this "new monitor."
- **LD1 (rx_locked)** should turn **ON solid** — Zybo locked to the HDMI pixel clock.
- **LD2** should start **flickering** (slow blink at the rate of the 24-bit `vde_counter` MSB, which advances during active video).

### 5. Connect monitor HDMI

Plug the external monitor cable into the Zybo HDMI-OUT port.

Expected:

- **LD3 (hdmi_tx_hpd)** turns **ON solid** (monitor sensed via HPD).
- **The monitor should display the laptop's screen.** Same pixels as the source — no scaling, no processing.

### 6. What "success" looks like

- Source laptop sees a 720p-class display
- External monitor shows the laptop's screen
- All 4 LEDs ON solid (LD0, LD1, LD3) plus LD2 flickering during active video
- Pulling the source HDMI cable: LD1 goes OFF, LD2 stops flickering, monitor goes blank
- Reconnecting: full chain comes back up

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No LEDs on at all | Bitstream not programmed, or BTN0 held | Reset (release BTN0), re-program |
| LD0 only, no LD1 when source plugged | EDID negotiation failed, or laptop doesn't like our 720p EDID | Try a different source (PC vs phone vs Pi); try lower-res 720p HDMI output forcing |
| LD1 ON, LD2 not flickering | Source claims a mode but isn't outputting active video | Check source side — display arrangement, refresh rate |
| LD1 + LD2 active but monitor blank | TMDS_OUT not driving cleanly | Try a different monitor (some are picky about non-CEA-861 timing); check HDMI cable; oscilloscope on TMDS_OUT pairs |
| Random LED flickering | Reset or clock noise | Check that BTN0 isn't being bumped |

## Forward-looking notes

- **Phase A is the simplest path to a working HDMI pipe.** No frame buffer, no buffering, no clock-domain crossing. Phase B replaces this simple pixel-domain wire with an AXI4-Stream Video pipeline through Xilinx AXI VDMA + Z-7020 DDR3 — that's where real processing becomes possible.
- **HDL ports to TE0720 1:1** when the production migration activates. The Zybo's onboard HDMI infrastructure becomes the LT8619C + ADV7511 chip pair on the production carrier, but the FPGA-side HDL is the same parallel RGB interface.
- **The Phase 2 R-2R DAC composite encoder HDL** (`vid_timing.v` + `vbi_gen.v` + `chroma_gen.v` + `sample_gen.v`) is untouched. Sits in `hdl/` alongside `top_phase_a.v`. Will be reattached as the NTSC composite encoder terminal off the HD signal bus in Phase G.

## Files

- [`hdl/top_phase_a.v`](../hdl/top_phase_a.v) — top-level
- [`constraints/zybo_z7_20_phase_a.xdc`](../constraints/zybo_z7_20_phase_a.xdc) — pins
- [`tcl/build_phase_a.tcl`](../tcl/build_phase_a.tcl) — build script
- `build/phase-a-hdmi-passthrough/` — generated build artifacts (excluded from git via existing `.gitignore`)
- `build_phase_a.log` — most-recent build log
