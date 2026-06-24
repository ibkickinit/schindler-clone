#!/usr/bin/env python3
# pg_projective_golden.py — bit-exact fixed-point reference model for the projective
# (homography / keystone / corner-pin) address generator pg_projective.v (Phase P1).
#
# Mirrors the HDL EXACTLY (no float divide anywhere in the model path):
#   - 3 incremental DDAs nx, ny, w  (signed Q(CW-FB).FB, CW=32, FB=12)
#   - per-pixel reciprocal iw = 1/w via  LUT seed (top bits of normalized w) + Newton-Raphson
#   - two products  sx = nx*iw,  sy = ny*iw   -> split int (src_col/row) + frac (Q.FB)
#
# Reciprocal algorithm (the part that must match the Verilog bit-for-bit):
#   w is Q20.12 and the firmware guarantees w>0 across the frame (convex in-front quad).
#   1. Normalize: find the bit position of the MSB of w, shift w left so it lands in
#      [1.0, 2.0) in a fixed RF (reciprocal-format) with RF fractional bits:  m = w * 2^-e,
#      m in [2^(RF), 2^(RF+1)).  Reciprocal of the shifted value, then shift the result back.
#   2. Seed:  x0 = LUT[ top LUT_BITS of mantissa ]  ~ 1/m   in RF format.
#   3. Newton-Raphson:  x_{k+1} = x_k * (2 - m*x_k)   (NR_ITERS steps), all in RF fixed point.
#   4. De-normalize: iw = x_final shifted by the normalization exponent back to Q.FB-ish RF.
#   5. Products nx*iw, ny*iw are taken in RF then rounded back to Q.FB.
#
# This file ALSO budgets precision: it sweeps keystone + 4-corner-pin homographies and reports
# worst-case sx/sy error of the fixed-point model vs a float reference, tuning LUT_BITS / NR_ITERS
# / widths until >=12 fractional bits (Q.12) sub-pixel accuracy at the most-foreshortened edge.
#
# Emits golden vectors (src_col, src_row, h_frac, v_frac, in_window) for the testbench.
#
# Pure stdlib (no numpy on this host).

import math, sys, argparse

# ---------------- fixed Q-format (CHOSEN by the precision sweep — see tune()) ----------------
# Two error sources, both AMPLIFIED by 1/w (~1.6x) at the most-foreshortened edge of a 1280-wide
# output, so both coeff families need MORE fractional bits than the affine engine's Q.12:
#   * numerator coeffs a..f -> FB = 24  (Q8.24 in a CW=32 word; affine-compat note below)
#   * perspective coeffs g,h -> GFB = 36 (tiny values, need a wide mantissa; GCW=40 word)
# Reciprocal LUT+NR adds negligible error at RF=28 / LUT_BITS=9 / NR_ITERS=2.
# Achieved worst-case sx/sy error over keystone+corner-pin @1280x720/1920x1080 = 1.2e-4 px (Q.13.0).
#
# AFFINE COMPATIBILITY: with FB=12 + g=h=0 the engine is byte-for-byte pg_affine. The projective
# build runs FB=24 (the firmware homography solver emits Q.24 a..f). The HDL parameterizes FB so the
# affine production build keeps FB=12 (port + GPIO unchanged); only the projective build pays Q.24.
CW  = 32                # numerator coeff / accumulator word width (a..f)
FB  = 24                # numerator fractional bits (Q8.24 projective; 12 for affine-compat build)
ONE = 1 << FB

GCW = 40                # perspective coeff word width (g,h)
GFB = 36                # perspective-coeff fractional bits
WONE = 1 << GFB         # i = 1.0 for the w accumulator / denominator
WW  = 48                # w accumulator width (w in [~0.3,2] in Q.36 -> ~38 bits + headroom)
AW  = 44                # numerator accumulator width (|nx| up to ~source-coord*2^FB)

# ---------------- reciprocal-format (internal to the divide) ----------------
RF        = 28     # reciprocal datapath fractional bits
LUT_BITS  = 9      # index bits into the seed LUT (top bits of mantissa after the leading 1)
NR_ITERS  = 2      # Newton-Raphson iterations
PW        = 64     # product width (nx_q[~36b] * iw[~RF+1 b]) -> ~64; guard only (Python unbounded)

