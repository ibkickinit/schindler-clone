"""
ntsc_line.py — Generate a single horizontal scan line of NTSC composite video.

Phase 0 of Schindler 2.0. Validates the encoder math against captured
ImagePro reference signals before any FPGA work.

Every constant traces to a source:
  - SMPTE 170M: standard NTSC composite signal (sync structure, voltage levels,
    colorburst, line timing for 525/59.94)
  - Cal Media MVPHD-24 flyer (v0.7.5): Schindler-specific non-standard frame
    rates and the 4x oversampled / 10-bit / 54 MHz DAC architecture

Usage:
    python ntsc_line.py                          # default: 29.97 fps, mid-gray
    python ntsc_line.py --fps 24                 # 24fps Schindler mode
    python ntsc_line.py --pattern bars           # 75% SMPTE bars (luma only)
    python ntsc_line.py --save-plot out.png      # save instead of display
    python ntsc_line.py --save-samples line.npy  # save samples for compare

Outputs voltage samples in volts referenced to blanking (0 V), at 54 MS/s.
"""

import argparse
import numpy as np
import matplotlib.pyplot as plt
from dataclasses import dataclass


# ============================================================
# CONSTANTS — every number traces to flyer or SMPTE 170M
# ============================================================

# Sample rate (Hz). Source: MVPHD-24 flyer — "4 x over-sampling, 10 bit DAC, 54 MHz"
FS = 54_000_000

# Voltage scale: NTSC composite is 1.0 Vpp = 140 IRE end-to-end
# Source: SMPTE 170M; flyer confirms "1.0 Vpp (including sync)"
IRE = 1.0 / 140.0  # ~7.143 mV per IRE

# Voltage levels (volts, blanking = 0 V reference)
V_SYNC_TIP   = -40.0 * IRE   # -0.2857 V; flyer: "286 mVpp composite sync"
V_BLANKING   = 0.0
V_BLACK      = 7.5 * IRE     # 7.5 IRE setup pedestal (NTSC, North America)
V_WHITE      = 100.0 * IRE   # +0.7143 V

# Colorburst (NTSC standard, SMPTE 170M)
F_SC = 3_579_545.0           # subcarrier frequency (Hz)
BURST_AMPL_IRE = 40.0        # peak-to-peak amplitude in IRE
BURST_AMPL_V = (BURST_AMPL_IRE / 2.0) * IRE  # ±0.1429 V peak
BURST_CYCLES = 9             # minimum per SMPTE 170M (typical: 8-11 cycles)


# ============================================================
# LINE TIMING — flyer + SMPTE 170M
# ============================================================

@dataclass
class LineTiming:
    """Horizontal line timing parameters in microseconds."""
    name:           str       # human-readable
    h_total_us:     float     # total line period
    h_front_us:     float     # front porch (active end → sync start)
    h_sync_us:      float     # sync pulse low duration
    h_back_us:      float     # back porch (sync end → active start)
    burst_start_us: float     # burst start, measured from end of sync pulse
    burst_dur_us:   float     # burst duration
    has_setup:      bool      # NTSC: True (7.5 IRE pedestal); PAL: False

    @property
    def h_active_us(self) -> float:
        return self.h_total_us - self.h_front_us - self.h_sync_us - self.h_back_us


# Standard 525/59.94 NTSC (29.97 fps × 525 lines = 15.7343 kHz)
# Source: SMPTE 170M
NTSC_525_5994 = LineTiming(
    name="NTSC 525/59.94 (standard broadcast)",
    h_total_us=63.5556,
    h_front_us=1.5,
    h_sync_us=4.7,
    h_back_us=4.7,
    burst_start_us=0.6,         # 0.6 µs after end of sync = ~5.3 µs after sync start
    burst_dur_us=BURST_CYCLES / F_SC * 1e6,  # ~2.514 µs
    has_setup=True,
)

# 30.000 fps NTSC (Schindler integer mode)
# Source: MVPHD-24 flyer — "30.000 FPS / 15.750 kHz / 525 lines"
NTSC_30 = LineTiming(
    name="NTSC 30.000 fps (Schindler integer)",
    h_total_us=1e6 / 15750.0,   # 63.4921 µs
    h_front_us=1.5,
    h_sync_us=4.7,
    h_back_us=4.7,
    burst_start_us=0.6,
    burst_dur_us=BURST_CYCLES / F_SC * 1e6,
    has_setup=True,
)

