#!/usr/bin/env python3
"""
gen_vectors.py — RGB → YCbCr 4:4:4 + 4:2:2 test vectors.

Outputs vectors/mode_<m>.txt for each colorimetry mode:
    rgb0_hex rgb1_hex ycc0_hex ycc1_hex out0_hex out1_hex

Where:
    rgb0/1   = 24-bit R-B-G byte order (input)
    ycc0/1   = 24-bit Y-Cb-Cr byte order (expected from rgb_to_ycbcr)
    out0/1   = 16-bit 4:2:2 packing (expected from ycbcr_444_to_422),
               beat0={Cb_avg, Y0}, beat1={Cr_avg, Y1}
"""

import random
from pathlib import Path
from rgb_to_ycbcr_ref import convert as ycc_convert
from ycbcr_422_ref import subsample, pack16


ROOT = Path(__file__).parent
VEC_DIR = ROOT / "vectors"
VEC_DIR.mkdir(exist_ok=True)


def rgb_pack(rgb):
    """Pack (R, G, B) into 24-bit R-B-G byte order (Schindler pipeline convention)."""
    r, g, b = rgb
    return (r << 16) | (b << 8) | g


def ycc_pack(ycc):
    """Pack (Y, Cb, Cr) into 24-bit Y-Cb-Cr byte order (HDL output convention)."""
    y, cb, cr = ycc
    return (y << 16) | (cb << 8) | cr


def gen_pixel_pairs(seed=0xC0FFEE):
    rng = random.Random(seed)
    pairs = []
    # Cardinals + edge cases
    cardinals = [
        (0, 0, 0), (255, 255, 255),
        (255, 0, 0), (0, 255, 0), (0, 0, 255),
        (128, 128, 128), (200, 150, 100),
        (16, 16, 16), (235, 235, 235),
        (255, 128, 0), (0, 255, 128), (128, 0, 255),
    ]
    for a in cardinals:
        for b in cardinals:
            pairs.append((a, b))
    # Plus random
    for _ in range(64):
        p0 = (rng.randrange(256), rng.randrange(256), rng.randrange(256))
        p1 = (rng.randrange(256), rng.randrange(256), rng.randrange(256))
        pairs.append((p0, p1))
    return pairs


def main():
    pairs = gen_pixel_pairs()
    for mode in (0, 1, 2, 3):
        fname = VEC_DIR / f"mode_{mode}.txt"
        with open(fname, "w") as f:
            f.write(f"// mode = {mode} ({['601L','601F','709L','709F'][mode]})\n")
            f.write(f"// {len(pairs)} pixel pairs\n")
            f.write("// rgb0 rgb1 ycc0 ycc1 out0 out1\n")
            for p0, p1 in pairs:
                ycc0 = ycc_convert(p0, mode)
                ycc1 = ycc_convert(p1, mode)
                subs = subsample([ycc0, ycc1])
                out0 = pack16(*subs[0])
                out1 = pack16(*subs[1])
                f.write(f"{rgb_pack(p0):06x} {rgb_pack(p1):06x} "
                        f"{ycc_pack(ycc0):06x} {ycc_pack(ycc1):06x} "
                        f"{out0:04x} {out1:04x}\n")
        print(f"  wrote {fname.name}: {len(pairs)} pairs")


if __name__ == "__main__":
    main()
