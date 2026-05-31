# Bench Workflow

How verification actually happens. **Read this before claiming anything is "verified."**

## Physical setup

```
Source(s) ──► Osee GoStream Duet switcher (192.168.0.10) ──► Zybo HDMI RX ──► Zybo HDMI TX ──► Bench monitor (Dell)
                          ▲                                                       │
                          │                                                       ├─► (sometimes) MS2109 HDMI capture
                          │                                                       │       on /dev/video4
                          │                                                       │
                          │                                                       └─► (sometimes) Brio webcam pointed at monitor
                          │                                                              on /dev/video2 (or 10/11; re-detect)
                          │
            Inputs to switcher:
              1: ImagePro (static SMPTE bars + grid patterns + diagonal motion)
              2: 4K@24p motion loop ("Quantum" overlay)
              3: Laptop (Justin can remote in and play any content)
```

## Source switching

```bash
python3 /tmp/osee_switch.py 1   # ImagePro static bars
python3 /tmp/osee_switch.py 2   # Motion loop
python3 /tmp/osee_switch.py 3   # Laptop
```

Protocol: TCP/19010, CRC-16/MODBUS framed. Reconstructed from `companion-module-osee-gostream-series` source — see `/tmp/osee_switch.py` for the script. **The `/tmp` location is volatile**; if the script disappears between sessions, it's reconstructed from the protocol spec in memory entry `osee_switcher_topology`.

<!-- AGENT_TASK[docs-5]: Move /tmp/osee_switch.py into the repo at python/bench/osee_switch.py so it survives reboots. -->

## Verification surface rules

### ✅ Bench monitor (real-time eyeball)

**The only valid verification surface for motion artifacts.** Tearing, judder, race conditions, slips — all only visible here in real time.

### ⚠️ Brio webcam (for photo records)

Useful for capturing static content + sharing screenshots. **Multi-frame exposure** (auto-exposure indoors lands at 1/15-1/8 sec = 4-8 monitor frames) means moving content blurs in photos that look crisp on the monitor. Do NOT use webcam photos to claim "this looks blended" — verify on monitor first.

### ❌ MS2109 HDMI capture

**Has its own framebuffer** that absorbs FRC-drift tearing the monitor would reject. Every "PASS" claim pre-2026-05-21 that used MS2109 evidence is now suspect. This is documented as the **MS2109 verification trap**.

**Rule:** never claim picture verification from MS2109 capture alone. Use it for static-content reference / color verification only.

## The no-coin-flip rule

`schindler_no_coin_flip_rule` memory documents this hard rule:

- **⚠️ LUCKY-BOOT** = passed on at least one boot, multi-reboot not ruled out
- **✅ CLEAN** = phase-correct picture stable across ≥3 reboots, with date in the cell

If output coin-flips vsync phase between boots, STOP. Do not bench-test other features on a coin-flipping build — fix root cause or revert.

Reload via JTAG (`xsct tcl/program_phase_b_full.tcl`) counts as a reboot for this rule. Cold-boot from QSPI is the strictest test but rarely needed.

## Standard verification protocol

For a new substrate / iter / feature:

1. **Set Osee to input 1** (ImagePro static SMPTE bars or grid).
2. **Reload firmware** via xsct. Wait for VDMA init messages on UART.
3. **Eyeball monitor.** Picture clean? Note exact symptoms if not.
4. **Reload firmware twice more.** Picture consistent across all 3 reloads? Promote to ✅; otherwise stays at ⚠️ LUCKY-BOOT or downgrade.
5. **Switch to ImagePro diagonal motion.** Strictest tearing test. Eyeball monitor.
6. **Switch to Osee input 2** (motion loop). Eyeball.
7. **Optional: DDR3 dump** via UART command (`F` on phase-e1, `diag_iter` trigger on iter5/mackin) to confirm byte-level state.
8. **Update `../build-manifest.md`** with date + branch + commit + reboot count + observation.

## Suspect equipment first

Memory `schindler_bench_equipment_confounder`: a faulty monitor cost 4 hours on 2026-05-21. **If you observe something architecturally impossible** (e.g., output behaving as if scaler is on when SCALER_MODULE bypass is active), suspect the monitor / cable / source BEFORE assuming an FPGA bug.

## Bench instrumentation tools

Documented in `bench_observation_tools` memory:

- **gst-launch recipe** for low-latency MS2109 capture: `gst-launch-1.0 v4l2src device=/dev/video4 ! image/jpeg ! jpegdec ! videoconvert ! autovideosink sync=false`
- **MS2109 internal bars trap**: capture stick has its own test pattern; verify input first

## What to capture per session

Per the `schindler_build_provenance_rule`, every bench session ends with a manifest update including:
- Date + branch + commit
- What was tested (input format, output format, modes engaged)
- What was observed (image clean? coin-flip? scroll? EOLLate? frame drops?)
- How many reboots verified the result
- If broken: symptom + next investigation step

<!-- AGENT_TASK[bench-1]: 3-cold-boot multi-reboot verification of iter12+iter13+iter13b on iter5-1080p-clean per no-coin-flip rule. Current status is ⚠️ LUCKY-BOOT in spirit (multi-reload verified) but no formal ≥3-boot log in the commit history. -->

<!-- AGENT_TASK[bench-2]: Re-verify ALL ✅/⚠️ rows in format-support-matrix.md HDMI Section §1 on monitor (NOT MS2109). All prior PASS claims are MS2109-tainted per schindler_ms2109_verification_trap. -->

<!-- AGENT_TASK[bench-3]: Cold-boot ≥3 of phase-e1-pll-spike for the no-coin-flip rule. Per commit fcd722c, motion verified clean once, but no multi-reboot record. -->
