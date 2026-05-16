#!/usr/bin/env python3
"""
analyze_capture.py — Quantify vsync alignment and edge sharpness from MS2109
captures of the Schindler bench output.

Two measurements:

1. **Q-square Y position** — locates the centroid of the bright "Q" patch
   that the ImagePro test pattern places in the lower-left of the frame.
   Use this to compare alignment across reboots. Stable Q-Y across boots
   = deterministic vsync alignment.

2. **Edge sharpness at a chosen bar boundary** — samples a horizontal slice
   across a known color-bar transition (e.g. green→magenta) and reports the
   rise distance in pixels (10%-90% of the transition amplitude). Sharper
   filter = shorter rise distance and less ringing.

Stdlib + Pillow only. Run from repo root:
   python3 python/analyze_capture.py build/ila-capture/phase-d/iter3*.jpg
"""

import argparse
import sys
from pathlib import Path
from PIL import Image


def find_q_y(img):
    """Locate the bright Q square's vertical center. The Q is at the LEFT
    third of the frame in the ImagePro test pattern. Sample column at x=w/4
    for rows containing R,G,B > 220 (near-white)."""
    w, h = img.size
    col_x = w // 4
    white_rows = []
    for y in range(0, h, 2):
        r, g, b = img.getpixel((col_x, y))
        if r > 220 and g > 220 and b > 220:
            white_rows.append(y)
    if not white_rows:
        return None
    return (min(white_rows) + max(white_rows)) // 2


def find_color_bar_x(img, y, target_a, target_b):
    """Find the x position of a color transition from target_a to target_b
    on the row y. Returns (x_a_pixels, x_b_pixels, x_transition)."""
    w, _ = img.size
    def _close(p, t, tol=40):
        return all(abs(p[i] - t[i]) < tol for i in range(3))
    x_a = None; x_b = None
    for x in range(w):
        p = img.getpixel((x, y))
        if _close(p, target_a):
            x_a = x
        elif x_a is not None and _close(p, target_b):
            x_b = x
            break
    if x_a is None or x_b is None:
        return None
    return (x_a, x_b)


def edge_transition_width(img, y, center_x, half_window=20, channel=0):
    """Measure the 10%-90% transition width in pixels around an edge.
    Samples a horizontal slice of width 2*half_window around center_x at row y,
    finds min/max for the given channel, returns the distance between 10% and
    90% crossings as the 'rise width'.
    Lower = sharper edge, less filter blur."""
    w, _ = img.size
    x0 = max(0, center_x - half_window)
    x1 = min(w, center_x + half_window)
    vals = [img.getpixel((x, y))[channel] for x in range(x0, x1)]
    vmin = min(vals)
    vmax = max(vals)
    if vmax - vmin < 20:
        return None
    threshold_lo = vmin + 0.1 * (vmax - vmin)
    threshold_hi = vmin + 0.9 * (vmax - vmin)
    # Find first lo crossing
    x_lo = x_hi = None
    rising = vals[-1] > vals[0]
    for i, v in enumerate(vals):
        if rising:
            if v >= threshold_lo and x_lo is None:
                x_lo = x0 + i
            if v >= threshold_hi:
                x_hi = x0 + i
                break
        else:
            if v <= threshold_hi and x_lo is None:
                x_lo = x0 + i
            if v <= threshold_lo:
                x_hi = x0 + i
                break
    if x_lo is None or x_hi is None:
        return None
    return abs(x_hi - x_lo)


def overshoot_pct(img, y, center_x, half_window=40, channel=0):
    """Measure overshoot/undershoot at an edge: percent excursion past the
    nominal high/low values, indicative of ringing.
    Higher = more ringing (Lanczos sidelobes etc.)"""
    w, _ = img.size
    x0 = max(0, center_x - half_window)
    x1 = min(w, center_x + half_window)
    vals = [img.getpixel((x, y))[channel] for x in range(x0, x1)]
    # Find local min/max in the window
    vmin = min(vals)
    vmax = max(vals)
    # Nominal values: use the values at the window extremes (well past the edge)
    left_nom = sum(vals[:5]) / 5
    right_nom = sum(vals[-5:]) / 5
    nom_lo = min(left_nom, right_nom)
    nom_hi = max(left_nom, right_nom)
    nom_amp = nom_hi - nom_lo
    if nom_amp < 20:
        return None
    over = max(vmax - nom_hi, 0)
    under = max(nom_lo - vmin, 0)
    return 100.0 * (over + under) / nom_amp


