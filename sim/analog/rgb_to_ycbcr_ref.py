#!/usr/bin/env python3
"""
rgb_to_ycbcr_ref.py — bit-exact Python reference for hdl/rgb_to_ycbcr.v.

Per channel:
  Y  = clamp( ((cY_R·R + cY_G·G + cY_B·B) >> 14) + off_Y, 0, 255 )
  Cb = clamp( ((cCb_R·R + cCb_G·G + cCb_B·B) >> 14) + 128, 0, 255 )
  Cr = clamp( ((cCr_R·R + cCr_G·G + cCr_B·B) >> 14) + 128, 0, 255 )

Modes (MUST match HDL ROM):
  00 = Rec.601 limited
  01 = Rec.601 full
  10 = Rec.709 limited
  11 = Rec.709 full
"""

COEFS = {
    # mode : (cY_R, cY_G, cY_B,   cCb_R, cCb_G, cCb_B,   cCr_R, cCr_G, cCr_B,   off_Y)
    0b00: ( 4211,  8258,  1606,  -2425, -4768,  7193,    7193, -6030, -1163,   16),  # Rec.601 limited
    0b01: ( 4899,  9617,  1868,  -2770, -5422,  8192,    8192, -6865, -1327,    0),  # Rec.601 full
    0b10: ( 2998, 10060,  1016,  -1655, -5555,  7193,    7193, -6537,  -656,   16),  # Rec.709 limited
    0b11: ( 3484, 11718,  1183,  -1878, -6315,  8192,    8192, -7442,  -750,    0),  # Rec.709 full
}


def clamp8(x):
    return max(0, min(255, x))


def arith_shift_right(x, n):
    """Arithmetic right shift (Python's >> already does this for signed)."""
    return x >> n


def convert(rgb, mode):
    r, g, b = rgb
    if not (0 <= r <= 255 and 0 <= g <= 255 and 0 <= b <= 255):
        raise ValueError(f"out of range RGB: {rgb}")
    if mode not in COEFS:
        raise ValueError(f"unknown mode: {mode}")

    cyr, cyg, cyb, ccbr, ccbg, ccbb, ccrr, ccrg, ccrb, oy = COEFS[mode]

    # HDL multiplies as 16-bit signed × 9-bit signed → 25-bit signed product,
    # sums three → 27-bit signed, then >>14 → 13-bit signed.
    y_sum  = cyr * r  + cyg * g  + cyb * b
    cb_sum = ccbr * r + ccbg * g + ccbb * b
    cr_sum = ccrr * r + ccrg * g + ccrb * b

    y_shift  = arith_shift_right(y_sum, 14)
    cb_shift = arith_shift_right(cb_sum, 14)
    cr_shift = arith_shift_right(cr_sum, 14)

    y  = clamp8(y_shift  + oy)
    cb = clamp8(cb_shift + 128)
    cr = clamp8(cr_shift + 128)

    return (y, cb, cr)


def demo():
    for mode, name in [(0, "Rec.601 limited"), (1, "Rec.601 full"),
                       (2, "Rec.709 limited"), (3, "Rec.709 full")]:
        print(f"\nMode {mode:02b} ({name}):")
        for label, rgb in [
            ("black",     (0, 0, 0)),
            ("white",     (255, 255, 255)),
            ("red",       (255, 0, 0)),
            ("green",     (0, 255, 0)),
            ("blue",      (0, 0, 255)),
            ("gray128",   (128, 128, 128)),
            ("warm-tan",  (200, 150, 100)),
        ]:
            ycc = convert(rgb, mode)
            print(f"  {label:9s} RGB={rgb}  →  YCbCr={ycc}")


if __name__ == "__main__":
    demo()
