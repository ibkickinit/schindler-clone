# Projective front-end — Phase P3 + P4(core) results (BD/XDC + firmware wiring)

**Scope:** P3 (BD + constraints) and P4-core (firmware coeffs + homography solver + UART) — the WIRING
that makes a projective bitstream buildable and drivable. **No bitstream build, no programming, no bench**
(that is P5, owned by the parent agent). All work is gated by a new `PROJECTIVE_BUILD=1` env flag; the
default (affine 10°-rotation) build is **byte-for-byte untouched**.

**Status: BD elaborates (projective config), firmware compiles to ELF (projective + affine), all P1/P2
sims still PASS bit-exact, and the firmware homography solver is cross-checked bit-identical to the
golden.** One inherited P1/P2 format gap surfaced and is flagged for P5 below (CW=32 numerator overflow at
1080p translation — NOT in scope to fix here).

---

## Files changed

| File | Change |
|------|--------|
| `tcl/readengine_warp_bd.tcl` | `PROJECTIVE_BUILD` env gate. When set: `CONFIG.PROJECTIVE {1} FB {24} GCW {40} GFB {36}` on `pg_re_0`; new `PROJ_GH` block builds the m_g/m_h GPIO path (PS `M_AXI_GP1` → new `axi_ic_lite2` → `axi_gpio_13/14` → slice+concat → `pg_re_0/m_g`,`/m_h`). When unset: affine, m_g/m_h left unconnected exactly as pre-P3 (byte-identical). |
| `constraints/zybo_z7_20_phase_b.xdc` | Added `set_false_path -quiet` for `*pg_re_0*/g1_reg[*]/D` and `*pg_re_0*/h1_reg[*]/D` (the new perspective-coeff GPIO→pclk CDC first stage). `-quiet` ⇒ harmless no-op in the affine build. |
| `tcl/build_phase_b_app.tcl` | `PROJECTIVE_BUILD` env gate adds `-DPROJECTIVE_BUILD=1` to the firmware compile (inside the existing `WARP_ENGINE` block). |
| `sw/phase-b/src/main.c` | `#ifdef PROJECTIVE_BUILD`: GH GPIO base defines, `warp_apply_homography()` (single coeff writer + g/h 40-bit packing), `warp_solve_cornerpin()` (8×8 DLT, mirrors the golden), `warp_set_keystone()`, `to_q24/to_q36/llround_floor`, UART `K`/`C` commands, help text. `warp_set_rotation` routes through `warp_apply_homography` at Q.24 (g=h=0) **only** under `PROJECTIVE_BUILD`; the affine path is the untouched `#else`. |

No HDL was changed. `hdl/pg_projective.v`, `hdl/pg_warp_engine.v`, `hdl/pg_warp_top.v` are exactly the
P1/P2 versions.

---

## g/h GPIO packing (firmware ↔ BD contract — MUST agree exactly)

`m_g` / `m_h` are signed **Q4.36 in a 40-bit word** (`GCW=40`, `GFB=36`). A 32-bit GPIO channel can't hold
40 bits, so each coeff is split **LOW 32 + HIGH 8** across two dual-channel GPIOs:

| GPIO | channel | reg offset | carries |
|------|---------|-----------|---------|
| `axi_gpio_13` | ch1 (`gpio_io_o`)  | `+0x00` | `m_g[31:0]` |
| `axi_gpio_13` | ch2 (`gpio2_io_o`) | `+0x08` | `m_h[31:0]` |
| `axi_gpio_14` | ch1 (`gpio_io_o`)  | `+0x00` | `{24'b0, m_g[39:32]}` (only bits [7:0] used) |
| `axi_gpio_14` | ch2 (`gpio2_io_o`) | `+0x08` | `{24'b0, m_h[39:32]}` (only bits [7:0] used) |

BD reassembly (`xlconcat`, `dout = {In1, In0}`):
`m_g = { axi_gpio_14.ch1[7:0], axi_gpio_13.ch1[31:0] }` (40 bits), `m_h` analogously.
Firmware writer is `gh_write40()` in `main.c` — it writes the four `Xil_Out32`s in exactly this layout.
Defaults = 0 ⇒ g=h=0 ⇒ w=1 ⇒ the engine boots to pure-affine (matches the firmware boot identity).

### Why a new AXI master path (axi_ic_lite2 on M_AXI_GP1)

