#!/usr/bin/env python3
"""
gen_coeffs.py — Generate polyphase scaler coefficients for Phase C.

Produces coefficient .hex files consumed by hdl/scaler_coeffs_h.v
(8-tap H, 64 phases) and hdl/scaler_coeffs_v.v (4-tap V, 64 phases).

Default kernel: Lanczos-2 (window=2, support=4 lobes). Good
sharpness/aliasing tradeoff for video downscale. Other kernels available
via --kernel; useful for Phase C.3 characterization.

Math:
  For a polyphase scaler with N taps and P phases:
    coeffs[phase][tap] = kernel((tap - center) + phase/P) * scale_correction
  where center = (N-1)/2 and scale_correction normalizes the kernel
  integral. We additionally rescale per-phase so that sum(coeffs[phase])
  = 1.0 — this prevents brightness ripple as the phase walks.

Fixed-point output: signed Q1.11 (1 sign bit, 11 fractional bits, range
[-1.0, +0.9995]). Negative taps are common for Lanczos (sidelobes).
12-bit signed coefficient × 8-bit pixel = 20-bit product; with 8 taps
summed we need 23-bit accumulator. Output truncated/saturated to 8 bits.

Usage:
  ./gen_coeffs.py                          # default Lanczos-2, write hdl/*.hex
  ./gen_coeffs.py --kernel mitchell        # Mitchell-Netravali kernel
  ./gen_coeffs.py --taps-h 8 --taps-v 4    # explicit tap counts
  ./gen_coeffs.py --phases 64              # phase count (power of 2 only)
  ./gen_coeffs.py --plot                   # show frequency response, requires matplotlib
"""

import argparse
import math
import sys
from pathlib import Path


# ---------- Kernels ----------

def sinc(x):
    if abs(x) < 1e-9:
        return 1.0
    return math.sin(math.pi * x) / (math.pi * x)


def lanczos(x, a=2):
    """Lanczos-a kernel. Zero outside [-a, a]."""
    if abs(x) >= a:
        return 0.0
    return sinc(x) * sinc(x / a)


def mitchell_netravali(x, B=1/3, C=1/3):
    """Mitchell-Netravali cubic kernel. Default B=C=1/3 is the
    canonical recommendation for image scaling."""
    ax = abs(x)
    if ax < 1:
        return ((12 - 9*B - 6*C) * ax**3 +
                (-18 + 12*B + 6*C) * ax**2 +
                (6 - 2*B)) / 6
    if ax < 2:
        return ((-B - 6*C) * ax**3 +
                (6*B + 30*C) * ax**2 +
                (-12*B - 48*C) * ax +
                (8*B + 24*C)) / 6
    return 0.0


def box(x):
    """Nearest-neighbor / box filter — for sanity testing only."""
    return 1.0 if abs(x) < 0.5 else 0.0


def linear(x):
    """Bilinear interpolation kernel."""
    ax = abs(x)
    if ax < 1:
        return 1.0 - ax
    return 0.0


KERNELS = {
    "lanczos2": lambda x: lanczos(x, a=2),
    "lanczos3": lambda x: lanczos(x, a=3),
    "mitchell": mitchell_netravali,
    "linear":   linear,
    "box":      box,
}


# ---------- Coefficient table builder ----------

def build_coeffs(kernel, taps, phases):
    """Return phases × taps list of float coefficients, per-phase normalized.

    For phase p (0..phases-1), the sample offset is p/phases. Tap t
    (0..taps-1) is at integer offset (t - center) where center = (taps-1)/2.
    The kernel argument is (t - center - p/phases) — note the sign: as
    phase increases, the kernel slides toward the next tap.
    """
    center = (taps - 1) / 2
    table = []
    for p in range(phases):
        frac = p / phases
        row = [kernel((t - center) - frac) for t in range(taps)]
        # Normalize so sum of taps = 1.0 (DC gain = unity, no ripple)
        s = sum(row)
        if abs(s) < 1e-9:
            raise RuntimeError(f"phase {p}: kernel sum is zero")
        row = [c / s for c in row]
        table.append(row)
    return table


def to_q1_11(x):
    """Convert float in [-1, +1) to signed Q1.11 (12 bits)."""
    q = round(x * 2048)
    if q >  2047: q =  2047
    if q < -2048: q = -2048
    return q & 0xFFF  # 12-bit two's-complement representation


def write_hex(path, table, comment_lines=None):
    """Write phases × taps coefficient table as a flat .hex file.
    Vivado readmemh format: one hex word per line, MSB first.
    Layout: phase 0 tap 0, phase 0 tap 1, ..., phase 0 tap N-1, phase 1 tap 0, ..."""
    lines = []
    if comment_lines:
        for c in comment_lines:
            lines.append(f"// {c}")
    for p, row in enumerate(table):
        lines.append(f"// phase {p}")
        for t, c in enumerate(row):
            q = to_q1_11(c)
            lines.append(f"{q:03x}  // phase {p:2d} tap {t}  ({c:+.6f})")
    path.write_text("\n".join(lines) + "\n")


# ---------- Diagnostics ----------

def report(label, table):
    taps = len(table[0])
    phases = len(table)
    print(f"\n=== {label} ({phases} phases × {taps} taps) ===")
    print(f"  min coeff: {min(min(row) for row in table):+.4f}")
    print(f"  max coeff: {max(max(row) for row in table):+.4f}")
    for p in [0, phases // 4, phases // 2, 3 * phases // 4, phases - 1]:
        row = table[p]
        s = " ".join(f"{c:+.3f}" for c in row)
        print(f"  phase {p:3d}: {s}  (sum={sum(row):.4f})")


# ---------- Main ----------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kernel", choices=list(KERNELS), default="lanczos2")
    ap.add_argument("--taps-h", type=int, default=8)
    ap.add_argument("--taps-v", type=int, default=4)
    ap.add_argument("--phases", type=int, default=64)
    ap.add_argument("--out-h", default="hdl/scaler_coeffs_h.hex")
    ap.add_argument("--out-v", default="hdl/scaler_coeffs_v.hex")
    args = ap.parse_args()

    if args.phases & (args.phases - 1):
        sys.exit(f"--phases must be a power of 2, got {args.phases}")

    kernel = KERNELS[args.kernel]
    h_table = build_coeffs(kernel, args.taps_h, args.phases)
    v_table = build_coeffs(kernel, args.taps_v, args.phases)

    report("H filter", h_table)
    report("V filter", v_table)

    repo = Path(__file__).resolve().parent.parent
    header = [
        f"Generated by python/gen_coeffs.py",
        f"Kernel: {args.kernel}",
        f"Format: signed Q1.11 (12 bits), two's complement",
        f"Layout: phase 0 tap 0, phase 0 tap 1, ..., phase 0 tap N-1, phase 1 tap 0, ...",
    ]
    h_path = repo / args.out_h
    v_path = repo / args.out_v
    write_hex(h_path, h_table, header + [f"H filter: {args.phases} phases × {args.taps_h} taps"])
    write_hex(v_path, v_table, header + [f"V filter: {args.phases} phases × {args.taps_v} taps"])

    print(f"\nWrote {h_path}")
    print(f"Wrote {v_path}")


if __name__ == "__main__":
    main()
