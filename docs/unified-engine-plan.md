# Unified Tile-Cache Warp Engine — Scope, State & Plan

**Living document.** This is the persistent source of truth for the warp/scale engine effort.
It survives context compaction and onboards new agents. Update it as state changes.

Last updated: 2026-06-25 eve · Branch: **`decimate-on-write`** (off the clean pivot `137b13d`)

---

## ★ CURRENT DIRECTION (2026-06-25 eve): DECIMATE-ON-WRITE — read the §D plan first

After the tiled-write paths failed (shear via the bursty scaler; empty-ring via the vestigial VDMA MM2S —
see §4 W1-B history), the architecture pivoted to a cleaner model that **dissolves the downscale-bandwidth
problem** instead of fighting it.

**THE IDEA.** Today the *warp* does the SCALE (reads a fixed-res LOD, downscales for sub-100%) and that
downscale-on-read is the bandwidth wall. Instead: the **scaler decimates the source to the scale-appropriate
size on the WRITE side**, the S2MM writes that small LOD into the ring, and the **read engine reads it at
~1:1** (cache-friendly — NO downscale fetch). SCALE moves to the scaler (quality polyphase decimation),
GEOMETRY (rotate / keystone / position) stays on the warp. Upscale (>100%) stays the warp's zoom-in
(already clean).

**WHY IT'S CLEAN (key insights, operator-derived 2026-06-25):**
- The warp **read engine + frame ring ARE the MM2S replacement.** In the warp build the VDMA MM2S is
  vestigial (connected, unused — warp drives output via re_mux/s1). We use only the VDMA *S2MM half*
  (write + `s2mm_frame_ptr_out`). → So there is **no MM2S to diverge from S2MM** → the
  "[[schindler_genlock_geometry_must_match]] / G1 reframe blacked out HDMI" failure mode **cannot happen**:
  the S2MM is free to write a RUNTIME-sized decimated LOD and the warp just adapts its read.
- The scaler sits **BEFORE** the S2MM (decimate-on-write), not after — so NO DDR read-back/retile. One
  decimating write, one 1:1 read, per engine. (The failed MM2S-retile was the opposite "process-after-S2MM"
  read-back pattern.)
- **Quality:** scaler is an 8-tap polyphase core; it AVERAGES (does not drop). Kernels: NN(drop — avoid) /
  2-tap boxcar (prod default) / 4-tap boxcar / [8-tap polyphase reserved]. Deep decimation (50% scale =
  ~3× from a 1080 source) wants **4-tap** (2-tap under-filters at 3×). 4-tap is runtime-selectable (iter14
  `k h/v 2`). This is a quality UPGRADE over the warp's old bilinear-2-tap downscale.
