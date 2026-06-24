# Projective front-end — numerator format fix FB 24 → 20

**Scope:** one foundational format change to the projective (keystone / corner-pin) warp front-end:
the numerator coefficient fractional bits **`FB` change from 24 to 20**, everywhere `FB` is used on the
projective path. **Sim + SW-compile + HDL-elaborate only** — no bitstream, no programming, no bench. The
**affine production build (`PROJECTIVE_BUILD` unset, FB=12, PROJECTIVE=0) is byte-for-byte unchanged.**

This resolves the inherited P1/P2 format gap flagged in
`docs/projective-p3p4-results.md` §"CW=32 numerator overflow at 1080p".

---

## The overflow (why FB=24 was wrong)

The a..f coeff GPIO **ports are `CW=32` signed** (fixed by P1/P2: the 6 coeff GPIOs are 32-bit each on
`axi_gpio_8/9/10`). The numerator coeffs are stored Q(CW−FB).FB:

- At **FB=24** the integer part is only **8 bits → signed range ±128 source-pixels.**
- The constant/translation coeffs `c` (= src_x at the output origin) and `f` (= src_y) are **source
  coordinates** — up to ~1920 px for a 1080p source, and **~320 px even for a centered identity**.
  `320 px · 2²⁴ = 5.37e9 > 2³¹ = 2.15e9` → **overflows signed-32**, so even identity (let alone any real
  keystone / corner-pin) wraps and warps to the **wrong source origin** on silicon.

The P1 "bit-exact @1280×720/1920×1080" proof was a pure-Python float-vs-fixed comparison (unbounded ints,
never truncated to 32), and the HDL faithful TB only ran at 64×48/96×72 (where coeffs fit signed-32), so
the overflow was never exercised in sim — golden, firmware, and HDL all *agreed on a wrapped value*.

## The fix (FB=20) — decision, already made

**FB = 20 (Q12.20).** Integer part is now **12 bits → signed range ±2048 source-pixels**, which covers the
full 1920-px source with margin. Measured `max|a..f_q|` over the strong-keystone / corner-pin cases at
1280×720/1920×1080 is **2^28.5** (`378,493,992`) — comfortably under `2³¹`.

**Precision cost (intended, acceptable):** worst-case sx/sy error of the fixed-point model vs the float
reference goes **Q.13 (1.2e-4 px) → Q.8.5 (≈2.7e-3 px ≈ 1/372 px)**. This worst case occurs ONLY at the
most-foreshortened corner of a strong keystone (sampled at (1275,714) in the sweep); it is **visually
lossless — well under one bilinear LSB** (the bilinear weight is 8-bit = 1/256 px granularity, and the
final coord int/frac split is unaffected).

Per-case worst error at FB=20 (1280×720 out / 1920×1080 src):

| case | worst \|err\| | ~Q | max\|a..f_q\| | signed-32 fit |
|------|-------------|----|-------------|---------------|
| keystone-H 0.35 | 2.689e-3 px | Q.8.5 | 378,493,992 (2^28.5) | ✅ |
| keystone-V 0.35 | 1.776e-3 px | Q.9.1 | 212,902,871 (2^27.7) | ✅ |
| keystone-HV 0.30 | 2.593e-3 px | Q.8.6 | 330,175,610 (2^28.3) | ✅ |
| cornerpin-skew | 1.879e-3 px | Q.9.1 | — | ✅ |
| cornerpin-strong | 2.028e-3 px | Q.8.9 | 311,217,356 (2^28.2) | ✅ |
| **WORST OVERALL** | **2.689e-3 px** | **Q.8.5** | **2^28.5** | **✅ all fit** |

**Not changed:** `GFB=36`/`GCW=40` for the perspective coeffs `m_g`/`m_h` (tiny values, never overflow);
the `PROJECTIVE` param; the reciprocal LUT/NR/RF params (RF=28, LUT_BITS=9, NR_ITERS=2); `CW` and the
coeff GPIOs (NOT widened); and the **affine build (FB=12)** — byte-for-byte untouched.

---

## What changed