def to_q(v):
    """float -> signed Q.FB int (truncate toward -inf via floor, like >>> on two's complement)."""
    return int(math.floor(v * ONE))

def to_qg(v):
    """float -> signed Q.GFB int (for g,h coeffs)."""
    return int(math.floor(v * WONE))

def sgn_extend(x, bits):
    m = 1 << (bits - 1)
    return (x ^ m) - m

# ---------------- LUT seed table (built once, in fixed point) ----------------
# Index = top LUT_BITS bits of the mantissa m where m in [1,2) represented with RF frac bits.
# The leading 1 is implicit; index spans the fractional [0,1) range. Seed ~ 1/m in RF format.
def build_seed_lut(lut_bits=LUT_BITS, rf=RF):
    n = 1 << lut_bits
    lut = []
    for i in range(n):
        # mantissa at the CENTER of the bin gives the smallest worst-case seed error
        frac = (i + 0.5) / n           # in [0,1)
        m = 1.0 + frac                 # in [1,2)
        recip = 1.0 / m                # in (0.5, 1]
        lut.append(int(round(recip * (1 << rf))))
    return lut

SEED_LUT = build_seed_lut()

# ---------------- the bit-exact reciprocal ----------------
def reciprocal_fixed(w_q, lut=None, lut_bits=None, rf=None, nr_iters=None, eps_q=None):
    """
    w_q : signed Q.GFB int (the denominator accumulator value, w_true*2^GFB).
    Returns (iw, valid):
       iw    : (1/w_true) scaled by 2^RF.
       valid : False if w <= eps (clamp to matte).
    Implementation mirrors the HDL integer ops exactly.
    NOTE: params default to the MODULE GLOBALS read at CALL time (so the tuning sweep that
    reassigns RF/LUT_BITS/NR_ITERS/SEED_LUT takes effect — default args would bind at def-time).
    """
    if lut is None:      lut = SEED_LUT
    if lut_bits is None: lut_bits = LUT_BITS
    if rf is None:       rf = RF
    if nr_iters is None: nr_iters = NR_ITERS
    if eps_q is None:
        eps_q = WONE >> 6   # epsilon ~ 1/64 in w_true; w<=eps -> matte (horizon/div-by-zero guard)
    if w_q <= eps_q:
        return 0, False

    # ---- 1. normalize w into mantissa m in [1,2) with RF frac bits ----
    # Find MSB position of w_q (w_q>0 here). We want m = w_q << s such that m has its
    # leading 1 at bit (rf).  i.e. m in [2^rf, 2^(rf+1)).
    msb = w_q.bit_length() - 1            # position of leading 1 in w_q
    # target leading-1 position is rf.  shift = rf - msb.  exponent e relates m to w_q:
    #   w_q = m * 2^(msb - rf)            (m has leading 1 at bit rf)
    shift = rf - msb
    if shift >= 0:
        m = w_q << shift
    else:
        m = w_q >> (-shift)
    # m now in [2^rf, 2^(rf+1)); mantissa frac = m - 2^rf, in [0, 2^rf)
    # exponent: true_w = m * 2^(msb - rf).  We will compute 1/m (in [0.5,1)) then divide by 2^(msb-rf).

    # ---- 2. seed from LUT: index = top lut_bits of the fractional part ----
    frac = m - (1 << rf)                  # in [0, 2^rf)
    idx = frac >> (rf - lut_bits)         # top lut_bits
    x = lut[idx]                          # ~ 1/m_normalized in RF format (value in (0.5,1] * 2^rf)

    # ---- 3. Newton-Raphson:  x = x*(2 - m*x)  ----
    # m is in [1,2) scaled by 2^rf; x ~ 1/m scaled by 2^rf.
    # m*x ~ 1.0 scaled by 2^(2rf). two = 2.0 scaled by 2^rf.
    half = 1 << (rf - 1)                  # round-to-nearest constant for the >>rf shifts
    for _ in range(nr_iters):
        mx = (m * x + half) >> rf         # ~ m*x  in RF  (rounded so NR can converge from above too)
        two_minus = (2 << rf) - mx        # 2 - m*x  in RF
        x = (x * two_minus + half) >> rf  # new x in RF

    # x ~ 1/m  (m in [1,2)) scaled by 2^rf, value in (0.5,1] * 2^rf.

    # ---- 4. de-normalize ----
    # x = (1/m) * 2^rf, with m the mantissa (leading 1 at bit rf, m_true in [1,2)).
    # w_q is the RAW integer = w_true * 2^GFB, and w_q = m * 2^(msb-rf).
    # So w_true = w_q/2^GFB and  1/w_true = 2^GFB * (1/w_q),  (1/w_q) = x*2^-msb (x already =(1/m)*2^rf).
    # iw = (1/w_true)*2^rf = x * 2^(GFB - msb).  (callers do (n_q*iw)>>rf -> Q.FB)
    e = GFB - msb
    if e >= 0:
        iw = x << e
    else:
        iw = x >> (-e)
    return iw, True

