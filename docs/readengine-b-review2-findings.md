# Read-Engine-B — Independent Review #2 Findings & Build Guidance

**Date:** 2026-06-02. **Branch:** `readengine-b-integration`. **Reviewer:** independent (verified from
HDL + build #14 192-bit ILA capture, not from the prose).
**Verdict in one line:** mechanism (per-row fetch latency) **CONFIRMED**; fix (packed-beat fill)
**SOUND** — build it *if full-master zoom is in scope*, behind a latency-modeling sim gate and an
even/odd read-bank. This is the first of the three theories that survives full scrutiny.

---

## 1. Corrected root-cause picture (supersedes "dither aliasing")

The artifact is **not** nearest-neighbor dither aliasing, and **not** corrupted pixels on screen.
It is an **output-FIFO underrun** — a held/blank band — caused by a structural line-fill rate deficit:

- The line fill is **pixel-limited at 1 px/clk** through `pg_unpack` (`pg_unpack.v:43,56`) → a
  1920-px master line takes **≥1920 clk** to land in the ring (`pg_linefetch.v:133`).
- Each in-window output row needs **one new master line** (1.5× V-DDA gives a distinct `src_row`
  per output row — `pg_addrgen.v:144-153`).
- One output row's budget is **htotal ≈ 1650 clk** (720p60; the fetch runs through blanking too).
- **1920 (really ~2200, see §2) > 1650 ⇒ a sustained ~270–550 clk/row deficit.** Fetches are
  serialized — `pg_linefetch` is a single `S_IDLE↔S_FILL` machine and `pg_compose.v:219` gates
  `do_pf = … && !m3_busy`, so only one fetch is ever in flight. Ring depth (`NBUF`) buys a one-time
  head start that depletes in ~12 rows, then the consumer stalls **mid-row** on the in-flight fetch.

On screen: a ~⅓-row blank/held band that **drifts frame-to-frame** because the stall phase moves
with DDR timing — exactly the reported symptom, and exactly why it can't be a deterministic
decimation of a (static, even dithered) source frame.

### Visual confirmation (`~/Pictures/Webcam/2026-06-02-173028.jpg`, solid-red source)

A monitor photo on a flat-red field shows a **drifting parallelogram band** with stair-stepped
left/right edges, filled with fine **black** horizontal striping. This discriminates against the
dither theory directly: dither aliasing would produce subtly-*varying red*, never black — the black
is the output being **starved** (no valid pixel → vid path emits zero/held), i.e. the underrun. The
diagonal slope + stair-steps are the per-row fetch deficit accumulating and walking the stall phase
down the frame; the band drifts frame-to-frame because the stall phase tracks DDR timing. Picture
matches the ILA mechanism below exactly.

## 2. Evidence (build #14, `/tmp/ila_dbg.csv`, 192-bit `dbg_probe`, `python/bench/decode_re_ila.py`)

- **Recovery edge (decisive), s1870→s1871:** `busy 1→0`, `res 0→1`, `rdsel 0→4`, `fill 4→0`. Row 376
  goes resident the instant its own fetch completes (`pg_linefetch.v:136-139`). ⇒ pure latency.
- **Stall / underrun:** residency lost s1249, `res=0` for **622 cyc**; output underrun
  (`m_tvalid=0 & m_tready=1`) s1310 for **563 cyc**.
- **Bottleneck is the unpack, not DDR:** `up_pvalid = 87% during the in-flight fetch` (553/622 even
  inside the stall). DDR/HP1 contention is keeping unpack ~saturated; if DDR were the cap, this would
  sit near 43% (720 beats / 1650 cyc). Effective fill ≈ 1920/0.87 ≈ **~2200 cyc/line**.
- **Emitted data is CLEAN** (revises review #1's worry): the `push_en`-gated `push_data` histogram is
  R = 0xf5–0xfa only — the dithered source red. The garbage values (0x24, 0x6a, 0xab, …) seen in the
  raw `rd_data` tap live **only during the stall and are never pushed** (`head_servable` requires
  residency — `pg_compose.v:155`). No corruption reaches the FIFO; the visible defect is the
  *absence* of valid pixels (underrun), not wrong ones.
- **Lap ruled out (by data):** during the fill, `fill_sel=4` but `rd_sel=0`, `res=0` — the
  read-select guard (`pg_linefetch.v:99-101`) excludes the in-flight buffer; slot 4 is never read
  while filling. Guard converts a would-be overwrite into a stall.
- **V-DDA divergence ruled out:** recovery edge proves row 376 *was* fetched (just late). The
  decoder's "miss list" is inconclusive (only one `pf_req` pulse in the 2048-sample window).

## 3. Why the corroborating facts all fit

| Observation | Explanation under this mechanism |
|---|---|
| NBUF 2→4 didn't help | depth can't close a sustained per-row rate deficit |
| window-size-independent | the fetch is always the full `IN_W`-px master line; htotal is fixed by output mode |
| follows engine on/off | the stall is engine-internal |
| crawls frame-to-frame | stall phase tracks DDR timing (non-deterministic), not a static decimation |
| build #7 was clean | a 1280-px line fills in 1280 < 1650 → no deficit (as much as any anti-alias) |

## 4. The fix — packed-beat line fill (and the cheaper fork)

**Packed-beat fill:** store the raw 64-bit DataMover beats in the ring at **1 beat/clk**
(`ceil(IN_W·3/8) = 720` beats for `IN_W=1920`), and extract the 24-bit pixel on the **read** side by
byte address. Drops `pg_unpack` out of the fill path. At the measured 13% bubble rate the fill is
~830 cyc/line < 1650 — ~2× margin. **Attacks the true bottleneck (§2).**

Two non-negotiables before/with the HDL:

1. **Even/odd beat-bank read (highest sim-pass/hardware-fail risk).** A pixel straddles two 8-byte
   beats whenever `p mod 8 ∈ {2,5}` (2 of every 8 pixels). With random-access `rd_col` a single-port
   read is 2 cycles for those → 0.5 px/clk → you'd trade the fill stall for a **read** stall. Store
   even/odd beats in separate banks (or dual-port both-as-read) so beat `b` and `b+1` return in one
   cycle, preserving the single-cycle `rd_data` that `pg_compose`'s C0→C1 pipeline assumes
   (`pg_linefetch.v:109`, `pg_compose.v:151-171`). Byte order stays low-24-bits `{R,B,G}`
   (`pg_unpack.v:8-10`), no swizzle; NN pick needs no rounding.
2. **A latency-modeling sim gate (the gap open since review #1).** The current TB *structurally
   cannot* show this stall — `pg_linefetch.v:90-92` says the long-HBLANK sim never overlaps a fill
   with a read of the same row. Build a behavioral DataMover that delivers beats at a realistic rate
   under an htotal-bounded row clock, **reproduce the underrun in sim first**, then prove packed-beat
   removes it AND that the read-bank sustains 1 px/clk at the straddle columns. A bit-exact NN golden
   alone proves nothing about this defect.

**Rejected alternative — pipeline more DataMover commands in flight:** inferior here. It speeds DDR
latency, which §2 shows is *not* the bottleneck; it feeds a gearbox that's already 87% fed.

**Cheaper fork — un-bypass the input scaler (build #7, 720 master at ~1:1):** a 1280-px line fills in
1280 < 1650 → no deficit, no stall, **even without packed-beat**, and skips the read-side gearbox
entirely. Cost: 720 detail ceiling, no zoom past native (doc Q2 / G2). Lower risk if zoom isn't
needed this milestone.

## 5. The decision (Q2 scope fork)

- **Full-master zoom needed now** → build **packed-beat fill** (§4), behind both gates.
- **720-native acceptable now** → **un-bypass input scaler** — one build, clean, defers zoom to G2.

Both eliminate the stall; they differ in cost vs capability, not correctness. Verify on the bench
**monitor**, not the MS2109.
