# Route-B Read-Engine — Implementation & Shear Diagnosis

**Branch:** `readengine-b-integration` (off `iter5-1080p-clean`)
**Status (2026-06-02) — READ §14 FIRST (latest), then §13/§12. §4–§11 = superseded trail.**
Root cause (ILA build #14, §13, two review rounds): **per-row fetch latency** — the consumer
outruns a serialized 1-px/clk line fill (~IN_W=1920 cyc/line > htotal=1650 cyc/row) → prefetch
falls behind → mid-row stall → output-FIFO underrun → drifting band (NOT dither aliasing — §9–§11
overturned in §12). **FIX (§14): packed-beat line fill — store 64-bit beats at 1 beat/clk
(~720 cyc/line « 1650), extract pixel read-side from even/odd beat banks.** SIM-PROVEN: latency TB
underrun gone (3072/3072, starv=0); top golden TB bit-exact (errors=0) incl. straddle columns.
Build #15 in progress → bench. Verify on the **bench monitor only** (MS2109 masks this).

This doc is the implementation + debug record for the **post-color output compositor
("route B")** that [`adjustable-scaler-design.md`](adjustable-scaler-design.md) calls for.
That doc is the *why/architecture*; this is the *how/as-built* and the debugging trail.

---

## 1. What it is

A **random-access DDR read-engine** that realizes runtime size / position / matte as a
**post-color, per-output presentation stage** — independent of the input scaler and of the
VDMA genlock ring. It reads the un-windowed master frame from DDR via an AXI DataMover,
walks the *output* raster, and for each output pixel picks the master pixel via a per-axis
DDA (downscale), or emits matte outside the window.

**Why a reader and not an input-side reframe:** the earlier G1 attempt put geometry on the
input side and windowed by reconfiguring S2MM VSIZE in firmware (`64aabe6`). At the bench
that **blacked out HDMI** — under VDMA dynamic genlock the S2MM and MM2S frame geometry must
stay matched (both full-raster); sub-windowing S2MM diverged it from MM2S's full read and
killed the genlock output leg. Geometry must live *after* color, *outside* the genlock ring.
See [`g1-bench-finding-genlock.md`](g1-bench-finding-genlock.md). (Memory:
`schindler_genlock_geometry_must_match`.)

## 2. Integration topology — additive + mux

The VDMA write (S2MM) and read (MM2S) legs are **untouched** — dynamic genlock keeps running
exactly as on `iter5-1080p-clean`. The read-engine is bolted on beside it:

```
                         ┌───────────────── DDR master ring (5 slots) ─────────────────┐
 HDMI in → scaler_bypass_1080p → S2MM ──writes full 1920×1080──▶ [slot 0..4]            │
                                  │ s2mm_frame_ptr_out[5:0]                              │
                                  ▼                                                      │
 (existing)  MM2S ──reads full raster──▶─────────────────┐                              │
                                                          │                              │
 (new) AXI DataMover (HP1, MM2S-only) ◀──reads master lines per pg_genlock slot──────────┘
        │  M_AXIS (64b beats)
        ▼
   pg_read_engine_top  ── m_axis (24b pixels) ──┐
                                                 ▼
                                          axis_mux2 (sel) ──▶ color stack ──▶ axis_to_vid_io ──▶ rgb2dvi
                                                 ▲
   MM2S passthrough ──────────────────────────────┘  (sel=0 = boot default; sel=1 = engine)
```

- **`axis_mux2`** drains BOTH inputs (`s0_tready=s1_tready=m_tready`) so the idle MM2S leg
  never parks the genlock ring. `sel` is 2-FF ASYNC_REG synced; firmware engages the engine
  by setting `sel=1` (boot-engage in full-master builds).
- **Genlock frame-follow** (`pg_genlock`): the read slot is derived from the *real* VDMA write
  pointer — tap `axi_vdma/s2mm_frame_ptr_out[5:0]` (exposed even with internal genlock ON, so
  VDMA config is untouched), `read_slot = (frame_ptr − READ_DELAY) mod NUM_FRAMES`
  (`READ_DELAY=2`, `NUM_FRAMES=5`), 2-FF CDC + debounce, latched at output vsync.
  An earlier "mirror" approach (count src-vsync, `slot = #vsync mod 5`) gave **frozen-slot
  cycling** and was wrong — frame-follow off the write pointer is the validated path.

### BD parameters (as built)
| Cell | Config |
|---|---|
| AXI DataMover | `c_enable_s2mm=0` (MM2S only; status stream drained), `c_mm2s_burst_size=256`, on HP1 via `axi_sc_mem2` smartconnect |
| `pg_re_0` | `IN_W=1920 IN_H=1080 OUT_W=1280 OUT_H=720 STRIDE=5760 SLOT_STRIDE=6226560 NBUF=4` (default), `FRAME_BUF_BASE=0x1000_0000 NUM_FRAMES=5 READ_DELAY=2` |
| AXI GPIO 8/9/10 | runtime geometry (firmware-computed DDA steps); see firmware `re_write_geometry()` |

### Full-master decision
S2MM stores the **full 1920×1080** master (`SCALER_MODULE=scaler_bypass_1080p`); the read-engine
does the 1920×1080→1280×720 downscale on the read side. The VTC output timing stays **720p60**
(1080p60 is hardware-blocked on the Zybo −1 part — see `zynq7020_rgb2dvi_1080p60_limit`).
Firmware `READENGINE_FULLMASTER` sets `FRAME_W/H=1920×1080`, `OUT_RASTER_W/H=1280×720`, and
boot-engages the engine. (An earlier build stored full-master but left firmware `FRAME_W/H` at
720p → top-left **crop**; full-master firmware fixed that.)

## 3. Module map (`hdl/pg_*.v`)

| Module | Job |
|---|---|
| `pg_addrgen` | output-raster walk → per pixel `{in_window, src_col, src_row}` via divider-free DDA (`step_int + step_frac/out_w`) |
| `pg_genlock` | pick completed ring slot from `s2mm_frame_ptr_out`; `read_base = FRAME_BUF_BASE + slot*SLOT_STRIDE` |
| `pg_linefetch` | **N-line ring buffer** + DataMover-style fetch; serves master pixels by `(rd_row, rd_col)` with residency |
| `pg_unpack` | 64-bit DataMover beat → 24-bit pixel gearbox (1 px/clk). `[G,B,R]` memory order reconstructs the `{R,B,G}` AXIS layout with **no swizzle** (`schindler_pipeline_rbg_byte_order`) |
| `pg_compose` | output walk + skid FIFO + residency-stall compositor + **prefetch scheduler** + matte mux + output FIFO |
| `pg_read_engine_top` | wraps the above + DataMover **command formatter** (72-bit cmd, BTT = `fetch_len*3` bytes) + status-sink + geometry-bus CDC |
| `axis_mux2` | 2:1 AXIS mux (drains both) |

DDA: `src_col = floor(out_x · IN_W / out_w)` realized as firmware-computed `step_int = IN_W/out_w`,
`step_frac = IN_W%out_w`, accumulated per pixel — **no runtime divider**.

## 4. The shear — symptom, discrimination, root cause

### Symptom
Full-master output **shears**: on a grid test pattern the **horizontal lines stay straight and
correctly placed** (vertical positioning perfect) while **vertical lines oscillate** — each
output *row* is displaced horizontally by a wandering amount that drifts and snaps back
repeatedly down the screen. Justin's read: **"writing lines late."** (720p→720p build #7 was
clean; the shear appeared only on the 1920-wide read path.)

