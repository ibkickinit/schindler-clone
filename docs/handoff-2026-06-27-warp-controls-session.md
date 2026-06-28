# Handoff — Warp controls session (2026-06-27)

Cold-agent start point for the warp engine + control-plane work done 2026-06-27. Read this, then
`docs/build-manifest.md` (canonical build state) and the memory `schindler_canon_scale_law` (corrected).

## STATE (2026-06-27, end of session)

**Flashed on the board (and banked, reproducible):**
- Bitstream: `build/artifacts/decimate-1080p30-1deg-rotation-frametalign-task58/phase_b.bit` (md5 `e1112da`),
  WNS +0.027. **No HDL change since** — all later work was firmware/daemon/UI.
- Firmware ELF (resynced 2026-06-27, md5 `5390dc89`, in the same bank): continuous 1° rotation hash-LUT +
  diagonal snap, anamorphic X/Y scale (`apply_scale_xy`, `Z x y`), WARN-only-on-downscale, boot matte BLACK.
- **source == flashed == bank** (verified: clean boot, identity FULL opix 2073600 @1080p, black matte).
- Daemon + web UI: all session changes are LIVE (daemon running on `:8080/:8081`). **Browser needs a hard
  refresh** to pick up the latest `index.html`.

**Board is at:** 1080p output, identity (no warp), black matte, daemon up. Osee switcher on **input 3**
(laptop) — `python3 python/bench/osee_switch.py <1|2|3>` (1=SMPTE bars, 2=motion, 3=laptop).

### What shipped this session
- **Continuous 1° rotation** — full 360°, reset-robust, both 720p/1080p (the 10° clamp is GONE). [D1,D2]
- **Anamorphic X/Y scale** — independent X/Y, output-px UI handles + link toggle, `Z x y`. [D3,D4]
- **True 4-corner pin** (image-corner forward model, absolute/independent) — dropped keystone sliders. [D5]
- **Corner-pin + pincushion coexist** (XOR removed). [D6]
- **Pincushion override** restored (toggle widens ±200↔±1000); rotation no longer wipes zoom.
- **Frame-aligned reset** (black-flash mitigation) — built, `N 1` toggle, default OFF, **UNTESTED visually**. [D9]
- **Bug fixes:** anchor-crush [D7], factory-reset black-screen, geom.set neutralized [D7], matte default black [D8].
- **Doc/comment cleanup:** "all scaling write-side" corrected to the real canon everywhere. [D3]

### Concrete next actions (file + verb)
1. ~~**Eyes-on `N 1`**~~ — ✅ DONE 2026-06-28: N 1 WORSE (transition artifacting), N 0 kept default. See OPEN.
2. **Confirm corner-pin directions on monitor** — `+`=OUT, `−`=IN should read the same on all 4 corners;
   dragging one corner's Y must NOT slide a whole edge sideways (that bug is fixed; verify). Daemon
   `_m_corner_set` in `control-plane/schindlerd/schindlerd.py`.
3. ~~**Separate X/Y pincushion**~~ — ✅ DONE 2026-06-28 (see OPEN section / build-manifest).
4. **Characterize rotate+zoom / rotate+keystone cache hash** — re-run the reset-robust sweep across the
   zoom axis (the per-angle LUT is pure-rotation-tuned; combos uncharacterized). Bench harness pattern:
   `/tmp/warp_full_sweep.py` style (regenerate; `/tmp` is wiped on reboot).

## DECISIONS (CLOSED — don't reopen without new info)