# iw = (1/w_true) scaled by 2^RF.  nx_q is Q.FB (= nx_true*2^FB), so
#   nx_q * iw = nx_true*2^FB * (1/w_true)*2^RF = sx_true * 2^(FB+RF).
# Hence sx_q (Q.FB) = (nx_q * iw) >> RF.
def project_pixel(nx_q, ny_q, w_q):
    iw, valid = reciprocal_fixed(w_q)
    if not valid:
        return None
    sx_q = (nx_q * iw) >> RF      # Q.FB
    sy_q = (ny_q * iw) >> RF
    return sx_q, sy_q

# ---------------- homography helpers ----------------
def solve_homography(src_quad, dst_quad):
    """Solve 3x3 H mapping dst(output) -> src(source), i.e. inverse map.
    src_quad/dst_quad: list of 4 (x,y). We want H * [ox,oy,1] ~ [sx,sy,1].
    Returns a,b,c,d,e,f,g,h (i=1)."""
    # Standard DLT 8x8 solve: map dst -> src (because engine inverse-maps output->source).
    # H maps dst (ox,oy) to src (sx,sy).
    A = []
    B = []
    for (ox, oy), (sx, sy) in zip(dst_quad, src_quad):
        A.append([ox, oy, 1, 0, 0, 0, -ox*sx, -oy*sx]); B.append(sx)
        A.append([0, 0, 0, ox, oy, 1, -ox*sy, -oy*sy]); B.append(sy)
    # Gaussian elimination 8x8
    n = 8
    M = [row[:] + [B[r]] for r, row in enumerate(A)]
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(M[r][col]))
        M[col], M[piv] = M[piv], M[col]
        pv = M[col][col]
        for j in range(col, n+1):
            M[col][j] /= pv
        for r in range(n):
            if r != col and M[r][col] != 0:
                fac = M[r][col]
                for j in range(col, n+1):
                    M[r][j] -= fac * M[col][j]
    sol = [M[r][n] for r in range(n)]
    a, b, c, d, e, f, g, h = sol
    return a, b, c, d, e, f, g, h  # i = 1

def keystone_homography(OUT_W, OUT_H, IN_W, IN_H, h_amt, v_amt):
    """Symmetric trapezoid keystone. h_amt/v_amt in [0,1): fraction the far edge shrinks.
    Output (full raster) maps to a trapezoid inside the source."""
    # dst = full output corners; src = trapezoid corners inside source.
    dst = [(0,0),(OUT_W-1,0),(OUT_W-1,OUT_H-1),(0,OUT_H-1)]
    # source trapezoid: top edge narrowed by h_amt (keystone-H), etc. Keep inside source.
    mx = IN_W*0.5; my = IN_H*0.5
    sw = IN_W*0.48; sh = IN_H*0.48
    # corners TL,TR,BR,BL of a trapezoid: top edge shrunk horizontally by h_amt,
    # left edge shrunk vertically by v_amt (classic keystone).
    tl = (mx - sw*(1-h_amt), my - sh*(1-v_amt))
    tr = (mx + sw*(1-h_amt), my - sh*(1-v_amt))
    br = (mx + sw,           my + sh)
    bl = (mx - sw,           my + sh)
    src = [tl, tr, br, bl]
    return solve_homography(src, dst)