### Discrimination (no rebuild — runtime `G` command)
`uart_cmd.py "G 960 540 0 0"` → a **960-wide window = exactly 2.0× = integer DDA**
(`hstep=2+0/960`, zero fractional). It **still wobbled** → the shear is **not** the fractional
H-DDA accumulator; it is intrinsic to the wide read path, independent of scale ratio.
The *oscillating* (not straight-diagonal) character ⇒ a read-vs-output **timing** beat, not an
addressing error.

### ⚠️ CORRECTION 2026-06-02 (build #11) — the real root cause is a read-during-write collision, NOT rate

The "rate ceiling" theory below was **disproven at the bench**: build #10 (`NBUF=4`) still
ghosted *identically* at output windows 1280×720, 960×540, **and 480×270** — the last has
4.5× rate headroom (270 fetches/frame), so a sustained fill-rate deficit cannot be the cause.
A 4-agent parallel code audit then converged (3 of 4) on the real mechanism:

**Read-during-write / buffer-recycle collision in `pg_linefetch`.** The line-buffer `mem[]`
is read every cycle by the consumer (`rd_data <= mem[{rd_sel,rd_col}]`) while the fetch FSM
writes it (`mem[{fill_buf,fill_idx}] <= fetch_pdata`). Two defects let the read side touch a
buffer the fetch was actively filling/recycling: (1) the read-buffer select had no priority and
**did not exclude the in-flight fill buffer**; (2) `pg_compose`'s prefetch ceiling was
`served_count + (NBUF−2)` = **zero steady-state margin**, so the round-robin recycle could lap
onto the buffer holding the row being read. On silicon a same-cycle read+write to that buffer
returns garbage for one pixel; in behavioral sim the Verilog NBA ordering **always returns old
data**, so it's bit-exact clean (sim *structurally cannot* reproduce it). The corrupted column
= `fill_idx` (fetch cadence) beating against `rd_col` (output cadence) → a **single wrong pixel
that drifts down the frame = the sparse "wavy vertical ghost."** Rate-independent (phase
collision, not throughput); appeared at 1920-wide (longer fetch overlaps the active read);
`NBUF` 2→4 reduced gross oscillation but left the collision (more slack, still zero margin).

