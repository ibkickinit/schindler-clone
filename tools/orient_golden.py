# orient_golden.py — reference (bit-exact spec) for the production orient engine's output->source mapping.
# 0/90/180/270 + scale + position. Fixed-point friendly: the per-output-pixel source coord is an INCREMENTAL
# walk (no per-pixel multiply), exactly like the HDL will do. This file is the golden the HDL must match.
#
# Inverse map (each OUTPUT pixel asks which SOURCE pixel it shows):
#   center the output -> scale (src px per out px) -> apply the orientation's inverse rotation/transpose
#   -> un-center into the source + pan. Orientations are EXACT integer transposes/flips (no interpolation
#   for the rotation; interpolation only for fractional scale, handled by the frac bits of sx/sy).

def orient_coeffs(OW, OH, SW, SH, orient, scale, panx, pany):
    """Return the 6 incremental-DDA coeffs (a,b,c)=sx and (d,e,f)=sy such that
         sx = a*ox + b*oy + c ;  sy = d*ox + e*oy + f
    in Q16.16 fixed point. orient in {0,90,180,270}. scale = source-px per output-px (float; 1.0=1:1,
    >1 zoom-out, <1 zoom-in). pan in OUTPUT px (signed)."""
    Q = 1 << 16
    s = scale
    # rotation matrix R(-orient) applied to the centered+scaled output vector (cx*s, cy*s):
    #   0:  ( cx*s,  cy*s)   90: ( cy*s, -cx*s)   180: (-cx*s, -cy*s)   270: (-cy*s,  cx*s)
    if   orient == 0:   axx,axy, ayx,ayy = ( s, 0,  0, s)
    elif orient == 90:  axx,axy, ayx,ayy = ( 0, s, -s, 0)
    elif orient == 180: axx,axy, ayx,ayy = (-s, 0,  0,-s)
    elif orient == 270: axx,axy, ayx,ayy = ( 0,-s,  s, 0)
    else: raise ValueError("orient must be 0/90/180/270")
    # cx = ox - OW/2 - panx ; cy = oy - OH/2 - pany  (pan moves the window: image shifts opposite, matte fills)
    ocx, ocy = OW/2.0 + panx, OH/2.0 + pany
    scx, scy = SW/2.0, SH/2.0
    a, b = axx, axy
    d, e = ayx, ayy
    c = scx - axx*ocx - axy*ocy
    f = scy - ayx*ocx - ayy*ocy
    q = lambda v: int(round(v*Q))
    return q(a), q(b), q(c), q(d), q(e), q(f)

def src_of(coeffs, ox, oy):
    a,b,c,d,e,f = coeffs
    sx = a*ox + b*oy + c          # Q16.16
    sy = d*ox + e*oy + f
    return sx, sy                  # integer part = >>16, frac = &0xFFFF

# ---- self-check: corners map where each orientation should, + scale/pan sanity ----
if __name__ == "__main__":
    OW,OH,SW,SH = 1920,1080,1920,1080
    def corners(orient, scale=1.0, panx=0, pany=0):
        c = orient_coeffs(OW,OH,SW,SH,orient,scale,panx,pany)
        out = {}
        for nm,(ox,oy) in {"TL":(0,0),"TR":(OW-1,0),"BL":(0,OH-1),"BR":(OW-1,OH-1)}.items():
            sx,sy = src_of(c,ox,oy); out[nm]=(sx>>16, sy>>16)
        return out
    print("Orientation corner maps (output corner -> source px):")
    for o in (0,90,180,270):
        c=corners(o); print(f"  {o:>3}: TL->{c['TL']} TR->{c['TR']} BL->{c['BL']} BR->{c['BR']}")
    print("\nExpected: 0=identity(TL->~0,0); 180=flip(TL->~SW,SH); 90/270=transpose(axes swapped).")
    print("\n2x zoom-IN (scale=0.5), 0deg — output covers center half of source:")
    c=corners(0,scale=0.5); print(f"  TL->{c['TL']} BR->{c['BR']}  (expect ~ (480,270)..(1440,810))")
    print("\nPan +200x,+100y, 0deg — source window shifts:")
    c=corners(0,scale=1.0,panx=200,pany=100); print(f"  TL->{c['TL']}  (expect ~ (-200,-100) -> matte)")
    # verify it's a pure incremental walk (no per-pixel multiply needed): sx increments by 'a' per ox, 'b' per oy
    cc=orient_coeffs(OW,OH,SW,SH,90,1.0,0,0)
    s00=src_of(cc,0,0); s10=src_of(cc,1,0); s01=src_of(cc,0,1)
    print(f"\n90deg incremental check: d(sx)/dox={s10[0]-s00[0]} (=a={cc[0]}), d(sx)/doy={s01[0]-s00[0]} (=b={cc[1]})")
