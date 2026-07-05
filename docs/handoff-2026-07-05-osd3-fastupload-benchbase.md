# Handoff — OSD-3 + fast image upload + bench base (2026-07-05)

Cold-agent start point for the work done 2026-07-05 (OSD-3 interactive menu, faster DDR image upload,
OSD auto-scale/baseline-font) and for **setting this build as the base for bench work** (chroma
scope-tune, ADV7393/Si5351 analog bring-up).

**Read next:** `docs/build-manifest.md` → the **⭐ CURRENT BENCH BASE — 2026-07-05** section (canonical
reflash target). Warp-engine decisions from the prior session are still valid — see
`docs/handoff-2026-06-27-warp-controls-session.md` (D1–D9). Memory: `schindler_ddr_image_playback`,
`schindler_osd_chargen`.

## STATE (2026-07-05, end of session)

**Bench base — flashed, archived, pushed:**
- Bitstream: **auto-scale OSD build, commit `b71b589`, WNS +0.286.** No HDL change since — all later work
  is firmware/daemon/UI.
- Firmware ELF: **OSD-3 menu, commit `696b37c`.**
- Archived (reproducible): `build/artifacts/bench-base-osd3-2026-07-05/` — `.bit` + `.elf` + `PROVENANCE.txt`.
- Pushed: branch **`v1-tsg`** → `origin` (`git@github.com:ibkickinit/schindler-clone.git`), HEAD `e13ffe9`.
- **source == flashed == bank == pushed.** Working tree clean.

**Board is at:** 1080p30 output, clean/valid timing, daemon up (`:8080` HTTP / `:8081` WS JSON-RPC).
Reflash the base: `xsct tcl/program_phase_b_full.tcl` (loads `.bit` + `.elf`).

### What shipped this session
- **Faster image upload — ~90s → ~18s** [D1]. 1-slot JTAG write + new firmware `O i` fanout
  (`ring_fanout_slot0()` memcpys slot 0 → all 7 ring slots at DDR BW). Image confirmed on monitor.
- **OSD-3 interactive menu** [D2,D3]. Single-level list menu in the pg_osd grid, bound live to the control
  globals (Source/Pattern/Bright/Saturat/Gamma/Temp/Chroma/Mono). Nav `Y m o|x|u|d|-|+`; daemon
  `osd.menu {action}`; web Menu row. Browser→firmware verified (pattern 0→3 e2e).
- **OSD auto-scale + auto-center** (`b71b589`) — pg_osd measures active region, 2× cells @1080p / 1× @720p,
  box auto-centered. **Baseline-aligned font** (`305f4a9`) — glyph bottoms align, descenders hang.
- **OSD compositor integrated on the HDMI path** (`5b2fb00`) — pg_osd after warp+color, visible over any source.

### Concrete next actions (bench — needs you + scope/hardware)
1. **Chroma scope-tune** — burst phase + gain on a real NTSC monitor. HDL is sim-proven
   (`hdl/pg_chroma_mod.v`, `E k 1` enables); PHASE_INCREMENT 0x21F07BD7 @27MHz. Only bench observation left.
2. **ADV7393 + Si5351 analog bring-up** — check replacement-chip status first (was NAK/dead; memory
   `schindler_phase_g_paused`, `si5351_chip_missing_restart`). Add the 1kΩ RESETB + I²C pull-ups noted there.
3. **(Optional, with scope) fix freeze VSIZE reg** [D4] — `sw/phase-b/src/main.c` `O z` handler re-arms
   VSIZE `@vb+0x80`; S2MM reg-direct VSIZE is `@vb+0xA0` (see `s2mm_set_geometry`). Latent; fix WITH eyes-on.

## DECISIONS (CLOSED — don't reopen without new info)

