# Phase E2.3 — Auto-FRC ratio detection

**Status:** Firmware shipped 2026-05-19. Bench validation pending (needs user). No HDL change — pure firmware on top of E2.1's src_vsync_divider.

**Goal:** Turn E2.1's manual `n <M> <N>` step into a one-button operation. Single UART command `a` measures the source rate, computes a reduced M/N matching the configured output target, applies it via the divider, and switches the loop reference to the source-vsync path.

## How it works

```
'a' command
   ↓
measure_source_rate_mhz(60)   ← existing iter-4a infrastructure; ~1 s window
   ↓
compute_frc_ratio(src_mhz, g_output_target_mhz, &M, &N)
   ↓                                       ↑
   ↓                  Euclidean GCD reduction of output_mhz / src_mhz
   ↓                  Rejected if M > N (up-conversion, not supported) or
   ↓                  if reduced terms > 255 (8-bit divider GPIO limit)
   ↓
srcdiv_write(M, N)            ← Phase E2.1 plumbing
refsel_write(REFSEL_SRC)      ← Phase E2.1 mux selection
   ↓
(loop, if enabled) state → ACQUIRING; integrator preload
```

## Supported ratios (current output = 50.000 Hz)

| Source rate | M/N | Notes |
|---|---|---|
| 50.000 Hz | 1/1 | passthrough |
| 59.940 Hz (NTSC) | 50000/59940 = 250/2997 | reduced terms too large → REJECTED |
| 60.000 Hz | 5/6 | the canonical case |
| 72.000 Hz | 25/36 | |
| 75.000 Hz | 2/3 | |
| 100.000 Hz | 1/2 | |
| 120.000 Hz | 5/12 | |
| < 50.000 Hz | — | REJECTED (M > N, up-conversion needs Mackin) |

Note: NTSC's 59.940 Hz (= 60000/1001 in exact terms) produces an irreducible ratio (250/2997 = 50000/59940 in lowest terms). The 8-bit M/N inputs can't hold this. Workarounds:

1. **Lock to nearest matching integer source** — pretend the source is at 60.000 Hz, set M/N=5/6, let the loop's ±500 ppm pull range absorb the ~1000 ppm offset (it can — barely; this is the spike approach).
2. **Widen the divider's M/N width to 16 bits** — `250/2997` fits in 12 bits. Trivial HDL change.
3. **Pick a different output target** — if output is 23.976 Hz, then ratio 23976/59940 = 2/5 (exact integer reduction). Generally, matching source-frame-rate-family (NTSC source → NTSC output) eliminates the issue.

For the spike, option 1 (lock-with-loop-pull) is what `a` will produce when invoked against a 59.94 Hz source — the function will REJECT the call. The user can manually set `n 5 6` and the loop will compensate the ~1000 ppm offset.

(Followup E2.3.1 idea: widen M/N to 16 bits in the divider HDL. Until then, NTSC sources need manual override.)

## UART interface

```
a                # auto-FRC: measure source rate, set M/N, switch ref to src
```

Example output (60.000 Hz Windows source → 720p50 output):

```
[A] auto-FRC: measuring source rate (~1 s) ...
[A] source = 60.000 Hz; output target = 50.000 Hz
[A] APPLIED: M/N = 5/6 → ref = source × 5/6 (= 50.000 Hz target)
    ref_mux now in SRC mode. Send 'L' to engage loop if not already.
```

Failure cases:

- pLocked drops mid-measurement: `[A] FAILED: source rate measurement returned 0`
- Up-conversion needed (src < out): `[A] FAILED: cannot derive M/N ... Current divider supports M ≤ N`
- Reduced terms > 255: same FAILED message (with the same architectural note about Mackin / wider GPIO)

## Test plan (no bench needed for the firmware-correctness checks)

### Firmware self-checks (UART-only)

1. **Help banner.** Send `?`; should list `a` command.
2. **Garbage / no source.** Disconnect HDMI source. Send `a`. Should print FAILED with pLocked-dropped message (no hang).
3. **Math correctness.** Set output target via the (not-yet-written) UART output-mode command. For now, with hardcoded 50.000 Hz target and the Windows ~60.000 Hz source, `a` should print M/N = 5/6.

### Bench validation (needs user)

4. **Windows 60Hz source.** Send `a`. Should auto-set M/N=5/6, switch to SRC ref. Send `L`. Loop should acquire; integrator should settle near 0 (because ref = source × 5/6 ≈ 50 Hz exact, matching MMCM-achievable output rate within ~100 ppm).
5. **Mac/Apple TV source.** Connect alternative source, send `a`. May FAIL (NTSC 59.94 produces irreducible ratio). Document for follow-up.
6. **Monitor visual.** With auto-FRC engaged and loop locked, monitor picture should stay clean across the source field — this is the E1.8 architectural prediction at last empirically realized.

## What's NOT in E2.3

- **Auto-retrigger.** If the source rate changes mid-operation (user switches input from PC to game console), the firmware doesn't notice. Future feature: poll source rate periodically; re-run `cmd_auto_frc()` if it shifts by > some threshold.
- **Output-mode awareness.** `g_output_target_mhz` is a global initialized to 50.000 Hz. When firmware grows runtime output-mode switching (e.g., 720p60 mode), that global must be updated alongside the VTC config.
- **NTSC fraction handling.** Per discussion above, 59.940 Hz produces irreducible 250/2997 ratio. Either widen the divider's M/N width to 16 bits OR add a separate "fractional ratio" approximation that adjusts M/N + lets the loop's pull range absorb the residual. Follow-up: pick one and implement.

## Provenance

- **Branch:** `phase-e1-pll-spike`
- **Commit:** TBD after this lands
- **Build:** firmware rebuilds against same XSA as E2.1/E2.2. Same bitstream from commit `07a8b39`.
