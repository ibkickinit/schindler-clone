# Warp engine — round-2 review (the crux answer)

**Date:** 2026-06-07. **Reviewer:** independent. **Re:** `warp-engine-round2-for-review.md`.
**TL;DR:** good gate, good data — but the root-cause read is **inverted for the worst case**. The
dominant wall for shrink (and a big part of rot45) is **cache associativity, not fill rate.** A
faster fill — including the expensive dual-clock fill (#3) — **cannot** fix shrink. Re-order the plan:
associativity is co-first, not last.

## The decisive number (model-independent)

For each transform, the max **simultaneously-live tiles that map to one cache set** (just the access
pattern + the set function — no cache sim to get wrong). It predicts your HDL sweep almost exactly:

| transform | live-tiles-per-set (HDL `{ty[2:0],tx[2:0]}`) | ways needed | your sweep |
|---|---|---|---|
| rot20 | **3** | fits 4-way | PASS |
| rot45 | **8** | 8-way | FAIL 40% |
| aniso | **4** | at the 4-way edge | FAIL 83% |
| shrink 1.5× | **15** | **15-way** | FAIL 94% |

## Crux answer

**"amortized < frame ⇒ a deep lead makes it real-time" is NOT sound for shrink/45° — but the reason
is associativity, not lead-vs-cache-size.** For shrink, 15 tiles are live in one set and you have 4
ways. The cache physically can't *hold* the working set: the RR victim evicts a still-live tile, which
is re-fetched, which evicts another. **A deeper lead can't help (prefetched tiles get evicted before
use), and neither can infinite fill bandwidth.** So **dual-clock fill (#3) is the wrong lever for
shrink** — bandwidth for a capacity problem.

Your "fill rate, aliasing secondary" read is inverted for shrink (and major for rot45). The hash
halving shrink's underruns was the tell.

## But it's *both* walls, transform-dependent — don't overcorrect

The one imperfection in the metric is the tell: **aniso needs only 4-way yet fails 83%, while rot45
needs 8-way but fails only 40%.** So fill-rate/lead is a real, independent factor — aniso fits the
cache and still starves on delivery. Honest conclusion: **associativity and fill-rate are co-primary;
which dominates is transform-dependent.** Shrink = associativity-bound; aniso = fill/lead-bound;
rot45 = both.

## Re-ordered plan

1. **Fix associativity (your #4) — promote to co-first.** Shrink cannot pass without it. Options,
   by confidence:
   - **16-way** (16 sets × 16 ways) covers every tested transform with the existing index (shrink
     needs 15). The 2×2 neighbor spreading is handled by the parity **banks**, not the sets, so ways
     are free to grow — more tag compares, but it's the bulletproof structural fix.
   - A **real mixing hash** (e.g. `set=(tx*13+ty*7)&63`, or a proper bit-finalizer) — **not** the
     naive XOR (it made every case worse: shrink 15→17, broke rot20 3→6). `tx[5:0]`-only makes all
     tested cases fit 4-way (rot20=4/rot45=3/shrink=3/aniso=4) **but** is axis-biased the other way
     (vertical access would collapse it). No low-bits index is robust to both axes — hence: more ways,
     or a validated mixing hash. Sweep any candidate against the per-set metric above before trusting.
2. **Multi-outstanding fill + wider gearbox (your #1/#2)** — still needed for the burst/lead
   (aniso/rot45 starve on delivery even when they fit the cache).
3. **DDR burst fix (48B → per-tile 2-D, your #5)** — do alongside #2; the 0.13% rot20 margin was real.
4. **Dual-clock fill (#3) — defer / probably skip.** Only reach for it if a *non-thrashing* cache
   with multi-outstanding fill *still* can't hold the lead. Don't build it for shrink — it won't help.
5. **Adaptive/larger tiles — skip as a primary lever.** Cuts tile count but doesn't fix `ty`-constant
   set-concentration and wastes edge bandwidth. (Your instinct was right.)
6. Tag-lookup pipeline (orthogonal) — fold into the same cache revision.

**Bottom line:** build **higher associativity (16-way or a metric-validated hash) + multi-outstanding
fill + the burst fix**, then re-sweep. That hits both walls. You likely don't need the dual-clock
fill — it's the expensive answer to the half of the problem that isn't the bottleneck.

Validation harness: `/tmp/warp_workingset.py` (the per-set-live metric) — re-run it on any candidate
set index before committing, and require worst-set-live ≤ ways for all swept transforms.
