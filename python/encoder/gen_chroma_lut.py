"""
gen_chroma_lut.py — Generate the cosine LUT used by hdl/chroma_gen.v.

Produces hdl/chroma_lut_cos.hex: 256 entries, each a signed 10-bit cosine
value (two's complement) scaled so that the peak amplitude is ±255.

The LUT is indexed by the top 8 bits of the 32-bit NCO phase accumulator
inside chroma_gen.v. At runtime the LUT output is multiplied by the
configured burst amplitude and shifted, so the LUT itself stores a
"unit-amplitude" cosine and the actual burst level is set in HDL parameters.

NTSC subcarrier math (cross-referenced for chroma_gen.v):
    f_sc           = 5_000_000 * 63 / 88 = 3.579545... MHz  (exact NTSC spec)
    f_pix          = 54.000 MHz  (Schindler 2.0 pixel clock)
    pix_per_cycle  = 15.0857 pixels per subcarrier cycle
    phase_inc_32b  = round(2**32 * f_sc / f_pix) = 284_704_272 (0x10F83E10)
    frequency error vs ideal = 0.002 ppm (essentially exact)

Burst placement defaults (also cross-referenced):
    sync leading edge  = pixel 81   (H_FRONT_PIXELS)
    sync trailing edge = pixel 335  (H_FRONT + H_SYNC)
    burst start        = pixel 368  (= sync_leading + 19 * pix_per_cycle, NTSC spec)
    burst end          = pixel 504  (start + 9 * pix_per_cycle, 9-cycle burst)
    active video start = pixel 589  (ACTIVE_START_PIXEL)

Usage:
    python gen_chroma_lut.py             # writes ../../hdl/chroma_lut_cos.hex
    python gen_chroma_lut.py --check     # prints sanity-check entries only
"""

import argparse
import math
import os


def cosine_lut(n_entries: int = 256, peak: int = 255) -> list[int]:
    """Return n_entries cosine samples scaled to ±peak, as signed integers."""
    return [round(peak * math.cos(2 * math.pi * i / n_entries)) for i in range(n_entries)]


def to_twos_complement(v: int, bits: int) -> int:
    """Convert a signed int to its bits-wide two's complement unsigned form."""
    if v < 0:
        return v + (1 << bits)
    return v


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=None,
                        help="Output hex file path (default: ../../hdl/chroma_lut_cos.hex)")
    parser.add_argument("--n", type=int, default=256, help="Number of LUT entries")
    parser.add_argument("--peak", type=int, default=255,
                        help="Peak amplitude of cosine values (signed)")
    parser.add_argument("--bits", type=int, default=10,
                        help="Bit width of two's complement output (must hold ±peak)")
    parser.add_argument("--check", action="store_true",
                        help="Print sanity-check entries to stdout, don't write file")
    args = parser.parse_args()

    lut = cosine_lut(args.n, args.peak)
    tc_values = [to_twos_complement(v, args.bits) for v in lut]
    hex_width = (args.bits + 3) // 4  # number of hex chars

    if args.check:
        print(f"LUT[{args.n} entries, peak ±{args.peak}, {args.bits}-bit 2's complement]")
        print(f"  [0]   = {lut[0]:+4d}  ->  {tc_values[0]:0{hex_width}X}")
        print(f"  [64]  = {lut[64]:+4d}  ->  {tc_values[64]:0{hex_width}X}")
        print(f"  [128] = {lut[128]:+4d}  ->  {tc_values[128]:0{hex_width}X}")
        print(f"  [192] = {lut[192]:+4d}  ->  {tc_values[192]:0{hex_width}X}")
        return

    # Default output path: ../../hdl/chroma_lut_cos.hex relative to this script
    out_path = args.out
    if out_path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        out_path = os.path.join(script_dir, "..", "..", "hdl", "chroma_lut_cos.hex")
        out_path = os.path.normpath(out_path)

    with open(out_path, "w") as f:
        for v in tc_values:
            f.write(f"{v:0{hex_width}X}\n")

    print(f"Wrote {args.n} entries to {out_path}")


if __name__ == "__main__":
    main()