The existing `axi_ic_lite` is a classic `axi_interconnect` at `NUM_MI=16` — **M00..M15 are all used** by the
affine warp build and the IP hard-caps at 16 master ports. There is no free slot for the g/h GPIOs there.
The projective build instead enables the Zynq PS's **second GP master `M_AXI_GP1`** (unused in the affine
design) and hangs a small 1→2 `axi_interconnect axi_ic_lite2` off it carrying `axi_gpio_13/14`. This leaves
`axi_ic_lite` and the entire affine build untouched. The two new GPIOs get `XPAR_AXI_GPIO_13/14_BASEADDR`
in `xparameters.h` regardless of which GP port they hang off, so the firmware addressing is unaffected.

---

## XDC false-path additions

```
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/g1_reg[*]/D}]
set_false_path -quiet -to [get_pins -hier -filter {NAME =~ *pg_re_0*/h1_reg[*]/D}]
```
Same GPIO(FCLK_CLK0)→pclk 2-FF ASYNC_REG capture-reg trap as the existing `a1..f1/lr1/dsel1/sr1` paths.
`g1`/`h1` are the first sync stage in `pg_warp_top`'s `m_g`/`m_h` CDC. `-quiet` keeps them harmless in the
affine build (the regs exist but the path is constant). 40 pins each.

---

## Coeff-write path (projective regime: FB=24 numerator / GFB=36 perspective)

ONE writer for ALL geometry — `warp_apply_homography(a..f Q8.24, g,h Q4.36, lead)`:
- a..f → `GEO_A/B/C` GPIOs (axi_gpio_8/9/10), **low 32 bits**, same registers as the affine build.
- g,h → `gh_write40()` (the packing above).
- Then the per-geometry LEAD + soft-reset pulse (`lead_cfg[31]`), identical to the affine flush sequence.

Rotation / zoom / pan are the affine sub-case (g=h=0): `warp_set_rotation` builds m_a..m_f as before, then
under `PROJECTIVE_BUILD` shifts them `<< 12` (Q.12 → Q.24) and calls `warp_apply_homography(..,0,0,lead)`.
The CPU does the float homography solve + fixed-point quantize once per geometry change (cheap, like the
gamma-curve compute).

---

## Homography solver + cross-check vs the golden

`warp_solve_cornerpin(sx[4], sy[4])` takes the 4 **SOURCE** corners that the 4 **OUTPUT raster** corners
map to (the engine inverse-maps output→source). It builds the same 8×8 DLT system as
`tools/pg_projective_golden.py::solve_homography` — identical row ordering
(`[ox oy 1 0 0 0 -ox·sx -oy·sx]=sx`, `[0 0 0 ox oy 1 -ox·sy -oy·sy]=sy`), Gaussian elimination with partial
pivoting, `i` normalized to 1 — then quantizes a..f→Q.24 (`floor`, matching the golden's `to_q`) and
g,h→Q.36 and writes via `warp_apply_homography`.

`warp_set_keystone(h, v)` derives the 4 source corners with the **same trapezoid formula** as the golden's
`keystone_homography` (mx,my=center; sw,sh=0.48·dim; TL/TR shrunk by `h` horizontally, left edge by `v`
vertically), then calls the cornerpin solver.

**Cross-check (decisive):** for the golden's `keystone-H 0.20` source corners at 1920×1080, the firmware
solver produced **bit-identical** quantized coeffs to `tools/pg_projective_golden.py::quantize_coeffs`:

```
       a          b      c            d   e          f          g    h
GOLD   12891616  -2985381  3736621547  0  12829672   362387865  -1  -12737624
FW     12891616  -2985381  -558345749  0  12829672   362387865  -1  -12737624
```

a,b,d,e,f,g,h are exactly equal. `c`: GOLD `3736621547` vs FW `-558345749` are the **same 32-bit word**
(`3736621547 − 2³² = −558345749`); the HDL takes the low 32 bits of `m_c` and sign-extends from bit 31, so
both feed the engine the identical bit pattern. The firmware solver is bit-exact to the sim's H. (This same
value is also the concrete demonstration of the CW=32 overflow flagged below.)

---

## UART command spec (mirrors the `W` style; both projective-only)

| Command | Meaning |
|---------|---------|
| `K <h> <v>` | **Keystone.** `h`,`v` = far-edge shrink in 1/1000 units (symmetric H/V trapezoid). `K 200 0` = 0.20 horizontal keystone, no vertical. `K` alone = query. |
| `C x0 y0 x1 y1 x2 y2 x3 y3` | **Corner-pin.** 8 ints = the 4 **SOURCE** corners (in source pixels) that the 4 **OUTPUT raster** corners map to, in **TL,TR,BR,BL** order (same quad order as the golden). e.g. identity-ish for a 1920×1080 source: `C 0 0 1919 0 1919 1079 0 1079`. Degenerate corners are rejected. |

