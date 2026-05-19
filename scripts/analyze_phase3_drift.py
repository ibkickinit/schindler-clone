#!/usr/bin/env python3
"""analyze_phase3_drift.py — parse Phase 3 drift capture, fit linear slope.

Input: UART log containing one or more phase3_capture blocks:
    # phase3_capture N=3000 base_out_count=<x>
    idx,out_count,ts_out_lo32,ts_out_hi16,ref_count,ts_ref_lo32,ts_ref_hi16
    0,...
    ...
    # phase3_capture done N=3000

Output:
- Clean CSV with phase_delta column
- Linear fit: phase_delta vs out_count (relative)
- Slope converted to ppm
- R²
- Pass/fail verdict per Phase 3 §4 criterion: R² ≥ 0.99, magnitude per spec

Pure-Python (no numpy).

Conventions:
- phase_delta = ts_out - ts_ref, mod 2^48, sign-extended to 64-bit signed.
- x-axis = out_count - base_out_count (1 unit = 1 output frame).
- Positive slope = output running FASTER than reference.
- ppm = slope_ticks_per_frame × output_frame_rate / counter_freq × 1e6.
  At 50 Hz / 100 MHz counter: ppm = slope × 50 / 100e6 × 1e6 = slope × 0.5.
"""

import sys
import re
import math
from pathlib import Path


COUNTER_FREQ = 100_000_000   # FCLK_CLK0, 100 MHz
OUTPUT_RATE  = 50            # 720p50 vsync rate


def parse_captures(lines):
    """Return list of (base_out_count, rows) for each phase3_capture block found.
    Each block is processed independently; the caller picks which to fit."""
    blocks = []
    current_rows = None
    current_base = None
    for line in lines:
        line = line.strip()
        m_hdr = re.match(r"# phase3_capture N=(\d+) base_out_count=(\d+)", line)
        if m_hdr:
            if current_rows is not None:
                # Previous block ended without a "done" marker — save anyway.
                blocks.append((current_base, current_rows))
            current_rows = []
            current_base = int(m_hdr.group(2))
            continue
        if line.startswith("# phase3_capture done"):
            if current_rows is not None:
                blocks.append((current_base, current_rows))
                current_rows = None
                current_base = None
            continue
        if current_rows is None:
            continue
        if line.startswith("idx,"):
            continue
        m = re.match(r"(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)$", line)
        if m:
            idx        = int(m.group(1))
            out_count  = int(m.group(2))
            ts_out_lo  = int(m.group(3))
            ts_out_hi  = int(m.group(4))
            ref_count  = int(m.group(5))
            ts_ref_lo  = int(m.group(6))
            ts_ref_hi  = int(m.group(7))
            ts_out = (ts_out_hi << 32) | ts_out_lo
            ts_ref = (ts_ref_hi << 32) | ts_ref_lo
            current_rows.append({
                "idx":       idx,
                "out_count": out_count,
                "ts_out":    ts_out,
                "ref_count": ref_count,
                "ts_ref":    ts_ref,
            })
    # Catch a still-open block at EOF.
    if current_rows is not None and current_rows:
        blocks.append((current_base, current_rows))
    return blocks


def parse_capture(lines):
    """Back-compat shim: return (rows_from_largest_block, its_base_out_count)."""
    blocks = parse_captures(lines)
    if not blocks:
        return ([], None)
    # Pick the longest block — typical bench runs do a short sanity capture
    # (R, 300 samples) followed by the production capture (r, 3000 samples);
    # we want the 3000-sample fit.
    blocks.sort(key=lambda b: len(b[1]), reverse=True)
    return (blocks[0][1], blocks[0][0])


def signed_48(u):
    """Sign-extend a 48-bit unsigned value to Python's arbitrary-precision int."""
    u &= (1 << 48) - 1
    if u & (1 << 47):
        return u - (1 << 48)
    return u


