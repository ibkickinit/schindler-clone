# Orient Engine — clean build plan (spec → bench)

**Date:** 2026-06-10. **Decision:** clean restart (per `orient-engine-decision.md`). This is the
self-contained build plan for a fresh agent to take the orient engine **all the way to a verified
bench test.** Companion: `orient-engine-decision.md` (why), this doc (how).

> **The one architectural idea that makes this clean:** the final scope (cardinal orientations + mild
> warps) is **deterministic** — known-ahead, structured source access. So the engine is a
> **deterministic, double-buffered output-tile pipeline with a direct region buffer — NOT an
> associative cache.** Every hard problem the prior branch fought (set-hash resonance, eviction,
> LEAD×associativity, the 512:1 mux, the −28 ns prefetch cone, the soft-reset black-flash) was an
> artifact of a cache built for *arbitrary* rotation. We don't need that cache. Build the deterministic
> pipeline and those whole problem families never appear.

---

## 1. Spec (frozen)

A production read-engine: captured **1080p source** → **oriented + scaled + positioned** output.

- **Orientation:** the four cardinals **0 / 90 / 180 / 270** only. (Arbitrary rotation is a separate
  future feature — do **not** build for it.) 90/270 are transposes.
- **Scale:** zoom; **100% = fit-to-output** (oriented source fits the raster, letterboxed,
  aspect-preserved). Zoom-in crops, zoom-out shows matte.
- **Position:** signed pan in output pixels; matte fills the vacated edge.
- **Mild warps (phase 2):** keystone / 4-corner / pincushion — bounded-local 2-D warps, bilinear.
  Architect the bilinear path for them; wire them after cardinals+scale+pan are clean.
- **Output:** 1280×720 on the Zybo bench; **1080p60 on production TE0720, same RTL** (Zybo just can't
  serialize 1485 MHz TMDS — `[[zynq7020_rgb2dvi_1080p60_limit]]`).
- **Quality (hard):** no tearing, **no per-change black flash**, clean at all four orientations across
  the full zoom/pan range, stable across ≥3 cold boots.
- **Constraints (hard):** XC7Z020-1; **140 BRAM, ~100% used**; one HP port **≈1.14 GB/s**; per-pixel
  datapath closes **148.5 MHz** (1080p60). Per `orient-engine-decision.md` §3 the per-pixel path is
  shallow (read-BRAM→bilinear, +1.8 ns @148.5) — **timing is not the risk; DMA throughput is.**

## 2. Architecture (the clean engine)

```
 1080p source ─ S2MM (tiled geom) ─► DDR as 16×16 tiles  [pg_raster_to_tile / ORIENT_TILED]
                                          │  (layout chosen in Step 2 — Z-order / 2-copy / strided+coalesce)
   pg_affine_tile (output-tile DDA) ──────┤  per OUTPUT tile: which SOURCE tile(s) it samples + frac + in-window
        (fit-scale + pan + orient,         ▼
         firmware coeffs)          pg_tile_dma TILED ─► REGION BUFFER ─► bilinear ─► pg_tile_to_raster ─► AXIS
                                  (coalesced 768B/tile)  (direct, double-   (2-stage)  (band→raster,        │
                                                          buffered, 4-bank,            SOF-early framing)   ▼
                                                          NO eviction/hash/LEAD)                    color stack ─ axis_to_vid_io ─ HDMI
```

