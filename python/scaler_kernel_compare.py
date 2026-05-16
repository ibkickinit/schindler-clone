#!/usr/bin/env python3
"""
scaler_kernel_compare.py — Bit-exact polyphase scaler model for kernel A/B.

Mirrors hdl/scaler_h.v + hdl/scaler_v.v exactly: signed Q1.11 coeffs,
9-bit signed pixel widening, 23-bit (H) / 22-bit (V) signed accumulator,
saturate to [0, 255], truncate (or round) the Q.11 fraction.

Used to compare Lanczos-2 vs Mitchell at the 2 H phases + 2 V phases
actually exercised by the 1920x1080 -> 1280x720 ratio (phases {0, 31}
in both axes), and to A/B the truncate-vs-round-to-nearest fix to
mac8_sat / mac4_sat.

Stdlib-only (matches gen_coeffs.py convention). PPM output for sim mode.
"""

import argparse
import math
import struct
import sys
from pathlib import Path

# Reuse kernels + builder from gen_coeffs (sibling module)
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_coeffs import KERNELS, build_coeffs, to_q1_11


# ---------- Bit-exact MAC matching scaler_h.v / scaler_v.v ----------

def _q11_to_signed(q):
    """Q1.11 12-bit two's complement -> signed int."""
    return q - 4096 if q >= 2048 else q


def mac_sat(pixels, coeffs_q11, *, round_to_nearest=False):
    """Bit-exact MAC + saturation matching mac8_sat / mac4_sat in HDL.

    pixels: list of unsigned 8-bit (0..255)
    coeffs_q11: list of signed Q1.11 ints (-2048..2047), same length
    round_to_nearest: if True, add 1024 before the >>11 (the rounding fix).
    Returns 0..255.
    """
    s = 0
    for p, k in zip(pixels, coeffs_q11):
        # 9-bit signed pixel * 12-bit signed coeff (Verilog semantics)
        s += p * k
    if round_to_nearest:
        s += 1024
    if s < 0:
        return 0
    if s > 522239:  # 255 << 11 - 1 (matches HDL guard)
        return 255
    return (s >> 11) & 0xFF


# ---------- Polyphase phase trace (matches HDL accum logic) ----------

