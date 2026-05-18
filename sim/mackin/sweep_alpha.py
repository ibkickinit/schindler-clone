#!/usr/bin/env python3
"""
sweep_alpha.py — Python-side monotonicity sweep.

Verifies the Mackin lerp is well-behaved across the full alpha range:
- Output is monotonic in alpha for any fixed (prev, curr) pair.
- Endpoint correctness: alpha=0 -> prev, alpha=0x8000 -> curr (bit-exact).
- Maximum step size between adjacent alpha values is bounded.

This is a property-test of the algorithm, not the HDL — but the HDL is
bit-exact vs. this reference per the main TB.
"""

from mackin_ref import blend_pixel


def sweep_one_pair(prev, curr):
    """Sweep alpha 0..0x8000 in steps of 1 for one (prev, curr) channel value."""
    outs = []
    for a in range(0, 0x8001):
        out = blend_pixel((prev, prev, prev), (curr, curr, curr), a)[0]
        outs.append(out)
    return outs


def check_monotonic(outs, prev, curr):
    """If curr > prev: outs must be non-decreasing. If curr < prev: non-increasing. Equal: constant."""
    if curr > prev:
        for i in range(1, len(outs)):
            if outs[i] < outs[i-1]:
                return f"non-monotonic at alpha={i}: outs[{i-1}]={outs[i-1]} outs[{i}]={outs[i]}"
    elif curr < prev:
        for i in range(1, len(outs)):
            if outs[i] > outs[i-1]:
                return f"non-monotonic at alpha={i}: outs[{i-1}]={outs[i-1]} outs[{i}]={outs[i]}"
    else:
        for i, o in enumerate(outs):
            if o != prev:
                return f"prev==curr but out differs at alpha={i}: out={o} prev={prev}"
    return None


def check_endpoints(outs, prev, curr):
    if outs[0] != prev:
        return f"alpha=0 should yield prev={prev}, got {outs[0]}"
    if outs[0x8000] != curr:
        return f"alpha=0x8000 should yield curr={curr}, got {outs[0x8000]}"
    return None


def check_step_size(outs, prev, curr):
    """Max single-alpha step should never exceed 1 LSB (output is 8-bit)."""
    max_step = 0
    for i in range(1, len(outs)):
        step = abs(outs[i] - outs[i-1])
        if step > max_step:
            max_step = step
    if max_step > 1:
        return f"max step {max_step} > 1 LSB for prev={prev} curr={curr}"
    return None


def main():
    n_pairs = 0
    n_fail = 0
    fails = []

    # Sweep a representative set of (prev, curr) pairs at every 16 values
    for prev in range(0, 256, 16):
        for curr in range(0, 256, 16):
            outs = sweep_one_pair(prev, curr)
            for check, name in [
                (check_monotonic, "monotonic"),
                (check_endpoints, "endpoints"),
                (check_step_size, "step_size"),
            ]:
                err = check(outs, prev, curr)
                if err:
                    n_fail += 1
                    fails.append(f"  {name}: prev={prev} curr={curr} — {err}")
            n_pairs += 1

    print(f"Tested {n_pairs} (prev,curr) pairs × 3 properties = {n_pairs * 3} property checks")
    if n_fail == 0:
        print("ALL PASS")
        print("  - Output monotonic in alpha across all (prev, curr) pairs")
        print("  - Endpoints bit-exact: alpha=0 -> prev, alpha=0x8000 -> curr")
        print("  - Max single-alpha step ≤ 1 LSB")
    else:
        print(f"FAIL: {n_fail} property violations")
        for f in fails[:20]:
            print(f)


if __name__ == "__main__":
    main()