`W` (rotation/zoom/pan) and `L` (lead override) keep working in the projective build (they now flow through
the Q.24 homography writer with g=h=0). Help text (`?`) lists `W`/`L` under `WARP_BUILD` and `K`/`C` under
`PROJECTIVE_BUILD`.

---

## Build / compile verification done here

- **HDL elaborate (projective):** `xelab pg_warp_top -generic_top PROJECTIVE=1 -generic_top FB=24` →
  snapshot built (`pg_projective_default` + `pg_warp_top(FB=24,PROJECTIVE=1)` compiled). The pre-existing
  `pf_cnt` index-bound warning is unrelated telemetry.
- **BD tcl:** `readengine_warp_bd.tcl` parses clean under both `PROJECTIVE_BUILD=0` and `=1` (the affine
  pass runs zero projective commands → byte-identical). slice/concat widths verified = 40 (32 low + 8 high).
- **Firmware ELF, projective:** `WARP_ENGINE=1 PROJECTIVE_BUILD=1 OUTPUT_MODE=720p xsct
  tcl/build_phase_b_app.tcl` → ELF built, no errors (only pre-existing unused-symbol warnings). All
  projective symbols present in the ELF (`warp_solve_cornerpin`, `warp_set_keystone`,
  `warp_apply_homography`, `gh_write40`, `to_q24`). *(Built against the on-disk affine XSA, which lacks
  `XPAR_AXI_GPIO_13/14`, so `gh_write40` compiled to a no-op there; the rest compiled fully. The real
  projective XSA from P5 will define those and the GH writes light up.)*
- **Firmware ELF, affine (regression):** `WARP_ENGINE=1 OUTPUT_MODE=720p xsct ...` → builds, no
  `-DPROJECTIVE_BUILD`, affine codepath unchanged.
- **P1/P2 sims:** `sim/run_warp_projective_faithful.sh` → all 9 cases PASS bit-exact (no HDL regression).
- **Solver cross-check:** firmware solver bit-identical to the golden (table above).

---

## ⚠️ Inherited P1/P2 format gap — CW=32 numerator overflow at 1080p (P5 must resolve, NOT a P3/P4 bug)

The a..f coeff GPIO **ports are 32 bits** (`CW=32`, fixed by P1/P2). At `FB=24` (Q8.24) the signed range is
**±128 source-pixels**. But the translation coeffs `c` (= src_x at the output origin) and `f` (= src_y) are
**hundreds of pixels at 1080p** (source center ≈ 960 px), so they **overflow signed-32** for essentially
every real 1080p geometry:

```
keystone-H 0.05 @1080p:  c ≈  84 px → fits (c_q 31 bits)
keystone-H 0.10 @1080p:  c ≈ 131 px → OVERFLOWS (c_q 32+ bits)
keystone-H 0.20 @1080p:  c ≈ 223 px → OVERFLOWS  (the cross-check value above)
keystone-H 0.35 @1080p:  c ≈ 361 px → OVERFLOWS
```