# 24.000 fps NTSC-rate (Schindler primary target)
# Source: MVPHD-24 flyer — "24.000 FPS / 15.720 kHz / 655 lines"
NTSC_24 = LineTiming(
    name="NTSC 24.000 fps (Schindler primary)",
    h_total_us=1e6 / 15720.0,   # 63.6132 µs
    h_front_us=1.5,
    h_sync_us=4.7,
    h_back_us=4.7,
    burst_start_us=0.6,
    burst_dur_us=BURST_CYCLES / F_SC * 1e6,
    has_setup=True,
)

# 23.976 fps NTSC-rate (Schindler pulldown rate)
# Source: MVPHD-24 flyer — "23.976 FPS / 15.752 kHz / 657 lines"
NTSC_2397 = LineTiming(
    name="NTSC 23.976 fps (Schindler pulldown)",
    h_total_us=1e6 / 15752.0,   # 63.4836 µs
    h_front_us=1.5,
    h_sync_us=4.7,
    h_back_us=4.7,
    burst_start_us=0.6,
    burst_dur_us=BURST_CYCLES / F_SC * 1e6,
    has_setup=True,
)

TIMING_PRESETS = {
    "29.97":  NTSC_525_5994,
    "30":     NTSC_30,
    "30.00":  NTSC_30,
    "24":     NTSC_24,
    "24.00":  NTSC_24,
    "23.98":  NTSC_2397,
    "23.976": NTSC_2397,
}


# ============================================================
# LINE GENERATOR
# ============================================================

def generate_line(timing: LineTiming, active_fn=None, fs: float = FS):
    """
    Generate one horizontal NTSC composite line as voltage samples.

    Time origin (t=0) is start of front porch (= end of previous line's active).

    Args:
        timing:    LineTiming preset
        active_fn: callable(t_us_array) -> voltages, where t_us starts at 0
                   at the start of active video. None → flat 50 IRE gray.
        fs:        sample rate (Hz). Default 54 MHz matches Schindler DAC.

    Returns:
        t_us:      sample times (µs), shape (N,)
        v:         composite voltage samples (V), shape (N,)
    """
    n = int(round(timing.h_total_us * 1e-6 * fs))
    t_us = np.arange(n) / fs * 1e6

    # Initialize at blanking
    v = np.full(n, V_BLANKING, dtype=np.float64)

    # Section boundaries (µs from start of line)
    t_sync_start = timing.h_front_us
    t_sync_end   = t_sync_start + timing.h_sync_us
    t_blank_end  = t_sync_end + timing.h_back_us  # = start of active

    # Sync pulse
    sync_mask = (t_us >= t_sync_start) & (t_us < t_sync_end)
    v[sync_mask] = V_SYNC_TIP

    # Colorburst rides on the back porch
    # NTSC convention: burst phase is 180° from +U axis → use cos(...+π)
    t_burst_start = t_sync_end + timing.burst_start_us
    t_burst_end   = t_burst_start + timing.burst_dur_us
    burst_mask = (t_us >= t_burst_start) & (t_us < t_burst_end)
    burst_t = (t_us[burst_mask] - t_burst_start) * 1e-6  # seconds
    v[burst_mask] += BURST_AMPL_V * np.cos(2 * np.pi * F_SC * burst_t + np.pi)

    # Active video
    active_mask = t_us >= t_blank_end
    if active_fn is None:
        v[active_mask] = 50.0 * IRE
    else:
        active_t_us = t_us[active_mask] - t_blank_end
        v[active_mask] = active_fn(active_t_us)

    return t_us, v


# ============================================================
# TEST PATTERNS — for active video region
# ============================================================

def flat_gray(level_ire: float = 50.0):
    """Active region of constant luma at given IRE level."""
    def fn(t_us):
        return np.full_like(t_us, level_ire * IRE)
    return fn


def linear_ramp(start_ire: float = 7.5, end_ire: float = 100.0):
    """Linear luma ramp across active region (default: black setup → peak white)."""
    def fn(t_us):
        if len(t_us) < 2:
            return np.full_like(t_us, start_ire * IRE)
        norm = (t_us - t_us[0]) / (t_us[-1] - t_us[0])
        return (start_ire + norm * (end_ire - start_ire)) * IRE
    return fn


def smpte_color_bars_luma():
    """75% SMPTE color bars, LUMA ONLY (no chroma modulation).
    Used for sync/timing validation. Adding chroma is Chapter 4 territory.
    Bar order: white, yellow, cyan, green, magenta, red, blue
    """
    bars_ire = [77.0, 69.0, 56.0, 48.0, 36.0, 28.0, 15.0]
    def fn(t_us):
        if len(t_us) < 2:
            return np.full_like(t_us, bars_ire[0] * IRE)
        norm = (t_us - t_us[0]) / (t_us[-1] - t_us[0])
        idx = np.clip((norm * len(bars_ire)).astype(int), 0, len(bars_ire) - 1)
        return np.array([bars_ire[i] for i in idx]) * IRE
    return fn


