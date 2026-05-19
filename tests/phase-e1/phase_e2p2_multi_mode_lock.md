# Phase E2.2 — Multi-mode lock (SNAP / SMOOTH / FILM)

**Status:** Firmware shipped 2026-05-19. Bench validation pending (needs user). No HDL change — pure firmware.

**Goal:** Give the loop three pre-tuned operating points for different downstream priorities, selectable at runtime via UART. Inspired by the RT4K's Frame Lock / Gen Lock / Triple Buffer triplet and the broader pro-FRC pattern.

## The three modes

| Mode | When to use | Kp (ppm/line) | Ki (ppm/line/frame) | Lock window | Lock frames | Acquire time |
|---|---|---|---|---|---|---|
| **SNAP** | Game / interactive sources where input latency matters more than visible step-changes during lock | 30 | 5.0 | 1 line (2667 t) | 30 frames | ~0.6 s |
| **SMOOTH** *(default)* | General desktop / media. Phase 6/7 calibration. | 10 | 1.0 | 1 line | 60 frames | ~1.2 s |
| **FILM** | 24p / cinema content where smooth motion is paramount; any per-frame actuator step is potentially visible | 3 | 0.3 | 0.5 line (1333 t) | 150 frames | ~3.0 s |

Same `INTEGRATOR_CLAMP_MILLI_PPM = ±500 ppm` across all modes (clamping further would just rate-limit SNAP during a large initial step, which is the opposite of what SNAP wants).

## Architecture

Per-mode parameters live in a `lock_mode_t` struct:

```c
typedef struct {
    const char *name;
    s32         kp_mppm_per_line;
    s32         ki_mppm_per_line;
    u32         lock_threshold_ticks;
    u32         unlock_threshold_ticks;
    u32         lock_frames;
    u32         unlock_frames;
} lock_mode_t;
```

Three const instances (`MODE_SNAP`, `MODE_SMOOTH`, `MODE_FILM`) hold the per-mode values. `g_active_mode` is a pointer to the current one (defaults to `&MODE_SMOOTH`). The existing PI loop code references `KP_MILLI_PPM_PER_LINE` / `KI_MILLI_PPM_PER_LINE` / `LOCK_THRESHOLD_TICKS` / `UNLOCK_THRESHOLD_TICKS` / `LOCK_FRAMES` / `UNLOCK_FRAMES` — these are now macros that indirect through `g_active_mode`. No call-site changes needed in `loop_tick`.

## UART interface

New command:

```
o <snap|smooth|film>     # select lock mode
```

When mode changes:
- The in-/out-lock frame counters reset (new mode's `lock_frames` count starts fresh).
- The integrator value is preserved (new mode's gains take effect on the next loop tick).
- Loop state (`LOCKED` / `ACQUIRING` / etc.) is preserved.

The LOCK summary line now includes the active mode:

```
LOCK mode=SMOOTH state=LOCKED err=0/-1/1 cmd=-101 int=-98 locked=1923 …
```

The `L` command's banner also prints the active mode + its gains:

```
[L] Phase 6 loop ENABLED  (ts_ref_count=…, mode=SMOOTH)
    Kp_milli=10000 ppm/line  Ki_milli=1000 ppm/line/frame
    integrator_clamp_milli=500000  lock_frames=60  lock_thresh_ticks=2667
```

## Test plan (no bench needed for the firmware-correctness checks)

### Firmware self-checks (UART-only)

1. **Default boot mode = SMOOTH.** Send `L` after boot; `[L]` banner should report `mode=SMOOTH` with Kp_milli=10000, Ki_milli=1000.
2. **Switch to SNAP, verify gains.** Send `o snap`. UART should print `[O] lock mode = SNAP (Kp=30.000, Ki=5.000, lock_frames=30, lock_thresh=2667 t)`.
3. **Switch to FILM, verify gains.** Send `o film`. UART: `Kp=3.000, Ki=0.300, lock_frames=150, lock_thresh=1333 t`.
4. **Switch back to SMOOTH.** Send `o smooth`. UART: `Kp=10.000, Ki=1.000`.
5. **Garbage argument.** Send `o blah`. UART should print usage and the current active mode, no state change.
6. **Mode visible in LOCK summary.** After `L`, every per-second summary line should include `mode=<NAME>` matching what was selected.

### Bench validation (needs user)

7. **SNAP acquire time.** From cold boot, `o snap`, `L`. Measure time from `L` to `>>> LOCKED at frame N` in the UART log. Should be ~0.6 s (30 frames at 50 Hz).
8. **SMOOTH acquire time.** From cold boot, `o smooth` (or default), `L`. Should be ~1.2 s (60 frames). Matches Phase 6 prior data.
9. **FILM acquire time.** From cold boot, `o film`, `L`. Should be ~3.0 s (150 frames).
10. **Steady-state jitter comparison.** Soak each mode for 30 s. Compare err mean / min / max. FILM should have tightest min/max envelope due to lower Ki + tighter lock_thresh.
11. **Monitor visual.** With each mode, picture should look the same once LOCKED (the loop is doing the same job — locking output to ref). Mode differences should only be visible during acquire / under perturbation. If picture differs significantly between modes in steady state, something's wrong.

## What's NOT in E2.2

- **Frame-rate-converter mode coupling.** The original RT4K-style three-mode design ties each mode to a specific FRC strategy (Frame Lock = output snaps to source rate; Gen Lock = source-derived ref + integer divider; Triple Buffer = framestore drop/repeat). E2.2 is just the PI-controller tuning piece; the FRC-strategy coupling needs Mackin blend + dual-VDMA integration. Defer to Phase E3.
- **Si5351 plant changes.** E2.2's per-mode gains assume the current asymmetric MMCM plant (dec ~2× slower than inc). With Si5351's symmetric plant, all three modes can probably use ~30% higher Kp / Ki than these defaults. Re-tune in Phase E2 (Si5351 arrival).
- **Auto-mode-detection.** Future feature: detect 24p content → auto-switch to FILM; detect gaming source → SNAP. Out of scope.

## Provenance

- **Branch:** `phase-e1-pll-spike`
- **Commit:** TBD after this lands
- **Build:** firmware rebuilds against same XSA as E2.1 (no HDL change). Same bitstream from commit `07a8b39`.
