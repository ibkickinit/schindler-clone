# Production orient engine — 0/90/180/270 + scale + position, 1080p60-capable

**Decision (2026-06-09):** the production read-engine handles the FOUR cardinal orientations + zoom + pan,
NOT arbitrary rotation (the warp/affine path is tabled as a future feature). This is bounded, rock-solid by
construction (no set-hash resonance, no eviction, no demand-fetch), and 1080p60-capable. Same hardware
(Zybo Z7-20); 1080p60 *output* needs a TE0720 (HDMI serializer ceiling) but the *throughput* is proven on
the Zybo — see `tools/orient_throughput_proof.py`.

## The one architectural decision: TILED DDR

The wall (proven): the warp reads 48-byte strided tile-rows → page-miss every read → ~37% efficient
(~200–343 MB/s), short of 1080p60's 373 MB/s and far short of 2× zoom-out's 746. **Store the source TILED**
(each 16×16 tile contiguous = 768 B) and every orientation reads contiguous 768 B bursts → ~1.1 GB/s, 3× the
need, for ALL of 0/90/180/270 + zoom (the read ORDER changes per orientation, the read EFFICIENCY doesn't).
This also kills the steep-rotation underrun and the 1080 underrun in one stroke — they were the same wall.

## Datapath

```
capture AXIS raster ─► [RASTER→TILE writer] ─► DDR (tiled: 16×16 tiles, tile-row-major)
                                                  │
DDR (tiled) ─► [TILE READER] ─► [IN-TILE XFORM] ─► [RESAMPLE] ─► [OUTPUT FRAMER] ─► AXIS ─► VTC/HDMI
                contiguous       transpose/flip     scale          raster @ pixclk
                768B bursts      per orientation    (bilinear)      + matte (pan off-edge)
```

### 1. RASTER→TILE writer (input)
Buffer 16 input rows in BRAM (16×1920×3 ≈ 92 KB), then emit 16×16 tiles in tile-row-major order to a tiled
DDR frame (double/triple-buffered for genlock). One BRAM line-band + a tile-order read-out + the S2MM
addressing. (Alternative: a standalone tiling DMA pass DDR→DDR — extra round-trip, no capture change.)

### 2. TILE READER (output, per output tile)
Output is produced in OUTPUT tiles. For output tile (otx,oty), orientation+scale+pan give the source tile(s)
needed (1 at integer scale/0°-aligned; up to 4 at fractional scale / sub-tile pan). **Deterministic** — the
tiles for the whole output frame are known ahead, so a small DOUBLE-BUFFER (ping-pong 2–4 tiles) prefetched
one output-tile ahead replaces the whole warp cache/eviction/demand-fetch machinery. Reads are contiguous
768 B bursts (the proof).

### 3. IN-TILE XFORM (orientation)
The macro-orientation = the output→source TILE mapping (tile-order). The micro-orientation = transpose/flip
WITHIN the 16×16 tile, done in BRAM as it's read out:
- **0°**: identity.  **180°**: reverse both indices.
- **90°/270°**: swap (row,col) + flip one axis. A 16×16 BRAM transpose is trivial + cheap (no DMA penalty —
  this is exactly why tiling beats a per-pixel transpose).

### 4. RESAMPLE (scale)
Zoom in/out via the source-step (integer for fit-modes, fractional for free zoom). Nearest for 1:1/integer;
2-tap or bilinear for fractional (reuse the proven scaler taps). Source step + tile mapping handle any zoom
within the bandwidth budget (zoom-out bounded by the proof).

### 5. OUTPUT FRAMER (position + matte)
Pan = a signed output-window offset (reuse the warp's signed-window seed: image leaves frame, matte fills
the opposite edge — `[[schindler_signed_window_geometry]]`). axis_to_vid_io-style SOF-anchored raster out.

## Why this closes 1080p60 timing (where the warp can't)
The warp barely closes 74.25 MHz (+0.0029 with demand-fetch); at 148.5 MHz it has no chance — its cone is
the associative tag-lookup + eviction + demand-fetch arbitration. This engine has NONE of that: integer
addressing (no per-pixel multiply / no affine DDA divide), a deterministic double-buffer (no tag CAM, no
eviction, no demand FSM), and a fixed 16×16 BRAM transpose. The per-pixel datapath is read-BRAM → mux →
(optional 2-tap) → out — shallow, 148.5 MHz-friendly.

## Phasing
| P | Build | Validates |
|---|-------|-----------|
| **P0** | ✅ throughput proof (`orient_throughput_proof.py`) | 1080p60 sustainable w/ tiling |
| **P1** | orient address-gen HDL (out→src tile + in-tile xform) + Python golden, bit-exact sim | the 4 orientations + scale + pan map correctly |
| **P2** | RASTER→TILE writer + tiled-DDR S2MM | the tiled source in DDR |
| **P3** | TILE READER + double-buffer + resample + framer → integrate, 720p bench | full engine @ 720p, rock-solid |
| **P4** | 1080p30 bench (Zybo) — clean (the throughput fix) | clean 1080 at last |
| **P5** | 148.5 MHz timing close + 1080p60 throughput proof on Zybo | engine sustains p60 rate |
| **P6** | TE0720 1080p60 output bring-up | visual 1080p60 |

P1 first (addressing is the spec; bit-exact sim de-risks everything downstream). Arbitrary warp stays on its
branches (`warp-demand-fetch-fsm` etc.), tabled.
