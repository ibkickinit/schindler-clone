# Warp read-engine — independent review (pre-bench)

**Date:** 2026-06-07. **Reviewer:** independent (verified against HDL + the realtime gate, not the prose).
**Reviewing:** `docs/warp-engine-briefing.md` @ `ace42ff` and the HDL it describes.
**Verdict in one line:** architecture sound and module-level verification genuinely strong — but the
**worst transforms have never met the real fill path *and* the real cache simultaneously**, and the
one real-fill margin number you have is **0.13%**. Two gates must close before bench; fix the 48-byte
bursts regardless.

---

## 1. Verified fine — clear these

- **Risk #7 (byte order):** `pg_tile_dma` keeps each pixel's low-24 `{R,B,G}` ordering
  (`g_p0=acc[23:0]`, `g_p1=acc[47:24]`) and the 2×2 pack is per-pixel (`fill_blk={p11,p01,p10,p00}`).
  No swizzle issue. Matches `schindler_pipeline_rbg_byte_order`. ✅
- **Risk #6 (free-running frame coherence):** fine as a first bench step. You latch `frame_ptr-1` at
  `sof` and hold it for the whole frame; S2MM advances ~1 slot/frame, so the read slot goes 1→2 behind
  the writer over one output frame — **3 slots of margin in a 5-slot ring, no lap.** Safe free-running;
  revisit when genlock layers on. (Same lap arithmetic as the cadence Q7 work.) ✅

## 2. Solid concerns (model-independent — straight from the code/table)

1. **The feasibility gate validated a *different cache than you built.*** `tilecache_realtime_gate.py`
   models a **fully-associative LRU** (`OrderedDict` + `move_to_end` + evict-LRU). The HDL is **4-way
   set-associative, `{ty[2:0],tx[2:0]}` set index, round-robin victim** (`pg_tilecache_rt2.v:60-70,156-174`).
   Set-assoc+RR is strictly weaker than fully-assoc+LRU, so the gate's "tear-free for all transforms"
   is **necessary but not sufficient** — it structurally **cannot see risk #2 (set-conflict thrash).**
2. **The real fill path was only tested at rot20.** §3 table: `pg_warp_dma_tb` (real `pg_tile_dma`,
   128-cyc/tile gearbox, VTC-paced) = **rot20 only**. rot45/downscale/pincushion used the *idealized*
   cache+prefetch path, not the real fill. So **"hard transform + real fill + real cache" — the actual
   silicon worst case — is untested.**
3. **The one real-fill margin is razor-thin: 56026 < 56100 = 74 cycles (0.13%)** — and that's rot20,
   the *easiest* real-fill case. 0.13% on the easy case with the hard cases unmeasured is the single
   most concerning data point, and it's from your own table.
4. **Risk #5 (48-byte bursts) is real and compounds #3.** `pg_tile_dma` issues **16 separate
   row-commands per tile, BTT = 48 B each** (`pg_tile_dma.v:56-57,77-78`). 48-byte bursts are
   pathologically small for an HP/DDR3 port — per-command address overhead + DDR row-activation
   dominate, and 48 B doesn't align to a DDR burst. Almost certainly *why* the rot20 margin is only 74
   cycles. A single per-tile 2-D transfer (768 B) or wider bursts would buy real headroom. **This is
   the exact class of failure the packed-beat work hit earlier — passes a forgiving sim, starves on
   real DDR.**
5. **Risk #4 (pulse `fetch_req`) is more fragile here than in route-B.** It fires **16×/tile** vs
   route-B's 1×/line (`pg_tile_dma.v:78`), so the unguarded "`cmd_valid` should be clear" assumption
   gets 16× the chances to race. If a `fetch_req` pulse ever lands while `cmd_valid` is still set, that
   row is silently dropped → gearbox waits forever → `busy` hangs → tile never fills → glitch. A
   held/acked handshake (or a 1-deep fetch FIFO) removes the failure mode cheaply.

## 3. Risk #2 (set-conflict thrash) — genuinely open, and nothing you've run can answer it

The set index is `{ty[2:0], tx[2:0]}` — low 3 bits of each tile coord. The immediate bilinear 2×2
never self-conflicts (its four tiles differ by 1, landing in 4 distinct sets ✅). The open question is
the **live working set**: can a transform put **>4 simultaneously-live tiles that alias to one set**?
45° rotation is the suspicious case — diagonal source access correlates `tx` and `ty`, which correlates
their low bits, potentially concentrating live tiles onto the diagonal sets.

**I could not answer this, and neither can your current tooling:** the gate is LRU (can't see
conflicts) and the real-fill HDL sim is rot20-only. I wrote a quick set-assoc+real-fill model to probe
it — **it underran even on *identity*, which is impossible on the real HDL, so it's buggy and its
numbers are discarded.** The lesson isn't "the cache thrashes"; it's that **a faithful set-assoc +
real-fill model is non-trivial to get right and you don't have one yet.** This question must be closed
with a correct model or a real HDL sim, not assumed away by the optimistic LRU gate.

## 4. Recommendations before bench (prioritized)

1. **Build one combined model that matches the silicon** — 4-way set-assoc with the real index + RR
   victim + realistic per-tile fill — and **sanity-check it against identity/rot20 first** (the check
   my quick model flunked). Then sweep rot45 / heavy-downscale (≤0.5) / anisotropic / keystone. This is
   the gate that should have gated the design.
2. **Run the *real* `pg_warp_dma_tb` on rot45 + a downscale + an anisotropic case**, not just rot20 —
   a few extra TB cases, directly closes the coverage hole (#2 + #3 together).
3. **Fix the fill bursts (#4 above / risk #5)** — per-tile 2-D / larger transfers instead of 16×48 B.
   Highest-leverage change for the thin margin; do it regardless of what the sweep finds.
4. **Consider a hashed set index** (e.g. `set = {ty[2:0]^ty[5:3], tx[2:0]^tx[5:3]}`) — a few XORs, and
   it de-risks diagonal/stride aliasing structurally whether or not the sweep finds thrash.
5. **Acked `fetch_req` handshake** (risk #4) — small change, removes a silent-hang path the 16×/tile
   rate makes non-negligible.

## 5. On the in-context timing (risk #1)
The 3.9 ns logic delay is reassuring and the registered-BRAM/4-way/pipelined-lerp fixes are the right
moves; the OOC-impl negative slack being 76% routing on a scattered placement is a fair read. The
held-in-reserve "pipeline the tag lookup" lever is sound. Nothing to add beyond: let the in-context
post-route WNS decide, and if it's negative, the tag-lookup pipeline stage is the right first lever
(the prefetch has the slack). This risk is well-handled; the fill/cache risks above are the ones to
chase.

---

**Bottom line:** clear #6/#7, treat **"rot45 + downscale on the real DMA path with a correctly-modeled
set-assoc cache"** as a **must-close gap before burning bench time**, and fix the 48-byte bursts. Don't
let the green LRU gate stand in for the set-assoc reality — it's measuring a more forgiving machine
than the one you built.
