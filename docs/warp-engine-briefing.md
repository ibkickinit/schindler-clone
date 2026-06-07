# Warp read-engine — design briefing for external review

**Date:** 2026-06-07  **Status:** full HDL stack sim-verified; first in-context Vivado build running.
**Ask:** sanity-check the architecture and the silicon-closure decisions; flag anything wrong or risky
before this goes to the bench. Specific questions at the end.

---

## 1. Context

Schindler is an FPGA video frame-rate-converter / genlock box (Zynq-7020, Zybo Z7-20 dev board;
production target Trenz TE0720) for filming CRTs at film cadences. The existing **route-B read engine**
(`pg_read_engine_top`: `pg_addrgen` DDA + `pg_linefetch` line-ring + `pg_compose`) does scale / shift /
flip / 180° — anything whose source access is **row-monotonic**, because it caches whole source *lines*.

The **warp engine** is a new read path that does **arbitrary geometry** — rotation (any angle),
keystone, pincushion, mesh warp — by replacing the line-ring with a **tile cache**, so non-monotonic
2-D source access works. Output 1280×720, source 1920×1080, 60 Hz, pixel clock 74.25 MHz.

A behavioral feasibility gate (`tools/affine_tilecache_gate.py`, `tools/tilecache_realtime_gate.py`)
established the design point before any HDL: **16×16 tiles, ~256–512-tile BRAM cache, prefetch run-ahead
warmed during V-blank, single DDR port** → tear-free for all transforms. The HDL implements that.

## 2. Datapath architecture

```
   VTC sof ─┐
            ├─ pg_affine (consumer) ─┐
            └─ pg_affine (prefetch) ─┤
                                     ▼
   DDR ─ DataMover ─ pg_tile_dma ─► pg_tilecache_rt2 ─► bilinear ─► AXIS out ─► color stack ─ HDMI
        (64b beats)  (gearbox+        (4-bank, 4-way      (2-stage
                      2×2 reorder)     set-assoc, BRAM)     H/V lerp)
```

- **`pg_affine`** (`hdl/pg_affine.v`) — incremental 2×3 affine DDA, no per-pixel multiply. Emits, per
  *output* pixel, the inverse-mapped *source* coord `sx=a·ox+b·oy+c, sy=d·ox+e·oy+f` plus the
  sub-pixel fraction. Coeffs signed Q20.12, firmware-computed. Proper ready/valid producer (it advances
  only on accept — a pulse-valid version dropped coords when the cache stalled). Two instances: a
  **consumer** that feeds the gather and a **prefetch** that runs ahead (bounded) to warm the cache.

- **`pg_tilecache_rt2`** (`hdl/pg_tilecache_rt2.v`) — the hard module. Two concurrent engines share a
  4-bank tile BRAM + tag store:
  - **Gather (consumer):** 1 pixel/clock. The bilinear 2×2 can straddle up to 4 tiles; **4 parity
    banks** (bank = `{col&1,row&1}`) let all 4 neighbours be read in one cycle. Registered (synchronous)
    BRAM reads; a 2-stage pipeline carries the pixel's parity/edge/fraction alongside the read.
  - **Prefetch (fill):** walks the prefetch affine's coord stream ahead of the consumer, parallel 4-tile
    residency check, issues a single-in-flight DMA fill for misses. Lead is bounded so the round-robin
    victim only ever evicts a *consumed* tile.
  - **Tags: 4-way set-associative** (set = low bits of `{ty,tx}` so the 2×2's four tiles spread across
    sets; per-set round-robin victim). NTILE=256 (64 sets × 4 ways).
  - **Fill:** one **2×2 block per beat → all 4 banks written in parallel** at the same within-tile addr
    (`block = (row>>1)·8 + (col>>1)`).

- **`pg_tile_dma`** (`hdl/pg_tile_dma.v`) — bridges cache↔DataMover. On a cache `fetch_req(tx,ty)` it
  issues 16 row-fetches (`addr = base + (ty·16+r)·stride + tx·16·3`, BTT=48B), **gearboxes the 64-bit
  beats to 2 px/clock** (a 1px/clock unpack starved the cache), buffers the even row, pairs it with the
  odd row → 64 2×2-block fills.

- **bilinear** (in `hdl/pg_warp_engine.v`) — pipelined H row-lerps then V column-lerp; weight = top 8
  bits of the Q0.12 fraction.

- **`pg_warp_top`** (`hdl/pg_warp_top.v`) — BD wrapper, drop-in for `pg_read_engine_top`: same
  DataMover / frame_ptr / VTC / output-AXIS interface. Adds the DataMover cmd formatter, frame-base
  selection (latest completed VDMA slot, `frame_ptr-1`, latched at `sof = vsync rising`), coeff CDC, and
  output **TUSER=SOF / TLAST=EOL** framing for the downstream SOF-realign in `axis_to_vid_io`.

**Scope of the first bitstream:** *free-running* — reads the latest captured frame and warps it.
Genlock / FRC cadence / Mackin frame-blend (the route-B production features) are deliberately **not**
wired yet; they layer on after the warp proves on silicon. Geometry default = fit-scale 1920→1280.

## 3. What's verified (all in `xsim`, bit-exact vs an independent golden)

