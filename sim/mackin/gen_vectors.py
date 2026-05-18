#!/usr/bin/env python3
"""
gen_vectors.py — generate test vectors for mackin_blender_tb.v.

Each vector file is plain text, one pixel-pair per line:
    prev_rgb_hex  curr_rgb_hex  expected_rgb_hex

All values are 24-bit hex (R-B-G byte order — same as the pipeline).
Python interprets and writes in (R,G,B) tuple form internally; the
hex packing matches the HDL tdata[23:16]=R, [15:8]=B, [7:0]=G layout.

Generates one file per alpha value tested:
    vectors/alpha_<hex>.txt

Plus a "manifest.txt" listing all generated files for the tb to iterate.
"""

import os
import random
from pathlib import Path
from mackin_ref import blend_pixel


ROOT = Path(__file__).parent
VEC_DIR = ROOT / "vectors"
VEC_DIR.mkdir(exist_ok=True)


def rgb_to_hex(rgb):
    r, g, b = rgb
    return (r << 16) | (b << 8) | g  # R-B-G byte order


def write_vector_file(alpha_q15, pixel_pairs, filename):
    """pixel_pairs: list of (prev_rgb, curr_rgb)."""
    with open(filename, "w") as f:
        f.write(f"// alpha_q15 = 0x{alpha_q15:04x}\n")
        f.write(f"// {len(pixel_pairs)} vectors\n")
        f.write("// prev curr expected\n")
        for prev, curr in pixel_pairs:
            expected = blend_pixel(prev, curr, alpha_q15)
            f.write(f"{rgb_to_hex(prev):06x} {rgb_to_hex(curr):06x} {rgb_to_hex(expected):06x}\n")


def gen_systematic_pairs():
    """Sweep cardinal pixel pairs that cover edge behavior."""
    cardinals = [
        (0, 0, 0), (255, 255, 255),
        (255, 0, 0), (0, 255, 0), (0, 0, 255),
        (128, 128, 128), (64, 64, 64), (192, 192, 192),
        (100, 50, 200), (255, 100, 0),
    ]
    pairs = []
    for p in cardinals:
        for c in cardinals:
            pairs.append((p, c))
    return pairs


def gen_random_pairs(n, seed=0xBEEF):
    rng = random.Random(seed)
    pairs = []
    for _ in range(n):
        prev = (rng.randrange(256), rng.randrange(256), rng.randrange(256))
        curr = (rng.randrange(256), rng.randrange(256), rng.randrange(256))
        pairs.append((prev, curr))
    return pairs


def gen_gradient_pairs():
    """Ramp through prev=0..255, curr=255..0. Stresses interpolation precision."""
    pairs = []
    for v in range(0, 256, 4):
        prev = (v, v, v)
        curr = (255 - v, 128, v // 2)
        pairs.append((prev, curr))
    return pairs


def main():
    alphas = [
        0x0000,  # pure prev (drop-degenerate, drop curr)
        0x0001,  # smallest non-zero alpha
        0x1000,  # 12.5% curr
        0x2000,  # 25%
        0x4000,  # 50/50 blend (midpoint)
        0x6000,  # 75%
        0x7FFF,  # just under full curr
        0x8000,  # pure curr (drop-degenerate, drop prev)
    ]

    pairs = gen_systematic_pairs() + gen_gradient_pairs() + gen_random_pairs(256)

    manifest = []
    for a in alphas:
        fname = VEC_DIR / f"alpha_{a:04x}.txt"
        write_vector_file(a, pairs, fname)
        manifest.append((a, fname.name, len(pairs)))
        print(f"  wrote {fname.name}: {len(pairs)} vectors @ alpha=0x{a:04x}")

    with open(VEC_DIR / "manifest.txt", "w") as f:
        for a, fname, n in manifest:
            f.write(f"0x{a:04x} {fname} {n}\n")

    print(f"\nManifest: {VEC_DIR / 'manifest.txt'}")


if __name__ == "__main__":
    main()
