# Glossary

Domain terms used throughout Schindler 2.0 documentation. Search this page first when a term in another doc is unfamiliar.

## Pipeline / HDL

- **dvi2rgb** — Digilent IP that decodes HDMI RX TMDS into RGB + sync. Provides `pLocked` flag indicating source presence.
- **rgb2dvi** — Digilent IP that drives HDMI TX TMDS from RGB + sync. Has the `kClkRange` patch documented in [XILINX-IP-NOTES](XILINX-IP-NOTES.md).
- **v_vid_in_axi4s** — Xilinx IP adapting raw vid_data/vid_sync to AXIS-Video stream. Sync wires must be connected explicitly.
- **axis_to_vid_io** — Xilinx (or custom; check `hdl/`) IP adapting AXIS-Video back to discrete vid_data/vid_sync for VTC + rgb2dvi.
- **axi_vdma** — Xilinx VDMA controller. Manages DDR3 framestore ring with Dynamic Genlock S2MM/MM2S modes.
- **v_tc** (VTC) — Xilinx Video Timing Controller. Generates HSync/VSync/Blank from configured horizontal+vertical timing parameters. `v_tc_tx` is output side; `v_tc_rx` is input-side detector.
- **scaler_top** — Wraps `scaler_h.v` (1920→1280) + `scaler_v.v` (1280→720). The polyphase scaler.
- **scaler_h** / **scaler_v** — Horizontal / vertical scalers. Current production = 2-tap boxcar via iter12+iter13.
- **scaler_crop_bypass** — Diagnostic module that replaces scaler_top with a 1280×720 crop. Pick via `SCALER_MODULE` env var. See `schindler_scaler_crop_bypass` memory.
- **lbuf** — Line buffer. The V scaler has 4 lbufs (lbuf0..lbuf3), each one source row.
- **lbuf_fresh** — Per-lbuf bit indicating "this buffer has been written with current-frame data." Cleared on TUSER, set when row write completes. Gates tap reads so unrefreshed lbufs contribute 0 to MAC.
- **tap0_slot** — Which lbuf is logically "tap 0" of the current emit row. Rotates as input rows advance.
- **v_cross** — V scaler's signal that the accumulator crossed `in_h_active` → emit one output row.
- **vsync_cdc_pulse.v** — Custom module: 2-FF synchronizer + edge detector. Generates 1-cycle pulse on rising edge of async input.
- **axi_sync_inputs.v** — Custom CDC pipeline for AXI-GPIO-driven runtime parameters into the pclk domain.

## VDMA + clocks

- **Dynamic Genlock** — VDMA mode where S2MM dynamically pushes slot pointers and MM2S follows with `repeat_en`. The current FRC substrate.
- **S2MM** — Slave-to-Memory-Mapped (DDR3 write side of VDMA).
- **MM2S** — Memory-Mapped-to-Slave (DDR3 read side of VDMA).
- **PARK_PTR_REG** — VDMA register; firmware-driven slot-park anti-pattern. See `schindler_vdma_dynamic_genlock` memory.
- **FrameDelay=1** — VDMA Dynamic Genlock config — MM2S lags S2MM by 1 frame.
- **c_use_s2mm_fsync** + **c_flush_on_fsync** — VDMA params for hardware fsync mode used by iter6.
- **DTSTAT** — VTC RX detector status register; bit 0 indicates source LOCK.
- **DASIZE** — VTC RX detector active-pixel count register.
- **EOLLate** — VDMA status flag: end-of-line arrived after expected count. Bit 15 of DMASR.
- **EOLEarly** — VDMA status flag: end-of-line arrived before expected count. Bit 14.
- **SOFLate** — Start-of-frame late. Bit 11. Cosmetic post-iter6.
- **FrmCnt_Irq** — Frame counter interrupt request. Bit 12. **BENIGN** — not an error despite scary name.

## Phases & iters

