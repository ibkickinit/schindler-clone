# Model-INDEPENDENT: per-set concurrent-live-tile count.
# A tile is "live" from first to last access (in consumer-pixel order). Within a set,
# the max number of tiles whose live-spans overlap = the associativity the set NEEDS.
# If that >> 4 ways, the 4-way cache thrashes regardless of fill rate.
import sys; sys.path.insert(0,'tools')
import math
from tilecache_realtime_gate import H_ACT,V_ACT,IN_W,IN_H
def need_tiles(TILE, sxsc=1.0,sysc=1.0,deg=0.0,shear=0.0):
    cxo,cyo=H_ACT/2.,V_ACT/2.; cxs,cys=IN_W/2.,IN_H/2.
    th=math.radians(deg); c,s=math.cos(th),math.sin(th)
    seq=[]
    for ay in range(V_ACT):
        dy=ay-cyo
        for ax in range(H_ACT):
            dx=ax-cxo; rx=c*dx+s*dy; ry=-s*dx+c*dy
            sx=cxs+rx/sxsc+shear*ry; sy=cys+ry/sysc
            if sx<0 or sy<0 or sx>=IN_W-1 or sy>=IN_H-1: seq.append(()); continue
            x0=int(sx); y0=int(sy); ts=set()
            for xx,yy in ((x0,y0),(x0+1,y0),(x0,y0+1),(x0+1,y0+1)):
                ts.add((xx//TILE, yy//TILE))
            seq.append(tuple(ts))
    return seq
def setf(t): tx,ty=t; return ((ty&7)<<3)|(tx&7)            # HDL index {ty[2:0],tx[2:0]}
def setf_hash(t): tx,ty=t; return (((ty&7)^((ty>>3)&7))<<3)|((tx&7)^((tx>>3)&7))
def setf_txonly(t): tx,ty=t; return tx&63                  # alt: 6 bits of tx

def max_overlap_per_set(seq, sf, NSET=64):
    # first/last access index per tile
    first={}; last={}
    for i,ts in enumerate(seq):
        for t in ts:
            if t not in first: first[t]=i
            last[t]=i
    # per set, sweep intervals -> max concurrent
    from collections import defaultdict
    ev=defaultdict(list)
    for t in first:
        s=sf(t); ev[s].append((first[t],+1)); ev[s].append((last[t]+1,-1))
    worst=0; worst_set=0; per=[0]*NSET; active_sets=0
    for s,e in ev.items():
        if e: active_sets+=1
        e.sort(); cur=0; mx=0
        for _,d in e: cur+=d; mx=max(mx,cur)
        per[s]=mx
        if mx>worst: worst=mx; worst_set=s
    return worst, active_sets, sorted(per,reverse=True)[:8]

TILE=16
for nm,p in [("rot20",dict(deg=20)),("rot45",dict(deg=45)),
             ("shrink 1.5x",dict(sxsc=1/1.5,sysc=1/1.5)),
             ("aniso rot30+1.5xH",dict(deg=30,sxsc=1/1.5))]:
    seq=need_tiles(TILE,**p)
    w,a,top=max_overlap_per_set(seq,setf)
    wh,ah,_=max_overlap_per_set(seq,setf_hash)
    wt,at,_=max_overlap_per_set(seq,setf_txonly)
    print(f"{nm:<20} HDL-index: worst-set-live={w:>3} (need {w}-way; have 4)  active_sets={a:>2}/64  top8={top}")
    print(f"{'':<20}   hashed-index worst={wh:<3}  tx-only-index worst={wt}")
