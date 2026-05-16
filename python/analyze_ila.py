#!/usr/bin/env python3
"""
analyze_ila.py — diff multiple ILA captures to localize per-frame variation.

Phase D iter-3n diagnostic. Reads ILA CSVs from
build/ila-capture/iter3n/{scaler,mm2s}-N.csv (N = 1..5) and reports:
  - Whether scaler_out pixel values are identical across captures (= scaler MAC is stable)
  - Whether mm2s_out pixel values are identical across captures (= MM2S delivery is stable)
  - Per-sample frame-to-frame difference at key columns

ILA CSV columns (Vivado's write_hw_ila_data format):
  Sample in Window, Sample in Buffer, TRIGGER, <probe_name>, ...
  Probe data is hex like '0xRRGGBB' for tdata, '0x1'/'0x0' for single-bit.

Usage:
  python3 python/analyze_ila.py
"""

import csv
import glob
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DIR  = REPO / "build" / "ila-capture" / "iter3n"


def parse_csv(path):
    """Return list of dict rows with hex values converted to int."""
    rows = []
    with open(path) as f:
        rdr = csv.DictReader(f)
        for r in rdr:
            cleaned = {}
            for k, v in r.items():
                if v is None or v == "":
                    cleaned[k] = None
                elif v.startswith("0x") or v.startswith("0X"):
                    try:
                        cleaned[k] = int(v, 16)
                    except ValueError:
                        cleaned[k] = v
                elif v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
                    cleaned[k] = int(v)
                else:
                    cleaned[k] = v
            rows.append(cleaned)
    return rows


def diff_captures(prefix):
    """Compare all scaler-N or mm2s-N captures."""
    files = sorted(glob.glob(str(DIR / f"{prefix}-*.csv")))
    if not files:
        print(f"No {prefix}-*.csv files in {DIR}")
        return
    print(f"\n=== {prefix.upper()} ===")
    captures = [parse_csv(f) for f in files]
    print(f"Loaded {len(captures)} captures from {[Path(f).name for f in files]}")
    if not captures:
        return

    # Identify probe column for tdata (the wide one with hex values)
    headers = [k for k in captures[0][0].keys() if k]
    tdata_col = None
    for h in headers:
        if "tdata" in h.lower():
            tdata_col = h; break
    if not tdata_col:
        print(f"  no tdata column found; headers: {headers}")
        return
    print(f"  tdata probe column: {tdata_col}")

    # Compare each sample index across captures
    n_samples = min(len(c) for c in captures)
    diff_count = 0
    diff_positions = []
    for i in range(n_samples):
        vals = [c[i].get(tdata_col) for c in captures]
        if len(set(vals)) > 1:
            diff_count += 1
            if len(diff_positions) < 20:
                diff_positions.append((i, vals))
    pct = 100.0 * diff_count / n_samples if n_samples else 0
    print(f"  {diff_count}/{n_samples} samples differ across captures ({pct:.2f}%)")
    if diff_count > 0:
        print(f"  First 20 differing samples:")
        for idx, vals in diff_positions:
            hex_vals = [f"0x{v:06x}" if isinstance(v, int) else str(v) for v in vals]
            print(f"    sample {idx:4}: {'  '.join(hex_vals)}")

    # Also: spread per-channel for first ~50 samples (to see edge structure)
    print(f"  First 30 samples (capture 1):")
    for i in range(min(30, n_samples)):
        v = captures[0][i].get(tdata_col)
        if isinstance(v, int):
            r = (v >> 16) & 0xFF
            g = (v >>  8) & 0xFF
            b = (v >>  0) & 0xFF
            print(f"    s={i:3}: 0x{v:06x}  R={r:3} G={g:3} B={b:3}")


def main():
    if not DIR.exists():
        print(f"ERROR: capture directory {DIR} not found")
        print(f"Run tcl/ila_capture.tcl first")
        sys.exit(1)
    diff_captures("scaler")
    diff_captures("mm2s")
    print("\nInterpretation:")
    print("  - 0% diff at scaler  + 0% diff at mm2s   → pipeline is stable; specks are display-side")
    print("  - 0% diff at scaler  + N% diff at mm2s   → VDMA / DDR3 / CDC introduces variation")
    print("  - N% diff at scaler  + similar at mm2s   → scaler input or scaler-internal varies (dvi2rgb jitter)")


if __name__ == "__main__":
    main()