- **Region buffer = the cache replacement.** Sized for **one output tile's source footprint**
  (worst case 90° fit s≈2.67 → ~4×4 source tiles, decision §9 Q3), **double-buffered** (fill next
  output tile's tiles while gathering the current). **4 parity banks** for a 1-cycle 2×2 bilinear
  gather. **No eviction, no set-hash, no LEAD** — it's a direct buffer over a deterministic walk.
- **Transpose (90/270)** is handled by the affine mapping (output tile → transposed source tile) and
  the DMA layout chosen in Step 2 — *not* by any cache cleverness.
- **Framing:** use `pg_tile_to_raster`'s band reorder with **SOF-early** to replace the line-FIFO
  entirely (decision §9 Q5) → kills the wrap *and* the black-flash; emit **TUSER=SOF / TLAST=EOL** for
  the downstream SOF-realign in `axis_to_vid_io`.

## 3. Reusable assets — cherry-pick to the fresh branch (do NOT re-derive)

| Asset | File | State |
|---|---|---|
| Fit/pan/orient affine + UART | `sw/phase-b/src/main.c` `warp_set_rotation`, `W`/`L` | bench-correct |
| Tile-order affine DDA | `hdl/pg_affine_tile.v` | sim bit-exact |
| Output band→raster reorder | `hdl/pg_tile_to_raster.v` | sim bit-exact |
| Raster→tiled-DDR writer | `hdl/pg_raster_to_tile.v` | sim bit-exact |
| Tiled tile-DMA | `hdl/pg_tile_dma.v` `TILED=1` | sim-valid (needs coalescing — Step 2) |
| Tiled-DDR BD recipe + S2MM geom | `build_phase_b.tcl` splice, `main.c` `#ifdef ORIENT_TILED` | bench-running |
| Throughput proof / golden / OOC | `tools/orient_throughput_proof.py`, `orient_golden.py` | done (re-derive in Step 2) |

**DROP (the baggage — do not carry forward):** `hdl/pg_warp_engine.v`, `hdl/pg_tilecache_rt2.v`, the
soft-reset, the line-FIFO. These are the arbitrary-warp cache the scope no longer needs.

## 4. Build sequence (each step has a gate that must pass before the next)

**Step 1 — Fresh branch + asset transfer.** Branch from trunk (`iter5-1080p-clean`). Cherry-pick the
§3 files. Confirm they `add_files`/build on trunk. *Gate:* clean branch, proven modules present, the
DROP list absent.

**Step 2 — RISK-FIRST: prove the transpose-DMA budget before building the core.** This is the only real
unknown and it gates the architecture. The old throughput proof assumed 768 B bursts sustain all
orientations — **the bench showed they do NOT** (command overhead + page-misses; decision §9 Q2.b).
- Re-derive `orient_throughput_proof.py` **with realistic command/page overhead and coalescing**, and
  **with S2MM write sharing the port** if it does.
- Decide the transpose layout: **Z/Morton-order tiles** (both axes semi-contiguous, one copy) vs **two
  copies** (raster + transposed, +1 write pass) vs **strided + coalesce the contiguous axis**. Pick by
  the proof, not by preference.
- *Gate:* amortized read **≤ ~70% of 1.14 GB/s for ALL orientations including 90/270 + max zoom-out**,
  with overhead modeled. If no layout hits it on one HP port, escalate (2nd HP port? read-sequential
  /reorder-on-chip?) **before** building the core — do not build the core on an unproven budget.

**Step 3 — Build the deterministic core.** Region buffer (direct, double-buffered, 4-bank, no cache) +
output-tile walk + bilinear + the Step-2 coalescing/layout. *Gate:* `xsim` **bit-exact vs
`orient_golden.py`** for: 0/90/180/270, one fit-scale (e.g. 50% zoom-out), one pan, and (phase 2) a
keystone + a pincushion. Underruns=0 at the modeled fill rate.

**Step 4 — Integrate.** BD splice (tiled S2MM + the recipe), output-tile→raster reorder with **SOF-early
framing (no line-FIFO)**, color stack, `axis_to_vid_io`. *Gate:* `pg_warp_top`-equivalent TB passes
(TUSER@px0, TLAST@EOL, frame completes).

**Step 5 — In-context build.** Vivado synth→impl→bitstream, **`NO_ILA=1`**. *Gate:* **WNS ≥ 0 @148.5
MHz**, BRAM fits 140 (reorder band ~40 + region buffer + the rest — budget explicitly), DRC clean,
`.xsa` produced. (Per decision §3 the path is shallow, so this should close — if it doesn't, the core
re-introduced cache-depth; check for it.)

**Step 6 — Bench (the acceptance test).** *Gate (all required):*
- **Monitor truth, not MS2109** (`[[schindler_ms2109_verification_trap]]`); verify the Osee input first
  (`[[schindler_osee_switcher_topology]]`).
- All **four orientations** correct (0/90/180/270), **full zoom range** (fit → zoom-in crop → zoom-out
  matte), **full pan range**, matte clean at edges.
- **No tearing, no black-flash on any orientation/scale/pan change**, **≥3 cold boots identical**
  (`[[schindler_no_coin_flip_rule]]`, `[[schindler_build_provenance_rule]]`).
- Record the result in `docs/build-manifest.md` with reboot count + modes tested.

## 5. Gotchas (paid for already — respect every one; decision §8)

- `export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files` before any Vivado.
- `NO_ILA=1` frees ~32 BRAM / ~10k LUT — use it; UART telemetry (`starved=`, `opix/frame=`) is separate.
- **BRAM is 100% full** — the reorder band alone is ~40 BRAM (16×OUT_W×24 deep). Budget the region
  buffer + band explicitly against 140 before building.
- `add_files` module-ref HDL in `build_phase_b.tcl` **before** `create_bd_cell`. AXIS splice needs
  `s_axis_*/m_axis_*` port naming for interface inference.
- **1080 is not a multiple of 16** (67.5 tile-rows) — **pad source to 1088** (simplest) or handle the
  partial last band in writer+reader. Decide once, early.
- Tiled S2MM geom: HSIZE=768, VSIZE=tiles/frame, STRIDE=768 (`#ifdef ORIENT_TILED`).
- **Progress only happens via launched builds** — background tasks re-invoke the agent; "status"
  without launching a build = no progress.
- Daemon: venv `/tmp/schindlerd-venv/bin/python3` (ephemeral — recreate if gone), catalog
  `control-plane/catalog-v0.2.0.json`, launch from `control-plane/schindlerd/`; check with
  `ps -eo args | grep schindlerd.py | grep -v grep` (pgrep self-matches).

## 6. Discipline (the lessons this project paid for in blood)

- **Sim-gate every module bit-exact before silicon**, and gate the *real* failure — model fill/throughput
  with realistic overhead, not an idealized DataMover (the 768B-burst assumption already lied once;
  the long-blanking sims lied before that).
- **Test the failure a fix introduces**, not just the one it cures.
- **Monitor is truth.** Every MS2109-verified "pass" in this project's history was later overturned.
- **3-boot or it didn't happen** — no coin-flip builds, no lucky boots.
- **Deterministic beats clever.** The entire win here is choosing a structure with no eviction/hash/LEAD
  to tune. If a design choice reintroduces "tune this parameter per transform," it's the wrong choice.
- The prior weeks were **not wasted** — they proved the spec, the tiled-DDR backend, and the output-tile
  structure. This build reassembles validated pieces on a clean foundation; the only genuinely new work
  is the transpose-DMA proof (Step 2) and the cache→region-buffer core (Step 3).

## 7. Definition of done
A fresh-branch bitstream that, on the bench monitor, renders the 1080p source at **all four cardinal
orientations + full zoom/pan**, **tear-free and black-flash-free across live changes**, **identical
over ≥3 cold boots**, closing **148.5 MHz** and fitting **140 BRAM** — recorded in `build-manifest.md`.
Keystone/4-corner/pincushion follow as phase 2 on the same proven bilinear path.
