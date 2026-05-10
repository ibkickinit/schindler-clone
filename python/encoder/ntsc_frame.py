"""
ntsc_frame.py — Assemble full NTSC fields and frames from line-level building blocks.

Phase 0 / Schindler 2.0 — extends ntsc_line.py from one horizontal line to a
complete interlaced frame with vertical blanking interval (VBI), pre- and
post-equalizing pulses, and broad vertical sync pulses.

Sources:
  - SMPTE 170M: VBI structure, equalizing pulse width, vertical sync width,
    half-line interlace offset
  - MVPHD-24 flyer (v0.7.5): per-rate H-rate × line-count combinations:
      24.000 fps × 655 lines × 15720 Hz   (interlaced 327.5 lines/field)
      23.976 fps × 657 lines × 15752 Hz   (interlaced 328.5 lines/field)
      30.000 fps × 525 lines × 15750 Hz   (interlaced 262.5 lines/field)
      29.97  fps × 525 lines × 15734.3 Hz (standard, interlaced 262.5/field)

Schindler-specific VBI quirks (per playbook Chapter 5: proprietary VITC-like
data on lines 14 / 277) are NOT modeled here — that requires captures from a
real MVPHD-24 unit. This module produces a SMPTE-170M-conformant VBI for
each Schindler frame rate.

Usage:
    python ntsc_frame.py --fps 24 --plot vbi    # plot just the VBI region
    python ntsc_frame.py --fps 24 --plot field  # plot one entire field
    python ntsc_frame.py --fps 24 --save-samples frame.npy
"""

import argparse
import numpy as np
import matplotlib.pyplot as plt
from dataclasses import dataclass

from ntsc_line import (
    FS, IRE, V_SYNC_TIP, V_BLANKING, V_BLACK,
    LineTiming, TIMING_PRESETS,
    generate_line, flat_gray, smpte_color_bars_luma,
)


# ============================================================
# VBI PULSE WIDTHS — SMPTE 170M
# ============================================================

# Equalizing pulse: half the width of normal H-sync. SMPTE 170M Table 1.
EQ_PULSE_US = 2.3

# Broad vertical-sync pulse: a "long" sync that fills most of a half-line,
# minus a short serration of width = normal H-sync (4.7 µs). The serration
# preserves H-sync timing recovery during V-sync. SMPTE 170M Table 1.
V_SERRATION_US = 4.7

# VBI line counts — SMPTE 170M, used for all NTSC-derived rates.
N_PRE_EQ_LINES   = 3   # 6 equalizing pulses (2 per line) before V-sync
N_VSYNC_LINES    = 3   # 6 broad pulses with serrations
N_POST_EQ_LINES  = 3   # 6 equalizing pulses after V-sync
N_VBI_BLANK_LINES = 12 # remaining VBI before active video (lines 10-21 in 525)


# ============================================================
# FRAME TIMING — derived from LineTiming + flyer line counts
# ============================================================

@dataclass
class FrameTiming:
    """Frame-level timing for an interlaced NTSC-derived format."""
    name:         str
    line:         LineTiming  # per-line timing (from ntsc_line)
    lines_total:  int         # total lines per frame (e.g. 525, 655, 657)

    @property
    def lines_per_field(self) -> float:
        return self.lines_total / 2.0  # half-line offset → .5 fractional

    @property
    def n_vbi_lines(self) -> int:
        return N_PRE_EQ_LINES + N_VSYNC_LINES + N_POST_EQ_LINES + N_VBI_BLANK_LINES

    @property
    def n_active_lines_per_field(self) -> int:
        # Whole active lines available after VBI; truncates the .5 (serration
        # absorbs the half-line in real interlace).
        return int(self.lines_per_field) - self.n_vbi_lines


