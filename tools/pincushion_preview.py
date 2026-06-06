#!/usr/bin/env python3
"""
Pincushion/barrel correction PREVIEWER (pure stdlib; validates the math + dials the slider range).

Renders a straight reference grid as the SOURCE, applies the read-engine inverse-map
  dx=ox-cx, dy=oy-cy ; r2=(dx²+dy²)/R² ; f=1+k1·r2+k2·r2² ; sx=cx+dx·f, sy=cy+dy·f
and writes the resampled OUTPUT to a PPM for several k1, so you can SEE the bow and pick the range.
Also prints corner/edge displacement metrics (scaled to the real 1280-wide output).

k1>0 = barrel-correct (edges pushed out); k1<0 = pincushion-correct (edges pulled in); k1=0 = identity.
"""
import math, zlib, struct

def write_png(path, w, h, rows):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    raw = bytearray()
    for row in rows:
        raw.append(0); raw += row          # filter type 0 per scanline
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))   # 8-bit truecolor
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)

PW, PH = 320, 180          # preview raster (represents the real 1280x720, 4x down)
REAL_W = 1280              # for reporting displacement in real output px
GRID = 20                  # source grid spacing (preview px)


def render(k1, k2=0.0, path=None):
    cx, cy = PW / 2.0, PH / 2.0
    R2 = cx * cx + cy * cy
    real_scale = REAL_W / PW
    # source test pattern: bright grid lines on a dark field
    def src(sx, sy):
        if sx < 0 or sy < 0 or sx >= PW or sy >= PH:
            return (0, 0, 40)                       # matte (out of source)
        on = (int(sx) % GRID < 2) or (int(sy) % GRID < 2)
        if on:
            return (240, 240, 240)
        return (20 + int(180 * sx / PW), 20, 20 + int(180 * sy / PH))  # faint position gradient
    rows = []
    max_disp = 0.0
    for oy in range(PH):
        dy = oy - cy
        row = bytearray()
        for ox in range(PW):
            dx = ox - cx
            r2 = (dx * dx + dy * dy) / R2
            f = 1.0 + k1 * r2 + k2 * r2 * r2
            sx = cx + dx * f
            sy = cy + dy * f
            r, g, b = src(sx, sy)
            row += bytes((r, g, b))
        rows.append(row)
    # metric: corner displacement (r=1) in real output px
    corner_f = 1.0 + k1 + k2
    corner_disp = abs((corner_f - 1.0)) * (cx) * real_scale   # along x at the corner-ish
    if path:
        write_png(path, PW, PH, rows)
    return corner_disp


def run():
    print(f"# pincushion preview  {PW}x{PH} (≙ {REAL_W}px wide)  grid={GRID}px")
    print(f"{'k1':>7}{'corner disp (real px)':>24}   file")
    for k1 in (-0.30, -0.15, 0.0, 0.15, 0.30):
        tag = f"{k1:+.2f}".replace("+", "p").replace("-", "m").replace(".", "")
        path = f"/tmp/pincushion_{tag}.png"
        disp = render(k1, 0.0, path)
        print(f"{k1:>7.2f}{disp:>20.0f} px   {path}")
    print("\nView: any image viewer (PPM), or `convert /tmp/pincushion_p030.png x.png`.")
    print("Read it as: grid SOURCE straight → output bows by k1 (this is the inverse of the")
    print("distortion you'd be correcting, so a barrel source + k1>0 ⇒ straight output).")


if __name__ == "__main__":
    run()
