#!/usr/bin/env python3
"""
ycbcr_422_ref.py — Python reference for hdl/ycbcr_444_to_422.v.

Box-filter chroma subsampling. Per pair of 4:4:4 input pixels (Y0,Cb0,Cr0),
(Y1,Cb1,Cr1) produces TWO 16-bit 4:2:2 output beats:

    Beat 0: { Cb_avg, Y0 }  (Cb in upper byte, Y in lower)
    Beat 1: { Cr_avg, Y1 }

    Cb_avg = (Cb0 + Cb1 + 1) >> 1   (round half up)
    Cr_avg = (Cr0 + Cr1 + 1) >> 1
"""


def subsample(pixels_444):
    """pixels_444: list of (Y, Cb, Cr) tuples. Returns list of (chroma, Y) tuples."""
    if len(pixels_444) % 2 != 0:
        raise ValueError(f"input must be even-length (got {len(pixels_444)})")
    out = []
    for i in range(0, len(pixels_444), 2):
        y0, cb0, cr0 = pixels_444[i]
        y1, cb1, cr1 = pixels_444[i + 1]
        cb_avg = (cb0 + cb1 + 1) >> 1
        cr_avg = (cr0 + cr1 + 1) >> 1
        out.append((cb_avg, y0))  # Beat 0
        out.append((cr_avg, y1))  # Beat 1
    return out


def pack16(chroma, luma):
    """Pack into 16-bit word: [15:8]=chroma, [7:0]=luma."""
    return ((chroma & 0xFF) << 8) | (luma & 0xFF)


def demo():
    test_in = [
        (16,  128, 128),  # black (601 limited)
        (16,  128, 128),
        (235, 128, 128),  # white
        (235, 128, 128),
        (81,  90,  239),  # red
        (144, 53,  34),   # green
        (40,  239, 109),  # blue
        (235, 128, 128),  # white
    ]
    out = subsample(test_in)
    for i, (ch, y) in enumerate(out):
        kind = "Cb" if i % 2 == 0 else "Cr"
        print(f"  beat {i:2d}  {kind}_avg={ch:3d}  Y={y:3d}  packed=0x{pack16(ch, y):04x}")


if __name__ == "__main__":
    demo()