def cornerpin_homography(OUT_W, OUT_H, IN_W, IN_H, offsets):
    """4-corner pin: offsets = [(dx,dy)*4] applied to source corners (TL,TR,BR,BL)."""
    dst = [(0,0),(OUT_W-1,0),(OUT_W-1,OUT_H-1),(0,OUT_H-1)]
    mx = IN_W*0.5; my = IN_H*0.5; sw = IN_W*0.46; sh = IN_H*0.46
    base = [(mx-sw,my-sh),(mx+sw,my-sh),(mx+sw,my+sh),(mx-sw,my+sh)]
    src = [(x+dx, y+dy) for (x,y),(dx,dy) in zip(base, offsets)]
    return solve_homography(src, dst)

# ---------------- DDA evaluation of a homography (matches HDL accumulators) ----------------
def quantize_coeffs(a,b,c,d,e,f,g,h):
    # a..f are Q.FB (numerator, == pg_affine); g,h are Q.GFB (wide, perspective).
    return (to_q(a),to_q(b),to_q(c),to_q(d),to_q(e),to_q(f),to_qg(g),to_qg(h))

def eval_frame(OUT_W, OUT_H, IN_W, IN_H, coeffs_q, projective=True):
    """Yield per-pixel (ox,oy, sx_q, sy_q, valid) using the SAME incremental DDA + reciprocal
    the HDL uses. coeffs_q are quantized ints."""
    aq,bq,cq,dq,eq,fq,gq,hq = coeffs_q
    iq = WONE  # i = 1.0 in Q.GFB
    for oy in range(OUT_H):
        # row-start accumulators (nx,ny Q.FB ; w Q.GFB)
        nx = cq + bq*oy
        ny = fq + eq*oy
        if projective:
            w = iq + hq*oy
        else:
            w = WONE
        for ox in range(OUT_W):
            if projective:
                r = project_pixel(nx, ny, w)
            else:
                # affine: sx_q = nx (already Q.FB), since w=1.0 -> iw=1.0
                r = (nx, ny)
            if r is None:
                yield ox, oy, 0, 0, False
            else:
                sx_q, sy_q = r
                sxi = sx_q >> FB
                syi = sy_q >> FB
                valid = (0 <= sxi < IN_W) and (0 <= syi < IN_H)
                yield ox, oy, sx_q, sy_q, valid
            # increment
            nx += aq; ny += dq
            if projective:
                w += gq

# ---------------- float reference for precision budgeting ----------------
def eval_frame_float(OUT_W, OUT_H, IN_W, IN_H, coeffs):
    a,b,c,d,e,f,g,h = coeffs
    i = 1.0
    for oy in range(OUT_H):
        for ox in range(OUT_W):
            w = g*ox + h*oy + i
            if w <= 1e-9:
                yield ox, oy, None, None
            else:
                sx = (a*ox + b*oy + c)/w
                sy = (d*ox + e*oy + f)/w
                yield ox, oy, sx, sy

# ---------------- precision sweep ----------------
def precision_sweep(verbose=True):
    OUT_W, OUT_H, IN_W, IN_H = 1280, 720, 1920, 1080
    cases = {
        "keystone-H 0.35": keystone_homography(OUT_W,OUT_H,IN_W,IN_H, 0.35, 0.0),
        "keystone-V 0.35": keystone_homography(OUT_W,OUT_H,IN_W,IN_H, 0.0, 0.35),
        "keystone-HV 0.30": keystone_homography(OUT_W,OUT_H,IN_W,IN_H, 0.30, 0.30),
        "cornerpin-skew": cornerpin_homography(OUT_W,OUT_H,IN_W,IN_H,
                              [(120,80),(-90,40),(60,-110),(-40,-70)]),
        "cornerpin-strong": cornerpin_homography(OUT_W,OUT_H,IN_W,IN_H,
                              [(220,160),(-180,90),(140,-200),(-110,-150)]),
    }
    global RF, LUT_BITS, NR_ITERS, SEED_LUT
    worst_overall = 0.0
    # sub-sample the frame to keep the sweep fast but hit the foreshortened edges (corners/edges)
    step = 17
    for name, coeffs in cases.items():
        coeffs_q = quantize_coeffs(*coeffs)
        worst = 0.0; worst_at = None
        # iterate float ref and fixed model in lockstep over sampled pixels
        a,b,c,d,e,f,g,h = coeffs
        for oy in range(0, OUT_H, step):
            nx0 = coeffs_q[2] + coeffs_q[1]*oy
            ny0 = coeffs_q[5] + coeffs_q[4]*oy
            w0  = WONE + coeffs_q[7]*oy
            for ox in range(0, OUT_W, step):
                nx = nx0 + coeffs_q[0]*ox
                ny = ny0 + coeffs_q[3]*ox
                w  = w0  + coeffs_q[6]*ox
                r = project_pixel(nx, ny, w)
                wf = g*ox+h*oy+1.0
                if wf <= 1e-9 or r is None:
                    continue
                sx_f = (a*ox+b*oy+c)/wf
                sy_f = (d*ox+e*oy+f)/wf
                sx_m = r[0]/ONE; sy_m = r[1]/ONE
                ex = abs(sx_m - sx_f); ey = abs(sy_m - sy_f)
                err = max(ex, ey)
                if err > worst:
                    worst = err; worst_at = (ox, oy, sx_f, sy_f, sx_m, sy_m)
        worst_overall = max(worst_overall, worst)
        if verbose:
            frac_bits = -math.log2(worst) if worst > 0 else 99
            print(f"  {name:20s} worst |err| = {worst:.3e} px  (~Q.{frac_bits:.1f})  at {worst_at[:2] if worst_at else None}")
    return worst_overall