- **Phase A** — HDMI passthrough. The ground-truth baseline.
- **Phase B** — DDR3 VDMA frame buffer. The substrate everything else builds on.
- **Phase C** — Polyphase scaler.
- **Phase D** — FRC via Dynamic Genlock (Methods A + D).
- **Phase E** — Production-grade FRC sub-phased E1-E4 (Gen Lock + Mackin + Triple Buffer + Output Scaler).
- **Phase F** — Geometry warp. Not started.
- **Phase G** — Analog out via ADV7393. Hardware-blocked.
- **iter4d** / **iter4d-3** — Production-clean 60→60 substrate; ancestor of iter5.
- **iter4g** — Diagnostic counter infrastructure.
- **iter4h-axis-fifo** — Failed VSIZE=747 fix. Causes 1-row-per-frame scroll. DO NOT USE.
- **iter5-1080p-clean** — Current production substrate. 1080p + color stack.
- **iter5-bisect-720p** — The bisect endpoint that proved iter4h structurally wrong.
- **iter6** — S2MM hardware fsync. Resolved bottom-bars.
- **iter12** — H scaler 2-tap boxcar with `s_axis_tdata` newest tap. Current H production.
- **iter13** — V scaler 2-tap boxcar `tap2 + tap3` post-rotation. Current V production.
- **iter13b** — +1 round-to-nearest on iter12/13 boxcars. Removes DC bias.
- **iter14** — Deferred runtime kernel-mode toggle. See `../iter14-plan.md`.

## FRC methods

- **Method A — Frame Lock** — Output clock derived from input pclk. No FRC. Matched-rate only.
- **Method B — Gen Lock** — MMCM `psincdec` tracks input rate.
- **Method C — Triple Buffer** — Free-running output + framestore ring. Compat mode.
- **Method D — Drop/Repeat** — Dynamic Genlock NN frame pick. Current shipping FRC.
- **Method E — Mackin Virtual-Shutter Blend** — Phase-weighted 2-frame blend.
- **MMCM psincdec** — Xilinx MMCM dynamic phase shift via DRP port. ±500 ppm pull range.
- **RT4K three-mode** — Retrotink RT4K's user-facing FRC mode picker (Frame Lock / Gen Lock / Triple Buffer). Target UX for Schindler.

## Hardware

- **Zybo Z7-20** — Digilent dev board with XC7Z020 Zynq SoC. Current development platform.
- **TE0720** — Trenz Electronic Zynq SoM. Production target.
- **ADV7393** — Analog Devices video DAC. Drives composite/S-Video/component analog outputs. Currently dead at the bench.
- **EVAL-ADV7393EBZ** — AD evaluation breakout for the ADV7393.
- **Si5351** — Skyworks programmable clock generator. Phase E2 actuator for extended FRC pull range.
- **JESSINIE breakout** — Cheap Si5351 module clone with marginal decoupling. See memory.
- **Osee GoStream Duet** — Switcher at 192.168.0.10:19010. Selects between 3 source inputs. See [BENCH-WORKFLOW](BENCH-WORKFLOW.md).
- **ImagePro** — Test pattern generator on Osee input 1. Static SMPTE bars + grids + diagonal motion.
- **MS2109** — Cheap USB HDMI capture stick. **Has its own framebuffer that masks artifacts.** See MS2109 verification trap.
- **Brio** — Logitech C920-class webcam used to photograph the bench monitor.
- **Pmod** — Digilent connector standard. Schindler uses JB + JD ports.

## Bugs / Heisenbugs

- **MS2109 verification trap** — Pre-2026-05-21 PASS claims using MS2109 evidence are suspect.
- **No-coin-flip rule** — Outputs that differ across boots = STOP and fix.
- **Bottom-bars artifact** — 27-row leak from frame K+1 top into slot K tail. RESOLVED iter6.
- **H-shift** — 2-3 pixel per-line shift, last pixels of row N appear at start of N+1. RESOLVED iter12.
- **V missing-lines** — Every 3rd horizontal grid line vanishing. RESOLVED iter13.
- **DC bias darkening** — Cumulative −1 LSB per channel from truncating boxcar `>>1`. RESOLVED iter13b.
- **CDC width truncation** — Silent upper-bit truncation when sync regs narrower than declared port. Bug class documented.
- **vsync-phase coin-flip** — Stable rolled frames at random per-boot offset. Pre-Phase-E1 issue.
- **Bench diagnostic Heisenbug** — Adding debug instrumentation perturbs the bug. Especially I²C transactions.
- **R-B-G byte order** — Pipeline carries `[23:16]=R, [15:8]=B, [7:0]=G`, not standard RGB.
- **BFBFBF corners** — Fingerprint pattern in DDR3 dumps at grid-line H+V intersections under 2-tap boxcar: `avg(255, 127) = 191 = 0xBF` per channel. Used to recognize "scaler producing expected output" in iter12+13 verification.

## Bench / tools