# Frame counts for each preset — line totals from MVPHD-24 flyer
FRAME_PRESETS = {
    "29.97":  FrameTiming("525/59.94 standard",   TIMING_PRESETS["29.97"],  525),
    "30":     FrameTiming("525/60 (Schindler)",   TIMING_PRESETS["30"],     525),
    "24":     FrameTiming("655/48 (Schindler)",   TIMING_PRESETS["24"],     655),
    "23.976": FrameTiming("657/47.95 (Schindler)",TIMING_PRESETS["23.976"], 657),
}


# ============================================================
# VBI LINE GENERATORS
# ============================================================

def _blank_samples(n: int) -> np.ndarray:
    return np.full(n, V_BLANKING, dtype=np.float64)


def equalizing_line(timing: LineTiming, fs: float = FS) -> np.ndarray:
    """One equalizing-pulse line: two narrow sync pulses (EQ_PULSE_US wide)
    at H and H/2 offsets. Used in the VBI before and after vertical sync.
    Per SMPTE 170M Fig 6."""
    n = int(round(timing.h_total_us * 1e-6 * fs))
    v = _blank_samples(n)
    half_h = timing.h_total_us / 2.0
    for offset_us in (0.0, half_h):
        i_start = int(round(offset_us * 1e-6 * fs))
        i_end   = int(round((offset_us + EQ_PULSE_US) * 1e-6 * fs))
        v[i_start:i_end] = V_SYNC_TIP
    return v


def vertical_sync_line(timing: LineTiming, fs: float = FS) -> np.ndarray:
    """One vertical-sync line: two broad sync pulses, each filling a half-line
    minus a short serration at the half-line boundary. The serration carries
    the normal H-sync edge so the receiver's H-PLL keeps tracking. Per SMPTE
    170M Fig 6."""
    n = int(round(timing.h_total_us * 1e-6 * fs))
    v = _blank_samples(n)
    half_h = timing.h_total_us / 2.0
    # Two broad pulses occupy nearly the full line; serrations are short
    # blanking-level notches at offset_us + (half_h - V_SERRATION_US).
    for offset_us in (0.0, half_h):
        broad_start = int(round(offset_us * 1e-6 * fs))
        broad_end   = int(round((offset_us + half_h - V_SERRATION_US) * 1e-6 * fs))
        v[broad_start:broad_end] = V_SYNC_TIP
    return v


def normal_blank_line(timing: LineTiming, fs: float = FS) -> np.ndarray:
    """A line with normal H-sync but no active video — active region held at
    blanking. Used for VBI fill between post-equalizing and first active line."""
    t_us, v = generate_line(timing, active_fn=flat_gray(0.0), fs=fs)
    return v


# ============================================================
# FIELD / FRAME ASSEMBLY
# ============================================================

def generate_field(frame: FrameTiming, active_fn=None,
                   fs: float = FS) -> np.ndarray:
    """Assemble one complete field: VBI followed by N_active_lines of video."""
    parts = []
    for _ in range(N_PRE_EQ_LINES):
        parts.append(equalizing_line(frame.line, fs))
    for _ in range(N_VSYNC_LINES):
        parts.append(vertical_sync_line(frame.line, fs))
    for _ in range(N_POST_EQ_LINES):
        parts.append(equalizing_line(frame.line, fs))
    for _ in range(N_VBI_BLANK_LINES):
        parts.append(normal_blank_line(frame.line, fs))
    for _ in range(frame.n_active_lines_per_field):
        _, v = generate_line(frame.line, active_fn=active_fn, fs=fs)
        parts.append(v)
    return np.concatenate(parts)


def generate_frame(frame: FrameTiming, active_fn=None,
                   fs: float = FS) -> np.ndarray:
    """Assemble two fields into one interlaced frame.
    Caveat: this approximation puts the half-line offset at the field
    boundary by simply concatenating two equal-structure fields. Real
    interlace embeds the .5-line offset inside the V-sync region of field 2;
    that refinement is deferred until we have captures to validate against."""
    return np.concatenate([generate_field(frame, active_fn, fs),
                           generate_field(frame, active_fn, fs)])