The P1 "bit-exact @1280×720/1920×1080" proof is a **pure-Python float-vs-fixed** comparison
(`eval_frame` uses unbounded ints, never truncates to 32). The **HDL** faithful TB ran only at
**64×48 / 96×72**, where coeffs fit signed-32 — so the overflow was never exercised in HDL sim. The firmware
faithfully writes the low-32 contract (and is bit-exact to the golden's low-32), so firmware + golden + HDL
all *agree* — they just agree on a **wrapped** `c`/`f` for aggressive 1080p translation, which would warp to
the wrong source origin on silicon.

**This is a P1/P2 numerator-format decision to revisit, NOT a P3/P4 wiring fix** (the coeff format is FIXED
for this phase). Options for whoever owns it: widen `CW` for a..f to ~40 bits (port + GPIO + a second
40-bit packing like g/h), or re-center the homography so `c`/`f` stay within ±128 px, or restrict the
projective bring-up to **720p** and/or **small keystone**. The slices/concat infra and the GPIO-packing
pattern from this task are directly reusable if `CW` is widened.

---

## → P5 build recipe (for the parent agent)

**Exact env vars (HDL bitstream):**
```
source /tools/Xilinx/2025.2/Vivado/settings64.sh
export BOARD_PARTS_REPO_PATHS=$HOME/fpga/vivado-boards/new/board_files
export DIGILENT_IP_REPO_PATH=$HOME/fpga/vivado-library/ip
WARP_ENGINE=1 PROJECTIVE_BUILD=1 OUTPUT_MODE=720p NO_ILA=1 \
  vivado -mode batch -nojournal -source tcl/build_phase_b.tcl
```
**Firmware ELF (after the XSA lands):**
```
source /tools/Xilinx/2025.2/Vitis/settings64.sh
WARP_ENGINE=1 PROJECTIVE_BUILD=1 OUTPUT_MODE=720p xsct tcl/build_phase_b_app.tcl
```
Recommend **720p** for first bring-up (keeps `c`/`f` smaller and avoids the worst of the CW=32 ceiling;
720p translation center ≈ 640 px still overflows for large keystone, so also start with **small** keystone,
see below).

**Resource / timing concerns (carried from P1/P2 + this work):**
- **Force the projective multiplies to DSP48.** The 4 output multiplies (`nx·iw`, `ny·iw` per `pg_projective`
  instance, ×2 instances) and the 4 NR `m·x` multiplies — `(* use_dsp = "yes" *)` / synth attr — or LUT
  multipliers will blow the WNS-critical cone. The 7020 has DSP headroom. The reciprocal is deeply pipelined
  (latency hidden by the prefetch lead; throughput stays 1 px/clk), so the exposure is the multipliers, not
  the divide. `RF` (28→24) is a free precision-margin timing knob if it closes short.
- **New CDC false-paths:** the two `g1`/`h1` paths added to the XDC (above). Without them the timer chases
  the unconstrained GPIO→g1/h1 route and wrecks the datapath placement (same failure mode that cost the
  `dsel1`/`sr1` paths real WNS).
- **WNS baseline:** the affine demand-fetch build closes at ≈ **+0.045 ns** @ 74.25 MHz on xc7z020-1 — razor
  thin. The projective additions land on/adjacent to the cache+coord cone. **Validate WNS empirically** with
  the timing-focused impl strategy the warp build already sets (ExtraTimingOpt place + Explore route +
  pre/post phys_opt) before committing the bitstream. The build already exports the post-phys_opt `.bit`
  (the stale-bit trap is handled in `build_phase_b.tcl`).
- **MMCM budget:** the projective build adds NO new clk_wiz (axi_ic_lite2 + the GPIOs are FCLK_CLK0). It
  does enable `M_AXI_GP1` (free PS resource). No MMCM impact.
- **Per-geometry LEAD:** keystone concentrates reads at the foreshortened edge; the firmware sets a deep
  lead (8192) for keystone/cornerpin. If the foreshortened edge underruns at 1080p, deepen `lead` (UART
  `L <n>`), don't change architecture — same character as the affine downscale lead.

**UART test sequence (after program):**
1. Boot → should show the affine boot identity (rotation path now flows through the Q.24 homography writer
   with g=h=0). Verify a clean passthrough/identity picture first.
2. `K 50 0` — small horizontal keystone (0.05 ⇒ `c` still fits signed-32 even at 1080p; the SAFE first
   test). Expect a gently keystoned (trapezoid) picture, no wedge.
3. `K 200 0` — 0.20 horizontal keystone. **Note:** at 1080p this OVERFLOWS CW=32 (see the gap above); at
   **720p** it is less severe but the translation center still risks overflow — watch for the image jumping
   to a wrong source origin (the CW=32 symptom) vs a clean stronger trapezoid. Capture and compare.
4. `C 0 0 1919 0 1919 1079 0 1079` — identity-ish corner-pin (sanity: should look ~unchanged).
   Then nudge a corner, e.g. `C 200 100 1700 50 1850 1000 100 1050`, to exercise a real 4-corner pin.
5. `W 0` — confirm rotation/zoom/pan still work (regression) and cancel the keystone.
6. **Verify on the bench MONITOR, not the MS2109** (per the standing MS2109 rule). If a "wrong origin /
   jump" artifact appears on strong keystone, it is most likely the CW=32 overflow, not a wiring bug —
   confirm against the safe `K 50 0` case which should be clean.

> Per the build-provenance + no-coin-flip rules: snapshot the projective XSA/ELF, record pass/fail per UART
> step in `docs/build-manifest.md`, and if the output coin-flips vsync phase or wedges, stop and root-cause
> (or fall back to `K 50 0` / 720p) rather than benching other features on a broken build.