def trace_phases(in_w, out_w, n_outputs):
    """Yield (input_index, phase) for each output pixel, matching scaler_h.v's
    state machine. input_index is the index of the NEWEST pixel in the 8-tap
    window at the moment of emit.
    """
    PHASES = 64
    PHASE_MUL_Q10 = (PHASES * 1024 + out_w // 2) // out_w
    accum = out_w  # post-TUSER reset value
    in_idx = 0     # 0 = first input pixel of frame (TUSER)
    emitted = 0
    while emitted < n_outputs:
        in_idx += 1
        accum_next = accum + out_w
        if accum_next >= in_w:
            excess = accum_next - in_w
            phase = (excess * PHASE_MUL_Q10) >> 10
            yield (in_idx, phase)
            emitted += 1
            accum = excess
        else:
            accum = accum_next


def scale_h_row(row, in_w, out_w, coeffs_table_q11, *, round_to_nearest=False):
    """Apply 8-tap polyphase H scaler bit-exactly. row is list of (R,G,B) tuples,
    length in_w. Returns list of (R,G,B) tuples, length out_w.
    """
    TAPS = 8
    # Build window history: window[0] = newest, [7] = oldest.
    # We reconstruct it from the input row at each emit point.
    out_row = []
    for in_idx, phase in trace_phases(in_w, out_w, out_w):
        # Window: last 8 input pixels including current (in_idx).
        # in_idx is 1-based (post first pixel = 1). 0-based source index is in_idx-1.
        cur = in_idx - 1
        window = []
        for t in range(TAPS):
            src = cur - t
            if src < 0:
                window.append((0, 0, 0))
            else:
                window.append(row[src])
        # window[0] = current (newest), window[7] = oldest (cur - 7)
        coeffs = [_q11_to_signed(c) for c in coeffs_table_q11[phase]]
        r = mac_sat([w[0] for w in window], coeffs, round_to_nearest=round_to_nearest)
        g = mac_sat([w[1] for w in window], coeffs, round_to_nearest=round_to_nearest)
        b = mac_sat([w[2] for w in window], coeffs, round_to_nearest=round_to_nearest)
        out_row.append((r, g, b))
    return out_row


def scale_v_frame(rows_after_h, in_h, out_h, coeffs_table_q11, *, round_to_nearest=False):
    """Apply 4-tap polyphase V scaler bit-exactly. rows_after_h is a list of
    out_w-long row lists (already H-scaled), of length in_h.
    Returns list of out_w-long rows, length out_h.
    """
    TAPS = 4
    out_w = len(rows_after_h[0])
    out_rows = []
    for in_row_idx, phase in trace_phases(in_h, out_h, out_h):
        cur = in_row_idx - 1
        # 4-tap window: rows [cur-3, cur-2, cur-1, cur], remapped so newest
        # pixel is index 0 (matches HDL tap0_slot rotation conceptually).
        # In HDL the lbufs rotate so tap0 is the newest line; here just gather.
        window_rows = []
        for t in range(TAPS):
            src = cur - t
            if 0 <= src < in_h:
                window_rows.append(rows_after_h[src])
            else:
                window_rows.append([(0, 0, 0)] * out_w)
        coeffs = [_q11_to_signed(c) for c in coeffs_table_q11[phase]]
        new_row = []
        for col in range(out_w):
            taps = [window_rows[t][col] for t in range(TAPS)]
            r = mac_sat([t[0] for t in taps], coeffs, round_to_nearest=round_to_nearest)
            g = mac_sat([t[1] for t in taps], coeffs, round_to_nearest=round_to_nearest)
            b = mac_sat([t[2] for t in taps], coeffs, round_to_nearest=round_to_nearest)
            new_row.append((r, g, b))
        out_rows.append(new_row)
    return out_rows


# ---------- Test patterns ----------

# SMPTE-like color bar values (75% saturation), matching what bench captures show.
# Order: gray | yellow | cyan | green | magenta | red | blue | gray
SMPTE_BARS_75 = [
    (180, 180, 180),
    (180, 180,   0),
    (  0, 180, 180),
    (  0, 180,   0),
    (180,   0, 180),
    (180,   0,   0),
    (  0,   0, 180),
    (180, 180, 180),
]

# Reverse-bars row (bottom of SMPTE pattern): blue | black | magenta | black | cyan | black | gray
REVERSE_BARS = [
    (  0,   0, 180),
    (  0,   0,   0),
    (180,   0, 180),
    (  0,   0,   0),
    (  0, 180, 180),
    (  0,   0,   0),
    (180, 180, 180),
]


def make_test_frame(in_w, in_h):
    """Build a SMPTE-like pattern: top 60% color bars, middle 15% reverse bars,
    bottom 25% PLUGE strip (sub-black to super-black gradient + IRE markers).
    Returns list of in_h rows of in_w (R,G,B) tuples.
    """
    band1 = int(in_h * 0.60)
    band2 = int(in_h * 0.75)
    rows = []
    # Top: color bars
    for r in range(band1):
        row = []
        for c in range(in_w):
            bar = (c * len(SMPTE_BARS_75)) // in_w
            row.append(SMPTE_BARS_75[bar])
        rows.append(row)
    # Middle: reverse bars
    for r in range(band1, band2):
        row = []
        for c in range(in_w):
            bar = (c * len(REVERSE_BARS)) // in_w
            row.append(REVERSE_BARS[bar])
        rows.append(row)
    # Bottom: PLUGE + low-IRE gradient
    # Layout (left to right): I-bar (-I/+Q), white, gray gradient 0..40 IRE,
    # PLUGE black-to-superblack ramp, +4 IRE / -4 IRE strips.
    for r in range(band2, in_h):
        row = []
        for c in range(in_w):
            f = c / in_w
            if f < 0.10:
                row.append((50, 50, 80))   # I-bar
            elif f < 0.25:
                row.append((220, 220, 220))  # white
            elif f < 0.65:
                # Gray gradient 0..40 IRE (~0..102 in 8-bit)
                v = int((f - 0.25) / 0.40 * 102)
                row.append((v, v, v))
            elif f < 0.75:
                row.append((0, 0, 0))       # solid black
            elif f < 0.83:
                row.append((4, 4, 4))       # +4 IRE (PLUGE bright)
            elif f < 0.91:
                row.append((0, 0, 0))       # 0 IRE
            else:
                row.append((12, 12, 12))    # +12 IRE marker
        rows.append(row)
    return rows


# ---------- PPM output (binary P6, no deps) ----------

def write_ppm(path, frame):
    h = len(frame)
    w = len(frame[0])
    header = f"P6\n{w} {h}\n255\n".encode("ascii")
    body = bytearray()
    for row in frame:
        for r, g, b in row:
            body.append(r)
            body.append(g)
            body.append(b)
    Path(path).write_bytes(header + bytes(body))


# ---------- Modes ----------

def cmd_analyze(args):
    """Print coeffs for the 2 phases used at 1080p->720p, both kernels."""
    # Phases used (from HDL trace): {0, 31}
    phases_used = sorted(set(p for _, p in trace_phases(1920, 1280, 50)))
    print(f"Phases exercised at 1920x1080 -> 1280x720: {phases_used}")
    print()
    for kname in ("lanczos2", "mitchell"):
        print(f"=== Kernel: {kname} ===")
        for taps_label, taps in [("H 8-tap", 8), ("V 4-tap", 4)]:
            table = build_coeffs(KERNELS[kname], taps, 64)
            print(f"  {taps_label}:")
            for ph in phases_used:
                row = table[ph]
                qrow = [to_q1_11(c) for c in row]
                srow = [_q11_to_signed(q) for q in qrow]
                fl_str = " ".join(f"{c:+.4f}" for c in row)
                q_str  = " ".join(f"{q:+5d}" for q in srow)
                l1 = sum(abs(c) for c in row)
                dc = sum(row)
                # Per-channel worst-case sum = 255 * sum(positive coeffs in Q.11)
                pos_sum_q = sum(s for s in srow if s > 0)
                neg_sum_q = sum(s for s in srow if s < 0)
                max_pos = 255 * pos_sum_q
                max_neg = 255 * neg_sum_q
                print(f"    phase {ph:3d}: float = {fl_str}")
                print(f"               q11   = {q_str}   L1={l1:.4f} DC={dc:.6f}")
                print(f"               worst-case sum range: [{max_neg}, {max_pos}]  (sat at [0, 522239])")
        print()


def cmd_sim(args):
    """Bit-exactly scale a synthetic SMPTE-like frame with both kernels and
    optionally with rounding fix. Output to PPM for visual diff."""
    in_w, in_h = args.in_w, args.in_h
    out_w, out_h = args.out_w, args.out_h
    print(f"Generating {in_w}x{in_h} test frame...")
    src = make_test_frame(in_w, in_h)
    write_ppm(args.outdir / "src.ppm", src)
    print(f"  wrote {args.outdir / 'src.ppm'}")

    runs = []
    for kname in ("lanczos2", "mitchell"):
        for rnd in (False, True):
            tag = f"{kname}{'-rnd' if rnd else '-trunc'}"
            runs.append((tag, kname, rnd))

    for tag, kname, rnd in runs:
        print(f"\nRun: {tag}")
        h_table = [[to_q1_11(c) for c in row] for row in build_coeffs(KERNELS[kname], 8, 64)]
        v_table = [[to_q1_11(c) for c in row] for row in build_coeffs(KERNELS[kname], 4, 64)]

        # H scale every row
        print(f"  H scaling {in_h} rows of {in_w} -> {out_w}...")
        h_rows = []
        for i, row in enumerate(src):
            h_rows.append(scale_h_row(row, in_w, out_w, h_table, round_to_nearest=rnd))
            if (i + 1) % 100 == 0:
                print(f"    row {i+1}/{in_h}")

        # V scale
        print(f"  V scaling {in_h} -> {out_h} rows...")
        out = scale_v_frame(h_rows, in_h, out_h, v_table, round_to_nearest=rnd)

        out_path = args.outdir / f"out_{tag}.ppm"
        write_ppm(out_path, out)
        print(f"  wrote {out_path}")


def cmd_diff(args):
    """Compute per-pixel abs difference between two PPMs and print stats."""
    def read_ppm(path):
        data = Path(path).read_bytes()
        # Parse P6 header
        idx = 0
        def readline():
            nonlocal idx
            end = data.index(b"\n", idx)
            line = data[idx:end].decode("ascii")
            idx = end + 1
            return line
        magic = readline()
        assert magic == "P6"
        # Skip comments
        while True:
            line = readline()
            if not line.startswith("#"):
                break
        w, h = (int(x) for x in line.split())
        maxval = int(readline())
        pixels = data[idx:]
        return w, h, pixels

    w1, h1, p1 = read_ppm(args.a)
    w2, h2, p2 = read_ppm(args.b)
    assert (w1, h1) == (w2, h2), f"size mismatch: {w1}x{h1} vs {w2}x{h2}"
    diffs = [abs(a - b) for a, b in zip(p1, p2)]
    n = len(diffs)
    s = sum(diffs)
    mx = max(diffs)
    nz = sum(1 for d in diffs if d != 0)
    mse = sum(d*d for d in diffs) / n
    psnr = 10 * math.log10(255 * 255 / mse) if mse > 0 else float("inf")
    print(f"diff {args.a} vs {args.b}:")
    print(f"  pixels: {w1}x{h1}, channels: 3, total samples: {n}")
    print(f"  mean abs diff: {s/n:.4f}")
    print(f"  max  abs diff: {mx}")
    print(f"  nonzero diffs: {nz} ({100*nz/n:.2f}%)")
    print(f"  MSE: {mse:.4f}   PSNR: {psnr:.2f} dB")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    a1 = sub.add_parser("analyze", help="Dump coeffs for phases used by 1080p->720p")
    a1.set_defaults(func=cmd_analyze)

    a2 = sub.add_parser("sim", help="Run bit-exact scale of synthetic frame, both kernels")
    a2.add_argument("--in-w", type=int, default=1920, dest="in_w")
    a2.add_argument("--in-h", type=int, default=1080, dest="in_h")
    a2.add_argument("--out-w", type=int, default=1280, dest="out_w")
    a2.add_argument("--out-h", type=int, default=720, dest="out_h")
    a2.add_argument("--outdir", type=Path, default=Path("build/scaler-kernel-sim"))
    a2.set_defaults(func=cmd_sim)

    a3 = sub.add_parser("diff", help="Per-channel diff stats between two PPMs")
    a3.add_argument("a")
    a3.add_argument("b")
    a3.set_defaults(func=cmd_diff)

    args = ap.parse_args()
    if hasattr(args, "outdir"):
        args.outdir.mkdir(parents=True, exist_ok=True)
    args.func(args)


if __name__ == "__main__":
    main()
