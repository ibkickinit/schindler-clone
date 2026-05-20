# Phase E2 — bench session 1 findings

**Date:** 2026-05-19 evening
**Build:** post-E2.4 (commit `aa0525f` + uncommitted minor doc fixes)
**Source:** Windows PC at 1920×1080 (per v_tc_rx detection)
**Operator:** Justin (eyes-on monitor); Claude (UART driving)

## What worked

### 1. E2.4 source format detector (v_tc_rx) — FULL VALIDATION ✓

`i` command produced a complete, accurate dump of the source format:

```
[I] SOURCE
    pLocked  : YES
    detector : LOCKED
    HxV act  : 1920x1080
    HxV tot  : 2200x1125
    H sync   : start=2009 end=2053  pol=POS    (44-pixel width — CEA-861 1080p60 spec)
    V sync   : start=1083 end=1088  pol=POS    (5-line width — CEA-861 1080p60 spec)
    AV pol   : POS                              (matches CEA-861)
    rate     : 62.006 Hz                        (anomaly — see below)
    pclk     : 153.464 MHz (derived from HTOTAL × VTOTAL × rate)
```

Every structural field matches the CEA-861 1080p60 spec exactly. Detector works.

### 2. E2.3 auto-FRC — works end-to-end

`a` command:
- Measured source rate
- Computed M/N via Euclidean GCD → produced 10000/12191 (or 12500/15239 on different invocations)
- Wrote M/N to the src_vsync_divider's AXI GPIO
- Switched ref_mux to SRC mode

The **14-bit M/N value** only fits because P1-3 widened the divider's M/N width 8→16. Pre-P1-3 would have rejected this case.

### 3. E2.2 multi-mode lock — switching banner correct

`o film` produced: `[O] lock mode = FILM (Kp=3.000, Ki=0.300, lock_frames=150, lock_thresh=1333 t)` — gains exactly as defined. The `LOCK mode=FILM ...` summary line confirms the active mode propagates through the loop tick code.

### 4. E2.1 src-vsync ref selector — engages cleanly

The `[I] LOOP` section reported `ref: SRC (mask=0)` after `a`. The src_vsync_divider's output is being routed to vsync_timestamp via the ref_mux. Confirmed in `i` output.

### 5. E1.7 firmware stability — UART hangs gone

Across hundreds of UART interactions during the session, never observed a firmware hang. The boot-drain + capture-loop-timeout fixes hold. (UART chaos in this session was *host-side* buffer accumulation, not firmware hangs.)

### 6. E1.7 timing closure — confirmed via build

WNS=+0.473 / WHS=+0.014 reported (intrinsic +0.064 ns). Well above the +0.050 ns floor across multiple rebuilds.

## What didn't work

### 1. PI loop never reaches LOCKED state

In both SMOOTH and FILM modes:

- Per-cycle `err` jumps wildly: **±900k ticks** (≈ half of a 50 Hz period at 100 MHz = ±10 ms = ±375 lines at 720p50)
- `cmd_mppm` is at or near the ±500k saturation clamp on most cycles
- `int_mppm` is bounded but oscillates over a range of ~300k mppm
- State stuck in `ACQUIRING`; never declared `LOCKED`
- Mean err over a few-frame window appears ~0 — the loop *is* averaging to the correct rate, but the instantaneous criterion never sees it

### 2. Picture has static mistiming on monitor

Visible as a vertical wraparound: top of screen shows top of source frame, taskbar mid-screen, then a duplicate band of the source's upper portion at the bottom. Pattern is **static** (not rolling/scrolling) — the rate ratio is correct but the framestore is being read with a fixed phase offset.

Loop engagement (`L`) did not change the picture noticeably. The static-mistiming pattern was present both with loop OFF and with loop ON.

### 3. Source rate measurement still reads off

Measured: 62.006 Hz (in one call) and 60.95–60.96 Hz (in subsequent calls). Expected: 60.000 Hz exactly (Windows 1080p60).

- 62.006 vs 60.000 → +33,433 ppm bias  
- 60.956 vs 60.000 → +15,933 ppm bias

Either:
- Source genuinely isn't at 60.000 Hz (Windows in a custom EDID mode), OR
- P0-1's edge-alignment fix didn't address all bias sources (still a measurement bug)

If the source IS 60.000 Hz and the iter-4a reading is biased high, the auto-FRC math also goes wrong: M/N=10000/12191 against a real 60.000 Hz source produces ref pulses at **49.22 Hz**, not 50.00 Hz. Loop would need −15,000 ppm pull (far outside ±500 ppm range) to match output to ref → loop saturates → never locks. That hypothesis is consistent with the observed loop behavior.

## Reflection — how far back?

Five architectural decisions are now worth re-examining, in roughly the order they were made:

### A) **Bresenham fractional divider for source-derived ref** (Phase E2.1)

The divider produces 1-cycle pulses with intervals that vary by ±1 source period. For M/N=5/6 at 60Hz source: 5 pulses out of 6 source edges, with one "skip" per 6-edge cycle.

**Consequence:** the loop's per-edge phase detector sees ±half-source-period of *unavoidable* jitter on every ref edge. This jitter dominates the per-cycle `err` value (±900k ticks observed), forcing the PI controller into per-cycle saturation regardless of mode.

**Realistic options:**
1. Software median filter on ts_ref before phase compute (~10 lines firmware, no HDL change)
2. Hardware: replace Bresenham with an **interpolated counter** — generate evenly-spaced output pulses by counting at pixel-clock rate divided by a fractional accumulator. Higher HDL cost, perfect output.
3. Use a different reference architecture entirely (Si5351 fractional PLL — Phase E2 originally planned anyway).
4. Lock to source vsync directly (no divider) — requires output VTC at source rate, which means **runtime output-mode switching** (deferred P2-7).

