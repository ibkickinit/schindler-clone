# Read-Engine-B — Session Handoff / RESUME HERE

**Written 2026-06-02 mid-session.** Read this top-to-bottom before touching anything.
Companion to [`readengine-b.md`](readengine-b.md) (the as-built + diagnosis). This file is
the *exact live state* and the *next moves*.

---

## 0-NEW. CURRENT STATE (2026-06-02, packed-beat fix) — START HERE

Root cause is settled (ILA build #14 + two review rounds): **per-row fetch latency** — the output
consumer outruns a serialized 1-px/clk line fill (~IN_W=1920 cyc/line > htotal=1650 cyc/row), so
the prefetch falls behind, the consumer stalls mid-row on an in-flight fetch, and the output FIFO
underruns → drifting band. NOT dither aliasing (that theory, §9–§11 of readengine-b.md, was
overturned in §12). Full record: `readengine-b.md` §12–§14.

**FIX = packed-beat line fill (implemented, SIM-PROVEN, build #15 → bench):** `pg_linefetch.v`
rewritten to store raw 64-bit DataMover beats at 1 beat/clk (~720 cyc/line « 1650) in even/odd
beat banks; read-side extracts the pixel by byte address (`o=3*rd_col`, `b=o>>3`, `sub=o&7`; read
both banks, 128-bit `{hi,lo}` window, `window[sub*8 +: 24]` = `{R,B,G}`, NN). `pg_unpack` dropped;
`pg_compose`/`pg_read_engine_top` carry 64-bit beats (`beat_data/valid/ready/last`). DDA +
residency unchanged. Sim gates: `sim/pg_latency_tb.v` (reproduces underrun on old RTL, GONE on new
— 3072/3072 starv=0) and `pg_read_engine_top_tb` golden `errors=0` incl. straddle cols.

**Bench-capable steps (in progress):** build #15 (Vivado) → full-master ELF (`READENGINE_FULLMASTER`)
→ `xsct tcl/program_phase_b_full.tcl`. Then verify on MONITOR (grid + solid, ≥3 cold boots); the
192-bit ILA is retained → re-capture (`tcl/capture_re_ila.tcl` + `python/bench/decode_re_ila.py`)
to confirm `starv=0` / no residency stalls. Stale standalone TBs (`pg_compose_tb`,
`pg_linefetch_tb`) predate the beat interface — refresh for hygiene (not a gate).

---

## 0. (prior) post-ILA-aliasing state — superseded by §0-NEW above

The long shear/ghost hunt is **resolved at the level of the read-engine logic**: an ILA capture
on silicon (**build #13**, both `ila_re_dbg` + `ila_re_beats` cores) PROVED the engine is
correct — `src_col` is a perfect decimating DDA, `src_row` steps right, `rd_data`/`up_pdata` are
bit-clean (only the source's true values). So addressing and data are NOT the problem. The grid
artifact is **nearest-neighbor decimation aliasing** (the full-master path bypassed the input
scaler's anti-alias boxcar). Builds #8–#11 chased wrong theories (shear/depth/rate/collision) —
all disproven; kept only as trail in `readengine-b.md` §4–§8. **The live truth + 4-agent fix
consensus + open questions are `readengine-b.md` §9–§11.**

**THE ONE BLOCKING OPEN QUESTION (do this first):** Justin showed that **truly flat color fields
(green/red/orange) all show the SAME fine pattern** — which pure aliasing does NOT predict, and
which the ILA-on-grid couldn't test (it only saw flat *black*, which is clean). Resolve before
any fix — `readengine-b.md` §11 Q1 has the decisive cheap tests:
  - **Test 1 (seconds):** flat color, toggle engine `G 0` (MM2S 1:1 crop) vs `G 1280 720 0 0`
    (engine). Pattern follows engine → it's engine/dither-aliasing; pattern with engine OFF too →
    it's display/camera (backlight bands + LCD-vs-camera moiré), engine exonerated.
  - **Test 2:** capture `ila_re_dbg` on a flat COLOR (board still has the #13 ILA;
    `tcl/capture_re_ila.tcl` works) — `rd_data` constant → engine clean on flat color; `rd_data`
    fine-varying → source dither (check `up_pdata`) being aliased.
Leading hypothesis: the laptop **dithers** solid colors; black needs none (ILA clean) but
mid-tones carry dither the NN decimation aliases. NOT yet confirmed.

**THE FIX (once Q1 + the scope question resolve), per 4-agent consensus:** un-bypass the input
scaler (`SCALER_MODULE=scaler_top`) so DDR holds a pre-filtered 1280×720 master and the
read-engine does size/position/matte on it — **exactly build #7, which was bench-clean.** Trades
away zoom-*in* past 720 native (that's G2, not G1). Full detail + golden-model spec for the
eventual G2 read-path box filter: `readengine-b.md` §10.

## 1b. Build/HDL state (builds #10→#13)

Uncommitted working-tree HDL (last commit `5407677` = build #9): `pg_linefetch.v` (NBUF ring +
read-select excludes in-flight `fill_buf`), `pg_compose.v` (`LOOKAHEAD=(NBUF>=3)?NBUF-3:0` +
`dbg_*` taps), `pg_read_engine_top.v` (`NBUF=5`, 96-bit `dbg_probe`), `tcl/readengine_b_bd.tcl`
(2 ILA cores), `sw/phase-b/src/main.c` (MM2S crop for clean engine=0 passthrough), new
`tcl/capture_re_ila.tcl`, `/tmp/decode_dbg.py`. **Build #13 (ILA) is the one on the board now**
(bit 12:34, ELF 12:38, programmed; engine boot-engaged; Osee was on input 1 = grid). None of this
is committed — commit only after the artifact is actually resolved + 3-boot verified.

## 1. EXACT live state (as of this writing — pre-#11; see §1b for the update)

- **Branch:** `readengine-b-integration`. **Last commit:** `5407677` (= build #9, burst/FIFO —
  did NOT fix shear).
- **Uncommitted working-tree changes** (these ARE build #10's content — NOT yet committed):
  - `hdl/pg_linefetch.v` — rewritten to `NBUF`-deep ring (default 4)
  - `hdl/pg_compose.v` — `NBUF` param + deepened lookahead + pass-through to linefetch
  - `hdl/pg_read_engine_top.v` — `NBUF` param (default 4) threaded to `pg_compose`
  - `docs/readengine-b.md` (new), `docs/readengine-b-SESSION-HANDOFF.md` (new, this file)
  - `python/bench/uart_cmd.py` (new tool)
- **Build #10 RUNNING:** `make build` (Vivado), log `/tmp/build10.log`, started synth 08:20.
  Background task id was `blh35clbu`. On-disk bitstream is **still old build #9** (`05:25`) —
  do not program until the log shows `write_bitstream` complete and the `.bit` mtime updates.
- **Board:** currently has **build #8 or #9** (full-master, shears). Firmware is alive
  (`uart_cmd.py "i"` returns DIAG `h_in=1920 v_in=1080`). Engine was last set to a `960×540`
  window via my discriminator (`G 960 540 0 0`).
- **Daemon `schindlerd` is RUNNING** and **owns `/dev/ttyUSB1`** (restarted it after the
  discriminator). To send UART you must stop it first (see §4).
- **Task #89** ("Adjustable scaler G1: runtime size HDL") is the umbrella task, `in_progress`.

## 2. What to do the moment build #10 finishes

```
cd /home/justin/Dropbox/_PROJECTS/Schindler-2.0
# 1. confirm it built + met timing
grep -E "write_bitstream|All user specified timing constraints are met|Timing constraints are NOT met|BUILD10_EXIT" /tmp/build10.log | tail
ls -la --time-style=+%H:%M build/vitis-phase-b/phase_b_pf/hw/phase_b.bit   # mtime must be new

# 2. rebuild the full-master ELF against the new hw platform (firmware unchanged, but relink)
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
source /tools/Xilinx/2025.2/Vitis/settings64.sh
READENGINE_FULLMASTER=1 make build-app          # -> vdma_init.elf

# 3. program
xsct tcl/program_phase_b_full.tcl               # log to a real path you can read

# 4. confirm Osee on input 1 (static SMPTE/grid), then run the experiment in §3
python3 python/bench/osee_switch.py 1
```
NOTE: `make build-app` and program both need a healthy Vitis platform export; if `build-app`
races a just-finished `write_hw_platform`, re-run it once.

## 3. THE EXPERIMENT (the point of build #10)

Engine boots engaged at **1280×720** (full window). Then drop to **960×540** via UART.
Observe the **monitor** (NOT capture stick, NOT frame-dump — see §6).

| Window | How | Predicted (if model correct) | Meaning |
|---|---|---|---|
| 1280×720 | boot default | **still wobbles** | rate-bound → need §5 packed-beat fill |
| 960×540 | `uart_cmd.py "G 960 540 0 0"` | **clean** | latency was the only issue there; `NBUF=4` fixed it |

**Decision tree:**
- **960 clean + 1280 wobbles** → model confirmed. Build the **packed-beat fill (§5)**. After
  that, both windows should be clean.
- **Both clean** → 🎉 rate model was over-conservative (maybe effective fetch < 1 px/clk worst
  case, or htotal margin). Skip §5. Run the 3-boot rule, then proceed to commit + catalog v0.3.0.
- **Both still wobble** → `NBUF=4` didn't take effect (check it's really build #10 on the board:
  `grep FIFO_DEPTH hdl/pg_compose.v` shows the source; confirm `.bit` mtime + reprogram), OR the
  wobble has a third cause. Re-open with an ILA on `pg_re_0/m_axis` + the DataMover data stream
  (there is already an `ila_s2mm_axi` core in the BD; add one on the read path).
- **960 wobbles too** → it's not (only) rate; suspect per-fetch command latency/overhead or a
  `pg_linefetch` ring bug. Bump `NBUF` (6/8) as a quick test, else ILA.

Always re-verify with ≥3 cold reboots before calling anything ✅ (no-coin-flip rule).

## 4. UART / daemon dance (the port is owned)

```
fuser /dev/ttyUSB1                      # shows the daemon pid
kill <pid>                              # stop daemon, frees port
/tmp/schindlerd-venv/bin/python python/bench/uart_cmd.py "i"             # firmware info+DIAG
/tmp/schindlerd-venv/bin/python python/bench/uart_cmd.py "G 960 540 0 0" # window: w h x y
/tmp/schindlerd-venv/bin/python python/bench/uart_cmd.py "G 0"           # disengage (passthrough)
# restart daemon when done:
nohup /tmp/schindlerd-venv/bin/python control-plane/schindlerd/schindlerd.py -v >/tmp/schindlerd.log 2>&1 &
```
- Use the **daemon venv python** (`/tmp/schindlerd-venv/bin/python`) — it has pyserial; system
  `python3` does not.
- Firmware also speaks JSON-RPC via `J {...}` (that's what the daemon uses); geometry `G` is the
  simple text parser, not exposed as a daemon RPC — hence the raw-serial tool.
- `i` output legend: `DIAG: h_in/v_in` = detected input (1920/1080 = full master good),
  `S2MM_SR/MM2S_SR` status, `src/out` ≈ source/output Hz.

## 5. Packed-beat fill — the rate fix (designed, ready to implement)

**Goal:** fill the line buffer at **1 beat/clk** (≈720 clk/line) instead of 1 px/clk (1920
clk/line), giving ~2.4× rate margin so the full 1280×720 window fits the frame budget.

**Plan (sim-verify before synth):**
1. `pg_linefetch.v`: change the backing store to **64-bit beats** (`mem64[NBUF][~720]`). Fill
   port takes `s_dm_tdata[63:0]` + `tvalid` + `tlast`, one beat/clk (`s_dm_tready` = ring has
   room). `fetch_len` becomes **beats** = `ceil(IN_W*3/8)`.
   - **Read path:** given `rd_col`, byte offset `o = 3*rd_col`; beat `b = o>>3`, `s = o & 7`.
     Read beat `b` and `b+1` (dual-port BRAM or two registered reads), then byte-mux 3 bytes
     starting at lane `s`. Memory order is `[G,B,R]`; assemble AXIS pixel `{R,B,G}` =
     `{byte[o+2], byte[o], byte[o+1]}` → tdata[23:16]=R, [15:8]=B, [7:0]=G. **Verify byte order
     against `pg_unpack`'s "low 24 bits, no swizzle" comment** (`schindler_pipeline_rbg_byte_order`).
   - Keep `rd_resident` / tag / round-robin ring logic identical (depth fix stays).
2. `pg_read_engine_top.v`: **remove `pg_unpack`**; wire DataMover `M_AXIS_MM2S` (64b) straight
   into `pg_compose`'s fetch port. Command formatter unchanged (BTT = `IN_W*3` bytes = 5760).
   `pg_compose`'s `fetch_pdata`/port widens 24→64; `fetch_pvalid`→beat valid, `fetch_last`→last
   beat.
3. **TBs:** `pg_compose_tb` + `pg_read_engine_top_tb` DataMover models must emit **64-bit beats**
   packed `[G,B,R]` from the `pix()` golden, and the checker stays pixel-domain. Add an adversarial
   model (initial command latency + a long stall every Nth fetch) and confirm fail@`NBUF=2` /
   pass@`NBUF=4` to prove depth, and that the rate now fits at the full window.
4. Risk: byte-straddle + `[G,B,R]` order. A bug shows as a constant horizontal shift or a
   per-pixel color swap. Catch it in sim, not on the bench.

**Smaller alternative if packed-beat is too risky:** run the fill/unpack/linefetch in a 2×
pixel-clock domain (148.5 MHz) with a CDC on the ring read — fills 1920 px in ~960 pixel-clks <
1650. More clocking/CDC complexity; packed-beat is cleaner and preferred.

## 6. Hard-won gotchas (do not relearn these)

- **VERIFY ON THE MONITOR.** MS2109 capture stick has its own framebuffer and hides vertical
  wrap/offset; the firmware **frame-dump reads DDR through the PS cache** and returns stale data
  (saw all 5 slots identical/colorless while the monitor showed real, changing content).
  `schindler_ms2109_verification_trap`.
- **Build needs both env vars** (`BOARD_PARTS_REPO_PATHS`, `DIGILENT_IP_REPO_PATH`) or it aborts
  instantly at the board-file check. Lost one build to this.
- **`make sim-pg` wrapper is broken** — it mis-reports an xsim exit code and aborts after the
  genlock TB. The TBs themselves pass; run `pg_compose_tb` / `pg_read_engine_top_tb` **directly**
  (commands in `readengine-b.md` §7) and check `Total errors = 0`.
- **Bash compound commands that START with `pkill ...; ...`** keep tripping the tool wrapper
  (the failing pkill aborts the rest). Run `pkill` as its **own** command, then the real command
  separately / in background.
- **`prog9.log` vanished** once and a program task reported "failed" while xsct was actually
  running — confirm board state empirically (UART `i`, `.bit` mtime), don't trust the wrapper
  exit code.
- **Daemon owns `/dev/ttyUSB1`** — stop it before raw serial (§4).
- **Never `git checkout` / start a competing Vivado build** while a build runs.
- **Genlock ring is sacred:** S2MM + MM2S stay full-raster + matched; geometry never touches it
  (`64aabe6` reframe blacked out HDMI). `schindler_genlock_geometry_must_match`.

## 7. When the engine is proven clean (post-fix)

1. ≥3 cold-boot verification (no-coin-flip).
2. `git add -A && git commit` the `NBUF` ring (+ packed-beat if built). Update `docs/build-manifest.md`
   with the build entry (params, timing WNS/WHS, pass/fail/why).
3. Catalog **v0.3.0**: add `hdmi.size_h/v`, `pos_x/y`, `matte_rgb` (per
   `adjustable-scaler-design.md` §Control-plane). Wire firmware knobs → `re_write_geometry()`.
4. UI sliders for geometry (deferred until bench-proven).
5. Then G2 (crop/zoom/pan/aspect), then Phase-G-gated dual-output (2nd present_geom + 480i).

## 8. Key files & symbols (orientation for a new agent)
- HDL: `hdl/pg_{addrgen,genlock,linefetch,unpack,compose,read_engine_top}.v`, `hdl/axis_mux2.v`
- BD: `tcl/readengine_b_bd.tcl` (DataMover, smartconnect HP1, mux reroute via `delete_bd_objs`,
  GPIO 8/9/10, `s2mm_frame_ptr_out→pg_re_0/frame_ptr`)
- Build: `tcl/build_phase_b.tcl` (HDL add_files + sources the BD tcl; `SCALER_MODULE` default
  `scaler_bypass_1080p`), `tcl/build_phase_b_app.tcl` (`READENGINE_FULLMASTER`), program:
  `tcl/program_phase_b_full.tcl`
- Firmware: `sw/phase-b/src/main.c` — `re_write_geometry()` (DDA steps→GPIO), `G`/`J` UART
  parsers, boot-engage block under `READENGINE_FULLMASTER`
- Constraints: `constraints/zybo_z7_20_phase_b.xdc` (hier false-paths `*/g_q1_reg[*]/D`,
  `*/fp_q1_reg[*]/D`, `*/sel_q1_reg/D`)
- Tools: `python/bench/osee_switch.py`, `python/bench/uart_cmd.py`
- Memory: `schindler_readengine_b_state`, `schindler_genlock_geometry_must_match`,
  `schindler_ms2109_verification_trap`, `schindler_pipeline_rbg_byte_order`,
  `schindler_no_coin_flip_rule`, `schindler_build_provenance_rule`
