# Bench session — E2 validation + P0-2 Bresenham jitter

**Target session:** next bench window after 2026-05-19.
**Goal:** validate the E2 stack (E2.1 src-vsync ref + E2.2 multi-mode lock + E2.3 auto-FRC), confirm the two pre-bench fixes (P0-1 measurement bias, P1-3 16-bit M/N), and resolve the one remaining architecture question (P0-2 Bresenham jitter response). After this session, the spike either declares done or surfaces a concrete follow-up.

**Expected duration:** ~3 hours. If any step blocks, drop the later steps and document what you learned.

**Companion docs:**
- [`phase_e1_e2_bench_review.md`](phase_e1_e2_bench_review.md) — full review with priorities
- [`phase_e1p6_baseline_root_cause.md`](phase_e1p6_baseline_root_cause.md) — context on monitor vs MS2109

---

## 0. Pre-flight (10 min)

### Gear checklist

- [ ] **Zybo Z7-20 board**, USB-attached to host for JTAG + UART.
- [ ] **HDMI source #1 — Windows PC** (the calibration source from prior phases). Output set to 1920×1080 @ 60 Hz. Have the PC powered up *before* connecting; some sources need to handshake on HDMI plug.
- [ ] **HDMI source #2 — Mac** (any Mac with HDMI out, or DisplayPort/USB-C → HDMI adapter). Default 1080p60 output (which Mac will produce as 59.940 Hz unless explicitly told otherwise).
- [ ] **HDMI source #3 (optional)** — Apple TV, Roku, video player, or anything with HDMI out. Useful for source variety; not required to declare the session done.
- [ ] **Real HDMI monitor**, 720p50-capable. Confirm it accepts 50 Hz signals before starting (most modern monitors do, some older PC-only displays don't). **The monitor is the primary truth source** for this session — MS2109 hid failure modes in earlier phases.
- [ ] **MS2109 capture stick** (secondary verification). Connect to the host so you can see the output stream alongside the monitor. Don't rely on it alone.
- [ ] **Host computer** with serial terminal (115200 8N1, on the Zybo's UART USB device — typically `/dev/ttyUSB1` on Linux, `COMx` on Windows). I recommend `picocom -b 115200 /dev/ttyUSB1` or `minicom`; use `screen` if neither is available.
- [ ] **Notebook or scratch file** for capturing observations per step.

### Software prep

- [ ] Build artifacts at commit `0c3a48e` or later. Verify with `git log --oneline -1` in the repo before going to the bench.
- [ ] Bitstream + firmware ELF ready in Vitis or `xsct` workflow. Use the existing program scripts (`tcl/program_phase_b.tcl` or whatever the current name is).
- [ ] A scratch CSV/text file open for noting UART output snippets per step.

### Source HDMI cables

- [ ] At least 2 HDMI cables (one to feed the Zybo, one for the output to monitor). Three if you want both MS2109 and monitor.
- [ ] If using HDMI splitter for parallel monitor + MS2109 verification: verify it doesn't add EDID weirdness — pass through with `--no-edid-injection` if your splitter supports it.

### One pre-bench check before powering on

- [ ] Confirm the firmware on disk matches the bitstream you're about to load. (Easy mistake to make: build bitstream from one commit, firmware from another — symptoms are mysterious.)

---

## 1. Wiring + power-up (10 min)

Standard Zybo + HDMI source setup. Nothing new from prior sessions, but worth re-checking from a cold start.

```
HDMI Source #1 (Windows PC) ──HDMI──> Zybo HDMI IN (J10)

Zybo HDMI OUT (J11) ──HDMI──> Monitor
                         └──> MS2109 → host USB  (optional, via splitter)

Zybo PROG/UART (USB) ────────> Host computer (JTAG + serial)
```

Sequence:

1. [ ] Connect HDMI source #1 to Zybo HDMI IN. **Do not turn the source on yet.**
2. [ ] Connect Zybo HDMI OUT to monitor (or splitter → monitor + MS2109).
3. [ ] Connect Zybo USB to host. Both JTAG and UART enumerate.
4. [ ] Power on Zybo (it'll boot but with no bitstream yet).
5. [ ] Open serial terminal: `picocom -b 115200 /dev/ttyUSB1` (or platform equivalent).
6. [ ] Power on the HDMI source. Wait for it to come up to its desktop.
7. [ ] Program board: `xsct tcl/program_phase_b.tcl` (or the appropriate program script for the current build).
8. [ ] Watch UART for boot banner. Expect to see firmware initialization messages.

**If you see nothing on UART after program:** check the serial terminal's port matches the Zybo (often the PROG/UART is two devices — pick the higher-numbered one, often `ttyUSB1` not `ttyUSB0`). UART RX drain on boot (E1.7 fix) means any keyboard input you make before firmware is ready will be silently discarded — that's expected, not a bug.

---

## 2. Sanity check — confirm baseline before testing (10 min)

Before running the new tests, verify the build is in a known-good state.

### 2a. Boot defaults

Expected behavior immediately after program:

- Banner prints, including version / build info.
- `LOCK mode=SMOOTH state=OFF` (or similar) once per second (the per-second telemetry summary).
- Reference mux selector reports `SYNC` (synth_vsync_gen reference, the legacy mode).
- Loop is OFF (no `L` issued yet).

Send:

```
?
```

Expected: help banner listing commands including `L`, `U`, `r`, `s`, `n`, `o`, `a`, `q`, `p`, `d`, `D`, `?`.

**If help banner is missing `a` or `n` or `o`:** wrong firmware loaded. Re-check the build commit and re-program.

### 2b. Sanity — legacy synth-ref mode still works

This is the Phase 6 / Phase 7 / Phase 8 baseline. If this regressed, something landed wrong in E2.x.

Send:

```
L
```

Expect: `[L] Phase 6 loop ENABLED (ts_ref_count=…, mode=SMOOTH)` plus gains banner. State transitions OFF → ACQUIRING → LOCKED over ~30–60 s.

Wait ~60 seconds. Expect to see `>>> LOCKED at frame N` and a sequence of `state=LOCKED` summary lines.

**Look at the monitor:** picture should be stable. Either the Phase 6 known-clean test pattern (if there's one in the build), or a passthrough of the source content (depends on the BD).

If monitor is clean and UART reports LOCKED:
- [ ] Sanity passed; the spike's known-good state is reproduced.

If monitor is *not* clean even at LOCKED:
- The pre-review build (E1.7 + E1.8 + E2.1 + E2.2 + E2.3 + this commit) regressed something. Don't proceed with new tests. Capture UART, capture a phone photo of the monitor, file as a regression.

Send:

```
U
```

To disable the loop. State should drop to OFF.

---

## 3. Step 1 — Confirm P0-1 (measurement bias fix) — 5 min

**Goal:** verify the iter-4a rate detector now reads ~60.000 Hz against the Windows source. Pre-fix it read ~60.164 Hz (+2733 ppm bias).

### Procedure

1. Ensure Windows source is connected and source HDMI is locked at the dvi2rgb (verify with `q` — should show source rate measurements). If `pLocked` isn't asserted, source isn't connected properly.
2. Send `a` (auto-FRC command).
3. Observe UART output. Expect:
   ```
   [A] auto-FRC: measuring source rate (~1 s) ...
   [A] source = 60.000 Hz (or within ±50 ppm); output target = 50.000 Hz
   [A] APPLIED: M/N = 5/6 → ref = source × 5/6 (= 50.000 Hz target)
       ref_mux now in SRC mode. Send 'L' to engage loop if not already.
   ```

### Pass criterion

- [ ] Source measurement within ±50 ppm of 60.000 Hz.
- [ ] M/N = 5/6 reported.
- [ ] No FAILED message.

### If fail

- **If source reads ~60.164 Hz still:** the P0-1 fix didn't take effect (or is on a different code path). Stop and check: `git log -1` to verify commit; reflash firmware if needed.
- **If `a` reports REJECTED with "reduced terms > 65535":** the 16-bit widening (P1-3) didn't take effect on the BD side. Check the bitstream is post-`0c3a48e`. Re-program if needed.
- **If source reads close to 60 but not exactly 5/6:** e.g., 60.05 Hz. The reduction `gcd(50000, 60050) = 50 → 1000/1201` would not fit in 8-bit M/N but does in 16-bit. Verify the test passed by checking the M/N values reported, not just "did it report something."

### Recording

```
Step 1 — P0-1 confirmation:
  source rate measured: ______ Hz
  M/N reported: ______ / ______
  PASS / FAIL: ______
  notes: ______
```

---

## 4. Step 2 — Confirm P1-3 (16-bit NTSC support) — 10 min

**Goal:** verify the canonical NTSC case (Mac at 59.940 Hz, output 50.000 Hz) produces M/N = 2500/2997 cleanly.

### Procedure

1. **Power off Zybo first** (some sources don't re-EDID cleanly mid-session). Actually — Zybo doesn't need to be off; just swap the HDMI cable at the source end.
2. Disconnect Windows PC, connect Mac to Zybo HDMI IN.
3. Set Mac display preferences to 1920×1080 @ 60 Hz. (Mac defaults to 59.940 at this setting; most modern Macs don't expose 60.000 as a choice.)
4. Wait for HDMI handshake (~5 s).
5. Send `U` to ensure the loop is off (carry-over from Step 1).
6. Send `r free` to reset the reference selector to free-run state (avoid stale state from Step 1).
7. Send `a` (auto-FRC).
8. Observe UART output. Expect:
   ```
   [A] auto-FRC: measuring source rate (~1 s) ...
   [A] source = 59.940 Hz (or within ±50 ppm); output target = 50.000 Hz
   [A] APPLIED: M/N = 2500/2997 → ref = source × 2500/2997 (= 50.000 Hz target)
       ref_mux now in SRC mode. Send 'L' to engage loop if not already.
   ```

### Pass criterion

- [ ] Source rate measured within ±50 ppm of 59.940 Hz.
- [ ] M/N = 2500/2997 reported (NOT 5/6, NOT REJECTED).
- [ ] No FAILED message.

### If fail

- **REJECTED:** P1-3 fix didn't propagate fully. Check the BD GPIO width (Vivado address editor; `axi_gpio_srcdiv` should be C_GPIO_WIDTH=16). If it's still 8, the bitstream is pre-fix.
- **M/N reports 5/6:** the firmware's `compute_frc_ratio` is still capping at 255. Check `cmd_auto_frc` and `compute_frc_ratio` in `sw/phase-b/src/main.c` — bound should be ≤65535.
- **Source rate way off (e.g., reads 60.000):** Mac is actually outputting 60.000 (some configs do). Try forcing the Mac to a 59.94-explicit mode if available, or accept and continue with whatever rate Mac is producing.

### Recording

```
Step 2 — P1-3 confirmation:
  Mac source rate: ______ Hz
  M/N reported: ______ / ______
  expected: 2500 / 2997
  PASS / FAIL: ______
  notes: ______
```

---

## 5. Step 3 — P0-2 Bresenham jitter investigation — 60 min

**Goal:** observe the PI loop's behavior in src-ref mode. Decide whether the Bresenham jitter is a real architectural problem (Outcome C in the review doc) or just a measurement-metric issue (Outcomes A/B).

### Step 3a — Engage src-ref + FILM mode

Stay with the Mac source from Step 2 (or switch back to Windows — both work; Windows simpler because Step 1 already confirmed it). For this step I recommend **Windows source** (cleaner reference point — the Mac NTSC ratio adds a variable on top of the jitter we're trying to study).

1. If still on Mac source, swap back to Windows PC. Wait for HDMI handshake.
2. Send `a` to set up src-ref + M/N=5/6. (Re-running `a` is harmless.)
3. Send `o film` to switch to FILM mode. Expect: `[O] lock mode = FILM (Kp=3.000, Ki=0.300, lock_frames=150, lock_thresh=1333 t)`.
4. Send `L` to engage the loop.

### Step 3b — Observe for 5 minutes

For the next 5 minutes, watch four things simultaneously:

| What | Where | What you're looking for |
|---|---|---|
| Monitor picture | Real monitor | **Clean** = success (per Phase E1.6 lesson, this is the *real* metric); tearing / horizontal stripes / drift = failure |
| LOCK state | UART per-sec summary | Will likely report `ACQUIRING` indefinitely due to jitter; that's the *expected* failure of the legacy instantaneous-err criterion |
| `err` rolling mean | UART per-sec summary (`err=N/min/max`) | Should be small (near 0) on the mean field, even if min/max swing widely |
| `cmd_mppm` stability | UART per-sec summary | Should hover near a stable value (probably −100 mppm given the +102 ppm baseline); large swings = integrator being pumped |

The 5 minutes lets you separate "transient — still acquiring" from "steady-state behavior."

### Step 3c — Capture a 60-second telemetry sample

After the 5-minute observation, capture detailed telemetry for analysis:

1. Send `S` to enable per-frame CSV dump (if not already on).
2. Wait ~60 seconds — collecting ~3,000 samples at 50 Hz output.
3. Send `S` again to disable CSV dump.
4. **Save the UART log** as `tests/phase-e1/phase_e1p8_p0p2_bresenham_film.csv` (or similar). The session can analyze this offline.

### Step 3d — Compare with SMOOTH mode

1. Send `U` (disable loop).
2. Send `o smooth` (back to default mode).
3. Send `L` (re-engage).
4. Wait 30 s; observe.
5. Note any difference between SMOOTH and FILM behavior:
   - Picture cleanliness (same / better / worse)
   - LOCK indicator (does SMOOTH lock, vs FILM stays ACQUIRING?)
   - `cmd_mppm` stability (SMOOTH may hunt more aggressively)

### Step 3e — Pick outcome A / B / C

After the comparison, classify the result:

**Outcome A** (best): FILM mode produces clean monitor picture + stable `cmd_mppm` + bounded `err` mean. SMOOTH may also work but with more `cmd` hunting. → Just need to redefine the lock criterion to be rolling-mean-based. Architecture is sound.

**Outcome B** (middle): FILM produces clean picture but SMOOTH/SNAP don't (integrator runs away under the higher gains). → src-ref + FILM is the production combo. Document the limitation.

**Outcome C** (worst): even FILM doesn't produce a clean monitor picture. Either `cmd_mppm` is being pumped by jitter, or the integrator is winding up despite the slower gains. → Need software median filter on `ts_ref` samples, OR HDL refactor of the divider for interpolated output.

### Pass criterion (P0-2)

- [ ] At least one mode (FILM minimum) produces a clean monitor picture.
- [ ] At least one mode has bounded, stable `cmd_mppm`.
- [ ] Outcome (A/B/C) determined from observation, not guess.

### Recording

```
Step 3 — P0-2 Bresenham jitter investigation:
  Source: Windows PC (~60.000 Hz)
  M/N: 5/6
  
  FILM mode (Kp=3, Ki=0.3):
    monitor picture: ______
    LOCK state after 5 min: ______
    err mean (per-sec): ______ ticks
    err min/max range: ______ ticks
    cmd_mppm: stable around ______ mppm, range ±______
  
  SMOOTH mode (Kp=10, Ki=1):
    monitor picture: ______
    LOCK state after 5 min: ______
    err mean: ______
    cmd_mppm: stable around ______ mppm, range ±______
  
  Outcome (A / B / C): ______
  CSV captured: yes / no, filename: ______
```

---

## 6. Step 4 — Multi-source soak — remaining time

**Goal:** validate the full E2 stack against a variety of HDMI sources. This is the "does the architecture actually work in the field" test.

Picking the mode based on Step 3 outcome:
- **Outcome A:** use SMOOTH (default) for this step.
- **Outcome B:** use FILM.
- **Outcome C:** use FILM but expect known limitations; this step is preview.

### Procedure (per source, ~10 min each)

1. Disconnect current source, connect new source. Wait for HDMI handshake.
2. Send `a` (auto-FRC).
3. Record: source rate reported, M/N reported, any FAILED message.
4. Send `L` (loop on, if it auto-engages this is OK).
5. Wait 30 s. Record:
   - Monitor picture: clean / tear / artifact / drift
   - UART state evolution (ACQUIRING → LOCKED, or stays ACQUIRING)
   - `cmd_mppm` steady value
6. **Run for 5 min sustained.** Note any UNLOCK events or picture changes.
7. Snapshot via MS2109 (or phone photo if monitor) for record.

### Sources to try (priority order)

- [ ] **Windows PC at 1080p60** (re-validate the canonical baseline)
- [ ] **Mac at 1080p60** (the NTSC test — confirms P1-3 architecturally)
- [ ] **Mac at 1080p50** if Mac supports it (the 1:1 case — should pass through cleanly)
- [ ] **Apple TV / Roku** (different oscillator, drift envelope)
- [ ] **PC at non-standard rate** (60.05, 59.95 if you can force the display setting — stresses the M/N reduction)

### Pass criterion (overall)

- [ ] Windows source: continues clean (regression check on Phase 7 + P0-1)
- [ ] Mac source: clean picture with src-ref + auto-FRC engaged (production-architecture validation)
- [ ] At least one alternative source: clean picture (multi-source robustness)
- [ ] No UNLOCK events across all sources in a 5-min window each

### Recording

```
Step 4 — Multi-source soak:

  Windows PC:    rate=____ M/N=____  picture=____  notes=____
  Mac (1080p60): rate=____ M/N=____  picture=____  notes=____
  Mac (1080p50): rate=____ M/N=____  picture=____  notes=____
  Apple TV:      rate=____ M/N=____  picture=____  notes=____
  Other:         rate=____ M/N=____  picture=____  notes=____
```

---

## 7. Post-session — commit & write up (15 min)

Once you're done at the bench:

1. **Save the UART logs.** Each step's serial terminal output goes into a timestamped file:
   - `tests/phase-e1/bench_session_<date>_step1_p0p1.txt`
   - `tests/phase-e1/bench_session_<date>_step2_p1p3.txt`
   - `tests/phase-e1/bench_session_<date>_step3_p0p2.csv`
   - `tests/phase-e1/bench_session_<date>_step4_soak.txt`

2. **Write up the results** as `tests/phase-e1/bench_session_<date>_results.md`. Structure: per-step summary (PASS/FAIL/observation), outcome of P0-2 (A/B/C), residual issues. Cross-reference against the review doc's P0/P1 items.

3. **Decide:** does the spike declare done, or does P0-2 surface architectural follow-up?
   - **Outcome A**: spike done. Next agent works on Mackin functional + Si5351 swap path.
   - **Outcome B**: spike done with documented mode limitation. Same next steps.
   - **Outcome C**: spike done with one HDL or firmware follow-up (median filter or divider refactor) added to the queue.

4. **Update the review doc** ([`phase_e1_e2_bench_review.md`](phase_e1_e2_bench_review.md)) with the cross-check results. Mark P0-2 as PASS or ESCALATED. Update the §5 interaction matrix with measured values.

5. **Commit** the results docs and any firmware changes that came out of bench observation. Commit message format consistent with prior phases: `phase-e2: bench session <date> — outcome A/B/C summary`.

---

## 8. Failure-mode triage (if things go sideways)

If anything in Steps 1–4 fails in a way the inline troubleshooting doesn't cover, here's a triage tree:

### Symptom: UART hangs (no output for 30s after a command)

E1.7 already fixed this for the most common cause (untimed polling loops + typeahead garbage). If it recurs:
- **Most likely:** a *new* polling loop got added in E2.x without a timeout. Most likely suspect is the auto-FRC rate measurement.
- Test: power-cycle Zybo + drain UART input (don't type anything) + program fresh + send minimal commands. If it still hangs, capture exactly which command caused it. File as a regression.

### Symptom: monitor tearing across all sources, all modes

E1.6's MS2109 caveat is *not* the issue here (you're on the monitor now). Likely:
- **VTC output rate is wrong:** `q` should show ts_out advancing at ~2M ticks per 20ms. If far off, the MMCM isn't producing the expected pixel rate.
- **Source rate measurement broke again:** double-check Step 1 confirmation.
- **HDL regressed:** worst case. Compare bitstream commit against `0c3a48e` (or current latest passing).

### Symptom: `a` always FAILED, even on Windows

- Source isn't actually locked: confirm via `q` that pLocked is asserted.
- Source rate measurement returns 0: timeout in `measure_source_rate_mhz` — increase its timeout if the source is producing slow vsyncs.
- Source rate produces an irreducible M/N > 65535: check the actual computed value via UART debug output; may need P1-3 to be widened further or different math.

### Symptom: monitor shows scrolling stripes (Phase E1.6-style)

This means output rate isn't matching source × M/N. Most likely:
- `r src` isn't actually engaged. Check UART for `[R] reference = SRC` message.
- Loop hasn't acquired yet. Wait full 60 s.
- Bresenham divider is producing wrong M/N. Check `q` output for divider state.
- **If all above check out and stripes persist:** P0-2 Outcome C — actuator can't follow the reference cleanly. Document and stop pursuing this source for the session.

---

## 9. Quick reference — UART commands

For copy-paste / glance reference:

```
?              Help banner
q              Query current state (ts_ref, ts_out, source rate, etc.)
p              Print current phase delta
L              Enable closed loop
U              Disable closed loop
r free         Reference = free-run (sel=00)
r sync         Reference = synth_vsync_gen (sel=01)
r src          Reference = source-vsync via divider (sel=11)
s              Toggle reference mask (force ref to 0)
n <M> <N>      Set src_vsync_divider M/N ratio
o snap         Lock mode = SNAP (Kp=30, Ki=5)
o smooth       Lock mode = SMOOTH (Kp=10, Ki=1) [default]
o film         Lock mode = FILM (Kp=3, Ki=0.3)
a              Auto-FRC: measure source rate, set M/N, switch to SRC ref
d              Drift capture (single-shot, 3000 samples)
D              Drift capture (continuous, prints CSV)
S              Toggle per-frame CSV dump
```

---

## 10. After-session checklist

- [ ] All UART logs saved to `tests/phase-e1/bench_session_<date>_*.txt`
- [ ] Photo of monitor for each source (phone photo OK)
- [ ] Results summary written to `tests/phase-e1/bench_session_<date>_results.md`
- [ ] Review doc updated with P0-2 outcome
- [ ] Commit pushed (`git push`)
- [ ] Spike-done declaration made, or next-step follow-up filed

Done. The spike either closes here or has one bounded follow-up remaining.
