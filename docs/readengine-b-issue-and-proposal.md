# Read-Engine-B — Issue Statement & Proposed Fix (for independent review)

> ## ⚠️ OVERTURNED 2026-06-02 by independent review — DO NOT BUILD THE §4 FIX.
> An independent agent re-analyzed the ILA capture's **temporal** structure (which the analysis
> below missed) and found the real cause. Confirmed by re-running `/tmp/decode_dbg.py`:
> a **buffer/prefetch coherency failure** — `resident` drops **mid-row** (s1268, `src_col`=7,
> `src_row`=162) → addrgen freezes **608 cycles** (`a_valid=0` @s1271) → **523-cycle active-video
> underrun** (`m_tready=1 & m_tvalid=0` @s1329) → `rd_data` held at **`0x240000`** (garbage, not the
> source) for the whole stall; the reviewer also found rd values `0x6a/0xab/0xb8` at s1879–1884
> **absent from `up_pdata`** (boundary garbage, not faithful transport). This is **timing-dependent
> → frame-to-frame variable**, matching the observed crawl; static dither-aliasing does NOT.
> **Corrections:** the "engine is bit-clean/faithful" claim is FALSE (it serves garbage during the
> stall); "NN dither aliasing" is insufficient (dither is ±2–3 LSB, invisible); "read-during-write
> collision ruled out" is FALSE (mid-row residency loss + boundary garbage IS that class — build
> #11's read-select fix stopped the garbage-READ but not the residency LOSS → stall → underrun).
> **Real next steps (supersede §4):**
> 1. Re-capture with a clean discriminator — probe `push_data` (the actually-pushed pixel), gate
>    the histogram on resident&pushed, capture ≥2 frames to confirm the band drifts.
> 2. Root-cause the mid-row residency loss in `pg_compose` prefetch / `pg_linefetch` recycle:
>    does `fill_sel` lap the read row (LOOKAHEAD/NBUF math), or does a redundant refetch invalidate
>    a row mid-read? (`pg_linefetch.v:90-92`, the read-during-write region.)
> 3. Only AFTER that is fixed, revisit anti-aliasing — and drive the sim with realistic
>    HBLANK/DDR-latency stalls, because the current TB structurally cannot exercise this underrun.
> The §1–§5 below are retained as the (now-refuted) prior analysis. Verdict table from the review
> is in the session log / `readengine-b.md`.

**Date:** 2026-06-02. **Branch:** `readengine-b-integration`.
**Purpose:** a clean, self-contained statement of the diagnosed issue and the proposed fix, so a
fresh agent can verify (or refute) the analysis from scratch. Long debugging trail is in
`readengine-b.md` §4–§8; ILA capture detail in §9; this doc is the distilled claim + proposal.

---

## 1. System (what the read-engine does)

Route-B "read-engine" reads a full **1920×1080** master frame from DDR (written by VDMA S2MM) and
produces a runtime-sized output window (≤**1280×720**) for HDMI 720p output, scaling on the read
side. Pipeline (`hdl/pg_*.v`):

```
DDR master (full 1920×1080)
  → AXI DataMover  : reads a FULL master line (1920 px) — NO decimation
  → pg_unpack      : 64b beats → 24b pixels (up_pdata) — the full 1920-px line
  → pg_linefetch   : stores the WHOLE 1920-px line in an NBUF-deep ring buffer
  → pg_addrgen     : walks the OUTPUT raster; DDA computes src_col/src_row = WHICH
                     buffered pixel each output pixel takes (e.g. 1920→1280: src_col =
                     0,1,3,4,6,7,9… = floor(out·1.5))  ← THE DECIMATION (a SELECTION)
  → pg_compose     : rd_data = mem[src_row][src_col]  (picks that one pixel) → output FIFO → AXIS
  → axis_mux2      : sel=1 → read-engine to color stack → rgb2dvi → HDMI
```

Byte order in the AXIS/DDR path: `tdata[23:16]=R, [15:8]=B, [7:0]=G` (memory
`schindler_pipeline_rbg_byte_order`).

## 2. THE ISSUE (claim to verify)

Output shows a fine, drifting "diagonal trash" pattern — on a grid test source AND on flat color
fields. **Claim: this is nearest-neighbor decimation aliasing of high-frequency source content
(GPU/panel dither + thin lines), because the read-engine decimates with NO anti-alias low-pass.**
The full-master path bypassed the input scaler (`SCALER_MODULE=scaler_bypass_1080p`), which also
bypassed `scaler_h/scaler_v`'s 2-tap boxcar anti-alias filter. The read-engine replaced it with
pure nearest-neighbor pixel selection.

### Where the decimation happens — AFTER the read (key structural point)
The DataMover read from DDR pulls the **full** 1920-px line (no decimation). The whole line is
buffered. The decimation is the **DDA picking a subset of the buffered columns/rows at read-out**
(`rd_data = mem[src_col]`). So the **entire source line is resident in the buffer** at the moment
of decimation — the data we'd want to low-pass is already in hand.