| File | Change |
|------|--------|
| `tools/pg_projective_golden.py` | `FB = 24 → 20` (`ONE = 1<<FB` recomputes). Header + emit comments updated; `tune()` docstring notes it is precision-only (would pick 24) and FB=20 is the deliberate CW=32-driven override. Golden vectors/pixels re-emitted at FB=20. |
| `tcl/readengine_warp_bd.tcl` | `PROJECTIVE_BUILD` block: `CONFIG.FB {24} → {20}` on `pg_re_0`. Affine path (`PROJECTIVE_BUILD=0`) sets no FB override → unchanged. |
| `sw/phase-b/src/main.c` | `#ifdef PROJECTIVE_BUILD` only: `to_q24 → to_q20` (×2²⁴ → ×2²⁰); `warp_set_rotation` projective branch shift `<< 12` (Q.12→Q.24) → `<< 8` (Q.12→Q.20); coeff-writer param names `a24..f24 → a20..f20`; `q24_t → q20_t`; comments/printf labels updated. The affine `#else` direct-write block is untouched. |
| `hdl/pg_projective.v` | Header precision comment updated to FB=20 / 2.7e-3 px (no logic change — FB is a parameter set by the BD; affine build passes FB=12). |
| `sim/pg_warp_projective_faithful_tb.v` | TB localparam `FB 24 → 20` (faithful full-engine projective DUT). |
| `sim/pg_projective_tb.v` | Projective DUT (B) param `FB 24 → 20`. The affine-equivalence DUTs (A) stay `FB=12`. |

No HDL **logic** changed (FB is a BD-set parameter); `hdl/pg_affine.v` has **zero** diff.

---

## Re-validation (all at FB=20)

- **Golden precision/fit sweep:** worst-case **2.689e-3 px (Q.8.5)**; **all a..f_q < 2³¹** (max 2^28.5).
- **`sim/run_pg_projective.sh` (P1):** **PASS, all cases bit-exact** — affine-equivalence (identity, zoom2,
  shrink0.5, rot30, rot90, shift, + back-pressure) AND the 5 projective golden cases (affine-id, keyH, keyV,
  keyHV, corner) + back-pressure variants. `RESULT: PASS (all cases bit-exact)`.
- **`sim/run_warp_projective_faithful.sh` (P2 full engine):** **all 9 cases bit-err=0, 3072/3072 px** —
  affine-id, keystoneH, keystoneV, keystoneHV, cornerpin, each with back-pressure: **PASS**.
- **Firmware ELF, projective:** `WARP_ENGINE=1 PROJECTIVE_BUILD=1 OUTPUT_MODE=720p xsct
  tcl/build_phase_b_app.tcl` → **builds, no errors** (only pre-existing unused-symbol warnings). Q.20
  symbols present (`to_q20`, `warp_apply_homography`, `warp_solve_cornerpin`, `warp_set_keystone`, `to_q36`).
- **Firmware ELF, affine (regression):** `WARP_ENGINE=1 OUTPUT_MODE=720p xsct …` (no `PROJECTIVE_BUILD`) →
  **builds, no errors**. Affine codepath unchanged.

### Firmware ↔ golden cross-check (at Q.20)

For the golden's **keystone-H 0.20** source corners at **1920×1080**, the firmware `warp_solve_cornerpin`
8×8 DLT + floor-quantize produces **bit-identical** Q.20 a..f and Q.36 g,h to
`pg_projective_golden.py::quantize_coeffs`:

```
       a        b          c          d        e          f      g        h
GOLD  1208904  -280010  233538846   -1   1203339   22649241  -1  -19115293
FW    1208904  -280010  233538846   -1   1203339   22649241  -1  -19115293
```

All 8 coeffs match exactly. Note `c = 233,538,846 = 2^27.8` is now a **true positive value that fits
signed-32** — at the old FB=24 the same geometry produced `c = 3,736,621,547` which wrapped to the
negative `-558,345,749` (the P3P4 overflow demonstration). The fix is confirmed end-to-end.

---

## Affine build untouched — verified

- `hdl/pg_affine.v`: **0-line diff.**
- `tcl/readengine_warp_bd.tcl`: the FB override lives only inside `if {$PROJECTIVE_BUILD} { … }`; the
  affine pass runs zero projective commands.
- `sw/phase-b/src/main.c`: every diff hunk is inside an `#ifdef PROJECTIVE_BUILD` region; the affine
  `#else` direct GPIO-write block and the affine `warp_set_rotation` math are byte-identical.
- Affine firmware ELF rebuilds clean with no `-DPROJECTIVE_BUILD`.
- `pg_projective_tb.v` affine-equivalence DUTs stay `FB=12` and still match `pg_affine` bit-exact.
