#!/usr/bin/env python3
"""
mackin_ref.py — golden reference for mackin_blender.v

Bit-exact Python reference of the HDL math:

    out_c = clamp( prev_c + ((alpha * (curr_c - prev_c) + 0x4000) >> 15), 0, 255 )

alpha is Q1.15 unsigned (0 .. 0x8000). curr_c, prev_c are 8-bit unsigned.

Used by:
    - sim/mackin/mackin_blender_tb.v       (Verilog tb diff target)
    - sim/mackin/gen_vectors.py            (generates RGB test frames)
"""

from typing import Iterable, Tuple
import struct
import sys


def blend_pixel(prev_rgb: Tuple[int, int, int],
                curr_rgb: Tuple[int, int, int],
                alpha_q15: int) -> Tuple[int, int, int]:
    """One pixel of the blender. alpha_q15 in [0, 0x8000]."""
    if not (0 <= alpha_q15 <= 0x8000):
        raise ValueError(f"alpha_q15={alpha_q15:#x} out of [0, 0x8000]")

    out = []
    for p, c in zip(prev_rgb, curr_rgb):
        if not (0 <= p <= 255 and 0 <= c <= 255):
            raise ValueError(f"channel out of 8-bit range: prev={p} curr={c}")
        diff = c - p                              # signed, -255..+255
        scaled = (alpha_q15 * diff + 0x4000) >> 15  # arithmetic shift
        result = p + scaled                       # 10-bit signed worst case
        if result < 0:
            result = 0
        elif result > 255:
            result = 255
        out.append(result)
    return tuple(out)


def blend_frame(prev_frame, curr_frame, alpha_q15):
    """Frame-level blend. Frames are lists of (r,g,b) tuples."""
    if len(prev_frame) != len(curr_frame):
        raise ValueError(f"frame length mismatch: {len(prev_frame)} vs {len(curr_frame)}")
    return [blend_pixel(p, c, alpha_q15) for p, c in zip(prev_frame, curr_frame)]


def edge_case_check():
    """Verify the two key endpoints are exact."""
    # alpha = 0 -> out = prev, regardless of curr
    for p in [(0, 0, 0), (128, 64, 200), (255, 255, 255), (100, 0, 50)]:
        for c in [(0, 0, 0), (255, 255, 255), (50, 50, 50), (200, 100, 0)]:
            out = blend_pixel(p, c, 0)
            assert out == p, f"alpha=0: prev={p} curr={c} out={out} should be prev"

    # alpha = 0x8000 -> out = curr, regardless of prev (within 1 LSB)
    for p in [(0, 0, 0), (128, 64, 200), (255, 255, 255), (100, 0, 50)]:
        for c in [(0, 0, 0), (255, 255, 255), (50, 50, 50), (200, 100, 0)]:
            out = blend_pixel(p, c, 0x8000)
            assert out == c, f"alpha=0x8000: prev={p} curr={c} out={out} should be curr"

    # alpha = 0x4000 -> 50/50: out = (p + c + 1) >> 1  (round-to-nearest)
    # Diff form gives: out = p + ((0x4000 * (c-p) + 0x4000) >> 15)
    #                      = p + (((c-p) + 1) >> 1)   when (c-p) << 14 doesn't overflow
    # That equals round((p + c) / 2) with bias toward larger.
    for p_val in range(0, 256, 32):
        for c_val in range(0, 256, 32):
            out_r = blend_pixel((p_val, 0, 0), (c_val, 0, 0), 0x4000)[0]
            # Expected midpoint with bias-toward-positive rounding
            diff = c_val - p_val
            expected = p_val + ((0x4000 * diff + 0x4000) >> 15)
            expected = max(0, min(255, expected))
            assert out_r == expected, f"50/50: p={p_val} c={c_val} out={out_r} exp={expected}"

    print("edge_case_check: PASS")


if __name__ == "__main__":
    edge_case_check()
    if len(sys.argv) > 1 and sys.argv[1] == "demo":
        # Quick demo: blend gray-50 frame with white frame at α=0x4000
        prev = [(128, 128, 128)] * 4
        curr = [(255, 255, 255)] * 4
        out = blend_frame(prev, curr, 0x4000)
        for i, (p, c, o) in enumerate(zip(prev, curr, out)):
            print(f"  px[{i}]  prev={p}  curr={c}  -> out={o}")
