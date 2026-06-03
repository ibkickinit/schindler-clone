# Build prompt — read-engine-B fill-rate fix (post review #2)

Hand this to the implementing agent. Full reviewer findings: `docs/readengine-b-review2-findings.md`.

---

The route-B read-engine's on-screen artifact has been root-caused and independently confirmed (two
review rounds + build #14 192-bit ILA). **It is NOT dither aliasing and NOT corrupted pixels.** It is
an **output-FIFO underrun** (a blank/held band that drifts frame-to-frame) caused by a structural
line-fill rate deficit: the fill is pixel-limited at 1 px/clk through `pg_unpack` (~2200 cyc per
1920-px master line, measured), while one output row's budget is htotal ≈ 1650 cyc, and fetches are
serialized (one in flight). Confirmed bottleneck is the unpack, not DDR (`up_pvalid`=87% during the
fetch). Working dir `/home/justin/Dropbox/_PROJECTS/Schindler-2.0`, Zynq-7020, Vivado 2025.2.

**STEP 0 — confirm the scope fork before writing HDL.** Ask Justin one question: *is zoom-IN past
720-native required for this milestone, or is a 720 master sufficient (zoom deferred to G2)?*

- **If 720 is sufficient → do the cheap fix, not packed-beat.** Un-bypass the input scaler
  (`SCALER_MODULE=scaler_top`), store a 1280×720 master, set the read-engine back to
  `IN_W=1280 IN_H=720 STRIDE=3840` + matching `SLOT_STRIDE`, drop `READENGINE_FULLMASTER`. A 1280-px
  line fills in 1280 < 1650 → no deficit, no stall, no read-side gearbox. One build. Verify ≥3 cold
  boots clean on the **monitor** (not MS2109). Done.
- **If full-master zoom is required → build packed-beat fill** (rest of this prompt).

**STEP 1 — build a latency-modeling sim FIRST (mandatory gate; do not skip).** The current TB cannot
reproduce this bug — `pg_linefetch.v:90-92` says the long-HBLANK sim never overlaps a fill with a
read of the same row. Write a behavioral DataMover model that delivers 64-bit beats at a realistic
rate (≈1 beat/clk with occasional gaps) and drive the compositor from an htotal-bounded output row
clock so the fill (1920 px @ 1px/clk) races the row budget (1650). **Reproduce the underrun in sim
(`m_tvalid=0 & m_tready=1` mid-frame) before changing any RTL.** If you cannot make the stall appear
in sim, stop — you cannot prove the fix.

**STEP 2 — implement packed-beat fill.**
- Store raw 64-bit DataMover beats in the ring at 1 beat/clk, `ceil(IN_W·3/8)` beats per line
  (derive from `IN_W`/`STRIDE` params — NOT a literal 720). `pg_unpack` leaves the fill path.
- **Read side: even/odd beat banks (the highest-risk part).** A pixel straddles two 8-byte beats
  when `(3·rd_col) mod 8 ≥ 6` (i.e. `rd_col mod 8 ∈ {2,5}`). Store even/odd beats in separate banks
  (or true dual-port both-read) so beat `b` and `b+1` come back in ONE cycle; barrel-shift by
  `((3·rd_col) mod 8)·8` and take the low 24 bits. Preserve the single-cycle `rd_data` contract
  (`pg_linefetch.v:109`, consumed by `pg_compose` C0→C1 at `:151-171`). Byte order stays
  low-24-bits = `{R,B,G}` per `pg_unpack.v:8-10` — no swizzle. NN pick → no rounding.
- Keep the decimating DDA exactly where it is (read-time `src_col`/`src_row` pick). This fix is
  pure throughput; it must not change which pixel each output position selects.

**STEP 3 — prove it against the STEP-1 sim.** Require all of:
1. the modeled underrun is gone (no `mtv=0 & mtr=1` during active video, across ≥2 frames);
2. `rd_data`/`push_data` is bit-exact to the existing nearest-neighbor golden at 1:1 and at 1.5×;
3. **no read-rate stall at the straddle columns** (`rd_col mod 8 ∈ {2,5}`) — assert 1 px/clk holds
   there specifically;
4. timing closes (report WNS).

**STEP 4 — one bench build, verify on the MONITOR.** Engage via `uart_cmd.py "G 1280 720 0 0"`,
steady solid color AND grid (Osee input 1). Confirm the drifting band is gone across ≥3 cold boots.
Re-capture `tcl/capture_re_ila.tcl` + `python/bench/decode_re_ila.py` and confirm: no 600-cyc
residency stalls, no underrun, `push_en`-gated pixels clean.

**Do NOT:** reprogram or start a competing Vivado/xsct session while a build is running; `git
checkout` mid-build; trust an MS2109 capture for the visual verdict; or add the anti-alias box filter
in this change — that's a separate G2 step on top of a clean engine.
