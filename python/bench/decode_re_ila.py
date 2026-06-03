#!/usr/bin/env python3
"""Decode the 192-bit ila_re_dbg probe0 capture (build #14) and root-cause the
prefetch/residency coherency stall.

Usage: python3 decode_re_ila.py [/tmp/ila_dbg.csv]

probe0[191:0] bit layout (must match hdl/pg_read_engine_top.v build #14):
  [11:0] src_col  [23:12] src_row  [35:24] rd_row(read)  [47:36] pf_src
  [59:48] pf_next_k [71:60] served  [75:72] fill_sel(4)  [79:76] rd_sel(4)
  [80] a_valid [81] inwin [82] newrow [83] resident [84] m3_busy [85] pf_req
  [86] have_row [87] push_en [88] up_pvalid [89] up_plast [90] m_tvalid [91] m_tready
  [119:96] rd_data  [143:120] up_pdata  [167:144] push_data
"""
import csv, sys
from collections import Counter

f = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ila_dbg.csv"
def b(v, lo, w): return (v >> lo) & ((1 << w) - 1)

rows = []
with open(f) as fh:
    r = csv.reader(fh); hdr = next(r); next(r)
    pi = [i for i, h in enumerate(hdr) if "probe0" in h][0]
    for ln in r:
        try: rows.append(int(ln[pi], 16))
        except (ValueError, IndexError): pass

def dec(v): return dict(
    src_col=b(v,0,12), src_row=b(v,12,12), rd_row=b(v,24,12), pf_src=b(v,36,12),
    pf_next_k=b(v,48,12), served=b(v,60,12), fill_sel=b(v,72,4), rd_sel=b(v,76,4),
    a_valid=b(v,80,1), inwin=b(v,81,1), newrow=b(v,82,1), resident=b(v,83,1),
    m3_busy=b(v,84,1), pf_req=b(v,85,1), have_row=b(v,86,1), push_en=b(v,87,1),
    up_pvalid=b(v,88,1), up_plast=b(v,89,1), mtv=b(v,90,1), mtr=b(v,91,1),
    rd=b(v,96,24), up=b(v,120,24), push=b(v,144,24))

av = [dec(v) for v in rows]
print(f"samples={len(av)}")

def runs(pred):
    out=[]; s=None
    for i,d in enumerate(av):
        if pred(d): s = i if s is None else s
        else:
            if s is not None: out.append((s,i-s)); s=None
    if s is not None: out.append((s,len(av)-s))
    return out
def top(rs,n=4): return sorted(rs,key=lambda x:-x[1])[:n]

starv = runs(lambda d: d['mtr'] and not d['mtv'])
nores = runs(lambda d: d['inwin'] and not d['resident'])
noav  = runs(lambda d: not d['a_valid'])
print(f"STARVATION (mtr&!mtv): n={len(starv)} total={sum(l for _,l in starv)} top={top(starv)}")
print(f"resident==0 (inwin):   n={len(nores)} total={sum(l for _,l in nores)} top={top(nores)}")
print(f"a_valid==0:            n={len(noav)} total={sum(l for _,l in noav)} top={top(noav)}")

# ---- prefetch state at the residency-loss onset (the mechanism discriminator) ----
if nores:
    s0,l0 = top(nores,1)[0]
    print(f"\n== PREFETCH STATE around residency-loss onset s{s0} (len {l0}) ==")
    print("  (rd_row = row being READ; pf_src = row prefetch is FETCHING; if they never align => V-DDA divergence;")
    print("   fill_sel==rd_sel while filling => recycle lap; pf_next_k<=served & m3_busy => prefetch-behind)")
    for i in range(max(0,s0-6), min(len(av), s0+l0+6)):
        d=av[i]
        print(f"  s{i:4d} rd_row={d['rd_row']:4d} pf_src={d['pf_src']:4d} pf_k={d['pf_next_k']:4d} "
              f"served={d['served']:4d} fill={d['fill_sel']} rdsel={d['rd_sel']} "
              f"res={d['resident']} busy={d['m3_busy']} pfreq={d['pf_req']} have={d['have_row']} "
              f"av={d['a_valid']} mtv={d['mtv']} mtr={d['mtr']} rd={d['rd']:06x} push={d['push']:06x}")
    # which rows did prefetch fetch in the whole window? did rd_row ever appear?
    pf_rows=set(d['pf_src'] for d in av if d['pf_req'])
    rd_rows=set(d['rd_row'] for d in av if d['inwin'])
    print(f"\n  pf_src rows requested (pf_req): {sorted(pf_rows)}")
    print(f"  rd_row rows demanded (inwin):   {sorted(rd_rows)}")
    miss=sorted(r for r in rd_rows if r not in pf_rows)
    print(f"  rd_rows NOT in pf requests (=> divergence if nonempty, but window may be short): {miss}")

# ---- histograms gated on actually-pushed pixels (reviewer's discriminator) ----
print("\n-- push_data histogram (when push_en) --")
for val,n in Counter(d['push'] for d in av if d['push_en']).most_common(10): print(f"  {val:06x}: {n}")
