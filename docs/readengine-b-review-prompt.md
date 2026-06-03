# Independent review prompt — read-engine-B aliasing diagnosis

(Paste to a fresh agent. It is deliberately adversarial: verify or REFUTE, do not rubber-stamp.)

---

You are an independent FPGA/video reviewer. Another engineer diagnosed a long-running artifact in
the "route-B read-engine" on a Xilinx Zynq-7020 (Vivado 2025.2) and proposed a fix. **Your job is
to verify their analysis FROM SCRATCH and try to break it** — re-derive the conclusion yourself
from the source and the captured evidence; do not assume their write-up is correct. Working dir:
`/home/justin/Dropbox/_PROJECTS/Schindler-2.0`.

Their conclusion (the thing you must independently confirm or refute): *the on-screen artifact is
nearest-neighbor decimation aliasing of high-frequency source content (GPU/panel dither + thin
lines); the read-engine itself is correct (addressing + data + transport); the decimation happens
AFTER the DDR read (the full master line is buffered, the DDA then picks a subset at read-out); the
proposed fix is a box-average anti-alias filter applied at the read (average the buffered span per
output pixel), preserving the full master.*

DO THIS:

1. **Read the HDL yourself** (in full): `hdl/pg_addrgen.v`, `hdl/pg_linefetch.v`, `hdl/pg_unpack.v`,
   `hdl/pg_compose.v`, `hdl/pg_read_engine_top.v`, `hdl/axis_mux2.v`, and `hdl/scaler_h.v` +
   `hdl/scaler_v.v` (the existing boxcar scalers). Independently establish: does the read-engine
   actually do nearest-neighbor pick with no low-pass? Is the DataMover read full-line (no
   decimation) with the decimation occurring at the buffer read-out (the DDA `src_col` selection)?
   Confirm or correct the "decimation is after the read" claim from the code.

2. **Inspect the captured ILA data yourself.** `/tmp/ila_dbg.csv` is a live capture of the 96-bit
   `dbg_probe` (bit layout in `hdl/pg_read_engine_top.v`); `/tmp/decode_dbg.py` decodes it — read
   the decoder, run it (`python3 /tmp/decode_dbg.py`), and judge the raw numbers for yourself. Does
   `src_col` actually march `floor(col·1.5)` with no anomaly? Are `rd_data` and `up_pdata` really
   dithered identically (supporting "dither is in the source, faithfully transported")? Could the
   data instead show an addressing or transport defect the other engineer missed? (Note: the CSV on
   disk may be the engine-OFF / solid-red capture; the bench board has the ILA build #13 — you may
   re-capture with `tcl/capture_re_ila.tcl` if the board is up, but do NOT reprogram or start a
   competing Vivado/xsct build, and never `git checkout` mid-build.)

3. **Stress-test the root-cause logic.** Is nearest-neighbor decimation of dithered/thin-line
   content a sufficient and necessary explanation for: (a) the artifact appearing only since
   720→1080 master (1:1 build #7 was clean), (b) it being rate-independent across window sizes,
   (c) it following the engine on/off toggle, (d) flat black being clean in the ILA but flat colors
   not? List anything that does NOT fit, and any alternative root cause not ruled out. The
   write-up's "ruled out" list (rate, depth, read-during-write collision, stride, display/camera,
   engine fabrication) — spot-check at least two against the code/data.

4. **Critique the proposed fix.** Read `docs/readengine-b-issue-and-proposal.md` §4 and
   `docs/readengine-b.md` §10. Evaluate the read-path box filter: is averaging the buffered span at
   the read actually feasible given `pg_linefetch`'s read port structure (single registered read of
   one `mem[{sel,col}]` — can it read 2 columns and 2 rows per output pixel without halving
   throughput? what changes are truly required)? Is a 2-tap box sufficient for 1.5×, and what about
   heavier shrink? Is the byte-order/rounding/edge handling in the golden-model spec correct? Is the
   cheaper alternative (un-bypass input scaler → pre-filtered 720 master = build #7) actually
   better for the stated goal, or does it wrongly discard the full master? Flag the highest-risk
   way the proposed fix would pass sim but fail on hardware.

5. **Verdict.** For each major claim (root cause, "decimation after read", each ruled-out
   alternative, the fix feasibility) state AGREE / DISAGREE / UNSURE with the specific file:line or
   data that supports your call. End with: is the diagnosis sound enough to build the fix, or is
   there a gap that must be closed first?

Be concrete and skeptical. Cite code and captured numbers, not the existing prose. If you think
the diagnosis is wrong, say exactly where and why.