def tune():
    """Sweep FB / GFB / LUT_BITS / NR_ITERS / RF; pick smallest that achieves >=12 frac bits.
    Two error sources, both AMPLIFIED by 1/w (~1.6x) at the foreshortened edge:
      (1) numerator coeff quant 2^-FB * max(ox,oy)  -> needs FB wider than the affine 12;
      (2) perspective coeff quant 2^-GFB * (ox+oy)  -> needs GFB wide;
      (3) reciprocal LUT+NR residual -> tuned by RF/LUT_BITS/NR_ITERS.
    """
    global RF, LUT_BITS, NR_ITERS, SEED_LUT, GFB, WONE, FB, ONE
    target = 2.0 ** -12   # < 1/4096 px
    print("=== Precision tuning sweep (target worst-case err < 2^-12 = %.3e px) ===" % target)
    best = None
    for fb in (24, 26, 28):
        for gfb in (32, 36, 40):
            for nr in (1, 2):
                for lb in (9, 10):
                    for rf in (28, 30, 32):
                        FB, ONE = fb, (1 << fb)
                        GFB, WONE = gfb, (1 << gfb)
                        RF, LUT_BITS, NR_ITERS = rf, lb, nr
                        SEED_LUT = build_seed_lut(lb, rf)
                        w = precision_sweep(verbose=False)
                        ok = w < target
                        fbits = -math.log2(w) if w > 0 else 99
                        tag = "OK " if ok else "   "
                        # prefer: smaller FB, smaller GFB, fewer NR, fewer LUT bits, smaller RF
                        cost = (fb, gfb, nr, lb, rf)
                        if ok and (best is None or cost < best[0]):
                            best = (cost, w, fbits)
                        if ok or (fb in (12,24) and lb==10 and nr==2):
                            print(f"  [{tag}] FB={fb} GFB={gfb} NR={nr} LUT={lb:2d} RF={rf:2d} -> worst={w:.3e} (~Q.{fbits:.1f})")
    return best