**Fix (build #11):** (1) `pg_linefetch` read select = first-match priority **excluding the
fill buffer during `S_FILL`** → consumer stalls (correct) instead of reading a being-written
buffer; this also removes the physical BRAM collision since `rd_sel ≠ fill_buf` ⇒ read/write
always hit different buffers. (2) `pg_compose` `LOOKAHEAD = NBUF−3` (one-row guard band) and
`NBUF=5` (keeps 2-ahead prefetch). Both integration TBs still pass `Total errors = 0`.

The rate analysis below is RETAINED as a *possible* secondary ceiling at the full window only
(it's real math), to be addressed with the packed-beat fill **only if** build #11 leaves
residue exclusively at 1280×720. Builds #8–#10 are superseded.

### Root cause (original two-ceiling theory — ceiling 1 confirmed via collision above; ceiling 2 unverified)

**(1) Buffer depth (latency / burst).** `pg_linefetch` was a strict **2-buffer, 1-row-ahead**
double buffer. `pg_compose`'s prefetch gate was `want_pf = pf_next_k <= served_count` — the next
source line could not start fetching until the consumer had *entered* the current line. So each
line had to fetch fully within one output-line time, with **zero slack** for DDR jitter. On
`iter5` the three DDR masters (S2MM write + VDMA MM2S read + read-engine read) contend for the
controller; any fetch that runs long starves the next line → consumer stalls at row start →
that row lands late → the wobble.

**(2) Fill rate (sustained).** `pg_unpack` emits **1 px/clk**, so the line buffer fills at
1 px/clk = **`IN_W` (1920) clocks per source line**. The engine fetches **one full 1920-px line
per output window row**. At 720p60 the frame budget is `htotal·vtotal = 1650·750 = 1,237,500`
clk:

| Output window | Fetch clk/frame (`win_h · IN_W`) | Budget | Verdict |
|---|---|---|---|
| 1280×720 (full) | 720 · 1920 = **1,382,400** | 1,237,500 | **~11% over → rate-bound** |
| 960×540 | 540 · 1920 = **1,036,800** | 1,237,500 | fits (+200k) → latency-only |

Depth absorbs *bursts* but cannot fix a *sustained* deficit. So at the **full** window the
engine falls behind every frame no matter how deep the buffer; at **960×540** the wobble was
purely latency and depth alone should clean it.

> Burst size was a red herring: build #9 (`c_mm2s_burst_size 16→256`, output FIFO `16→64`)
> changed nothing — it tunes bus efficiency, not scheduling or fill rate.

## 5. Fixes

| Ceiling | Fix | Where | Status |
|---|---|---|---|
| Latency / burst | **`NBUF`-deep ring (=4) + (NBUF−2)=2-row lookahead** | `pg_linefetch` (flat BRAM `{sel,col[10:0]}`, `BSTRIDE=2048`, round-robin fill, N-way residency); `pg_compose` `want_pf = pf_next_k <= served_count + (NBUF-2)`; `NBUF` threaded through `pg_read_engine_top` | **build #10**, sim-clean |
| Sustained rate | **Packed-beat fill** (below) | `pg_linefetch` + `pg_read_engine_top` (drops `pg_unpack` from datapath) | **TODO** — only if bench confirms rate-bound |

`NBUF=2` collapses `pg_linefetch`/`pg_compose` to the exact original 1-ahead double buffer →
regression-safe. BRAM cost at `NBUF=4`: 4 · 2048 · 24b ≈ 5.3 BRAM36.

### Packed-beat fill (the rate fix, designed, not yet built)
Store the **raw 64-bit DataMover beats** in the line buffer at **1 beat/clk** (≈ `ceil(IN_W·3/8)`
= 720 clk/line, **2.4× margin**), and extract the 24-bit pixel on the **read** side by byte
address:
- pixel `src_col` occupies bytes `[3·col, 3·col+2]` in memory order `[G,B,R]`;
- those 3 bytes may straddle two adjacent 64-bit beats → read beat `b=(3·col)>>3` and `b+1`
  (dual-port or two registered reads), byte-mux 3 bytes → assemble `{R,B,G}` AXIS pixel;
- removes `pg_unpack` from the datapath (the buffer ingests beats directly; `s_axis_dm_tready`
  = "ring has room").
Risk = the byte-straddle extraction + `[G,B,R]` order (a mistake here shows as a horizontal
shift or a color swap) → must be sim-verified against a packed-beat golden before synth.

## 6. Build & bench history

| Build | Change | Bench result |
|---|---|---|
| #7 | genlock frame-follow, 720p master (1:1) | **clean** — core validated, steady live windowed scaling |
| #8 | full-master 1920×1080 | crop fixed, but **shears** |
| #9 | burst 16→256, FIFO 16→64 | **no change** — disproves throughput-tuning |
| #10 | **`NBUF=4` ring + 2-row lookahead** | *pending* — discriminator |

**Build #10 prediction (the experiment):** `G 960 540 0 0` → **clean** (latency fixed);
boot `1280×720` → **still wobbles** if rate-bound (→ do packed-beat). If *both* clean, the rate
model is wrong/over-conservative and we're done.

## 7. Bench procedure & tooling

**Verify on the monitor, not the capture stick or the frame-dump.** The MS2109 has its own
framebuffer and masks vertical wraparound/offset; the firmware frame-dump reads DDR through the
PS cache and returns stale data. Bench truth = the **HDMI monitor**. (`schindler_ms2109_verification_trap`.)

**Source:** `python/bench/osee_switch.py 1` selects Osee input 1 = ImagePro static SMPTE/grid
(only known-static source). Always confirm the Osee input before drawing visual conclusions.

**Runtime geometry over UART** (`python/bench/uart_cmd.py`): the daemon `schindlerd` owns
`/dev/ttyUSB1`, so to send a raw `G` command, stop it first, send, then restart:
```
kill <schindlerd pid>                       # frees the port
/tmp/schindlerd-venv/bin/python python/bench/uart_cmd.py "i"            # firmware info / DIAG
/tmp/schindlerd-venv/bin/python python/bench/uart_cmd.py "G 960 540 0 0"  # window w h x y ; "G 0" disengages
nohup /tmp/schindlerd-venv/bin/python control-plane/schindlerd/schindlerd.py -v >/tmp/schindlerd.log 2>&1 &
```
(`uart_cmd.py` uses the daemon venv because it has pyserial; the system python3 does not.)

**Build / program:**
```
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
source /tools/Xilinx/2025.2/Vitis/settings64.sh
make build        # Vivado → bitstream  (SCALER_MODULE defaults to scaler_bypass_1080p)
READENGINE_FULLMASTER=1 make build-app   # Vitis ELF (full-master firmware)
xsct tcl/program_phase_b_full.tcl        # download
```
Both env vars are mandatory or the build aborts at the board-file check. Never `git checkout`
or start a competing Vivado build while one is running.

**Sim:** run the integration TBs directly (the `make sim-pg` wrapper mis-reports an xsim exit
code and aborts after the genlock TB):
```
cd sim && xvlog pg_compose_tb.v ../hdl/pg_compose.v ../hdl/pg_addrgen.v ../hdl/pg_linefetch.v \
  && xelab -top pg_compose_tb -snapshot s && xsim s -runall   # expect Total errors = 0
```

## 8. Verification rules in force
- **No coin-flip:** ≥3 cold reboots steady before declaring a build ✅ (`schindler_no_coin_flip_rule`).
- **Provenance:** every build snapshotted + recreatable; `docs/build-manifest.md` is canonical.
- **HDMI compliance:** output stays spec-compliant — no out-of-spec MMCM, no margin tricks as a
  shipping path (`hdmi_compliance_rule`).
- **Pmod naming:** physical "Pin 7", never Digilent signal-index.

---

## 9. ILA capture (build #13) — ROOT CAUSE CONFIRMED: nearest-neighbor aliasing

After builds #10/#11 (depth + collision fixes) the artifact persisted identically at every
window size, so we instrumented the read-engine internals with two `system_ila` cores and
captured on live silicon (engine engaged, grid source). This **ends the guessing** — it is
hardware ground truth, not theory.

**Build #13** = build #11 substrate + ILA. Timing met (WNS +0.170). Two cores:
- `ila_re_dbg` — NATIVE, 96-bit `pg_re_0/dbg_probe` (bit layout in `hdl/pg_read_engine_top.v`):
  `[11:0]src_col [23:12]src_row [24]a_valid [25]inwin [26]newrow [27]resident [28]up_pvalid
  [29]up_plast [30]m_tvalid [31]m_tready [55:32]rd_data(buf→out) [79:56]up_pdata(unpack→buf)`.
- `ila_re_beats` — AXIS on `re_datamover/M_AXIS_MM2S` (64-bit DDR beats).

### Capture procedure (reproducible)
1. Program PL+PS via `xsct tcl/program_phase_b_full.tcl` (engine boot-engages; ghost on screen),
   Osee on input 1 (grid). xsct exits → JTAG free.
2. `vivado -mode batch -source tcl/capture_re_ila.tcl` — attaches the hw_manager read-only,
   loads `build/phase-b-vdma-passthrough/phase-b-vdma-passthrough.runs/impl_1/phase_b_bd_wrapper.ltx`,
   immediate-triggers each ILA, writes `/tmp/ila_dbg.csv` + `/tmp/ila_beats.csv`.
   Gotchas learned: hw ILAs are named `hw_ila_N` (match by **probe name**, not CELL_NAME which is
   empty); `refresh_hw_device` must run WITHOUT `-update_hw_probes false` or probes don't load;
   NATIVE `system_ila` needs `CONFIG.C_PROBE0_WIDTH` set or `probe0` pin won't exist; write the
   data object returned by `upload_hw_ila_data`, not `current_hw_ila_data`.
3. Decode with `/tmp/decode_dbg.py`.

### Result — the engine is provably CORRECT
- **`src_col` marches `+1,+2,+1,+2…`** = exact `floor(col×1.5)` for 1920→1280; strictly
  monotonic; **zero** non-monotonic events. At a row boundary `src_row 363→364`, `src_col`
  resets to 0, `newrow=1`. **Addressing (H+V DDA) is perfect — no skew, no drift, no off-by-one.**
- **`resident`≈always 1** (3 stalls in 1294 in-window pixels) — buffer keeps up.
- **`rd_data` over the whole capture = exactly `000000` and `ffffff`. Nothing else.** Black runs
  (the grid's flat regions) read as pure `000000`, every pixel. `up_pdata` likewise only
  black/white. **Data in and out is bit-clean; no corruption; uniform input → uniform output.**

**Conclusion:** there is NO bug in the read-engine. It performs a correct decimating DDA on
bit-clean data. The on-screen artifact is therefore **nearest-neighbor decimation aliasing
(moiré)** — the engine correctly keeps ~1 of every 1.5 columns / ~2 of every 3 rows with **no
low-pass filter**, so fine source detail beats against the sample grid. This kills every prior
theory (rate, depth, collision, stride, addressing/skew) — all disproven by hardware capture.

> **Root architectural cause:** `SCALER_MODULE=scaler_bypass_1080p` stored the full master to
> enable read-side geometry, which also bypassed `scaler_h/scaler_v`'s 2-tap boxcar
> **anti-alias filter**. The read path replaced it with pure nearest-neighbor. Full-res-in +
> no-filter + downscale = moiré.

## 10. Fix — 4-agent design consensus (2026-06-02)

Four parallel agents (H-filter, V-filter, reuse-assessment, risk/verification) **converged**:

**DO FIRST — un-bypass the input scaler (build #7 config).** Set `SCALER_MODULE=scaler_top`
(its 2-tap boxcar does the anti-aliased 1080→720), store a **1280×720 master**, and the
read-engine does only size/position/matte on that pre-filtered master (read-engine params back to
`IN_W=1280 IN_H=720 STRIDE=3840` + matching `SLOT_STRIDE`; firmware drop `READENGINE_FULLMASTER`,
`FRAME_W/H=1280×720`). This is **exactly build #7, which was bench-CLEAN.** The real
anti-aliasing happens in the proven, sim-gated scaler; the read-engine's residual resample is
~1:1 (minimal aliasing). ~1 build, low risk, and it sidesteps the read-path-filter rewrite AND the
genlock-geometry pitfalls. Verify on the **monitor** (MS2109 masks exactly this class).

**Cost / trade:** the master detail ceiling becomes 720p — you can shrink/place but not **zoom
*in* past native sharpness**. Per `adjustable-scaler-design.md` that is **G2**, not G1 (G1 =
size/shrink/position/matte). **Needs a scope confirmation from Justin** (see open questions).

**Rejected:** embedding `scaler_h/scaler_v` inside the read path — they are streaming/raster
modules; the read path is random-access. Incompatible data-flow; not reusable as-is.

**Eventual (G2) — read-path box filter** (only after the read-engine is bench-clean AND scope
confirms full-master zoom is wanted). Agent-specced design, recorded so a future agent can build it:
- **Horizontal — box-average during the line FILL.** New `pg_hbox` between `pg_unpack` and
  `pg_linefetch`: forward DDA (`accum += out_w; emit when ≥ IN_W`), per-bin running sum of the
  source pixels in the bin, divide by **measured count** via a small reciprocal-LUT (`recip[n]=
  round(65536/n)`, `avg=(sum*recip+32768)>>16`) — NOT a single firmware `1/span` (the +1/+2 DDA
  gives cnt=1 vs 2 on adjacent bins → a global reciprocal stripes the edges). Stores OUT_W-wide
  filtered lines → read stays 1 px/clk. **Consequence:** read-side `rd_col` must become the output
  window column, not `src_col` (the H downscale moves from read-time to fill-time) — a real
  `pg_compose`/`pg_addrgen` refactor.
- **Vertical — 2-tap boxcar on READ.** Split `pg_linefetch`'s single `mem[{sel,col}]` into NBUF
  independent BRAM arrays (mirrors `scaler_v`'s per-slot lbufs) so two adjacent rows can be read in
  one cycle; blend `(a+b+1)>>1` per channel in `pg_compose`'s C1; gate `head_servable` on BOTH rows
  resident; bump `NBUF` 5→6 and `LOOKAHEAD=NBUF-4` (2-row read window needs a bigger guard).
- **Filter strength:** 2-tap is sufficient for the 1.5× production case; heavy-shrink windows
  (≥2×, e.g. →480) need a span-width box (`taps≈ceil(ratio)`) or they still alias. Don't
  over-filter (a box wider than the span blurs — see scaler_h iter10 "too soft").
- **No-divider V:** 2-tap is `(a+b+1)>>1`, a fixed shift — no divider. (H needs the count-LUT.)
- **[G,B,R] order:** average each 8-bit lane independently in its bit position; never average the
  packed 24-bit word (cross-channel carry → chroma speckle).

### Golden-model spec for the G2 read-path box (gate before any synth)
The TBs (`sim/pg_compose_tb.v`, `pg_read_engine_top_tb.v`) currently check a **nearest-neighbor**
golden. A box filter MUST update the golden in lockstep or the sim proves nothing. The golden must
match the HDL **exactly**:
1. **Tap selection = "newest + one-older", not centered.** 2-tap H golden = `avg(src[sr][sc],
   src[sr][sc-1])`; V = `avg(src[sr][sc], src[sr-1][sc])` — the same asymmetry `scaler_h/v` use.
2. **Rounding = `(a+b+1)>>1` per channel** (round-to-nearest; truncation gives a −0.5 LSB/axis DC
   darkening the MS2109 hides and the monitor shows).
3. **Per-lane**: slice `[23:16]/[15:8]/[7:0]`, average each, repack — never the packed word.
4. **Edge**: `scaler_h/v` clear `window[0]` on TLAST, so the first output pixel of a row/frame
   averages `(src[0], 0)` = half-bright; the golden must replicate (don't edge-clamp/replicate).
5. **No fractional weighting** — boxcar is equal-weight integer-indexed neighbors; do not weight by
   the DDA fraction (that's the dead polyphase path).
Run with the box degenerated to 1:1 first (must match NN golden), then enable; include a ≥2×
heavy-shrink case to document the 2-tap limit. Verify on the monitor, Osee input 1.

## 11. OPEN QUESTIONS (for the next agent to drive)

### Q1 — ✅ RESOLVED 2026-06-02: it IS aliasing — of source DITHER. Engine is correct.

Test 1 (engine on/off A/B on flat colors) + Test 2 (ILA on solid red) settled it on silicon:
- **Test 1:** flat R/G/B clean with engine **OFF** (1:1 crop, no decimation); the diagonal "trash"
  returns with engine **ON** (decimation) on the *same* colors → pattern **follows the engine** →
  display/camera (H-C) RULED OUT.
- **Test 2 (`ila_re_dbg` on solid red):** `rd_data` is NOT constant — R wanders 0xF4–0xF8 with
  sparse B/G 1–3 (19 distinct values, dithered around the nominal). `up_pdata` (data straight from
  DDR, before the engine) shows the **same** dither distribution. ⇒ the laptop outputs a
  **spatially-dithered** red; the dither is in the SOURCE, the engine **faithfully carries it**
  (`rd_data`≈`up_pdata`, not fabricated → H-B ruled out), and the **nearest-neighbor decimation
  aliases the dither** → the visible "trash."

**Final root cause (whole investigation):** nearest-neighbor decimation aliasing of high-frequency
source content (panel/GPU dither + thin lines), introduced because the full-master path bypassed
`scaler_h/scaler_v`'s anti-alias boxcar. The read-engine is provably correct (addressing perfect,
data bit-clean, transport faithful). Fix = low-pass before decimation (§10): un-bypass the input
scaler (boxcar low-passes the dither before DDR → decimation has nothing to alias → clean = build
#7), or add a read-path box. Engine-at-1:1 is clean because there is no decimation.

### Remaining OPEN items

**Q2 — SCOPE (Justin to confirm): does G1 need zoom-*in* past 720 native, or is a 720 master
sufficient (zoom deferred to G2)?**

The contradiction the next agent must resolve:
- **ILA (build #13, grid source):** in the grid's flat **black** regions the engine output
  `rd_data` is pure `000000`, every pixel — engine digital output is provably clean on flat BLACK.
- **Bench (Justin, 2026-06-02):** full-screen flat **green / red / orange** fields each show the
  SAME fine pattern (fine horizontal striping + faint soft vertical/diagonal bands). Confirmed on
  multiple solid colors — NOT a gradient, NOT dismissible as camera moiré alone.

Black is the ONE color the ILA-on-grid couldn't use to expose a value-dependent or dither effect.
The two surviving hypotheses (and the cheap tests that decide between them):

  **H-A: source dither aliased.** The laptop likely dithers solid non-black colors (GPU spatial/
  temporal dither); black needs none (→ ILA clean), a dithered mid-tone carries fine HF noise that
  the engine's NN decimation aliases → the pattern. Still "aliasing", of dither.
  **H-B: a value-dependent effect downstream of the `rd_data` tap** (output FIFO / color stack /
  output stage) invisible on black. (Weaker: the MM2S crop went through the same downstream clean.)
  **H-C: display/camera** (LCD backlight vertical bands + camera-vs-LCD horizontal moiré) present
  regardless of the engine.

**Decisive tests (cheap, board still has the build #13 ILA + firmware):**
  1. **Engine ON/OFF toggle on a flat color** (the fastest discriminator): show a solid color, then
     `uart_cmd.py "G 0"` (MM2S 1:1 crop, no decimation) vs `"G 1280 720 0 0"` (engine, decimating).
     Pattern **follows the engine** → H-A/H-B (engine-introduced; proceed to §10 fix + confirm it
     clears the dither-alias). Pattern **present with engine OFF too** → H-C (display/camera; the
     engine is exonerated and the §10 fix is still correct for the *grid* aliasing but won't change
     the flat-color look because it's not in the signal).
  2. **ILA `ila_re_dbg` on a flat COLOR field** (`tcl/capture_re_ila.tcl`): is `rd_data`
     **constant** (→ engine clean even on flat color → pattern is H-C display/camera) or **fine-
     varying around the nominal color** (→ H-A dither being aliased, or H-B if it varies in a way
     the source dither doesn't explain — capture `up_pdata` too: if `up_pdata` already varies, the
     dither is in the source; if `up_pdata` is constant but `rd_data` varies, it's an engine bug)?
  Run test 1 first (seconds), then test 2 to nail the mechanism. This MUST resolve before
  committing to the §10 fix — if it's H-C the fix won't change the flat-color look (set
  expectations), if H-A the fix should clear it, if H-B neither §10 path helps and it re-opens.

**Q2 — SCOPE (Justin to confirm): does G1 need zoom-*in* past 720 native, or is a 720 master
sufficient (zoom deferred to G2)?** If 720 is sufficient → the §10 "un-bypass input scaler" fix is
the fast clean path. If full-master zoom is required now → must build the G2 read-path box (§10),
which is multi-build and should wait until Q1 is closed and the read-engine is confirmed clean.

**Q3 — IMPLEMENTATION:** once Q1/Q2 resolve, execute the chosen path. For the input-scaler path,
restore the build #7 geometry (720 master) and verify ≥3 cold boots clean. For the read-path box,
follow the §10 design + the golden-model spec, sim-gate first, then one bench build.

## 12. INDEPENDENT REVIEW (2026-06-02) — diagnosis OVERTURNED

A fresh agent verified the §9–§11 diagnosis from scratch (HDL + the ILA capture's TEMPORAL
structure, which the original analysis missed) and **refuted the core conclusion**. Confirmed by
re-running `/tmp/decode_dbg.py` with run-length analysis:
- **523-cycle output underrun** (`m_tready & !m_tvalid`) @ s1329 — a third of an active row starved.
- **608-cycle addrgen freeze** (`a_valid=0`) @ s1271; **residency lost mid-row** (`resident=0`,
  in-window) @ s1268, `src_col` frozen at 7, `src_row` 162.
- **`rd_data` held at `0x240000`** (garbage, not source) through the stall; review also found rd
  values `0x6a/0xab/0xb8` @ s1879–1884 **absent from `up_pdata`** → boundary garbage, not faithful
  transport.

### Verdict table (reviewer)
| Claim | Verdict | Basis |
|---|---|---|
| Addressing/DDA correct (`floor(col·1.5)`, monotonic) | **AGREE** | decoder: 0 non-monotonic; `pg_addrgen.v:19,122` |
| Decimation is after the read (H: full line buffered) | **AGREE (H); corrected: V is pre-fetch** | `pg_linefetch.v:126-134`; `pg_compose.v:228-234` |
| Engine "provably correct / bit-clean / faithful transport" | **DISAGREE** | `rd_data` carries `0x24/0x6a/0xab/0xb8` absent from `up_pdata`; resident garbage s1879-1884 |
| Root cause = NN aliasing of source dither | **DISAGREE (insufficient)** | dither is ±2-3 LSB (invisible); doesn't explain frame-to-frame crawl or 523-cyc underrun |
| Ruled out: stride | **AGREE** | BD/firmware both 5760 |
| Ruled out: read-during-write collision | **DISAGREE** | residency lost mid-row + resident boundary garbage = that class |
| Ruled out: fill rate / buffer depth | **UNSURE / not established** | 608-cyc residency stall; tests measured steady-state, not per-row latency |
| Box-filter fix feasibility | **DISAGREE (premature)** | needs un-fetched V rows; sim can't catch the real bug (`pg_linefetch.v:90-92`) |

### Corrected root cause + plan
**Real cause:** prefetch/residency coherency failure — a row's residency is lost MID-READ →
consumer stalls hundreds of cycles → active-video underrun → held/boundary garbage. Timing-
dependent → frame-to-frame variable (the observed crawl). Build #11's read-select-excludes-fill
fix stopped the garbage *read* but not the residency *loss* → still stalls → underruns.

**Three candidate sub-mechanisms (data must distinguish — do NOT guess):**
1. recycle lap — `fill_sel` overwrites the buffer holding the read row (LOOKAHEAD/NBUF guard
   insufficient);
2. prefetch-behind / per-row latency — the row wasn't fetched in time (re-opens the rate question);
3. V-DDA divergence — `pg_compose` prefetch `pf_src` ≠ `pg_addrgen` read `v_src` for the same
   window-row → read asks for a never-fetched row.

**Next steps (supersede §10/§11 fix):**
1. Widen `dbg_probe` to expose prefetch state (`pf_src`, `pf_next_k`, `served_count`, `fill_sel`,
   `rd_sel`, `m3_busy`, `pf_req`, `have_row`) + `push_data`/`push_en`; capture across the stall and
   ≥2 frames (confirms mechanism AND drift). [Build #14 = this ILA.]
2. Root-cause + fix the coherency bug in `pg_compose` prefetch / `pg_linefetch` recycle.
3. Anti-alias work deferred until residency is provably stable; when sim is used, drive realistic
   HBLANK/DDR-latency stalls (the current TB structurally cannot reproduce this underrun — which is
   why 6 builds + the original analysis missed it).

## 13. ROOT CAUSE (ILA build #14, prefetch-state probe) — per-row fetch latency

Build #14 widened `dbg_probe` to 192-bit to expose the prefetch state (`pf_src`, `pf_next_k`,
`served`, `fill_sel`, `rd_sel`, `m3_busy`, `pf_req`, `have_row`, `push_data`). Captured on a
**steady solid red**, engine engaged. Decoder: `python/bench/decode_re_ila.py`. Raw CSV preserved.

### What the capture shows (the recovery edge is the proof)
- Run-lengths: **resident=0 for 622 cyc** (s1249), **a_valid=0 for 622 cyc** (s1252, addrgen frozen
  because the skid filled), **output STARVATION (`m_tready & !m_tvalid`) for 563 cyc** (s1310).
- At stall onset **s1249**: consumer advances `rd_row 375→376`; row 376 is **not resident**
  (`res=0`); a fetch is **in progress** (`m3_busy=1`) the entire stall; `served=251`,
  `pf_next_k=252` (prefetch only ~1 row ahead in issue).
- **Recovery s1871 (smoking gun):** the instant the in-flight fetch completes (`m3_busy 1→0`,
  `fill_sel 4→0`), row 376 **becomes resident in slot 4** (`rd_sel 0→4`, `res 0→1`, `have=1`) and
  the consumer resumes (`a_valid→1` @ s1874). **The wanted row appears exactly when its fetch
  finishes.**

### Mechanism (data-justified): the consumer outruns a serialized, too-slow line fetch
The line fill is **1 px/clk through `pg_unpack`** ⇒ ~**IN_W cycles to fill one master line**
(1920 for the current master). One output row's budget is `htotal` ≈ **1650 cycles** (720p60).
Since `IN_W (1920) > htotal (1650)` **and fetches are serialized (one in flight)**, the prefetch
loses ~270 cyc/row; the NBUF ring only delays the catch-up a few rows, then the consumer reaches a
row whose fetch isn't done → **622-cyc stall → 563-cyc output underrun → ~⅓-row band of held/blank
output**, drifting frame-to-frame as the stall position moves. This is the reviewer's UNSURE
"rate/per-row latency" item, now confirmed; it explains why NBUF 2→4 didn't help (depth delays a
*sustained* per-row deficit, never closes it) and why it's window-size-independent (the per-line
fetch is always IN_W px regardless of output width). **Lap and V-DDA divergence are ruled out**:
the slot received the *correct* row (376), just late (recovery edge), and the rows were fetched
(the decoder "miss" set is a short-capture artifact — only one `pf_req` pulse was in-window).

### ⚠️ "720" clarification (so this isn't misread)
The proposed fix's "~720 cycles/line" is **`ceil(IN_W·3/8)` = number of 64-bit beats in a 1920-px
RGB line** (5760 bytes / 8). It is **IN_W-derived, NOT the 720p output resolution** — pure
coincidence of value. The budget `htotal=1650` is the 720p VTC timing. Nothing hard-codes 720; the
read-engine geometry is fully runtime-parameterized.

### Proposed fix: packed-beat line fill (was designed at build #10, now data-justified)
Store the **raw 64-bit DataMover beats** in the ring at **1 beat/clk** (~`ceil(IN_W·3/8)` cyc/line
≈ 720 for IN_W=1920), and extract the 24-bit pixel on the **read** side by byte address (`pg_unpack`
moves from the fill path to a read-side extractor; a pixel may straddle two beats → read beat b and
b+1, byte-mux, `[G,B,R]` order). Then per-line fill (~720 cyc) « per-row budget (1650 cyc), so the
fetch outpaces the drain, the prefetch stays ahead, and the stall/underrun cannot occur. Anti-alias
work stays deferred until residency is stable. Open risks to verify before building: (a) DDR/DataMover
command latency + 4 KB-boundary beat gaps on top of the 720 beats (still « 1650?); (b) read-side
2-beat straddle extraction correctness (byte order/rounding); (c) sim must drive realistic
HBLANK + DDR-latency stalls (current TB can't reproduce the underrun). Pending independent review.

## 14. FIX IMPLEMENTED + SIM-PROVEN (build #15) — packed-beat line fill

Per the reviewer's gated plan, with the latency-modeling sim as the hard gate FIRST.

**STEP 1 (gate) ✅** `sim/pg_latency_tb.v` reproduces the underrun on the OLD RTL: with a
realistic deficit ratio (per-line fill IN_W=256 cyc > row budget OUT_W+HBLANK=168; packed-beat
would be 96), it shows `seen≈1787/3072, starvation≈1285/frame, golden errors=0` (delivery fails,
data uncorrupted) — exactly the mechanism. (The stock TBs never showed it: long HBLANK + tiny
IN_W = huge fill surplus.)

**STEP 2 ✅ packed-beat HDL.** `pg_linefetch.v` rewritten to store raw 64-bit beats at 1 beat/clk
in **even/odd beat banks** (beat bi → bank[bi&1] at idx bi>>1, so two consecutive beats read in
one cycle). Read side: `o=3*rd_col`, `b=o>>3`, `sub=o&7`; read `mem_e[{sel, (b>>1)+(b&1)}]` and
`mem_o[{sel, b>>1}]` (registered), form 128-bit `{hi,lo}` window, `rd_data = window[sub*8 +: 24]`
= `{R,B,G}` ([G,B,R] memory order, no swizzle), NN pick (no rounding). Single-cycle `rd_data`
preserved (registered banks + combinational shift). `pg_unpack` removed from the datapath
(`pg_compose` fetch port and `pg_read_engine_top` now carry 64-bit beats: `beat_data/valid/ready/
last`; `s_axis_dm_tready ← beat_ready`). DDA + residency/recycle + the read-during-write
fill-buffer exclusion all unchanged.

**STEP 3 ✅ proven in sim.** `pg_latency_tb` on the NEW RTL: `3072/3072, starvation=0, errors=0`
(underrun GONE, fill now ~96 « 168). `pg_read_engine_top_tb` (full chain, real beat interface):
`Total errors = 0` across 1:1 (64×48 — cycles every `sub` incl. the straddle cols 2,5), 1.6×
(40×30), 2× (32×24); latency TB adds 2× (256×128). Byte-straddle extraction is bit-exact.

**STEP 4 (in progress):** build #15 (Vivado) → full-master ELF → program. 192-bit ILA retained to
re-capture on HW and confirm zero residency stalls / zero underrun. Then monitor verify (grid +
solid, ≥3 cold boots). Standalone `pg_compose_tb`/`pg_linefetch_tb` predate the beat interface and
need a beat-model refresh (hygiene; the full-chain top TB + latency TB are the authoritative gates).

Why packed-beat over the alternatives: input-scaler un-bypass would discard the full master (no
zoom — Justin requires zoom-past-native); pipelining multiple in-flight fetches doesn't help while
a single 1px/clk unpack is the limiter. Packed-beat removes the 1px/clk bottleneck at the source.
