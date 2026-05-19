#!/usr/bin/env python3
"""analyze_phase5_plant.py — fit MMCM plant gain across a multi-point sweep.

For each capture block in the UART log, finds the most-recent commanded ppm
from a preceding `[M] requested <ppm>` line, fits drift slope → measured ppm,
then computes a meta-regression of measured ppm vs commanded ppm. Reports
slope, intercept, R² + Phase 5 pass verdict.

Pass per ground-up plan §4 Phase 5:
  - slope within 10% of 1.0   (i.e. 0.9 ≤ m ≤ 1.1)
  - intercept within ±5 ppm   (corresponds to Phase 3 baseline absorbed
                               in the constant)
  - R² ≥ 0.99

Note: the "boot" capture before any `m` command is excluded from the meta-fit
(no commanded ppm associated). The `M` (zero) capture is included with
cmd=0, which is useful because it anchors the intercept.

Usage: analyze_phase5_plant.py <uart_log> [<out_csv>]
"""

import sys
import re
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from analyze_phase3_drift import parse_captures, linreg, signed_48, OUTPUT_RATE, COUNTER_FREQ


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_phase5_plant.py <uart_log> [<out_csv>]")
        sys.exit(2)
    inp = Path(sys.argv[1])
    lines = inp.read_text(errors="replace").splitlines()
    blocks = parse_captures(lines)

    # Walk events in order, pairing each capture with the most-recent m-command.
    re_m = re.compile(r"\[M\] requested (-?\d+) ppm")
    points = []   # list of (cmd_ppm, measured_ppm, slope, r2_of_block, samples)
    last_m = None
    block_idx = 0
    inside = False
    for line in lines:
        m = re_m.search(line)
        if m:
            last_m = int(m.group(1))
            continue
        if line.startswith("# phase3_capture N="):
            inside = True
        elif line.startswith("# phase3_capture done"):
            if inside:
                base_oc, rows = blocks[block_idx]
                xs, ys = [], []
                for r in rows:
                    if r["ref_count"] == 0:
                        continue
                    xs.append(r["out_count"] - base_oc)
                    ys.append(signed_48(r["ts_out"] - r["ts_ref"]))
                slope, intercept, r2 = linreg(xs, ys)
                meas_ppm = slope * OUTPUT_RATE / COUNTER_FREQ * 1e6
                points.append({
                    "block_idx": block_idx,
                    "cmd_ppm":    last_m,
                    "meas_ppm":   meas_ppm,
                    "slope_ticks_per_frame": slope,
                    "r2_block":   r2,
                    "samples":    len(xs),
                })
                block_idx += 1
                inside = False

    if not points:
        print("ERROR: no phase3 capture blocks found")
        sys.exit(2)

    print(f"Phase 5 plant characterization ({inp})")
    print(f"  total capture blocks: {len(points)}")
    print()
    print(f"{'blk':>3}  {'cmd':>6}  {'measured ppm':>12}  {'slope (ticks/frame)':>20}  {'R²':>10}  {'samples':>7}")
    print(f"{'-'*3:>3}  {'-'*6:>6}  {'-'*12:>12}  {'-'*20:>20}  {'-'*10:>10}  {'-'*7:>7}")
    for p in points:
        cmd_label = "boot" if p["cmd_ppm"] is None else f"{p['cmd_ppm']:+d}"
        print(f"{p['block_idx']:>3}  {cmd_label:>6}  {p['meas_ppm']:>+12.4f}  {p['slope_ticks_per_frame']:>+20.4f}  {p['r2_block']:>10.6f}  {p['samples']:>7}")

    # Meta-regression: measured ppm vs commanded ppm. Exclude boot point.
    swept = [p for p in points if p["cmd_ppm"] is not None]
    if len(swept) < 3:
        print("\nNOT ENOUGH SWEEP POINTS for a meaningful meta-fit (need ≥3).")
        sys.exit(1)

    xs = [p["cmd_ppm"]  for p in swept]
    ys = [p["meas_ppm"] for p in swept]
    slope, intercept, r2 = linreg(xs, ys)
    print()
    print(f"Meta-regression (measured ppm = slope × commanded + intercept):")
    print(f"  N points    = {len(swept)}")
    print(f"  slope       = {slope:+.4f}")
    print(f"  intercept   = {intercept:+.4f} ppm")
    print(f"  R²          = {r2:.6f}")

    # Pass criteria per §4 Phase 5:
    ok_slope     = 0.9 <= slope <= 1.1
    ok_intercept = abs(intercept) <= 5.0
    ok_r2        = r2 >= 0.99
    print()
    print("Pass criteria (per ground-up plan §4 Phase 5):")
    print(f"  slope within 10% of 1.0      : {slope:+.4f}   {'PASS' if ok_slope else 'FAIL'}")
    print(f"  |intercept| ≤ 5 ppm          : {intercept:+.4f} ppm   {'PASS' if ok_intercept else 'FAIL — Phase 3 baseline shift remains'}")
    print(f"  R² ≥ 0.99                    : {r2:.6f}   {'PASS' if ok_r2 else 'FAIL'}")
    overall = ok_slope and ok_intercept and ok_r2
    print(f"  overall                      : {'PASS' if overall else 'FAIL (calibration needs work)'}")

    # Residuals around the meta-fit
    residuals = [ys[i] - (slope * xs[i] + intercept) for i in range(len(xs))]
    print(f"  residual max-abs             : {max(abs(r) for r in residuals):.3f} ppm")

    # Calibration advice for ACT_STEP_PER_PPM
    if abs(slope - 1.0) > 0.05:
        # If commanded N produces N*slope measured, then to make commanded N
        # produce N measured, multiply ACT_STEP_PER_PPM by 1/slope.
        old = 2_857_143
        new = int(round(old / slope))
        print()
        print(f"  Calibration suggestion: divide ACT_STEP_PER_PPM by current slope.")
        print(f"  Theoretical default = {old}.")
        print(f"  Empirical suggestion = {old} / {slope:.4f} = {new}")

    if len(sys.argv) >= 3:
        out_csv = Path(sys.argv[2])
        with out_csv.open("w") as f:
            f.write("cmd_ppm,meas_ppm,slope_ticks_per_frame,r2_block,samples\n")
            for p in swept:
                f.write(f"{p['cmd_ppm']},{p['meas_ppm']:.4f},{p['slope_ticks_per_frame']:.4f},{p['r2_block']:.6f},{p['samples']}\n")
        print(f"\n  wrote: {out_csv}")


if __name__ == "__main__":
    main()