- **Two engines = two parallel rings at two LODs.** source ─broadcast─► {scaler_A→S2MM_A→ringA→read_A→HDMI},
  {scaler_B→S2MM_B→ringB→read_B→analog}. Each decimates to its own runtime scale-res. Because both reads are
  ~1:1, the two-engine DDR budget (W2) gets EASIER, not harder. (Cost: 2 scalers + 2 rings + 2 read engines —
  needs a 7020 BRAM/LUT fit check; SD engine's scaler is small. Prove single-engine first.)

**REALTIME.** scaler out-res (G1) + kernel (iter14) are both GPIO/runtime → firmware reprograms decimation
per scale-change (~1-frame granularity; possible 1-frame VDMA-reprogram glitch only while dragging).

**THE PLAN (single-engine 720p first):**
  D1. ✅ DONE (commit `4508d49`). Port the **G1 runtime-output scaler** (runtime OUT_W/OUT_H in
      scaler_h/v/top — `iter5-1080p-clean` @ `ffcd4ce`) onto this branch. scaler_top_tb PASS, identity
      path unchanged. Cherry-pick applied clean.

  ★★ D2 REFRAMED (2026-06-25 late eve) — SUB-WINDOW WRITE, FIXED-RES FRAME, **NO warp HDL surgery.** ★★
      The user requirement "**each engine works from an LOD equal to its OUTPUT RESOLUTION, never switch
      LOD within an engine**" means the warp SOURCE FRAME is FIXED at output res (1280×720) and never
      changes. So we do NOT make warp IN_W/IN_H runtime (that was a 4-module address-math surgery —
      pg_tile_dma stride, pg_tilecache clamps, pg_projective window + CDC — high risk, hard to bench-verify).
      Instead:
        • The scaler DECIMATES the source to a small raster (e.g. 640×360 for 50%) via the G1 out_w/out_h
          GPIO (D1) — content quality = polyphase, runtime.
        • The VDMA S2MM writes that small raster as a **SUB-WINDOW** of the fixed 1280×720 frame
          (HoriSizeInput=out_w·3, VertSizeInput=out_h, **Stride FIXED = OUT_W·3 = 3840**, base unchanged →
          top-left anchor). Runtime, firmware-set per scale-change. Safe because MM2S is vestigial → no
          [[schindler_genlock_geometry_must_match]] trap (that needed a live MM2S; here only S2MM is used).
        • The warp reads the FULL fixed 1280×720 frame at **IDENTITY** — the bench-proven clean read path
          (137b13d whole-image). Content occupies the top-left out_w×out_h; the rest is **pre-cleared
          DDR matte**. The "small picture" = content physically smaller in a fixed frame, NOT a warp
          downscale-fetch → the starve wall is DISSOLVED, not fought.
        • Firmware pre-clears the ring frames to matte on scale-change (covers scale-DOWN stale region;
          cheap transient memset, not per-frame).
      BD work DONE (this session): axi_gpio_1 made dual-channel — ch2 (gpio2_io_o) bits[15:0]=OUT_W,
      [31:16]=OUT_H drives scaler out_w/h_async (default 0x02D00500=1280×720=identity). scaler_bypass_1080p
      + scaler_crop_bypass given matching out_w/h_async stub ports (module-agnostic BD convention).
  D3. **Firmware: decompose the user transform** → SCALE = scaler decimation (out_w/out_h GPIO + VDMA
      sub-window geometry + matte-clear + auto-center warp translate so default downscale is centered) ;
      GEOMETRY = warp 1:1 rotate/translate/keystone. Downscale→scaler; upscale→warp zoom; 100%→1:1.
      Set kernel = 4-tap for deep decimation (`k h/v 2`). Add a daemon `scale.set <pct>` command.
  D4. Build + bench: clean whole-image at 100%, **clean downscale to 50%** (no starve, polyphase quality),
      clean rotation/keystone, upscale to 200% via warp zoom.
  D5. Then instantiate the **second engine** (broadcast source, 2nd scaler/ring/read) + the W2 fit check.
      NOTE: with the fixed-per-engine-res model, the 2nd engine is a 2nd BD instance at SD res — no
      runtime-source-dim engine needed; each engine's frame res is its (build-time) output res.

**BASE = the clean pivot `137b13d`** (warp + projective + scaler_top + color + VDMA raster ring + clean
whole-image, bench-proven). NOT iter5 (it has the G1 scaler but no warp engine — grafting the warp would be
the bigger job). The dead-end tiled/retile experiment code (pg_raster_to_tile, pg_tile_s2mm_cmd,
RASTER_TO_TILE conditionals) is INERT in the decimate-on-write config — prune later for tidiness.

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

- **W1 ✅ Dest-res-master — clean 50% BENCH-VALIDATED (2026-06-25).** Move the scaler in FRONT of the tile-writer:
  scaler reduces master → this engine's output-res LOD → `raster_to_tile` tiles the LOD → ring does
  0.5–2.0× of it. Make **LOD size, tile-frame geometry (currently hardwired 1920×1080/8040 tiles),
  and warp source dims** runtime params. This delivers clean 50% and retires the mip.
  - **W1-A ✅ Runtime tiler geometry (sim-proven, commit `6eab0fb`).** `pg_raster_to_tile` IN_W → BRAM-
    sizing MAX + new runtime `in_w` input drives address math/tiles_x (height was already band-runtime).
    `pg_tile_s2mm_cmd` FRAME_BYTES (BTT) + SLOT_STRIDE → runtime inputs. BD wrappers pass them through.
    `sim/run_path_b_dedicated.sh` all PASS incl. runtime-width proof (tiler synth max 64, active in_w=32,
    8-frame ring-wrap bit-exact). 
  - **W1-B ✅ BENCH-VALIDATED 2026-06-25 (commit `32e66fb`, artifact `unified-engine-destres-720p-
    scaler_top-enable-32e66fb`).** scaler_top reduces source→1280×720 LOD; tiler tiles the LOD (in_w/
    frame_bytes/slot_stride driven by xlconstants); pg_re_0 source=1280×720 (TILES_X=80 writer==reader).
    **DEST-RES DELIVERS CLEAN 50%:** uniform downscale opix/frame=921600 (full) at 100/80/67/57/**50%**,
    margin to 40%, falls off only at 33% (beyond spec). Upscale 133/200% + rot 30/90 all 921600. The
    full-master path teetered at 67%/50% (82k–845k); reading the pre-scaled 720 LOD bounds the working
    set. **SPEC (0.5–2.0×) MET on silicon.** WNS=+0.0035 (met, razor-thin — scaler_top adds logic;
    margin is a follow-up). Identity is now a 1:1 LOD→output map = whole image (visual check owed).
  - **W1-B-tiled ❌ ABANDONED (scaler→tiler corruption).** The dedicated-DMA tiled write
    (scaler_top→pg_raster_to_tile) produces a persistent 640-seam shear. JTAG DDR forensics proved it's
    write-side (scaler's bursty/variable-length output corrupts the count-based tiler); the AXIS FIFO and a
    TLAST-delimited tiler BOTH failed to fix it (DDR byte-identical). Builds 32e66fb/cd24288/b168c06.
  - **W1-B-pivot ◐ PARTIAL WIN, bench 2026-06-25 (commit `137b13d`, artifact unified-engine-destres-720p-
    scaler_top-enable-137b13d).** Pivoted to the PROVEN scaler_top→**VDMA→raster** write + warp **TILED=0**
    strided read of the 1280×720 LOD. **SHEAR GONE** — DDR raster clean every row (JTAG-verified), identity
    + rotation + zoom-in full 921600, and **100% = whole image** (the goal). BUT **downscale STARVES**
    (80%/67%/50% = 219–310 rows) — the TILED=0 strided read lacks throughput for downscale. So the two
    problems are now SEPARATED: shear=FIXED (VDMA raster), downscale-bandwidth=needs tiling (which corrupts).
    WNS +0.286. This is the cleanest usable warp build to date (clean whole-image identity/rotation/zoom).
  - **W1-B-next ◐ DDR retile via VDMA MM2S (IN PROGRESS — the chosen fix for downscale BW + clean picture).**
    Reuse the VDMA's existing MM2S leg (24-bit, framed tuser=SOF/tlast=EOL, dynamic-genlock slave, PROVEN) to
    read the clean raster back from DDR ring A → feed the EXISTING Path-B tiler chain → write tiles to DDR
    ring B → warp reads ring B TILED=1 (full downscale BW). The MM2S delivers a STEADY fixed-length raster,
    not the bursty scaler that corrupted the tiler. **NO new HDL** (all blocks exist; MM2S↔tiler contract
    matches). Latency cost ~1–2 frames. Design map (agent-verified):
    * 2 DDR rings: A raster @0x10000000 stride 2,768,640 ×7; B tiled @**0x11400000** stride **2,768,640** ×7
      (use 2,768,640 NOT the tiler's 6,226,560 — else 7-slot ring overruns into MIP_L1 @0x12991180).
    * Genlock: stage1→2 = VDMA internal (S2MM master mode2 ↔ MM2S slave mode3); stage2→3 = wr_cmd gray
      frame_ptr_out → pg_re_0/frame_ptr (existing RASTER_TO_TILE branch, widen gate to ||DDR_RETILE).
    * HP map: HP0=VDMA(S2MM+MM2S), HP1=warp read B, HP2=tiled write B (re-enable). No HP3.
    * Tiler chain moves to **pclk_out** (=mm2s_aclk, 148.5MHz, source-independent) + rst_pixclk_out.
    * Feed tiler from `axi_vdma_0/M_AXIS_MM2S` via an axis_broadcaster (leg→tiler, leg→re_mux/s0 fallback);
      warp still drives output via re_mux/s1 (sel=1).
    * **pg_re_0 needs CONFIG.FRAME_BUF_BASE {0x11400000} ADDED (currently absent → defaults 0x10000000).**
    * Firmware: gate `DDR_RETILE` (+DEST_RES_LOD, NOT PATH_B_DEDICATED_DMA so both VDMA channels run);
      FRAME_W/H=1280×720; warp lead tiled-table (8192). Build env: WARP_ENGINE=1 PROJECTIVE_BUILD=1
      SCALER_MODULE=scaler_top OUTPUT_MODE=720p DDR_RETILE=1 (do NOT set RASTER_TO_TILE).
    * Risks: MM2S per-LINE tlast (tiler rolls band-row per tlast — needs per-line not per-frame); pclk_out
      domain (flip ALL tiler-block pclk_in refs + reset); both ring-B bases (wr_cmd + pg_re_0).
  - **W1-B-retile-MM2S ❌ DID NOT WORK (3 builds, 2026-06-25 eve).** Reused the VDMA MM2S to read ring A
    back into the tiler (DDR_RETILE, commits up to `ac36487`). Tiled ring B stays EMPTY (251/8192 nonzero)
    and the MM2S asserts `SOFEarly` — the tiler never produces frame-starts, so wr_cmd never issues tiled
    writes. Fixed a real broadcaster-stall bug along the way (axis_broadcaster M01→re_mux/s0 held tready=0 on
    the unselected mux input → starved the tiler feed; dropped the broadcaster, MM2S→tiler direct) but the
    EMPTY-ring-B + SOFEarly PERSIST. Conclusion: the VDMA MM2S genlock/pacing is too coupled to its
    video-output role to repurpose as a steady tiler feed. WNS +0.308 (build is fine; the dataflow isn't).
  - **W1-B-retile-dedicatedDMA ☐ THE ROBUST PATH (deferred decision).** The original design (agent a8196e20):
    a DEDICATED axi_datamover MM2S on HP3 + a small command-gen (pg_retile_rd_cmd: gray2bin(s2mm_frame_ptr)-1,
    BTT=1280*720*3, triggered by source-vsync pulse) + a framer (pg_unpack 64→24, exists; assert SOF). This
    bypasses the VDMA-MM2S coupling entirely — clean steady read. MORE new HDL (rd_cmd + framer + HP3) +
    another build cycle. Full map in the design-agent transcript; rings/genlock same as the MM2S variant.
  - **W1-B-alt ☐ other fallbacks:** root-cause scaler bursty-output corruption; or 128-bit read DM for TILED=0.
  - **W1-C ◐ Runtime per-engine LOD (deferred to multi-engine).** Today LOD is build-time (xlconstants +
    pg_re_0 CONFIG + scaler_top fixed OUT_W/H + firmware FRAME_W/H). True runtime per-engine res needs:
    xlconstants→GPIO (firmware-set), scaler_top OUT_W/H made runtime, firmware LOD from a define/GPIO.
    Folds into W2 (two engines, each runtime res). Not needed for the clean-50% goal.
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