def emit_vectors(path, OUT_W, OUT_H, IN_W, IN_H, coeffs, projective=True):
    """Write <path>.coef (8 hex coeffs a..f [CW-bit], g,h [GCW-bit], one per line, MSB-padded to
    GCW hex digits so $readmemh is uniform) and <path>.vec (one pixel per line:
    'inwin col row hf vf' all hex). o_h_frac/o_v_frac = TOP 12 bits of the Q.FB fraction (port
    semantics, matching pg_affine)."""
    coeffs_q = quantize_coeffs(*coeffs)
    FSH = FB - 12
    HD = (GCW + 3)//4   # hex digits to pad all coeffs to (uniform for $readmemh)
    def hx(v, bits): return f"{v & ((1<<bits)-1):0{HD}x}"
    aq,bq,cq,dq,eq,fq,gq,hq = coeffs_q
    with open(path + ".coef", "w") as fp:
        # a..f sign-extended to GCW bits for uniform readmemh; HDL takes the low CW bits.
        for v in (aq,bq,cq,dq,eq,fq):  fp.write(hx(v, GCW) + "\n")
        for v in (gq,hq):              fp.write(hx(v, GCW) + "\n")
    # metadata in a side file (NOT in .vec, so the TB's $fscanf sees only data lines)
    with open(path + ".meta", "w") as fp:
        fp.write(f"DIM {OUT_W} {OUT_H} {IN_W} {IN_H} PROJ {int(projective)} "
                 f"FB {FB} GFB {GFB} RF {RF} LUT {LUT_BITS} NR {NR_ITERS}\n")
    n = 0
    with open(path + ".vec", "w") as fp:
        for ox, oy, sx_q, sy_q, valid in eval_frame(OUT_W, OUT_H, IN_W, IN_H, coeffs_q, projective):
            if valid:
                fp.write(f"1 {(sx_q>>FB)&0xFFF:03x} {(sy_q>>FB)&0xFFF:03x} "
                         f"{(sx_q>>FSH)&0xFFF:03x} {(sy_q>>FSH)&0xFFF:03x}\n")
            else:
                fp.write("0 000 000 000 000\n")
            n += 1
    return n

# ---------------- synthetic source image + golden OUTPUT PIXELS (P2 faithful-TB) ----------------
# The faithful warp TBs fill the source frame with frame[y*IN_W+x] = {x[7:0], y[7:0], (x*3+y*5+7)[7:0]}
# (R=x, G=y, B=mix). We mirror that EXACTLY so the TB can check the full engine output (addr-gen ->
# cache -> bilinear) bit-exact, not just the gathered coords.
def src_px(x, y):
    r = x & 0xFF
    g = y & 0xFF
    b = (x*3 + y*5 + 7) & 0xFF
    return (r << 16) | (g << 8) | b

def lerp8(a, b, w):
    # bit-exact match to pg_warp_engine.lerp8 / the TB's g8: r = a + ((b-a)*w + 128) >> 8 (arith)
    d = b - a
    p = d * w
    r = a + ((p + 128) >> 8)
    return r & 0xFF

def lerp24(a, b, w):
    return (lerp8((a>>16)&0xFF,(b>>16)&0xFF,w) << 16) | \
           (lerp8((a>>8)&0xFF,(b>>8)&0xFF,w) << 8)  | \
            lerp8(a&0xFF,b&0xFF,w)

def golden_pixel(sx_q, sy_q, valid, IN_W, IN_H, matte):
    """Bilinear gather/lerp on the synthetic source at the golden Q.FB coords. Matches the engine's
    cache neighbour-clamp (col+1 clamped to IN_W-1) and 2-stage lerp (weight = frac[11:4])."""
    if not valid:
        return matte
    col = sx_q >> FB
    row = sy_q >> FB
    if col < 0 or row < 0 or col >= IN_W or row >= IN_H:
        return matte
    cn1 = col if col >= IN_W-1 else col+1
    rn1 = row if row >= IN_H-1 else row+1
    # weight = top 8 bits of the 12-bit fraction = (sx_q >> (FB-12)) >> 4, i.e. bits [FB-1:FB-8]
    wx = (sx_q >> (FB-12)) >> 4 & 0xFF
    wy = (sy_q >> (FB-12)) >> 4 & 0xFF
    p00 = src_px(col, row);  p10 = src_px(cn1, row)
    p01 = src_px(col, rn1);  p11 = src_px(cn1, rn1)
    tp = lerp24(p00, p10, wx); bt = lerp24(p01, p11, wx)
    return lerp24(tp, bt, wy)