| # | Decision | Why | Considered & rejected |
|---|---|---|---|
| D1 | Fast image upload = **1-slot JTAG write + firmware `O i` fanout** | JTAG is ~340 KB/s; writing 1 slot (~6MB, ~13s) + PS memcpy fanout (tens of ms) beats writing all 7 (~43MB, ~90s). Verified byte-exact at DDR level (all 7 slots == slot 0, frozen). | (a) 7-slot JTAG write — 90s, the baseline. (b) "park the read engine on ONE known slot" so only 1 slot needs writing — deferred (needs a firmware image-mode + knowing the genlock parked slot; fanout is simpler & robust to which slot is parked). (c) faster transport than JTAG (bake in ELF / net) — deferred; JTAG is the only bulk path to bare-metal PS. |
| D2 | OSD-3 menu nav verb = **`Y m ...`** (grouped under the OSD verb), NOT `M` | `M` is ALREADY the warp mip-fill (`WARP_BUILD`) / Mackin-blend (`GEO_A_BASE`) verb. The dispatch is a first-match `else if (op==...)` chain, so a new `M` branch was **dead code**. Cost a long detour to find. | standalone `M` verb — collided; the `M` menu branch never executed. |
| D3 | OSD-3 = **single-level list menu**, each item calls the **SAME setter the UART verb uses** (`engb_write`/`cp_set_sat`/`colortemp_preset`+`operator_apply`/`gamma_load`) | menu and CLI stay in sync (no drift); minimal code, no new HDL. Bench-verified (pattern 0→3 browser→firmware). | submenu tree / `osd_menu.c` state machine — deferred (more complex; not needed for the 8 flat controls). Physical rotary/buttons — deferred (web-driven first). |
| D4 | **Freeze VSIZE-reg bug left UNFIXED** (latent, documented) | the DDR-image FREEZE path only uses the RS-halt `@vb+0x30` (correct) and displays fine; the wrong `@0x80` VSIZE write is on the UN-freeze re-arm, which the display path doesn't use. Changing freeze/genlock geometry blind is risky (memory `schindler_genlock_geometry_must_match`). | fixing it now, blind — risk > reward; do it WITH a scope during bench. |
| D5 | **Firmware app MUST build via `run_dual_engine_build.sh` env** (`OUTPUT_MODE=1080p30 WARP_ENGINE=1 PROJECTIVE_BUILD=1 SCALER_MODULE=scaler_top RASTER_TO_TILE=0 DUAL_ENGINE=1`), never a bare `xsct tcl/build_phase_b_app.tcl` | without `OUTPUT_MODE`, `FRAME_W/H` default to 720p → `SLOT_BYTES=2768640` vs 1080p `6226560` → ring geometry mismatches the 1080p bitstream → scrambled fanout + broken output. **This ate most of the session as a phantom "fanout bug."** | bare app-build (the trap). |

## OPEN (genuinely unresolved)
- **Chroma burst phase/gain** — never scope-tuned on an NTSC monitor (D-next-1). HDL sim-clean only.
- **Analog output (ADV7393 + Si5351)** — not brought up; chip was NAK/dead, replacement status unknown.
- **Freeze VSIZE reg** — latent (D4); fix with scope.
- **OSD menu value read-back to web UI** — buttons drive nav but the browser doesn't yet show live values
  (firmware echoes `MENU[sel] label: value` over UART via `menu_print_current()`; daemon would need to
  parse + push it). Nice-to-have, deferred.
- **Route-B sliders** (deferred pre-existing): scale slider 200% cap, color-temp slider intermittent drops
  (memory `schindler_scale_slider_200_cap`, `schindler_color_temp_slider_drops`).

## GOTCHAS / conventions (this session's hard-won ones)
- **Build firmware with the full env** (D5) — the single biggest time-sink. Always `run_dual_engine_build.sh`.
- **Cached-DDR variables are invisible to JTAG.** `g_menu_sel` lives in cached DDR; the CPU's write sits in
  D-cache, JTAG reads stale physical DDR. Verify firmware effects via **non-cached hardware registers**
  (GPIO20 `0x81270000` = pattern/tsg bits; GPIO22 `0x81290000` bit20 = osd_en).
- **UART TX reads were flaky all session** (RX/sends reliable). Don't trust reading firmware `xil_printf`
  ACKs; verify state changes via JTAG hardware-register reads instead.
- **Dispatch is first-match** `else if (op=='X')` — check for an existing verb before adding one
  (`grep "op == 'X'"`). `M` was defined 3×.
- **Verification surface = the monitor + your clean capture.** MS2109 stick was unreliable this session;
  the webcam (`/dev/video4` this session — devices re-enumerate) overexposes white (OSD boxes look blank).
  Memory `schindler_ms2109_verification_trap`, `bench_observation_tools`.
- Control paths: firmware UART `/dev/ttyUSB1 @115200`; daemon `systemctl --user restart schindlerd`
  (owns the UART — stop it to drive UART directly); web `:8080` static+upload, `:8081` WS JSON-RPC.
