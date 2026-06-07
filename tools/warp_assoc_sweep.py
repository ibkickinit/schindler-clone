# Sweep cache (set-function, NSET) candidates -> needed ways + NTILE, gated on worst-set-live <= ways.
# Goal: smallest NTILE (= BRAM) with worst-set-live <= ways for ALL transforms. NTILE<=512 (~96 BRAM).
import sys; sys.path.insert(0,'tools')
from warp_workingset import need_tiles, max_overlap_per_set

TILE=16
XFORMS=[("rot20",dict(deg=20)),("rot45",dict(deg=45)),
        ("shrink1.5",dict(sxsc=1/1.5,sysc=1/1.5)),("aniso",dict(deg=30,sxsc=1/1.5))]
seqs={nm:need_tiles(TILE,**p) for nm,p in XFORMS}

def mk_lowbits(nset):
    b=nset.bit_length()-1; h=b//2
    return lambda t,_h=h: ((t[1]&((1<<_h)-1))<<_h)|(t[0]&((1<<_h)-1))
def mk_mul(nset):     return lambda t: (t[0]*13+t[1]*7)&(nset-1)
def mk_fin(nset):     # bit-finalizer mix
    def f(t):
        h=(t[0]*0x9E37+t[1]*0x85EB)&0xffffffff
        h^=h>>13; h=(h*0xC2B2)&0xffffffff; h^=h>>11
        return h&(nset-1)
    return f

CANDS=[]
for nset in (16,32,64,128):
    CANDS.append((f"lowbits/{nset}set", mk_lowbits(nset), nset))
    CANDS.append((f"mul13_7/{nset}set", mk_mul(nset), nset))
    CANDS.append((f"finalizer/{nset}set", mk_fin(nset), nset))

print(f"{'candidate':<20}{'rot20':>7}{'rot45':>7}{'shrink':>7}{'aniso':>7}{'ways':>6}{'NTILE':>7}{'BRAM~':>7}  fit?")
best=None
for name,sf,nset in CANDS:
    worst={nm:max_overlap_per_set(seqs[nm],sf,nset)[0] for nm,_ in XFORMS}
    need=max(worst.values())
    # round ways up to a power of 2 for clean indexing
    ways=1
    while ways<need: ways*=2
    ntile=nset*ways
    bram=ntile*64*24*4/(36*1024)  # 4 banks, 64 px/tile (2x2 blocks), 24b; RAMB36=36Kb
    fit = ntile<=512
    print(f"{name:<20}{worst['rot20']:>7}{worst['rot45']:>7}{worst['shrink1.5']:>7}{worst['aniso']:>7}"
          f"{ways:>6}{ntile:>7}{bram:>6.0f} {'  OK' if fit else '  >512'}")
    if fit and (best is None or ntile<best[1]):
        best=(name,ntile,ways,nset)
print("\nBEST within NTILE<=512:", best)