def emit_pixels(path, OUT_W, OUT_H, IN_W, IN_H, coeffs, matte, projective=True):
    """Write <path>.pix: one 6-hex-digit RGB per output pixel (the expected ENGINE output), computed
    by bilinear-sampling the synthetic source at the golden projective coords. matte where OOW."""
    coeffs_q = quantize_coeffs(*coeffs)
    n = 0
    with open(path + ".pix", "w") as fp:
        for ox, oy, sx_q, sy_q, valid in eval_frame(OUT_W, OUT_H, IN_W, IN_H, coeffs_q, projective):
            fp.write(f"{golden_pixel(sx_q, sy_q, valid, IN_W, IN_H, matte):06x}\n")
            n += 1
    return n

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tune", action="store_true", help="run the LUT/NR/RF tuning sweep")
    ap.add_argument("--emit", metavar="DIR", help="emit golden vectors into DIR")
    ap.add_argument("--emit-pix", action="store_true",
                    help="also emit golden OUTPUT PIXELS (.pix) for the faithful TB (needs --emit)")
    ap.add_argument("--matte", default="101010", help="matte RGB hex for OOW pixels (default 101010)")
    ap.add_argument("--out-w", type=int, default=64)
    ap.add_argument("--out-h", type=int, default=48)
    ap.add_argument("--in-w", type=int, default=96)
    ap.add_argument("--in-h", type=int, default=72)
    args = ap.parse_args()

    if args.tune:
        global GFB, WONE, RF, LUT_BITS, NR_ITERS, SEED_LUT, FB, ONE
        best = tune()
        print()
        if best:
            fb_c, gfb, nr, lb, rf = best[0]
            print(f"CHOSEN: FB={fb_c} GFB={gfb} NR_ITERS={nr} LUT_BITS={lb} RF={rf} "
                  f"-> worst {best[1]:.3e} px (~Q.{best[2]:.1f})")
            # lock the chosen params for the final report
            FB, ONE = fb_c, (1 << fb_c)
            GFB, WONE = gfb, (1 << gfb)
            RF, LUT_BITS, NR_ITERS = rf, lb, nr
            SEED_LUT = build_seed_lut(lb, rf)
        print()
        print(f"=== Final report at chosen params (FB={FB} GFB={GFB} RF={RF} LUT_BITS={LUT_BITS} NR={NR_ITERS}) on 1280x720/1920x1080 ===")
        w = precision_sweep(verbose=True)
        fb = -math.log2(w)
        print(f"  WORST OVERALL = {w:.3e} px  (~Q.{fb:.1f} sub-pixel)")
        return

    if args.emit:
        import os
        d = args.emit; os.makedirs(d, exist_ok=True)
        OW, OH, IW, IH = args.out_w, args.out_h, args.in_w, args.in_h
        # affine-equivalence cases (g=h=0) — rotation/scale/shift, projective=1 forced
        def rot(deg, s):
            th = math.radians(deg); co=math.cos(th); si=math.sin(th)
            cxo=OW/2.0; cyo=OH/2.0; cxs=IW/2.0; cys=IH/2.0
            a=co/s; b=si/s; cc=cxs-a*cxo-b*cyo
            dd=-si/s; ee=co/s; ff=cys-dd*cxo-ee*cyo
            return (a,b,cc,dd,ee,ff,0.0,0.0)
        # Projective golden cases (FB=24 chosen config). The affine-EQUIVALENCE check is done in
        # HDL (pg_projective#(FB=12) vs pg_affine), so no affine golden files are needed.
        sets = {
            # an affine homography (g=h=0) run THROUGH the projective path -> exercises the
            # reciprocal-of-1.0 boundary at FB=24 (proves iw=1.0 path is exact).
            "proj_affineid":rot(0,1.0),
            "proj_keyH":    keystone_homography(OW,OH,IW,IH,0.30,0.0),
            "proj_keyV":    keystone_homography(OW,OH,IW,IH,0.0,0.30),
            "proj_keyHV":   keystone_homography(OW,OH,IW,IH,0.22,0.18),
            "proj_corner":  cornerpin_homography(OW,OH,IW,IH,
                                [(6,4),(-5,3),(4,-6),(-3,-4)]),
        }
        matte = int(args.matte, 16)
        for name, coeffs in sets.items():
            p = os.path.join(d, name)
            n = emit_vectors(p, OW, OH, IW, IH, coeffs, projective=True)
            msg = f"  emitted {name}: {n} px -> {p}.coef/.vec"
            if args.emit_pix:
                np = emit_pixels(p, OW, OH, IW, IH, coeffs, matte, projective=True)
                msg += f"/.pix ({np})"
            print(msg)
        return

    # default: just tune
    print("(no action; use --tune or --emit DIR)")

if __name__ == "__main__":
    main()
