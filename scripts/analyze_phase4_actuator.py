#!/usr/bin/env python3
"""analyze_phase4_actuator.py — extract per-block drift slope for Phase 4.

Input: UART log with multiple `# phase3_capture` blocks interspersed with
`[M] requested <ppm>` lines. For each capture block, fits a slope and reports
ppm_relative. Prints a summary table mapping commanded → measured ppm.

Usage: analyze_phase4_actuator.py <uart_log>
"""

import sys
import re
from pathlib import Path

# Import the shared linreg + parser helpers from the Phase 3 analyzer.
sys.path.insert(0, str(Path(__file__).parent))
from analyze_phase3_drift import parse_captures, linreg, signed_48, OUTPUT_RATE, COUNTER_FREQ


def main():
    if len(sys.argv) < 2:
        print("usage: analyze_phase4_actuator.py <uart_log>")
        sys.exit(2)
    inp = Path(sys.argv[1])
    lines = inp.read_text(errors="replace").splitlines()

    # Walk the file capturing (M-command, ppm) markers and (capture block) pairs
    # in document order. The Mth capture block belongs to the most recent
    # commanded ppm before it.
    events = []   # list of dicts: {"kind": "m" | "capture", "ppm": x or rows: list}
    blocks = parse_captures(lines)

    # Parse M-lines in original order.
    re_m = re.compile(r"\[M\] requested (-?\d+) ppm")
    last_m_ppm = None
    # We need event ordering. Easiest: re-scan the file once tracking the
    # most recent m-command, and assigning it to each capture block.
    cmds_in_order = []   # list of either ("m", ppm) or ("capture", block_index)
    block_idx = 0
    inside_block = False
    for line in lines:
        line = line.rstrip()
        m = re_m.search(line)
        if m:
            cmds_in_order.append(("m", int(m.group(1))))
            continue
        if line.startswith("# phase3_capture N="):
            inside_block = True
            continue
        if line.startswith("# phase3_capture done"):
            if inside_block:
                cmds_in_order.append(("capture", block_idx))
                block_idx += 1
                inside_block = False

    # Associate each capture with the most recent m-command (or None if no m
    # was issued before it = boot baseline).
    print(f"Phase 4 actuator analysis ({inp})")
    print(f"  blocks: {len(blocks)}")
    print()
    print(f"{'idx':>3}  {'commanded':>10}  {'samples':>7}  {'slope':>12}  {'ppm':>10}  {'R²':>8}  {'residual_max':>12}")
    print(f"{'-'*3:>3}  {'-'*10:>10}  {'-'*7:>7}  {'-'*12:>12}  {'-'*10:>10}  {'-'*8:>8}  {'-'*12:>12}")
    last_m = None
    results = []
    for event in cmds_in_order:
        if event[0] == "m":
            last_m = event[1]
        elif event[0] == "capture":
            base_oc, rows = blocks[event[1]]
            xs, ys = [], []
            for r in rows:
                if r["ref_count"] == 0:
                    continue
                xs.append(r["out_count"] - base_oc)
                ys.append(signed_48(r["ts_out"] - r["ts_ref"]))
            slope, intercept, r2 = linreg(xs, ys)
            ppm = slope * OUTPUT_RATE / COUNTER_FREQ * 1e6
            residuals = [ys[i] - (slope * xs[i] + intercept) for i in range(len(xs))]
            res_max = max(abs(rv) for rv in residuals)
            cmd_label = "boot" if last_m is None else f"{last_m:+d} ppm"
            print(f"{event[1]:>3}  {cmd_label:>10}  {len(xs):>7}  {slope:>+12.4f}  {ppm:>+10.4f}  {r2:>8.6f}  {res_max:>12.2f}")
            results.append({
                "cmd_ppm": last_m,
                "measured_ppm": ppm,
                "samples": len(xs),
                "r2": r2,
            })

    print()
    print("Calibration check (commanded vs measured ppm shift relative to boot):")
    if results and results[0]["cmd_ppm"] is None:
        baseline = results[0]["measured_ppm"]
        print(f"  baseline (no nudge): {baseline:+.4f} ppm")
    else:
        baseline = 0.0
        print(f"  no boot-baseline capture found; using 0 ppm baseline")
    for r in results:
        if r["cmd_ppm"] is None:
            continue
        cmd = r["cmd_ppm"]
        meas = r["measured_ppm"]
        shift = meas - baseline
        # Pass criterion per ground-up plan §4 Phase 4: drift moves by commanded
        # amount within ±20%. With sign convention possibly inverted in HDL,
        # compare both signed and abs-shift.
        ratio_signed = shift / cmd if cmd != 0 else float('inf')
        verdict = ""
        if cmd == 0:
            ok = abs(shift) < 5.0
            verdict = "PASS (≤5 ppm zero)" if ok else "FAIL (zero command shift)"
        else:
            ok = 0.8 <= abs(ratio_signed) <= 1.2
            sign_match = (ratio_signed > 0)
            verdict = "PASS" if ok else "FAIL"
            if ok and not sign_match:
                verdict += " (sign inverted)"
        print(f"  cmd {cmd:+5d} ppm  →  measured {meas:+8.4f} ppm  (shift {shift:+8.4f} ppm, ratio {ratio_signed:+.4f})  {verdict}")


if __name__ == "__main__":
    main()
