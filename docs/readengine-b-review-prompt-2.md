# Independent review prompt #2 — read-engine-B root cause (round 2)

(Paste to a fresh agent. Adversarial: verify or REFUTE the mechanism AND the proposed fix.)

---

You previously (or another reviewer) overturned a "dither-aliasing" diagnosis of a route-B
read-engine artifact and pointed to a prefetch/residency coherency stall. The engineer then added
a 192-bit prefetch-state ILA probe (build #14), captured on a steady solid-red source with the
engine engaged, and now claims a specific mechanism + fix. **Verify both from scratch — re-derive
from the HDL and the captured data; do not trust the prose.** Working dir:
`/home/justin/Dropbox/_PROJECTS/Schindler-2.0`. Zynq-7020, Vivado 2025.2.

The engineer's CLAIM (to confirm or refute):
1. **Mechanism = per-row fetch latency.** The output consumer outruns the line fetch. The line
   fill is 1 px/clk through `pg_unpack` (~IN_W=1920 cycles per master line); one output row's
   budget is `htotal`≈1650 cycles; fetches are serialized (one in flight). So the prefetch loses
   ~270 cyc/row, the NBUF ring only delays the catch-up, and the consumer stalls mid-row waiting
   for an in-flight fetch — the wanted row (`rd_row=376`) goes resident *exactly* when `m3_busy`
   goes 1→0 (recovery edge s1871), causing a 622-cyc stall and a 563-cyc output underrun (the
   visible drifting band). Lap and V-DDA divergence are claimed RULED OUT.
2. **Fix = packed-beat line fill.** Store raw 64-bit DataMover beats in the ring at 1 beat/clk
   (~`ceil(IN_W·3/8)` = 720 cyc/line for IN_W=1920), extract the 24-bit pixel on the READ side by
   byte address (drop `pg_unpack` from the fill path; a pixel may straddle 2 beats). Then
   720 « 1650, so the fetch outpaces the drain and the stall/underrun cannot occur.

DO THIS:

1. **Re-derive the mechanism from the data.** Read `python/bench/decode_re_ila.py` and run it on
   the capture: `python3 python/bench/decode_re_ila.py /tmp/ila_dbg.csv` (if absent, the bench has
   ILA build #14 loaded; re-capture with `tcl/capture_re_ila.tcl` on a steady solid color, engine
   engaged via `python/bench/uart_cmd.py "G 1280 720 0 0"` — but do NOT reprogram/compete with a
   running build). The 192-bit `dbg_probe` layout is in `hdl/pg_read_engine_top.v`. Verify the
   recovery-edge claim (row resident the cycle `m3_busy` drops) and that lap (`fill_sel`==`rd_sel`
   overwrite) and divergence (`pf_src`≠`rd_row` for the same window-row, i.e. a never-fetched row)
   are genuinely absent — or show they are not.

2. **Check the rate arithmetic and the serialization claim in the HDL.** Read `hdl/pg_unpack.v`
   (is fill really 1 px/clk?), `hdl/pg_linefetch.v` (is the fetch FSM single-in-flight S_IDLE↔
   S_FILL? does it fill at 1 px/clk via `fetch_pvalid`?), `hdl/pg_compose.v` prefetch scheduler
   (`do_pf = ... && !m3_busy && ...` — does this serialize fetches? can the prefetch ever get >1
   fetch ahead? is `LOOKAHEAD=NBUF-3` actually reachable given serialization?). Confirm or refute:
   per-line fill ≈ IN_W cycles, > htotal, sustained deficit not closable by depth.

3. **Is the bottleneck really the 1-px/clk unpack, or something else?** Could the dominant latency
   instead be DataMover command turnaround / DDR arbitration / 4 KB-boundary beat gaps (HP1 shared
   with S2MM + VDMA-MM2S)? If so, packed-beat fill (which only speeds the unpack side) might not
   fully close it. Estimate the real per-line fetch time including those, vs 1650.

4. **Critique the packed-beat fix.** (a) Does 720 beats + realistic DDR latency still fit < 1650?
   (b) Read-side 2-beat straddle extraction: is byte order `[G,B,R]`→`{R,B,G}` and rounding
   correct; does it add read-side latency that breaks `pg_compose`'s single-cycle `rd_data`
   assumption? (c) Is there a simpler/safer fix — e.g. allow multiple DataMover commands in flight
   (pipeline fetches) instead of changing the buffer format; or un-bypass the input scaler so the
   read-engine works on a pre-filtered 720 master at ~1:1 (build #7 was clean) — which avoids the
   heavy 1920-wide per-line fetch entirely? Weigh these against packed-beat.

5. **Confirm the "720" is not a hidden hard-coding.** The fix's ~720 is `ceil(IN_W·3/8)` (beats in
   a 1920-px line), NOT the 720p output res. Verify nothing in the proposed change hard-relies on
   720p and that it scales with IN_W / output geometry.

6. **Verdict.** For the mechanism and the fix: AGREE / DISAGREE / UNSURE with specific file:line or
   captured-sample evidence. End with: is this sound enough to build the packed-beat fill, is a
   different fix better, or is there still a gap to close first?

Be concrete and skeptical; cite code and the captured numbers.
