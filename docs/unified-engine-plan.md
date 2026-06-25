# Unified Tile-Cache Warp Engine — Scope, State & Plan

**Living document.** This is the persistent source of truth for the warp/scale engine effort.
It survives context compaction and onboards new agents. Update it as state changes.

Last updated: 2026-06-25 · Branch: `unified-engine-destres` (off `warp-demand-fetch-fsm` @ `3783d95`)

---

## 0. One-paragraph orientation

We are building **one** runtime-parameterized read engine (the "unified tile-cache warp engine")
that does scale + rotation + corner-pin + pincushion in a single continuous address-mapped fetch.
It replaces the older orient-ring + `present_geom` stack (retired — couldn't hit the spec).
**Two instances run simultaneously at all times**, each independently set by the user to any output
from composite-SD up to 1080p. The engine lives on `warp-demand-fetch-fsm`; this branch
(`unified-engine-destres`) carries the next phase (dest-res-master + UI convergence + pincushion).

---

## 1. SETTLED SCOPE (agreed with operator 2026-06-25)

These are the product requirements as the operator stated them, with the technical reading.

1. **Scale range: 0.5× – 2.0×.** (300% target relaxed → only 200% needed.) **50% must be clean.**
   - **1080p60: scale DISABLED** (canon — downscale multiplies the fetch past the 60p budget).
   - BUT **1080p60 still allows geometry *trim*: small rotation + non-shrinking corner-pin/keystone**
     (these remap a ~1:1 fetch, they don't multiply it). Caveat: corner-pin that significantly
     *shrinks* the image is downscale-in-disguise → falls back to the ≤30p rule. Cache fit at the
     larger 1080 frame must be verified (rotation/corner-pin cache was proven at 720p).
2. **Each engine works from an LOD = its OUTPUT RESOLUTION. Never switch LOD within an engine.**
   - This is the **dest-res-master** architecture. The scaler reduces the master → this engine's
     output-res LOD; the tiler tiles that LOD; the ring does ±2× of it. One fixed LOD per engine.
   - **Retires** the half-res-mip / LOD-switching idea entirely (dead `mip_*` firmware to remove).
3. **Full corner-pin AND pincushion. Both mandatory.**
   - Corner-pin: already in firmware (`warp_solve_cornerpin`, `C` cmd; projective build).
   - Pincushion: **NOT built** — projective maps straight→straight, can't bow lines. Committed
     net-new non-linear address-gen HDL.
4. **Remove the dedicated keystone handle** — it's a constrained corner-pin, redundant. Drop the
   `K` command + keystone UI panel when porting controls.
5. **Rotation: infinite if possible, else cardinals ± a few degrees.**
   - Infinite/continuous is **proven structurally impossible** on the 4-way cache (every set-hash
     overflows >4-way at some narrow angle band; resonance relocates, never vanishes).
   - Shipped today: **10° rotation grid** (snap 0/10/20/…). Operator's fallback (cardinals±few) is met.
   - **NEW ask:** fine trim **0.1–0.5° within ±a few degrees of each cardinal.** Plausibly clean
     (near-cardinal angles barely shear the tile grid → tiny working set) but must be verified, not
     promised. See work item W5.

### System constraints (load-bearing)

- **TWO engines run simultaneously, always.** Each independently HD↔SD per user resolution/framerate.
  → They **share one DDR/HP bandwidth budget.** Worst case = both fetching hard at once, NOT one
    engine alone. Aggregate two-engine bandwidth is a first-class design item (see W2/§4).
  → Forces **runtime parameterization**: one engine design, instantiated twice, each with its own
    runtime LOD size / tile geometry / source dims / framerate.
- **Engine assignment (relaxes W2 a lot):** Engine A = **HDMI/VGA** (high-res, up to 1080p), Engine B =
  **Composite/Component analog** (SD/ED, occasionally 1080i). **SDI** assignable to either as needed.
  Any PHY that can't do the engine's set res/framerate is **disabled** (engine is master of res; PHYs
  follow or drop). → The two engines are **naturally asymmetric** (analog ≪ HDMI res), so "two 1080p
  engines both downscaling" is mostly off the table by construction. **Operator OK'd clamping combos**,
  so W2 = a small table of legal (A res/fps, B res/fps) pairs that fit aggregate bandwidth.
- **Output resolution range: composite-SD (~720×480) → 1920×1080.** Difficulty of clean-50% scales
  with output res (see §3). 1080p is the binding case.
- **Canon:** 1080p-warp is a **≤30p** feature; **1080p60 = clean passthrough** (no warp/scale).
  60→30 doubles the per-frame fetch budget — the lever that makes 1080p/50% reachable.

---

## 2. CURRENT STATE (what's proven, 2026-06-25)

**Substrate: `warp-demand-fetch-fsm` @ `3783d95` (Path B dedicated-DMA, bench-validated).**
Build env: `WARP_ENGINE=1 PROJECTIVE_BUILD=1 RASTER_TO_TILE=1 SCALER_MODULE=scaler_bypass_1080p
OUTPUT_MODE=720p NO_ILA=1`. WNS +0.027. Artifact:
`build/artifacts/warp-demand-fetch-fsm-720p-scaler_bypass_1080p-enable-49b17ab/` (bit+ELF).

Bench (720p60 output, reading the FULL 1920×1080 master; silicon `opix/frame` is truth, exp 921600):
- **Genlock coherence FIXED.** Dedicated-DMA tiled write/read: identity, rotations (30/90), zoom-in
  (2×) all full 921600 and stable.
- **Tiling INVERTS the old downscale asymmetry.** Old raster path: "H free, V walled." Tiled path:
  **V free (cheap tile-row bursts), H is the per-row cost.**
- **Downscale envelope at the (fixed) 8192 lead, by default:**
  - single-axis downscale (H *or* V alone): **full to 2×**.
  - uniform both-axis downscale: **clean to ~1.4× (71%), marginal/teetering 1.5×–2×.**
- **Lead fix:** tiled downscale lead must be 8192, not the old raster path's 24576 (which thrashes
  the tiled cache → 82–126k/921600). Gated on `RASTER_TO_TILE` in `warp_calc_lead`.

> The 720p60-reading-1080-master bench is **pessimistic** vs the real dest-res design: it fetches the
> whole 1080 tile space to make 720 output. With LOD=720 the tile working set ~halves → cleaner.

**Rotation:** clamped to 10° grid + (1,33) cache hash. Full clean rotation set on the grid.
**Corner-pin/keystone:** in firmware (`C`/`K` UART cmds). **UI NOT on this branch** (see §5).

---

## 3. WHY 50% difficulty scales with output res (the binding-case analysis)

LOD = output res, so:
- **SD engine** (LOD ~720×480): 50% = 2× downscale of 480 lines → tiny tile working set → trivially clean.
- **Mid (480p–720p):** comfortably inside the validated envelope.
- **1080p engine** (LOD = 1920×1080 = the full master): 50% = uniform 2× downscale of 1080 → the
  marginal case measured this session. **No LOD headroom left at the top** (LOD already = output = max).
  → The lever here is **time**: at 1080p**30** the per-frame budget doubles → clean 50% reachable.

**Net:** clean 50% is easy below 1080p (LOD-shrink does it), and at 1080p it's clean specifically at
≤30p. Two simultaneous engines share the budget, so two HD engines both at heavy downscale is the
true worst case → likely both ≤30p, or one HD + one SD.

---

## 4. PLAN / WORK ITEMS

Status: ☐ todo · ◐ in progress · ✅ done · 🔬 needs verification
**Priority (operator-set 2026-06-25):** W1 is the lead (delivers clean 50%). W3 (UI) PARKED — not needed now.

- **W1 ◐ Dest-res-master build (the main change).** Move the scaler in FRONT of the tile-writer:
  scaler reduces master → this engine's output-res LOD → `raster_to_tile` tiles the LOD → ring does
  0.5–2.0× of it. Make **LOD size, tile-frame geometry (currently hardwired 1920×1080/8040 tiles),
  and warp source dims** runtime params. This delivers clean 50% and retires the mip.
- **W2 ☐ Two-engine bandwidth clamp table.** Given Engine A = HDMI/VGA (HD), Engine B = Composite/
  Component (mostly SD/ED) + assignable SDI, produce the **table of legal (A res/fps, B res/fps)
  combos** that fit aggregate DDR/HP bandwidth (operator OK'd clamping). PHY-disable rule applies.
  Asymmetric assignment makes this tractable. HP map today: HP0=VDMA, HP1=warp read, HP2=Path-B write;
  second engine needs its own read path.
- **W3 ☐ (PARKED — operator doesn't need the UI handles now.)** Port corner-pin UI + daemon
  `corner.set` onto this branch, MINUS keystone, when control surface is wanted. UI panels live on
  `orient-integration` (dd4afd5, 62e5bed, 5983031); firmware here already supports `C`. Low priority.
- **W4 ☐ Pincushion (mandatory, net-new HDL).** Non-linear/radial term in the address generator on
  the projective core. Sim-prove, then bench. **Validate cache/lead behavior independently** — non-
  linear excursion per row breaks the affine/projective locality assumptions.
- **W5 🔬 Fine rotation near cardinals.** Offline cache-hash analysis restricted to cardinal±3° at
  0.1° steps (target worst-set-live ≤4), then bench-sweep `opix/frame`. Likely clean; verify before
  promising. Tooling exists (the offline analysis that proved the 10° grid).
- **W6 ☐ Remove dead LOD/mip firmware** (`mip_downsample`/`mip_fill_static`) — wrong approach per W1.
- **W7 🔬 1080p60 geometry-trim envelope.** Verify small rotation + non-shrinking corner-pin fit the
  60p budget at the 1080 frame (bandwidth ~1:1, but cache fit at the bigger frame is unproven — the
  rotation/corner-pin cache was validated at 720p). Define the "non-shrinking" corner-pin boundary
  beyond which it becomes downscale (→ ≤30p). Enables keystone correction at full 1080p60.

### Honest unknowns (do not promise)
- **Infinite/continuous rotation** — structurally impossible on 4-way cache. Only a cache-associativity
  change (BRAM + timing cost) could unlock it; would appear at SD first (more headroom), 1080p last.
  Treat as a separate research bet, not a deliverable.
- **Two HD engines both at 50% simultaneously** — may exceed aggregate bandwidth even at ≤30p; W2 decides.
- **Pincushion cache locality** — unproven; W4 must validate, not assume.

---

## 5. BRANCH MAP (why the corner-pin UI "disappeared")

Two parallel branches since they forked at `2fba7f4` (2026-06-09):
- **`orient-integration`** (tip `5983031`, 06-24): the OLDER stack (orient-ring + present_geom +
  projective front-end). **Your corner-pin/keystone/scale UI was built here.** Hit walls
  (present_geom tiled-vs-linear mismatch retired; scale clamped ≤145%). Can't reach the spec.
- **`warp-demand-fetch-fsm`** (tip `3783d95`, 06-25): the unified tile-cache engine — the deliberate
  pivot. Has the warp/projective firmware + the validated Path B downscale substrate. Its `index.html`
  predates the corner-pin UI work, so the panel isn't here → that's why it's missing from the daemon.
- **`unified-engine-destres`** (this branch): carries W1–W6.

The corner-pin UI was never deleted — it's on `orient-integration`. W3 ports it here.

---

## 6. OPERATIONAL NOTES (bench/daemon, for next agent)

- **Build:** `source /tools/Xilinx/2025.2/Vivado/settings64.sh` then `vivado -mode batch -source
  tcl/build_phase_b.tcl` with the env vars from §2. App ELF: `xsct tcl/build_phase_b_app.tcl` (same env;
  `RASTER_TO_TILE=1` auto-adds `-DPATH_B_DEDICATED_DMA=1`). Program: `xsct tcl/program_artifact.tcl <tag>`.
- **Bench truth = `opix/frame` over UART `/dev/ttyUSB1` @115200**, exp 921600 at 720p. MS2109 capture
  masks artifacts — monitor is the visual authority. Warp UART cmds: `W <deg> <invx> <invy>` (invx/invy
  Q12 inverse-scale, 4096=1:1, >4096=downscale), `L <n>` lead override, `C`/`K` corner-pin/keystone.
- **Daemon:** `~/.local/share/schindlerd-venv/bin/python control-plane/schindlerd/schindlerd.py
  --port /dev/ttyUSB1 --catalog control-plane/schindlerd/../catalog-v0.2.0.json -v`. UI http://127.0.0.1:8080,
  WS :8081. (System python has no pip — use the venv.)
- **Osee switcher** (source select to the Zybo): `python3 python/bench/osee_switch.py <1|2|3>` BUT the
  device intermittently drops SET (set→GET-verify→retry needed; see `/tmp/osee_robust.py`). pgmIndex is
  0-based (0=IN1=ImagePro, 1=IN2=media, 2=IN3=laptop). NOTE 2026-06-25: switching pgmIndex did not change
  the Zybo's program feed at the bench despite confirmed GET — physical feed wiring (PGM vs AUX) unresolved.
