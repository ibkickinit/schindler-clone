# Control-plane warp UI — v1 + roadmap (2026-06-26)

## v1 SHIPPED (host-side, daemon + UI; no board change)
Wires the locked two-stage warp (Bite 1/2) into schindlerd + the web UI.

**Daemon (`schindlerd.py`) — new special methods (send_raw + clamp + `*.changed` broadcast):**
- `sheet.set {h,v,override}` → `K h v` (keystone/corner-pin, the simple sheet-warp driver).
- `pincushion.set {amt,override}` → `I amt` (radial; corners pinned).
- `matte.set {r,g,b}` → `T r g b`.
- `output.set {mode}` → `R 720|1080` (720p60 / 1080p30 today).
- **XOR**: daemon holds `_sheet_mode`; setting keystone non-zero clears pincushion and vice-versa
  (#49 — they don't compose: pincushion is post-corner-pin so the black border wouldn't bow).
- **Clamps**: conservative single-engine 1080p envelope (keystone/pincushion ±150 ‰); `override:true`
  unlocks toward the firmware limit (±900 / ±1000). Will be tightened by the two-engine measurement.

**UI (`web/index.html`):**
- "Sheet Warp" section: mode select (None / Keystone / Pincushion), keystone H/V sliders OR pincushion
  slider (shown per mode), `override` checkbox (widens ranges), matte colour picker.
- Output section: live resolution/rate `<select>` (720p60, 1080p30 enabled; 720p50/1080p24/25 disabled
  "firmware TODO"; 1080p60 disabled "Zybo serializer").
- Engine 2 → Output B: stub section (disabled) describing the analog path + that controls activate when
  engine B is wired.

## Staged follow-ups
1. **End-to-end live test** — after the #48 build programs, start schindlerd against the board and drive
   the new sheet/pincushion/matte/output controls from the browser; run `tests/test_web_smoke.py`.
2. **Engine B bandwidth build (task #41)** — instantiate a 2nd read engine reading the ring from DDR
   (real contention), route its RGB+sync to a spare Pmod (pre-wire for analog), output otherwise
   terminated/ILA. Measure engine-A edge-limit derate with B running → set the production two-engine
   clamps. No external clock (run B at 74.25 MHz).
3. **74.25-family firmware modes** — add VTC timing tables for 720p50 / 1080p24 / 1080p25 (same clock,
   just blanking), extend firmware `R` + daemon `output.set` map, enable in the UI select.
4. **State readback + profiles** — expose sheet/pincushion/matte/output current state in the firmware
   status so the UI reflects live values on connect; add them to profile save/load.
5. **59.94 family** — MMCM fractional / psincdec for 59.94/29.97/23.98 (on-board clock, more fw work).
6. **Engine-2 UI activation** — mirror Engine-1 geometry/sheet-warp/color once engine B is in the build.

## CANON (2026-06-26, clarified 2026-06-27) — SHRINK write-side, ENLARGE read-side
SHRINK routes through the ONE write-side scaler (scaler_top, pre-S2MM); ENLARGE (zoom-in) is the read-side
warp zoom (invx<4096), which is legit and kept. Scale-DOWN must go through the scaler (`Z <pct>` /
apply_scale → decimate source to a compact LOD → low warp fetch). The warp READ must NEVER downscale:
`W <deg> <invx> <invy>` with invx>4096 is a read-side downscale-FETCH = the bandwidth wall (bench: a
90% warp-scale + 10° + 15% pincushion STARVED at the default deep lead; only a hand-tuned shallow lead
clawed it back — a self-inflicted problem). Up-scale (zoom-IN, invx<4096) IS fine on the warp (fetches
less). `Z` already does the right thing: down → write-scaler, up → warp zoom-in.

UI implications (fix in v1 before the live test):
- Add daemon `scale.set {pct}` → raw `Z <pct>` (the unified, correct scale knob). The UI Scale control
  should drive THIS for down-scale, not the warp-zoom (warp.set zoom<100 = read-side downscale = footgun).
- `warp.set` "zoom" should be limited to zoom-IN (>=100%) or removed; expose rotation separately.
- Minor: warp_calc_lead mis-picks the deep downscale lead (24576) when rotation+mild-read-downscale are
  combined (wants ~4096). Low priority once scale is forced through the write-scaler (the read-downscale
  case shouldn't occur in normal UI use). Note alongside task #50's res-aware lead work.

## Position / Shift X/Y wired to warp PAN (2026-06-27)
Shift X/Y (UI handle `geo-px`/`geo-py`) now drives the warp **placement pan** via
`warp.set {panx,pany}` → firmware `W <deg> <invx> <invy> <panx> <pany>` (5-arg). Previously it called
`geom.set`/`'G'` (route-B, **inert** in the warp build — the handle did nothing). Daemon `_m_warp_set`
holds `_warp_panx/_warp_pany` so pan survives rotation/zoom changes (and apply_scale re-applies it on Z
scale). Clamp ±2560/±1440 OUTPUT px (image may leave frame; matte backfills — canon signed-window).
Verified via WS: pan holds across `deg` change, off-screen value clamps. `syncGeoUI()` no longer touches
`geo-px/py` (they're warp-owned, not geom-owned).

### Deferred: separate "Output alignment" control (task #56)
Pan = move CONTENT inside the sheet (matte fills the vacated edge). A *different* position semantic —
translate the WHOLE sheet (image + matte + black exterior) via a uniform delta on all 4 corner-pin coords
(projective `m_a..m_h`), so black grows on one side — is wanted for physical projector/panel mount
alignment. Expose later as its own control (likely inside the corner-pin panel as "move all 4 pins by the
same delta"), NOT mixed into the main Position handle (border behaves oppositely → confusing).
