# Canon re-verification (2026-06-26) — read-side scaling retired

Principle (this doc, 2026-06-26): ALL size change via Z; placement invx=4096; corner-pin/pincushion/
rotation = ~1:1 shape remaps. Measure: opix exact-full (2073600 @1080p) = clean. Replaces the
read-side-shrink "corner-pin breakup" numbers (those measured the RETIRED DOWNSCALE path).

> **CLARIFIED 2026-06-27:** "ALL size change via Z" applies to **SHRINK** only. **ENLARGE (zoom-in,
> >=100%) is a read-side warp zoom (invx<4096)** — legit and kept (fetches FEWER px). Only read-side
> DOWNSCALE (invx>4096) is retired (the bandwidth footgun). Canon = "shrink write-side, enlarge
> read-side; never read-side downscale." `apply_scale_xy` encodes exactly this.

## GROUP A — core mechanism, canon (no read-side scale)  [1080p]
- A1 passthrough        : FULL ✓
- A2 rotation 10deg(1:1): FULL ✓
- A3 pan +350,+250 (1:1): FULL ✓

## GROUP B — canon SCALE via write-scaler Z  [1080p]  (REPLACES read-side W-scale)
- Z 90/75/50/25% : all FULL ✓   (write-scaler decimate; warp ~1:1; NO bandwidth wall)
- Z50 + rot10    : FULL ✓
=> Canon downscale clean to 25%+ ; read-side W-downscale (RETIRED) starved at mild levels. Use Z always.

## GROUP C — corner-pin re-characterization  [1080p]  (RETIRES the read-side-shrink "15%" numbers)
- C1 keystone on FULL LOD: chaotic/bimodal (K50 nearly full=1-line-short; K100-200 short; K300 full;
  K400-500 short). Foreshortening = local read-side downscale + mis-picked lead. NON-CANON path.
- C2 CANON (Z50 pre-shrink -> keystone remap on small LOD): K100/200/300/500 ALL FULL ✓✓.
=> Canon corner-pin/keystone has NO bandwidth limit in range. The old "corner-pin clean to ~15%",
   "opposing ~6.4%", 720p corner-pin numbers, #50 lead-on-shrink-quads = all measured the RETIRED
   read-side-shrink path. RETIRE those numbers. Canon = Z for size, corner-pin for shape (~1:1).

## GROUP D — pincushion re-characterization  [1080p]  (RETIRES the "+25%" number)
- D1 pincushion on FULL LOD: bimodal (I100 short; I150 nearly-full 1077; I200 short; I250 nearly-full
  1078; I300 full). The earlier "+25% clean" was a LUCKY-LEAD reading. Full-LOD path is lead-sensitive.
- D2 CANON (Z50 + pincushion): I150/250/400/600 ALL FULL ✓✓ (incl. 60%).
=> Same as corner-pin: geometry on full LOD = read-side-fetch + mis-picked lead (bimodal); on a
   Z-pre-shrunk LOD = clean at any level. RETIRE the "+25%". Canon = Z for size, pincushion = ~1:1 bow.
FINDING: the LEAD heuristic mis-picks for full-LOD geometry (keystone/pincushion) -> bimodal near-full
   shorts. Real bug for the 1080p60 full-size geometry-trim case (separate from the canon shrink flow).

## GROUP E/F — AA + black-border on CANON scale  [1080p]
- E Z70 + pincushion (curved edge): FULL ✓ (telemetry); eyes-on AA smoothness pass PENDING.
- F Z50 + BLACK matte (image in black frame, canon — not a shrinking corner-pin): FULL ✓; eyes-on PENDING.

## SUMMARY / VERDICT
CANON CONFIRMED: size via the write-scaler (Z), geometry (rotation/corner-pin/keystone/pincushion) as
~1:1 shape remaps on the (pre-sized) LOD. In that flow EVERYTHING is full-frame at any level tested
(Z to 25%, keystone K500, pincushion I600). There is NO geometry bandwidth wall on the canon path.

RETIRED (read-side-shrink path — DO NOT use these as product limits):
  - "corner-pin clean to ~15% @1080p", "opposing-corner ~6.4% / 700px", "720p corner-pin 60%",
    "pincushion +25% @1080p / +100% @720p", and the #50 lead behaviour measured on shrinking quads.
  All of those applied the geometry to the FULL LOD (= read-side downscale-in-disguise) and are
  lead-sensitive/bimodal. They measure the path being removed, not the product.

STILL VALID (mechanism proofs, scale-path-independent):
  - Bite 1 two-stage datapath, Bite 2 pincushion datapath, #48 edge AA, rotation, pan, matte, the
    off-sheet->black / off-content->matte classification. (Bite1 black-exterior + the keystone-tilts-
    matte demo were SHOWN via a shrinking corner-pin/placement-scale; canon equivalents = Z + matte /
    Z + keystone, both telemetry-clean here — re-show visually.)

OPEN (real bug, separate from canon): the LEAD heuristic mis-picks for FULL-LOD geometry (gentle
  keystone/pincushion at full size = the 1080p60 geometry-trim case) -> bimodal near-full shorts
  (eol 1077-1079). Needs a geometry-aware lead, not the shrink-quad heuristic. Track w/ #50.

PENDING: eyes-on visual pass for E (AA) and F (black border) on canon; and the two-engine derate (#41)
  re-measured on the canon path.
