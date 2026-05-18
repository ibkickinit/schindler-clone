#!/usr/bin/env python3
"""analyze_tpg_capture.py — check if a captured HDMI frame shows aligned TPG.

Expected TPG output (pattern 0 = bars + overlays):
  - 1-pixel MAGENTA border around full frame
  - Top-left 256x48 region: dark blue counter background + yellow digit cells
  - Rest: SMPTE 75% bars (7 vertical bars)

This script:
  1. Loads a JPEG (from gst capture).
  2. Checks for magenta border on all 4 sides.
  3. Checks for counter overlay at top-left.
  4. If counter is found at wrong vertical position, reports the offset.

Exit codes:
  0 = TPG output detected AND aligned
  1 = TPG output detected but vertically offset
  2 = TPG output NOT detected (MS2109 fallback or no signal)
"""

import sys
from PIL import Image


def is_magenta(rgb, tol=40):
    r, g, b = rgb
    return r > 200 - tol and g < 40 + tol and b > 200 - tol


def is_dark_blue(rgb, tol=30):
    r, g, b = rgb
    return r < 30 + tol and g < 30 + tol and 50 - tol < b < 110 + tol


def is_yellow(rgb, tol=40):
    r, g, b = rgb
    return r > 200 - tol and g > 200 - tol and b < 40 + tol


def check_border(img):
    """Check magenta border on all 4 sides. Returns count of magenta sides (0-4)."""
    w, h = img.size
    sides_found = 0
    samples = [
        ('top',    [(x, 0)         for x in range(0, w, w // 20)]),
        ('bot',    [(x, h - 1)     for x in range(0, w, w // 20)]),
        ('left',   [(0, y)         for y in range(0, h, h // 20)]),
        ('right',  [(w - 1, y)     for y in range(0, h, h // 20)]),
    ]
    side_results = {}
    for name, pts in samples:
        hits = sum(1 for p in pts if is_magenta(img.getpixel(p)))
        side_results[name] = (hits, len(pts))
        if hits >= len(pts) * 0.5:
            sides_found += 1
    return sides_found, side_results


def find_counter_overlay(img):
    """Search for the dark-blue counter background. Returns (top_row, bot_row, left_col, right_col)
    or None if not found. The overlay is 256x48 at (col=0, row=0) in the SOURCE 1920x1080.
    Scaled down 1.5x to 720p output: should be at top-left, ~170x32 px."""
    w, h = img.size
    # Scan a center column near col=80 (inside expected overlay) for dark blue
    col = 80 if w >= 200 else w // 4
    blue_rows = []
    for y in range(0, min(h, 100)):
        if is_dark_blue(img.getpixel((col, y))):
            blue_rows.append(y)
    if not blue_rows:
        # Try wider sweep
        for y in range(0, h):
            for x in range(0, w // 4, 10):
                if is_dark_blue(img.getpixel((x, y))):
                    blue_rows.append(y)
                    break
    if not blue_rows:
        return None
    return min(blue_rows), max(blue_rows)


def detect_ms2109_fallback(img):
    """The MS2109 fallback uses 8 bars with full saturation (255), no border, no overlay.
    My TPG has 7 bars at 75% (191) and a magenta border. If we see 100% saturation
    primary colors at frame edges with no border, it's the stick's fallback."""
    w, h = img.size
    # Check the very top-left and top-right corners. In MS2109 fallback,
    # top-left is WHITE (255,255,255). My TPG top-left is MAGENTA (border).
    tl = img.getpixel((0, 0))
    tr = img.getpixel((w - 1, 0))
    # MS2109 fallback: tl=white, tr=black
    is_fallback = (tl[0] > 200 and tl[1] > 200 and tl[2] > 200) and \
                  (tr[0] < 40 and tr[1] < 40 and tr[2] < 40)
    return is_fallback


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_tpg_capture.py <jpeg>")
        sys.exit(2)
    img = Image.open(sys.argv[1]).convert("RGB")
    w, h = img.size
    print(f"image: {w}x{h}")

    # MS2109 fallback check first (most likely failure mode)
    if detect_ms2109_fallback(img):
        print("VERDICT: MS2109 capture-stick fallback pattern (no signal from FPGA)")
        print("  tl={}, tr={}".format(img.getpixel((0, 0)), img.getpixel((w-1, 0))))
        sys.exit(2)

    # Check border
    sides, side_detail = check_border(img)
    print(f"magenta border sides: {sides}/4  details: {side_detail}")
    if sides < 3:
        print("VERDICT: TPG border not detected — possibly wrong source or output corrupted")
        sys.exit(2)

    # Check counter
    counter = find_counter_overlay(img)
    if counter is None:
        print("VERDICT: counter overlay not found — TPG might be wrong pattern or offset")
        sys.exit(1)
    top, bot = counter
    print(f"counter overlay rows: {top}..{bot}")

    # Expected: counter starts at row 1 (right under border), extends to ~32 (scaled from 48)
    # Allowing some tolerance.
    if top > 5:
        offset = top - 1
        # Estimate offset in source-resolution rows (1.5x for 1080->720)
        src_offset = int(offset * 1.5)
        print(f"VERDICT: TPG offset by ~{offset} output rows (~{src_offset} source rows)")
        sys.exit(1)
    print(f"VERDICT: TPG aligned correctly (counter at top edge, border present on {sides} sides)")
    sys.exit(0)


if __name__ == "__main__":
    main()