| # | Decision | Why | Considered & rejected |
|---|---|---|---|
| D1 | 1° rotation via **per-angle hash-select LUT**, **bench-derived by reset-robustness** | offline working-set model is USELESS at the ≤3 margin (reports =3 uniformly; can't tell silicon-dead 45° from clean 44°). Failures are per-reset BIMODAL. Only re-applying each variant many times (`B 0..8`) finds a truly robust pick. | (a) single global hash constant `(1,15)` — =4 is the NSET=64 floor and **=4 is metastable on silicon** (relocated the dead-band + regressed keystone). (b) model-derived LUT (single-pass) — picked metastable variants that fail on re-reset. |
| D2 | Hash mux = **registered `bmul`** (one variable mult off the per-pixel path) | a 9-way mux of products ×8 setf sites (72 mults) blew the set-index critical path (WNS −3.2). Registering the selected multiplier → +0.027. | 9-way per-pixel constant mux (timing). Also: any new GPIO→reg CDC (`fa1`,`hs1`) MUST get an XDC false-path or the timer chases it to −3.4 and wrecks placement. |
| D3 | **Scale canon: SHRINK = write-side decimate (`Z`); ENLARGE (zoom-in ≥100%) = read-side warp zoom (`invx<4096`).** The warp never DOWNSCALES. | zoom-in fetches FEWER source px → cheap, no bandwidth wall. Downscale-on-read reads MORE → the footgun (that's what `Z` replaces on the write side). | "ALL scaling write-side / warp never scales" (the 2026-06-26 wording) — upscale-on-write is wasteful (stores an upsampled LOD, no detail gain). Corrected in firmware/daemon/4 docs/memory. |
| D4 | Anamorphic X/Y scale = per-axis decimate (<100) / warp-zoom (≥100); `Z <x> [y]` | the scaler out-dims (`scaler_out_dims_write`) and warp `invx/invy` are already independent — nearly free. | — |
| D5 | Corner-pin = **image-corner FORWARD model** (daemon solves output→source homography), absolute & independent; convention **`+`=OUT, `−`=IN** for all corners | the source-corner offset model is an inverse homography → moving one corner shifted the whole map (the "drag TL-Y slides the left edge" coupling bug). | source-corner-offset model (coupling + inconsistent per-corner directions). |
| D6 | Corner-pin + pincushion **coexist** (no XOR) | firmware applies them as separate stages (projective → pincushion → placement); both work. Bench: 10% corner + 15% pincushion = full-frame. | the daemon XOR (a #49 safety) — removed. Caveat: pincushion bows content not the corner-pinned black border (#49 still open). |
| D7 | **`geom.set` (route-B `G`) NEUTRALIZED at the daemon** | `G`/`re_write_geometry` writes `GEO_A/B/C` — the SAME GPIOs as the warp's projective (`warp_apply_homography`) → any `G` clobbers the warp matrix (the "anchor crushed it on the left" bug; factory-reset's `geoSend` re-triggered it). | keeping route-B controls live. Route-B is dead in the warp product; anchor/resample/flip UI hidden. |
| D8 | Matte **default BLACK** | operator preference (was GPIO-default gray). | — (firmware boots `warp_set_matte(0,0,0)`; UI/daemon/factory-reset all default black). |
| D9 | Frame-aligned reset built but **default OFF**, `N 1` toggle | the engine walk is `sof`-gated, so a frame-aligned reset gives ~1 CLEAN frame-boundary blink, NOT zero. True zero needs a double-buffered cache (2× BRAM). Better than the torn mid-frame flash; ship behind a toggle. | reset-at-sof claimed to eliminate the flash (it only cleans it up). |

## OPEN (genuinely unresolved)
- **Frame-align (`N 1`) visual** — ✅ TESTED 2026-06-28 (eyes-on, rotation-toggle compare). **N 1 is WORSE
  than N 0:** visible artifacting during the transition (sof-gated cache rewarm doesn't finish before
  active video on a steep rotation change). **N 0 (legacy immediate) retained as default.** True zero-flash
  still needs the double-buffered cache (2× BRAM) per D9 — `N 1` not worth shipping as-is.
- **Combined geometry cache hash** — rotate+zoom and rotate+keystone NOT characterized (LUT is pure-rotation). If a glitch shows only when zoomed+rotated, that's this, not a regression.
- **Separate X/Y pincushion** — ✅ SHIPPED 2026-06-28 (build `decimate-1080p30-pincushion-xy`, WNS +0.122).
  HDL `kx`/`ky` split, dual-channel `axi_gpio_19`, `I <x> [y]`, `pincushion.set {x,y}`, UI Pin X/Y + link.
  H-only + V-only bench-confirmed on monitor. See build-manifest 2026-06-28 section.
- **Sub-1° rotation** — untestable without interpolated trig (table is per-integer-degree). 45.0° = slope-1 maximal resonance; a 0.2° nudge *might* dodge it (hypothesis, model-blind).
- **1080p geometry bandwidth ceiling** — corner-pin/pincushion combined ~20% clean @1080p; more needs NTILE 512 (BRAM-blocked by the decimate scaler) or a 128-bit DataMover. Pure rotation is fine (all 360 clean).
- **#54 geometry-aware lead** — partially addressed 2026-06-28 by AUTO-TUNE LEAD ON BREAK (firmware
  `decimate-1080p30-autotune-lead`): on a starve the firmware sweeps a lead ladder, applies the lowest
  full lead, and LOGS each (geom,lead,opix) trial (`AUTOTUNE:` lines) to harvest for a static heuristic.
  Root cause of "tiny corner-pin + tiny pincushion breaks": corner-pin's deep lead (~24576) reused by
  pincushion thrashes the cache; clean at moderate lead (~6144). STILL OWED: bake the harvested data
  into `warp_calc_lead` so common combos pick the right lead without the ~3s sweep + transient flicker.
- **#41 two-engine DDR budget**, **#55 Engine-B analog** — pre-existing, untouched.

## GOTCHAS / conventions
- **Daemon owns `/dev/ttyUSB1`.** Kill it (separate command) before JTAG-program or direct-serial; restart after. Pattern: `for p in $(ps -eo pid,args | grep schindlerd | grep -v grep | awk '{print $1}'); do kill $p; done`.
- **After any flash, wait ~12s** for HDMI source re-lock before measuring, or you get false short-frame fails (cost me a false "regression" this session).
- **Verify visuals on the MONITOR**, not MS2109 (it masks artifacts). opix counter is for *starve* only (full opix ≠ correct content — e.g. black matte is "full").
- **`pgrep -f` uses ERE** (`|` not `\|`) AND matches your own shell's cmdline — check process liveness by listener (`ss -ltn | grep :8080`) when the `-f` pattern appears in the command itself. (Two false "build done / procs gone" alarms this session.)
- **Build flow:** `./run_decimate_1080_build.sh` (HDL+firmware, ~35–40min) | firmware-only = `xsct tcl/build_phase_b_app.tcl` (with the env exports, ~10s) | flash = `xsct tcl/program_phase_b_full.tcl`. Bank every build to `build/artifacts/<tag>/` with a manifest.
- **Live UART tuning commands (no rebuild):** `W deg invx invy panx pany hf vf anchor` (rotation/zoom/pan/anchor) · `Z x [y]` (scale) · `C x0 y0..x3 y3` (4-corner) · `K h v` (keystone, legacy) · `I amt` (pincushion) · `B 0..8` (hash-select override, 9+=auto) · `N 0|1` (frame-align) · `L lead` · `R 720|1080` · `T r g b` (matte).
- **Daemon API:** `scale.set {x,y}|{pct}` · `warp.set {deg,panx,pany}` · `corner.set {tl:{x,y}...}` · `pincushion.set {amt,override}` · `matte.set {r,g,b}` · `output.set {mode}`. `geom.set` is a NEUTRALIZED no-op (D7).
- Bench scripts live in `/tmp` (wiped on reboot) — regenerate from this doc's patterns.