def linreg(xs, ys):
    """Least-squares fit y = m*x + b. Returns (slope, intercept, r_squared).
    Pure-Python; xs and ys are equal-length numeric sequences."""
    n = len(xs)
    if n < 2:
        return (0.0, 0.0, 0.0)
    mean_x = sum(xs) / n
    mean_y = sum(ys) / n
    s_xx = sum((x - mean_x) ** 2 for x in xs)
    s_xy = sum((xs[i] - mean_x) * (ys[i] - mean_y) for i in range(n))
    if s_xx == 0:
        return (0.0, mean_y, 0.0)
    slope = s_xy / s_xx
    intercept = mean_y - slope * mean_x
    s_yy = sum((y - mean_y) ** 2 for y in ys)
    if s_yy == 0:
        r2 = 1.0
    else:
        r2 = (s_xy ** 2) / (s_xx * s_yy)
    return (slope, intercept, r2)


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_phase3_drift.py <uart_log> [<out_csv>]")
        sys.exit(2)
    inp = Path(sys.argv[1])
    if not inp.exists():
        print(f"ERROR: {inp} not found")
        sys.exit(2)

    lines = inp.read_text(errors="replace").splitlines()
    rows, base_oc = parse_capture(lines)
    if not rows:
        print("ERROR: no phase3 capture rows found")
        sys.exit(2)

    print(f"Phase 3 drift analysis ({inp})")
    print(f"  samples: {len(rows)} (base_out_count={base_oc})")

    # Build phase delta series.
    xs = []   # output frame index (out_count - base)
    ys = []   # ts_out - ts_ref, signed 48-bit
    first_dropped = 0
    for r in rows:
        if r["ref_count"] == 0:
            first_dropped += 1
            continue  # ref not yet running at this sample
        phase = signed_48(r["ts_out"] - r["ts_ref"])
        xs.append(r["out_count"] - base_oc)
        ys.append(phase)
    if first_dropped:
        print(f"  dropped {first_dropped} samples taken before ref_count > 0")
    if len(xs) < 100:
        print(f"  WARNING: only {len(xs)} usable samples — fit may be noisy")

    slope, intercept, r2 = linreg(xs, ys)

    # ppm from slope (ticks per output frame).
    # ppm = slope * (output_rate / counter_freq) * 1e6 = slope * 50 / 1e8 * 1e6 = slope * 0.5
    ppm = slope * OUTPUT_RATE / COUNTER_FREQ * 1e6
    sign = "output faster than reference" if slope > 0 else "reference faster than output"

    print(f"")
    print(f"  linear fit: phase_delta(ticks) = {slope:.4f} * (out_count - base) + {intercept:.2f}")
    print(f"  R²                = {r2:.6f}")
    print(f"  slope             = {slope:+.4f} ticks/output_frame")
    print(f"  intercept (t=0)   = {intercept:+.2f} ticks ({intercept*10:+.1f} ns initial phase offset)")
    print(f"  ppm_relative      = {ppm:+.4f} ppm  ({sign})")

    # Residual stats (jitter around the fit line).
    residuals = [ys[i] - (slope * xs[i] + intercept) for i in range(len(xs))]
    max_abs = max(abs(r) for r in residuals)
    print(f"  residual max-abs  = {max_abs:.2f} ticks ({max_abs*10:.1f} ns)")

    # Phase 3 pass criteria:
    #   - single signed number      (yes — we have ppm)
    #   - R² ≥ 0.99                  per spec
    #   - "5–100 ppm typical" — relaxed per user (synthetic ref → sub-ppm
    #     expected by construction). Just print magnitude commentary.
    verdict_r2 = "PASS" if r2 >= 0.99 else "FAIL"
    print(f"")
    print(f"  pass (R² ≥ 0.99): {verdict_r2}")
    if abs(ppm) < 1.0:
        print(f"  magnitude: sub-ppm — consistent with shared-PS-PLL synthetic ref")
    elif abs(ppm) < 100:
        print(f"  magnitude: {abs(ppm):.1f} ppm — within MMCM ±500 ppm pull range")
    else:
        print(f"  magnitude: {abs(ppm):.1f} ppm — exceeds MMCM ±500 ppm pull range")

    if len(sys.argv) >= 3:
        out_csv = Path(sys.argv[2])
        with out_csv.open("w") as f:
            f.write("idx,out_count_rel,ts_out_48,ref_count,ts_ref_48,phase_delta,fit,residual\n")
            for i, r in enumerate(rows):
                if r["ref_count"] == 0:
                    continue
                ph = signed_48(r["ts_out"] - r["ts_ref"])
                x  = r["out_count"] - base_oc
                fit = slope * x + intercept
                f.write(f"{r['idx']},{x},{r['ts_out']},{r['ref_count']},{r['ts_ref']},{ph},{fit:.2f},{ph - fit:.2f}\n")
        print(f"  wrote: {out_csv}")


if __name__ == "__main__":
    main()