### B) **Per-edge phase detector** (Phase E1, vsync_timestamp design)

The detector captures ts_out and ts_ref on edges and computes phase per-edge. This works perfectly when ref and output rates are equal (1:1 lock). When they're equal-on-average-but-jittery (Bresenham), per-edge phase is dominated by jitter, not by drift.

**Realistic options:**
1. Keep the detector; do the filtering in firmware (option A.1 above).
2. Replace with a **phase accumulator detector**: a hardware counter ticks at expected ref rate; compares current ts_ref to its predicted phase; outputs only the residual. Robust to ref jitter. Bigger HDL change.

### C) **Loop's lock criterion: instantaneous err** (Phase 6)

`LOCK_THRESHOLD_TICKS` compares per-cycle |err| to a fixed limit. This works in synth-ref mode (clean ref, low jitter). In src-ref mode it's wrong.

**Realistic options:**
1. Rolling-mean criterion (review's option A.1).
2. Two-tier: instantaneous threshold for synth-ref mode; rolling-mean threshold for src-ref mode. Add to lock_mode_t struct (orthogonal to gains).

### D) **iter-4a source rate measurement** (Phase D, used by E2.3)

After P0-1 fix, reading is still off by tens of thousands of ppm. Either source isn't at expected rate, or there's a different bias source.

**Realistic options:**
1. Cross-check with v_tc_rx's detected timings. We now have HTOTAL=2200, VTOTAL=1125, vsync polarity etc. If we measure the pixel clock independently (e.g., GPIO-loopback of dvi2rgb's PixelClk through a divider, timestamped), we can derive frame rate as pclk/(HTOTAL×VTOTAL) — independent of vsync-edge counting.
2. Use v_tc_rx's internal frame counter (the detector counts frames; expose via register read).
3. Investigate the residual bias mechanically: instrument with known-rate signal (e.g., divider output) into the iter-4a path.

### E) **VDMA Dynamic Genlock alignment** (Phase D iter-4d-3)

Picture has static mistiming regardless of loop state. The 6:5 FRC ratio appears correct (no rolling), but the read-pointer is initialized at the wrong phase relative to the source's first frame. Phase D handled this for synth-ref mode by aligning VTC fsync to source vsync at boot; for src-ref mode, that alignment may not still hold (or may need re-running each time ref source changes).

**Realistic options:**
1. Add explicit VDMA park-pointer initialization step after the auto-FRC `a` command applies.
2. Reset Phase D's alignment sequence after every ref-mode switch.

## How far back?

**If the goal is "src-ref mode produces a clean picture":**

Far enough back to address (A) or (B). The Bresenham divider's jitter is fundamental and can't be hidden by tuning the PI gains. Either filter in firmware (cheapest) or rebuild the divider as an interpolated counter (proper). My recommendation: **(A.1) software median filter** as the next iteration; defer (B) until Si5351 lands and we can drop the MMCM-based actuator entirely.

**If the goal is "auto-FRC computes the correct M/N":**

Verify (D). The iter-4a bias might be a real Windows-custom-mode situation, or my P0-1 fix might be incomplete. Cross-checking with v_tc_rx's detected timing (HTOTAL × VTOTAL × derived rate) is the cheapest validation.

**If the goal is "picture is monitor-clean":**

(A) + (E). The framestore alignment issue is independent of the loop's behavior; both need addressing.

**If the goal is "Phase E1/E2 spike is declared production-architecture-validated":**

The spike's architectural claims are already validated where the substrate cooperates (E2.4 detector, E2.1 ref selector, E2.2/E2.3 firmware). The Bresenham jitter problem is **an artifact of the MMCM actuator's narrow pull range + the simple Bresenham divider choice**. With Si5351 (Phase E2's planned actuator swap), the pull range is wider AND we can lock to source vsync directly without a fractional divider (because Si5351 produces output at source × m/n exactly, no fractional ref pulse generation needed). So **most of (A)–(E) may evaporate after the Si5351 swap.**

The architectural understanding is sound. The current bench has surfaced two real issues (Bresenham jitter and framestore alignment) but both have known paths to resolution. The biggest open question is **(D) the iter-4a bias** — if real, it's a problem; if a measurement artifact, it's solvable.

## Next-session candidate work

In rough priority:

1. **Cross-check the iter-4a reading against v_tc_rx-derived frame rate.** This is a 10-minute firmware change: have `i` compute `vsync_rate = pclk / (HTOTAL × VTOTAL)` from detector registers and compare to iter-4a. If they agree, source really is at the reported rate. If they diverge, iter-4a has bias.

2. **Software median filter on ts_ref samples in loop_tick** (option A.1). Tiny firmware change to test the jitter-suppression hypothesis without HDL work.

3. **Investigate framestore alignment in src-ref mode** (option E). Probably ties into the Phase D iter-4d-3 alignment dance.

4. **Defer Si5351-readiness items** until that board arrives.

## Build state at session end

- Branch: `phase-e1-pll-spike`
- Latest commit: `aa0525f` (E2.4 detector)
- Uncommitted: this doc + the bench review's results section
- Bitstream / firmware: loaded, board running, loop ENGAGED in FILM mode with src-ref + M/N=10000/12191. Loop is ACQUIRING (not LOCKED), picture has static framestore offset.