| Check | Result |
|---|---|
| `pg_affine` standalone | bit-exact (identity/zoom/shrink/rot/shift) |
| cache gather + concurrent prefetch, real-time | identity/rot25/rot45/shrink all produce a frame within a frame period, 0 underrun, 0 bit-err |
| full datapath (`pg_warp_engine_tb`, rot20) | 0 bit-err, real-time |
| **real fill path** (`pg_warp_dma_tb`: engine+tile_dma+behavioral DataMover, VTC-paced + V-blank warmup) | **underruns=0, bit-err=0, 56026 < 56100 cyc** |
| BD wrapper glue (`pg_warp_top_tb`: cmd-formatter path + sof + framing) | 0 bit-err, 0 framing-err (TUSER@px0, TLAST@every OUT_W) |
| OOC synth/impl on xc7z020-**1** | fits 12k LUT (22%) / 48 BRAM (34%); **logic timing clean (3.9 ns of 13.5 ns)** |

The golden is an independent affine-bilinear reference computed in each TB; the lerp is byte-identical to
the HDL. The real-time TBs model the leading V-blank warmup (a prior project lesson: a real-time cache
gate that omits V-blank warmup lies).

## 4. Silicon-closure decisions (the cache didn't fit/time as first written)

OOC synth flagged the sim-oriented cache at 107% LUT / 0 BRAM / WNS −6.7. Six fixes, each re-verified
bit-exact (`docs/warp-cache-timing.md`):
1. **Registered BRAM reads** — the gather read banks combinationally → inferred as distributed RAM
   (the 107% LUT). Synchronous read → true BRAM (57k→12k LUT, 0→48 BRAM).
2. **4-way set-assoc tags** — a 256-way fully-associative compare was the −6.7 path; 4 compares/tile.
3. **Pipelined bilinear** — the chained 2× lerp24 became the new critical path → split H/V.
4. **Skid buffers** between each affine and the cache — the affine's `o_ready` was gated by the live tag
   lookup, putting the DDA adder in a combinational loop with the lookup. The skid makes `o_ready`
   register-based.
5. **Multiply-free tile-id** — `tidf = {ty,tx}` concat instead of `ty·TX+tx` (the multiply sat on the
   lookup path).
6. **Registered lead-counter events** — kept `pf_ready` out of the wide lead-counter adder.

After these the **logic delay is 3.9 ns** (well inside 13.5 ns). The OOC *impl* still showed negative
slack, but it was **76% routing** on an unconstrained-OOC placement that scattered a 12k-LUT design
across the die — route delay is placement-dependent, logic delay isn't. The running in-context build is
the real test; the held-in-reserve fix is to pipeline the tag lookup into its own register stage (the
prefetch has slack to absorb the extra cycle).

## 5. Open risks / things I'm least sure about

1. **In-context timing.** Logic is 3.9 ns but the full design adds congestion. If post-route WNS < 0,
   is pipelining the tag lookup the right lever, or is there a better structural move (smaller NTILE?
   register the gather output? a different set-index hash)?
2. **Set-associative conflict misses under pathological transforms.** Set = `{ty[2:0],tx[2:0]}`. For
   rotations the 2×2's four tiles land in distinct sets, but could a specific shear/keystone cluster >4
   live tiles into one set and thrash? The lead bound + 4 ways seemed enough in sim (rot20/25/45,
   shrink) but I haven't swept adversarial transforms.
3. **Fill bandwidth headroom.** Real DataMover delivers 64 b/clk (~2.67 px). I gearbox to 2 px/clk →
   ~128 clk/tile. Sim passed with the V-blank warmup giving the lead. Is the margin enough for the
   worst real burst (e.g. 50% downscale + rotation simultaneously), or should the fill go wider / the
   lead deeper?
4. **`pg_tile_dma` ↔ cmd-formatter handshake.** `fetch_req` is a 1-cycle pulse; the formatter latches
   on `fetch_req && !cmd_valid`. Spacing (one fetch per row, after the prior row's beats) means
   `cmd_valid` should be clear — but it's not a held/acked handshake. Is that fragile? (The route-B
   `pg_linefetch` uses the same pattern and ships.)
5. **DataMover bursts vs my per-row fetches.** I issue 16 separate row commands per tile (BTT=48 B
   each) rather than one 2-D transfer. Simpler, but is the per-command overhead going to bite at speed,
   and is a 48-byte burst pathologically small for the HP port / DDR efficiency?
6. **frame coherence.** Free-running: I latch `frame_ptr-1` at `sof`. No tearing protection beyond
   "read the previously completed slot". Genlock/FRC is deferred — is free-running a safe first bench
   step, or will an in-flight VDMA write into the slot I'm reading cause visible artifacts?
7. **Byte order.** Pixels are stored {G,B,R} little-endian in DDR (a confirmed project quirk); the
   gearbox reconstructs the low-24 bits as the AXIS {R,B,G} pixel with no swizzle. Worth a second look.

## 6. Current state

- All HDL committed on the working branch. BD swap variant `tcl/readengine_warp_bd.tcl`
  (`WARP_ENGINE=1`); production route-B path untouched (default).
- First in-context Vivado build running (synth → impl → bitstream). Awaiting post-route WNS + `phase_b.xsa`.
- Not yet bench-verified — that's the owner's step, and the point of this review is to catch problems
  before burning bench time.

**Files:** `hdl/pg_affine.v`, `pg_tilecache_rt2.v`, `pg_tile_dma.v`, `pg_warp_engine.v`, `pg_skid.v`,
`pg_warp_top.v`; sims `sim/pg_*_tb.v`; `tcl/readengine_warp_bd.tcl`; `docs/warp-engine-build.md`,
`docs/warp-cache-timing.md`, `docs/affine-warp-gate-results.md`.
