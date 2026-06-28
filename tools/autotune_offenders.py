#!/usr/bin/env python3
"""Rank corner-pin geometries by lead difficulty from the scan-all autotune CSV.
Filters to corner-only @100% (rot=0, invx=4096, pin=0,0). A lead is FULL only if every
scan row at that lead was FULL (min semantics). Ranks: wall > high lowest_full > eviction-edge.
Usage: autotune_offenders.py [csv] [topN]"""
import csv, sys
CSV  = sys.argv[1] if len(sys.argv) > 1 else "docs/autotune-leads.csv"
TOPN = int(sys.argv[2]) if len(sys.argv) > 2 else 8
COLS = ("tl_x","tl_y","tr_x","tr_y","br_x","br_y","bl_x","bl_y")
geom = {}
for r in csv.DictReader(open(CSV)):
    if r["rot"] != "0" or r["invx"] != "4096" or r["pin_x"] != "0" or r["pin_y"] != "0":
        continue
    key = tuple(int(r[c]) for c in COLS)
    geom.setdefault(key, {}).setdefault(int(r["lead"]), []).append(r["result"] == "FULL")
def analyze(leads):
    res = {L: all(v) for L, v in leads.items()}          # FULL iff every sample full
    al  = sorted(res)
    fl  = [L for L in al if res[L]]
    lowest_full = fl[0] if fl else None
    eviction = any((not res[L]) and any(res[L2] for L2 in al if L2 < L) for L in al)
    return lowest_full, fl, al, eviction
scored = []
for key, leads in geom.items():
    lf, fl, al, ev = analyze(leads)
    if lf is None:   rank = (3, 0)            # WALL: nothing reaches full
    elif ev:         rank = (2, -fl[-1])      # eviction: narrower window (lower top-full) = worse
    else:            rank = (1, lf)           # normal: higher lowest-full = worse
    scored.append((rank, key, lf, fl, al, ev))
scored.sort(key=lambda x: (-x[0][0], -x[0][1]))
print(f"# {len(geom)} corner-only @100% geometries analyzed")
nontrivial = [s for s in scored if s[0][0] > 1 or (s[2] and s[2] > 4096)]
print(f"# nontrivial (need >4096, eviction, or wall): {len(nontrivial)}")
print(f"{'TL':>10} {'TR':>10} {'BR':>10} {'BL':>10} | {'lowest_full':>11}  full_leads / eviction")
for (tier, sev), key, lf, fl, al, ev in scored[:TOPN]:
    tl,tr,br,bl = (f"{key[i]},{key[i+1]}" for i in (0,2,4,6))
    lfs = "WALL" if lf is None else str(lf)
    print(f"{tl:>10} {tr:>10} {br:>10} {bl:>10} | {lfs:>11}  {fl}{'  EVICT' if ev else ''}")
