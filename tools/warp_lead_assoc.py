# Lead-AWARE associativity gate (reviewer caution): a deep prefetch lead extends every tile's live
# span backward (the prefetch fetches a tile LEAD output-px before the consumer's first access), which
# inflates per-set concurrent-live-tiles. worst-set-live<=4 WITHOUT the lead does NOT guarantee <=4 WITH
# it. This sweeps LEAD (in output px) on the REAL geometry (1280x720 <- 1920x1080) with the production
# mul13_7/128-set hash and reports worst-set-live per transform -> the LEAD ceiling for 4-way.
#
# Usage: python3 tools/warp_lead_assoc.py
import sys; sys.path.insert(0,'tools')
from warp_workingset import need_tiles
from collections import defaultdict

TILE=16; NSET=128
def setf(t):                       # production hash: (tx*13 + ty*7) & 127  (matches pg_tilecache_rt2)
    tx,ty=t; return (tx*13+ty*7)&(NSET-1)

XFORMS=[("rot20",dict(deg=20)),("rot45",dict(deg=45)),
        ("shrink1.5",dict(sxsc=1/1.5,sysc=1/1.5)),("aniso",dict(deg=30,sxsc=1/1.5))]
seqs={nm:need_tiles(TILE,**p) for nm,p in XFORMS}

def worst_live(seq, lead):
    # first/last consumer-access index per tile; prefetch shifts first earlier by `lead`
    first={}; last={}
    for i,ts in enumerate(seq):
        for t in ts:
            if t not in first: first[t]=i
            last[t]=i
    ev=defaultdict(list)
    for t in first:
        s=setf(t)
        ev[s].append((max(0,first[t]-lead),+1)); ev[s].append((last[t]+1,-1))
    worst=0
    for s,e in ev.items():
        e.sort(); cur=0
        for _,d in e:
            cur+=d
            if cur>worst: worst=cur
    return worst

LEADS=[0,1280,2560,5120,8192,12800,25600,51200]   # output-px of prefetch run-ahead
print(f"Real geometry 1280x720<-1920x1080, mul13_7/{NSET}set, 4 ways. worst-set-live vs LEAD (out-px):")
print(f"{'LEAD':>7} " + "".join(f"{nm:>11}" for nm,_ in XFORMS) + "   4-way?")
for lead in LEADS:
    w={nm:worst_live(seqs[nm],lead) for nm,_ in XFORMS}
    ok = max(w.values())<=4
    print(f"{lead:>7} " + "".join(f"{w[nm]:>11}" for nm,_ in XFORMS) + f"   {'OK' if ok else 'NEEDS >4 WAYS'}")
print("\nNote: the TB sweep (256x144<-384x216, 1/5 scale) passes real-time at LEAD=8192 TB-px (~32 rows).")
print("The scaled-equivalent real lead is what must sit under the 4-way ceiling above.")