## 3. EVIDENCE (ILA on silicon, build #13 — `ila_re_dbg` 96-bit `dbg_probe`)

(Captured via `tcl/capture_re_ila.tcl`, decoded with `/tmp/decode_dbg.py`. `dbg_probe` bit layout
in `hdl/pg_read_engine_top.v`.)

1. **Addressing is correct.** `src_col` marches `+1,+2,+1,+2…` = exact `floor(col·1.5)`, strictly
   monotonic, resets to 0 per row; `src_row` steps correctly. Zero anomalies. → no skew/off-by-one.
2. **Data transport is bit-clean.** On a grid, `rd_data` took only `000000`/`ffffff` (black/white,
   matching the source); black flat regions = pure `000000`. → no corruption; uniform-in→uniform-out.
3. **The flat-color pattern follows the engine** (Test 1): flat R/G/B are CLEAN with the engine OFF
   (mux→MM2S 1:1 crop, no decimation) and show the "trash" with the engine ON (decimation), on the
   SAME colors. → display/camera ruled out; it is the decimation.
4. **The source is dithered** (Test 2, ILA on "solid" red): `rd_data` is NOT constant — R wanders
   0xF4–0xF8 with sparse B/G of 1–3 (≈19 values). Crucially **`up_pdata` (data straight from DDR,
   pre-engine) shows the SAME dither distribution.** → the dither is in the SOURCE (the laptop
   dithers the solid color); the engine faithfully carries it (`rd_data`≈`up_pdata`, not
   fabricated); the **NN decimation samples every ~1.5th dithered pixel → aliases the dither →
   the trash.** With engine OFF the full dither is preserved 1:1 → looks smooth (= clean).
5. **Engine-OFF capture:** even with `engine=0` the read-engine still decimates internally
   (`src_col` 1,2,1,2; `rd_data` dithered) — `engine=0` only flips the output mux; it does not stop
   the read-engine. So engine-OFF "clean screen" is the MM2S 1:1 path being shown, not the
   read-engine stopping.

### Ruled out (each disproven, not just deprioritized)
addressing/skew (ILA: perfect DDA) · fill rate (identical at 480×270, 4.5× headroom) · buffer
depth (NBUF 2→4 unchanged) · read-during-write collision (fix #11 unchanged the artifact) · stride
mismatch (firmware S2MM stride == read STRIDE == 5760) · display/camera (Test 1) · engine
fabrication (Test 2: `up_pdata`==`rd_data` dither, source-origin).

## 4. PROPOSAL (the fix to verify)

**Add an anti-alias box filter at the READ — average the buffered source span per output pixel —
instead of nearest-neighbor pick.** Rationale: the full master line is already resident in the
ring buffer (decimation is post-read, §2), so the low-pass can be applied there, which **fixes the
aliasing while preserving the full master** (so runtime zoom/pan — the read-engine's whole reason
to exist — survives). Concretely:

- **Horizontal:** for output pixel x, `rd_data = average(mem[src_row][src_col .. src_col+spanH-1])`
  where `spanH = src_col(x+1) − src_col(x)` (1 or 2 at 1.5×; grows for heavier shrink). A 2-tap
  `(a+b+1)>>1` covers the 1.5× production case; heavier shrink wants `taps≈ceil(ratio)`.
- **Vertical:** average across the adjacent buffered source rows (`src_row`, `src_row+1`), a 2-tap
  `(a+b+1)>>1`. Needs both rows resident simultaneously → split `pg_linefetch`'s single backing
  BRAM into per-slot arrays for 2 parallel reads, bump ring depth + guard band (`NBUF` 5→6,
  `LOOKAHEAD=NBUF-4`).
- **Per-channel**, in `[R][B][G]` lane positions, round-to-nearest `(a+b+1)>>1` (NOT truncate — a
  −0.5 LSB DC bias would darken and be hidden by the MS2109). No hardware divide for 2-tap (shift).
- **Sim gate first:** update the TB golden to the box model (newest+one-older taps, the exact
  `(a+b+1)>>1` rounding, the `window[0]=0` edge behavior `scaler_h/v` use) — see `readengine-b.md`
  §10 golden-model spec — and require `Total errors=0` before any synth.

**Alternative (cheaper, lossy):** un-bypass the input scaler (`SCALER_MODULE=scaler_top`) so its
2-tap boxcar low-passes 1080→720 and DDR holds a pre-filtered **720** master; the read-engine then
does ~1:1 placement (= the bench-clean build #7). Fixes the aliasing but **discards the full
master → no zoom-in past 720 (that becomes G2)**. Recommended only if 720-detail ceiling is
acceptable for the current milestone.

**Chosen direction (Justin):** the read-path box, to keep the full master.

## 5. Verify on the bench MONITOR, not the MS2109 (it masks this exact class). Tools:
`tcl/capture_re_ila.tcl`, `/tmp/decode_dbg.py`, `python/bench/uart_cmd.py` (`G w h x y` / `G 0`),
`python/bench/osee_switch.py`. ILA build (#13) is currently on the board.