# ============================================================
# PLOTTING
# ============================================================

def plot_line(t_us, v, timing: LineTiming, title=None, save_path=None):
    """Plot the line with annotations and IRE reference lines."""
    fig, ax = plt.subplots(figsize=(14, 6))

    ax.plot(t_us, v * 1000, linewidth=1.0, color='#1f77b4')

    # IRE reference levels
    refs = [
        (V_SYNC_TIP, 'sync tip (−40 IRE, −286 mV)', 'red'),
        (V_BLANKING, 'blanking (0 IRE)',            'gray'),
        (V_BLACK,    'black setup (7.5 IRE)',       'black'),
        (V_WHITE,    'peak white (100 IRE)',        'green'),
    ]
    for vlevel, label, color in refs:
        ax.axhline(vlevel * 1000, color=color, linestyle=':', alpha=0.4, label=label)

    # Section boundaries
    t_sync_start = timing.h_front_us
    t_sync_end   = t_sync_start + timing.h_sync_us
    t_blank_end  = t_sync_end + timing.h_back_us
    t_burst_start = t_sync_end + timing.burst_start_us
    t_burst_end   = t_burst_start + timing.burst_dur_us

    boundaries = [
        (0,                  'line start'),
        (t_sync_start,       'sync ↓'),
        (t_sync_end,         'sync ↑'),
        (t_burst_start,      'burst start'),
        (t_burst_end,        'burst end'),
        (t_blank_end,        'active start'),
        (timing.h_total_us,  'line end'),
    ]
    ymin, ymax = ax.get_ylim()
    for t, label in boundaries:
        ax.axvline(t, color='orange', linestyle='--', alpha=0.3)
        ax.annotate(label, xy=(t, ymax * 0.95),
                    xytext=(3, 0), textcoords='offset points',
                    fontsize=8, color='darkorange', rotation=90, va='top')

    ax.set_xlabel('Time (µs)')
    ax.set_ylabel('Voltage (mV)')
    ax.set_title(title or f'NTSC composite line — {timing.name}')
    ax.legend(loc='upper right', fontsize=8, framealpha=0.9)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(0, timing.h_total_us)

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
    p = argparse.ArgumentParser(description='NTSC line generator (Phase 0 / Schindler 2.0)')
    p.add_argument('--fps', default='29.97', choices=list(TIMING_PRESETS.keys()),
                   help='Frame rate preset (default: 29.97 — what ImagePro outputs)')
    p.add_argument('--pattern', default='gray', choices=['gray', 'ramp', 'bars'],
                   help='Active video test pattern')
    p.add_argument('--gray-ire', type=float, default=50.0,
                   help='IRE level for "gray" pattern (default 50)')
    p.add_argument('--save-plot', metavar='PATH', help='Save plot PNG instead of display')
    p.add_argument('--save-samples', metavar='PATH', help='Save samples to .npy for compare')
    args = p.parse_args()

    timing = TIMING_PRESETS[args.fps]

    pattern_map = {
        'gray': flat_gray(args.gray_ire),
        'ramp': linear_ramp(),
        'bars': smpte_color_bars_luma(),
    }
    active_fn = pattern_map[args.pattern]

    t_us, v = generate_line(timing, active_fn=active_fn)

    print(f'NTSC line generated:')
    print(f'  Mode:         {timing.name}')
    print(f'  Sample rate:  {FS/1e6:.3f} MS/s')
    print(f'  Line period:  {timing.h_total_us:.4f} µs ({len(t_us)} samples)')
    print(f'  H rate:       {1e3/timing.h_total_us:.3f} kHz')
    print(f'  Active video: {timing.h_active_us:.4f} µs')
    print(f'  Sync tip:     {V_SYNC_TIP*1000:+.1f} mV')
    print(f'  Peak white:   {V_WHITE*1000:+.1f} mV')
    print(f'  Burst:        {timing.burst_dur_us:.3f} µs @ {F_SC/1e6} MHz')

    if args.save_samples:
        np.save(args.save_samples, np.column_stack([t_us, v]))
        print(f'  Samples →     {args.save_samples}')

    plot_line(t_us, v, timing, save_path=args.save_plot)


if __name__ == '__main__':
    main()