# ============================================================
# PLOTTING
# ============================================================

def plot_region(samples: np.ndarray, fs: float, title: str,
                save_path: str = None):
    t_us = np.arange(len(samples)) / fs * 1e6
    fig, ax = plt.subplots(figsize=(16, 5))
    ax.plot(t_us, samples * 1000, linewidth=0.8, color='#1f77b4')
    for vlevel, label, color in [
        (V_SYNC_TIP, 'sync tip',    'red'),
        (V_BLANKING, 'blanking',    'gray'),
        (V_BLACK,    'black setup', 'black'),
    ]:
        ax.axhline(vlevel * 1000, color=color, linestyle=':', alpha=0.4, label=label)
    ax.set_xlabel('Time (µs)')
    ax.set_ylabel('Voltage (mV)')
    ax.set_title(title)
    ax.legend(loc='upper right', fontsize=8, framealpha=0.9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    if save_path:
        fig.savefig(save_path, dpi=120)
        print(f'  Saved plot → {save_path}')
    else:
        plt.show()
    return fig


# ============================================================
# CLI
# ============================================================

def main():
    p = argparse.ArgumentParser(description='NTSC frame generator (Phase 0 / Schindler 2.0)')
    p.add_argument('--fps', default='24', choices=list(FRAME_PRESETS.keys()),
                   help='Frame-rate preset (default: 24 — Schindler primary)')
    p.add_argument('--pattern', default='bars', choices=['gray', 'bars'],
                   help='Active video test pattern')
    p.add_argument('--plot', default='vbi', choices=['vbi', 'field', 'none'],
                   help='What to plot: vbi region (default), entire field, or nothing')
    p.add_argument('--save-plot', metavar='PATH', help='Save plot PNG instead of display')
    p.add_argument('--save-samples', metavar='PATH', help='Save full-frame samples to .npy')
    args = p.parse_args()

    frame = FRAME_PRESETS[args.fps]
    active_fn = smpte_color_bars_luma() if args.pattern == 'bars' else flat_gray(50.0)

    samples = generate_frame(frame, active_fn=active_fn)
    samples_per_line = int(round(frame.line.h_total_us * 1e-6 * FS))
    field_samples = samples_per_line * (frame.n_vbi_lines + frame.n_active_lines_per_field)

    print(f'NTSC frame generated:')
    print(f'  Mode:                {frame.name}')
    print(f'  Lines per frame:     {frame.lines_total} ({frame.lines_per_field}/field)')
    print(f'  VBI lines per field: {frame.n_vbi_lines}')
    print(f'    pre-eq             {N_PRE_EQ_LINES}')
    print(f'    vertical sync      {N_VSYNC_LINES}')
    print(f'    post-eq            {N_POST_EQ_LINES}')
    print(f'    blank fill         {N_VBI_BLANK_LINES}')
    print(f'  Active lines/field:  {frame.n_active_lines_per_field}')
    print(f'  Samples per frame:   {len(samples)}  ({len(samples)/FS*1000:.3f} ms = 1/{1e3/(len(samples)/FS*1000):.3f} Hz)')
    print(f'  Sample rate:         {FS/1e6:.3f} MS/s')

    if args.save_samples:
        np.save(args.save_samples, samples)
        print(f'  Samples →            {args.save_samples}')

    if args.plot == 'vbi':
        # First N VBI lines + a couple of active lines for context
        n_show = samples_per_line * (frame.n_vbi_lines + 2)
        plot_region(samples[:n_show], FS,
                    f'VBI region — {frame.name} (first {frame.n_vbi_lines} VBI lines + 2 active)',
                    save_path=args.save_plot)
    elif args.plot == 'field':
        plot_region(samples[:field_samples], FS,
                    f'One field — {frame.name}',
                    save_path=args.save_plot)


if __name__ == '__main__':
    main()
