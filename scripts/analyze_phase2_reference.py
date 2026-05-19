#!/usr/bin/env python3
"""analyze_phase2_reference.py — parse Phase 2 ts_ref capture CSV.

Input: UART log containing one or more capture blocks of the form:
    # phase2_capture N=1000 base_count=<x>
    idx,ref_count,ts_ref_lo32,ts_ref_hi16
    0,<count>,<lsb>,<msb>
    ...
    # phase2_capture done N=1000

Output:
- A clean CSV at <out_csv> containing idx, ts_ref_48b, period_ticks
- Stats: mean period, std dev, min/max period, peak-to-peak jitter
- Pass/fail per Phase 2 §4 criterion: jitter < 100 ticks across 100 captures

Pure-Python (no numpy) — runs in the bench environment as-is.
"""

import sys
import re
import math
from pathlib import Path


def parse_capture(lines):
    """Extract (idx, count, lsb, msb) rows from one capture block.
    Returns: list of (idx, count, ts48) tuples; empty if no data found."""
    rows = []
    in_block = False
    for line in lines:
        line = line.strip()
        if line.startswith("# phase2_capture") and "done" not in line:
            in_block = True
            continue
        if line.startswith("# phase2_capture done"):
            in_block = False
            continue
        if not in_block:
            continue
        if line.startswith("idx,"):
            continue  # header
        m = re.match(r"(\d+),(\d+),(\d+),(\d+)$", line)
        if m:
            idx = int(m.group(1))
            count = int(m.group(2))
            lsb = int(m.group(3))
            msb = int(m.group(4))
            ts48 = (msb << 32) | lsb
            rows.append((idx, count, ts48))
    return rows


def compute_stats(rows):
    if len(rows) < 2:
        return None
    ts = [r[2] for r in rows]
    periods = [ts[i] - ts[i - 1] for i in range(1, len(ts))]
    # Unwrap 48-bit wraps (counter wraps every ~32 days at 100 MHz; unlikely
    # in a 17 s capture but cheap to be safe).
    MASK48 = (1 << 48) - 1
    periods = [(p & MASK48) for p in periods]

    n = len(periods)
    mean = sum(periods) / n
    var = sum((p - mean) ** 2 for p in periods) / n
    stdev = math.sqrt(var)
    return {
        "n": n,
        "mean": mean,
        "stdev": stdev,
        "min": min(periods),
        "max": max(periods),
        "p2p": max(periods) - min(periods),
        "periods": periods,
    }


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_phase2_reference.py <uart_log> [<out_csv>]")
        sys.exit(2)
    inp = Path(sys.argv[1])
    if not inp.exists():
        print(f"ERROR: {inp} not found")
        sys.exit(2)

    lines = inp.read_text(errors="replace").splitlines()
    rows = parse_capture(lines)
    if not rows:
        print("ERROR: no capture rows found in input")
        sys.exit(2)

    stats = compute_stats(rows)
    n = stats["n"]
    print(f"Phase 2 reference capture analysis")
    print(f"  samples: {len(rows)} ({n} periods)")
    print(f"  period stats (counter ticks @ 10 ns/tick):")
    print(f"    mean    = {stats['mean']:>15.3f} ticks  =  {stats['mean']*10:>10.1f} ns  =  {1e9 / (stats['mean']*10):>8.4f} Hz")
    print(f"    stdev   = {stats['stdev']:>15.3f} ticks  =  {stats['stdev']*10:>10.1f} ns")
    print(f"    min     = {stats['min']:>15d} ticks  =  {stats['min']*10:>10.1f} ns")
    print(f"    max     = {stats['max']:>15d} ticks  =  {stats['max']*10:>10.1f} ns")
    print(f"    peak-to-peak = {stats['p2p']} ticks  =  {stats['p2p']*10} ns")

    # Phase 2 pass criterion: peak-to-peak < 100 ticks
    verdict = "PASS" if stats["p2p"] < 100 else "FAIL"
    print(f"  pass (p2p < 100 ticks): {verdict}")

    # Also show first/last 5 periods for sanity
    print(f"  first 5 periods: {stats['periods'][:5]}")
    print(f"  last  5 periods: {stats['periods'][-5:]}")

    if len(sys.argv) >= 3:
        out_csv = Path(sys.argv[2])
        with out_csv.open("w") as f:
            f.write("idx,ref_count,ts_ref_48b,period_ticks\n")
            for i, (idx, count, ts48) in enumerate(rows):
                period = stats["periods"][i - 1] if i > 0 else 0
                f.write(f"{idx},{count},{ts48},{period}\n")
        print(f"  wrote: {out_csv}")


if __name__ == "__main__":
    main()