- **diag_iter** — AXI GPIO bit firmware uses to trigger one-shot diagnostic dumps.
- **dump_slot_bytes** / **dump_slot_head_pixels** — Firmware functions that read DDR3 directly and print to UART.
- **gst-launch recipe** — GStreamer pipeline for low-latency MS2109 capture viewing.
- **picocom** — Serial terminal used for UART interaction. `picocom -b 115200 /dev/ttyUSB1`.

## Methodology

- **Build provenance rule** — Every claim references commit + reboot count + symptom.
- **Suspect equipment first** — When something seems architecturally impossible, check monitor/cable/source before assuming an FPGA bug.
- **Source first** — When pLocked flickers, swap HDMI source before debugging FPGA.
- **HDMI compliance rule** — No out-of-spec MMCM, no non-standard TMDS, no patched vendor IP for margin tricks. See [HDMI-COMPLIANCE](HDMI-COMPLIANCE.md).
- **MS2109 verification trap** — The capture stick masks vertical wraparound + offset artifacts that the bench monitor rejects. Bench monitor is the verification surface, not MS2109.

## V0a control plane

- **V0a** — Host-side bridge daemon + browser UI shipped 2026-05-31. Catalog v0.2.0. No HDL change beyond the firmware `J` UART handler. Bench-host dependency is acceptable for v1.
- **V0b** — Future: PetaLinux on the Zynq PS so `schindlerd` runs on the board itself. No HDL change. Post-v1 per [`v0a-scope-fence.md`](../v0a-scope-fence.md).
- **V0c** — Future: RP2040 front-panel firmware + EVE BT817Q TFT. Requires the Pro v2 mezzanine PCB. Post-v1.
- **Catalog** — Single JSON file (`control-plane/catalog-v0.2.0.json`) declaring every operator-tunable control + read-only status field. Daemon, web UI, and future RP2040 firmware all generate their code from it. See [CATALOG-EVOLUTION](CATALOG-EVOLUTION.md).
- **schindlerd** — Python daemon at `control-plane/schindlerd/schindlerd.py`. Bridges firmware UART (115200 8N1) ↔ WebSocket (`:8081`) + HTTP for the web UI (`:8080`). See [SCHINDLERD-RUNBOOK](SCHINDLERD-RUNBOOK.md).
- **JSON-RPC 2.0** — The wire protocol between daemon and clients (over WS), and between daemon and firmware (over UART). Request/response with `id` field; notifications (status push) have no `id`.
- **J command** — UART prefix: `J {…json…}`. Hand-rolled JSON tokenizer in `sw/phase-b/src/main.c` dispatches to per-control setters/getters.
- **Profile** — JSON file storing `controls: {id: value, …}` with a `catalog_version` stamp. Daemon best-effort applies on `profile.load`; skips ids the current catalog doesn't recognize. See [FACTORY-PROFILES](FACTORY-PROFILES.md).
- **Factory profile** — Read-only profile shipped in `control-plane/profiles/factory/`. Identity/grayscale/warm/cool. Shadowed by same-named user profiles.
- **TelemetryParser** — Daemon-side regex set against firmware DIAG/TELEMETRY/VTC_RX lines. Publishes typed status updates. See [STATUS-PANEL](STATUS-PANEL.md).
- **status.update** — JSON-RPC notification (no id) the daemon broadcasts to subscribed clients when a status field changes value.
- **control.changed** — JSON-RPC notification the daemon broadcasts after every successful `control.set` so all open browsers stay in sync.
- **status.snapshot** — RPC method the UI calls after render to back-fill stable status values that the connect-time replay raced past.
- **available flag** — Catalog annotation set by the daemon: `true` if the firmware reports the control via `system.list_controls`. The UI hides controls with `available: false`.
- **requires_status / requires_branch / requires_hw / requires_iter** — Gating attributes on catalog entries. `requires_status: "placeholder"` forces a control unavailable even if firmware lists it (used today for `frc.mackin_alpha`).
- **surface** — Catalog field listing which operator surfaces should render a control: `["web"]`, `["front"]`, `["front", "web"]`, or `[]` (UART-only meta).
- **FakeSerial** — `tests/conftest.py` drop-in for `serial.Serial` that lets the daemon run against scripted firmware responses without `/dev/ttyUSB1`. Backbone of `make sim`-style CI.
- **catalog.schema.json** — JSON Schema 2020-12 document at `control-plane/catalog.schema.json` formalizing the catalog format. Validated by `tests/test_schema.py`.

<!-- AGENT_TASK[docs-12]: When a new domain term appears in any new doc, add it here. Periodic audit: search docs/ + memory for capitalized acronyms not yet in this glossary. -->