def analyze(path):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    qy = find_q_y(img)

    # Sample a row in the top-half color bars to measure edge transitions.
    # 100% color bars in ImagePro test pattern (left-to-right):
    #   gray, yellow, cyan, green, magenta, red, blue, black
    # Transitions of interest:
    #   green->magenta (sharp R/G channel inversion, opposite hue)
    #   blue->black (lum drop, channel B falls)
    # Sample at y = h/4 (well into the color-bar band)
    sample_y = h // 4

    # Find green->magenta x by scanning
    gm = find_color_bar_x(img, sample_y, (0, 220, 0), (220, 0, 220))
    bb = find_color_bar_x(img, sample_y, (0, 0, 220), (10, 10, 10))

    result = {"path": path, "size": (w, h), "qy": qy, "sample_y": sample_y}

    if gm:
        # green-to-magenta center is between gm[0] and gm[1]
        edge_x = (gm[0] + gm[1]) // 2
        # On this edge: R rises (0→220), G falls (220→0). Measure both.
        result["gm_x"] = edge_x
        result["gm_R_rise_px"] = edge_transition_width(img, sample_y, edge_x, channel=0)
        result["gm_G_fall_px"] = edge_transition_width(img, sample_y, edge_x, channel=1)
        result["gm_R_overshoot_pct"] = overshoot_pct(img, sample_y, edge_x, channel=0)
        result["gm_G_overshoot_pct"] = overshoot_pct(img, sample_y, edge_x, channel=1)

    if bb:
        edge_x = (bb[0] + bb[1]) // 2
        result["bb_x"] = edge_x
        # On blue→black edge: B falls (220→0). R and G stay near 0.
        result["bb_B_fall_px"] = edge_transition_width(img, sample_y, edge_x, channel=2)
        result["bb_B_overshoot_pct"] = overshoot_pct(img, sample_y, edge_x, channel=2)

    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", type=Path)
    args = ap.parse_args()

    print(f"{'File':<55} {'Q-y':>5}  {'gm-Rrise':>9} {'gm-Gfall':>9} {'gm-Rover%':>9} {'gm-Gover%':>9}  {'bb-Bfall':>9} {'bb-Bover%':>9}")
    print("-" * 130)
    qy_values = []
    for p in args.paths:
        r = analyze(p)
        qy = r.get("qy")
        if qy is not None:
            qy_values.append(qy)
        gm_R = r.get("gm_R_rise_px")
        gm_G = r.get("gm_G_fall_px")
        gm_Ro = r.get("gm_R_overshoot_pct")
        gm_Go = r.get("gm_G_overshoot_pct")
        bb_B = r.get("bb_B_fall_px")
        bb_Bo = r.get("bb_B_overshoot_pct")

        def fmt(v, places=1):
            if v is None: return "  --"
            if isinstance(v, float): return f"{v:.{places}f}"
            return str(v)
        print(f"{p.name:<55} {fmt(qy):>5}  {fmt(gm_R):>9} {fmt(gm_G):>9} {fmt(gm_Ro):>9} {fmt(gm_Go):>9}  {fmt(bb_B):>9} {fmt(bb_Bo):>9}")

    if len(qy_values) > 1:
        print()
        print(f"Q-y spread across {len(qy_values)} captures: min={min(qy_values)} max={max(qy_values)} range={max(qy_values)-min(qy_values)}")
        if max(qy_values) - min(qy_values) <= 2:
            print("  -> DETERMINISTIC alignment ✓")
        elif max(qy_values) - min(qy_values) <= 20:
            print("  -> SUB-PIXEL or near-deterministic alignment")
        else:
            print("  -> NON-DETERMINISTIC alignment (coin-flip remaining)")


if __name__ == "__main__":
    main()
