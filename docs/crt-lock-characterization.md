# Schindler 2.0 — CRT Lock Characterization & Composite-Output Crafting

**Status:** Draft 2026-06-06 — captures the CRT-compatibility model, the MVPHD-24 trick catalog, the preset framework, the active-line/scaler coupling rule, and the composite-output ownership map. Decisions banked from the 2026-06-06 session. **Not yet bench-validated** — the per-model lock ranges are a bench output, not a literature output (see §11).

**Purpose:** SSOT for two questions — *"how much range do we have to coax a CRT into locking at film rate, and how do we craft the signal to do it"* and *"which block owns the composite output."* Grounds the intelligent-timing-module design in the MVPHD-24 reference behavior so we mimic it rather than reinvent it.

**Sources:**
- `MVPHD-24-flyer-v2.pdf` — Appendix A Specifications, "COMPOSITE OUTPUT FORMATS" table (the format recipe).
- `MVPHD-24-OM-v0-9-0.pdf` — Ch. 4 "Overview of 24 Fps Video Playback" (pp. 45–48); Ch. 5 "Tips and Suggestions" (pp. 49–53).
- NTSC receiver vertical-sync pull-in patents (US 4,425,576; US 4,489,343) for the count-type lock windows.
- Internal: [[signal-flow]], [[dev-roadmap]], [[mvphd-comparison]], [[rf-modulator-subsystem]].

---

## 1. The core constraint: horizontal is free, vertical rate is the whole game

For driving a CRT at film cadence, the horizontal oscillator is a non-issue — 24 fps lands the line rate at ~15.6–15.75 kHz, within a few hundred Hz of standard NTSC (15.734 kHz), inside every set's horizontal AFC capture range. **The entire problem is vertical.** 24 fps forces a field rate (48 Hz interlaced, or 24 Hz progressive) that sits below where most sync circuits will lock, and how much room exists depends almost entirely on the set's **vertical-sync architecture**. That architecture sorts CRTs into hard buckets (§2).

The whole premise (MVPHD OM Ch. 4, p. 45): make the video frame rate equal the camera frame rate, so exactly one whole image is exposed per shutter opening and the rolling light/dark band disappears. Everything else is in service of getting the CRT to *accept* that film-rate signal.

---

## 2. CRT buckets by vertical-sync architecture

| Bucket | Vertical-sync type | Lock behavior | 24 fps native? |
|---|---|---|---|
| **A — IC count-type** (~mid-80s consumer onward) | Digital line-counter, no user controls | Hard pull-in window: broadcast mode ~57.8–61.5 Hz, widest (VTR) mode ~54.6–65.6 Hz. Rejects anything below ~54.6 Hz. | **No.** MVPHD OM (p. 49): these "must be modified in order to be used." |
| **B — Pro CRT monitors** (PVM/BVM/Ikegami) | Multiformat autolock | Lock standard rates 50/60 Hz; 50 Hz is the lowest native. External-sync inputs allow a CUSTOM genlock rate. Native 24 not a documented CRT mode. | Marginal — via the PAL/50 window or ext-sync CUSTOM. |
| **C — Analog-hold vintage** (~50s–early 80s) | Free-running oscillator + vertical-hold pot | Wide, adjustable, can be coaxed off-standard. **The trickable class** — the '73 Zenith. | **Yes**, native 48 Hz field, if the hold range reaches ~48 Hz. |

**The multistandard sub-case (cuts across A and B).** A set that accepts PAL (50 Hz) switches into a **PAL vertical window** when it sees PAL-class line counts/horizontal — and that window is centered on 50 Hz reaching *down to ~44 Hz* (PAL count range 288–356 lines). 48 Hz (= 24 fps) sits inside it. This is the lever the MVPHD's PAL-dialect exploits (§3.2). A truly **NTSC-only** count-type set has no PAL window and cannot be reached this way.

**Honest ceiling:** the MVPHD itself does not have a software trick for NTSC-only count-type sets — it tells the operator to modify the hardware (OM p. 49). We inherit that ceiling. Our presets help the *multistandard* subset and the analog sets; NTSC-only IC sets are modify-or-3:2.

---

## 3. The MVPHD trick catalog (mimic, do not reinvent)

### 3.1 Two 24 fps dialects + the full format table

The MVPHD outputs **genuine 24 fps** — interlaced 2:1, 48 Hz field rate — with a non-standard line count chosen to keep the horizontal rate in the CRT's comfort zone. From the flyer's COMPOSITE OUTPUT FORMATS table ("interlaced 2:1 with user controlled active lines of video"):

**NTSC / NT443 / PAL-M family:**

| Fps | Horizontal | Lines/frame |
|---|---|---|
| 23.976 | 15.752 kHz | 657 |
| 24.000 | 15.720 kHz | 655 |
| 25.000 | 15.625 kHz | 625 |
| 29.970 | 15.734 kHz | 525 |
| 30.000 | 15.750 kHz | 525 |

**PAL / SECAM / PAL-N family:**

| Fps | Horizontal | Lines/frame |
|---|---|---|
| 23.976 | 15.608 kHz | 651 |
| 24.000 | 15.624 kHz | 651 |
| 25.000 | 15.625 kHz | 625 |
| 29.970 | 15.734 kHz | 525 |
| 30.000 | 15.750 kHz | 525 |

Mechanism: to drop the frame rate to 24 while holding the horizontal near-standard, **add lines** (525 → 655 NTSC, → 651 PAL). Field rate is 48 Hz either way.

### 3.2 The PAL-dialect is native 24 in PAL clothing (not a speed conform)

The PAL-family 24 fps row keeps horizontal at **15.624 kHz ≈ exact PAL (15.625)**. A multistandard set sees PAL-class horizontal + line count, enters **PAL mode**, and opens its 50-Hz-centered vertical window that reaches down to ~44 Hz — which brackets the 48 Hz field rate. Result: the set locks a **genuine 24 fps** signal. No speed change, no post conform — it's native 24 dressed as PAL so the lower PAL sync window accepts it.

A literal "run 25, slow to 24 in post" conform is only a **fallback** for a set whose PAL window locks 50 Hz solidly but won't quite reach 48 (§4, §5).

### 3.3 Vertical lock requirement — the honest ceiling (OM p. 49)

Sets with a vertical-hold control (analog, Bucket C) generally have enough range to lock 24 fps. Newer sets with a digital locking circuit and no controls (Bucket A) may not lock at 24 fps and **must be modified** to be used. The reference device does not crack count-type sets in software; neither do we.

### 3.4 Shutter angle ↔ blanking: the active-line lever (OM Ch. 4–5, pp. 47–53)

The blanking interval hides the field seam, giving shutter-angle latitude around 180°:
- Standard 24 fps ≈ **300 active lines/field of 655 total**.
- Min shutter angle = 300/655 = 45.8% → **164.9°** (captures all of field 1).
- Max shutter angle = (655−300)/655 = 54.2% → **195.1°** (before field 2 begins to expose).
- Standard ~8% blanking → tolerance of ±14° around 180° before a visible band appears; tolerance tightens as you approach the edge.

**Extending the range:** reduce vertical active size to widen blanking. Floor is **150 active lines/field** (50%), giving max angle (655−150)/655 = 77.1% → **278°**. The picture then looks vertically compressed on the CRT; the operator re-stretches it with the **monitor's own vertical-size control** (use the Sizing Chart pattern). Add extra guard blanking to cover phase/frequency tolerance when running near the limits.

So **active-line count is a first-class parameter** (a shutter-angle lever), not just a porch tweak. See §8 for how it ties to the scaler.

### 3.5 Genlock to anything; camera-as-reference (OM p. 51)

The MVPHD locks to a frame square wave, vertical drive, composite sync (no burst), black burst, or HD tri-level — and can lock directly to a **single camera's shutter/frame/V-drive signal** with no sync box (the monitor is phase-adjusted instead of the camera). Matches our camera-as-reference plan.

**Gotcha:** if the camera's shutter signal is *mechanically* generated, color-phase (tint) errors can appear on composite/Y-C outputs — for mechanical shutter signals, recommend **component output**. Bank in operator guidance.

### 3.6 Shutter phasing — F1-BLU/F2-YEL (OM p. 52)

Field-alternating pattern (blue field 1, yellow field 2) that reads as flashing gray to the eye. With a 180° shutter the camera sees one field — solid blue or solid yellow when phased; split blue/yellow when mis-phased. Already banked in our spec as **Shutter Phase Reference** (color pair operator-selectable). This is also the natural manual aid alongside the camera-feed auto-phasing loop (§7).

---

## 4. Rate strategies to land inside a lock window

| Strategy | Field rate | Works on | Notes |
|---|---|---|---|
| **Native 48 (NTSC dialect)** | 48 Hz | Bucket C analog-hold | 655 lines / 15.720 kHz. Relies on vertical-hold range reaching 48 Hz. |
| **Native 48 (PAL dialect)** | 48 Hz | Multistandard A/B | 651 lines / 15.624 kHz. Locks via PAL window (§3.2). Native 24, no conform. |
| **60 Hz + 3:2 pulldown** | 59.94 Hz | Bucket A (incl. NTSC-only) | CRT runs standard; content is 24p-origin via 3:2. Cadence judder handled by shutter sync. The only path for NTSC-only IC sets short of hardware mod. |
| **25→24 conform** | 50 Hz | Multistandard A/B that won't reach 48 | Shoot camera + CRT both at 25 (coherent), conform 25→24 in post (4.2% slowdown). Fallback only; PAL-dialect native-48 is preferred. |
| **72 Hz (3 fields/frame)** | 72 Hz | Rare wide/multisync | Pushes *up* instead of down. Above the count-type 65.6 Hz ceiling, so only very tolerant sets. |

---

## 5. Presets (3 + CUSTOM, mirroring the MVPHD dialects)

1. **Vintage Analog / Native 24** — Bucket C. NTSC dialect (655 lines / 15.720 kHz), 48 Hz field, wide back porch, classic equalizing/serration VBI, generous hold margin.
2. **PAL-dialect 24** — multistandard A/B. 651 lines / 15.624 kHz, native 24 in PAL clothing. (This is the "make it look like PAL" idea — it's a real MVPHD mode.)
3. **Modern Consumer / 3:2** — Bucket A (incl. NTSC-only). 59.94 Hz + 24p-origin 3:2, shutter-synced. The "can't get native 24 but can still shoot it" fallback.
4. **25→24 conform** — fallback for sets that lock 50 solidly but not 48 (post-conform required; flag in operator notes so a US crew doesn't shoot a day at 25 thinking it's native 24).
5. **CUSTOM** — always available; per-set tuning never goes away.

---

## 6. Intelligent timing module — decision logic (PS-side)

The module sits on the Zynq PS, above `vid_timing.v`, and chooses parameters; the genlock loop fixes the frame rate; the module decides the raster *shape*. Decision flow:

- **Set is analog-hold (Bucket C)?** → Native 48, NTSC dialect. Tune active-lines/porch via the camera-feed loop.
- **Set is multistandard (A/B with PAL window)?** → PAL-dialect native 48 first; fall back to 25→24 conform if it won't reach 48.
- **Set is NTSC-only count-type?** → 60 Hz + 3:2 + shutter management (or hardware mod — out of our scope).
- Always expose **CUSTOM**.

Free parameters the module controls (everything the locked frame rate leaves open): total line count + dialect, field/interlace structure, front/back porch + sync widths, VBI (equalizing/serration counts), burst phase per field, sync/pedestal levels, and **active-line count** (the shutter-angle lever, §3.4 / §8).

Tier question is open (§12): Tier 2 (model-based solver from a few measured CRT constants) is the v1 target; Tier 3 (closed-loop adaptive via the camera feed) is the headline R&D bet.

---

## 7. Sensor: the camera feed (not a yoke pickup)

Decision 2026-06-06: lock quality is observed from the **camera shooting the CRT**, not a magnetic yoke pickup. Rationale: the only thing that matters is the on-camera result, so optimize directly against it — analyze the operator's return feed (or a tap) for the rolling-bar signature (vertical unlocked), tearing (horizontal unlocked), and shutter-beat flicker. This folds shutter phasing (§3.6) into the same loop. Yoke-pickup path dropped.

---

## 8. Active-line ↔ scaler coupling rule (resolved 2026-06-06)

**One parameter drives both** the composite present-geometry resampler's vertical output size *and* `vid_timing.v`'s active-line count. When active lines are reduced for shutter-angle headroom (§3.4), the composite read engine **resamples the full master image down into exactly that many active lines — it shrinks, it never crops.** The freed-up lines go to blanking, distributed symmetrically (image centered).

This is the MVPHD "Vertical Size" behavior (OM p. 53): shrinking active size compresses the picture on the CRT; the operator re-stretches with the monitor's vertical-size control. **We cannot un-compress it in our pipeline** — the CRT sweeps full screen height regardless of active-line count; we only control how many lines carry picture. Our job is to keep all content intact and centered.

Implementation notes:
- The vertical resize lives in the **composite present-geometry stage** (the per-output analog resampler in [[signal-flow]]), downstream of the shared master — *not* the input format-scaler.
- The polyphase vertical scaler already does arbitrary scale factors; this is a parameter change, not new hardware. 50% floor (150/300 active) from the reference device.
- Active-line change must update the scaler's V scale factor **and** the timing's blanking split in the **same frame** — coordinated atomic write via the sequence-numbered AXI bridge (`PL_BRIDGE`), or it glitches.

---

## 9. Composite-output ownership map (Q2)

**The composite signal is generated by the composite terminal encoder in the FPGA PL fabric.** Concretely, the Phase 2 HDL cluster:

- `vid_timing.v` — raster engine: line counts (655/651 dialect), sync widths, porches, pixel clock, **active-line count**. *Every timing trick lands here.*
- `vbi_gen.v` — vertical blanking structure: equalizing/serration pulses, blanking-line distribution (incl. the extra blanking when active size shrinks).
- `chroma_gen.v` — colorburst and (Phase G onward) I/Q chroma modulation: NTSC-vs-PAL color encoding, per-field burst-phase alternation.
- **composite present-geometry resampler** — the per-output reader that does the §8 vertical resize ("present-geometry — analog" stage in [[signal-flow]]).

Blocks that *direct* the encoder but don't generate the signal:
- **Genlock loop** — sets the frame rate (locks master clock to the camera reference).
- **Intelligent timing module** (PS) — chooses parameters (dialect, active lines, preset) and pushes them to `vid_timing.v` over the AXI bridge.
- **DAC** — ADV7393 (production) / R-2R ladder (Zybo bench) — converts the encoder's digital samples to analog composite. Makes zero decisions.

**Roadmap location:** all composite-output crafting is **Phase G** ("re-attach the analog terminal encoders") in [[dev-roadmap]], building on the scope-validated Phase 2 HDL. The intelligent timing module is the new PS-side layer on top.

---

## 10. Over RF (carrier-coherence correction)

**Correction to bank** (and to propagate into [[rf-modulator-subsystem]] — see §12): the RF **picture carrier** does *not* need to phase-lock to the genlock loop or be reprogrammed when timing changes. NTSC RF is negative-modulated AM; the tuner recovers the composite envelope, and all frame/line timing lives in that recovered baseband. The carrier is just transport — it needs to be frequency-stable and in-channel, nothing more. The only line-rate-coherence requirement is the **3.58 MHz color subcarrier**, which is a baseband concern handled inside `chroma_gen.v`, identical whether the output goes to the BNC or the modulator. The RF doc's dedicated, fixed, stable RF Si5351 was correct; the earlier verbal claim that it must track genlock was wrong.

Consequence: the intelligent timing module is **RF-transparent** — the CRT recovers the same crafted composite and locks the same way. RF adds only three couplings the module must respect:
1. **Modulation-depth ↔ sync-level coupling** — sync tip → max carrier, peak white → min carrier (negative mod); composite levels and RF modulation index set together.
2. **IF-bandwidth edge rounding** — the tuner's VSB IF (~4.2 MHz) softens sync edges; may need slight pre-comp (widen sync / pre-shoot edges) so they arrive clean at the sync separator.
3. **Clamp-aware back porch** — RF detection is AC-coupled with DC restoration off the back porch; the wide-back-porch default matters *more* over RF.

---

## 11. Bench characterization protocol (fills in the per-model data)

The count-type window is precise (silicon, documented). The **analog-hold pull range per model is empirical and unpublished** — it only exists on the bench. Protocol per set:

1. Genlock the Schindler to a swept reference; step the field rate down from 60 Hz toward 44 Hz (and up toward 72 Hz).
2. At each rate, observe the **camera feed** (§7) for lock: roll-bar stopped, no tearing.
3. Log the lockable field-rate range and the rate where lock is most stable (centered, not edge).
4. Assign the set to a bucket (A/B/C) and record which preset + dialect achieves lock.
5. Sweep active-lines at the chosen rate to map the usable shutter-angle range for that set.
6. Save as a per-CRT JSON profile (NovaTool-pattern profile system).

A single afternoon per set builds the profile library that Tier 2 generalizes from.

---

## 12. Open decisions / to-dos

- [ ] **Tier choice for v1** — Tier 2 (model solver) ships; Tier 3 (closed-loop camera-feed adaptive) is the headline R&D bet. Decide commitment.
- [x] **Propagate the §10 RF carrier-coherence correction into [[rf-modulator-subsystem]]** — DONE 2026-06-07; clarification note added to the RF doc's "Si5351 dedicated to RF subsystem" section (the doc's architecture was already correct).
- [x] **Modulator chip choice** — DONE 2026-06-07; ADL5391 committed, AD835 head-to-head dropped. RF-modulator bench parts ordered (DigiKey SO 99663237); amp/filter/output substrate = Manhattan copper-clad. RF-modulator subsystem phase banked.
- [ ] **Validate the preset list** against real sets via §11.
- [ ] **Operator guidance** — mechanical-shutter → component output (§3.5); 25→24 conform is a flagged post step (§5).
- [ ] Confirm whether `vid_timing.v` parameter set already exposes per-dialect line counts (655/651) or needs extending in Phase G.

---

## Cross-references

- Reference device: `MVPHD-24-flyer-v2.pdf`, `MVPHD-24-OM-v0-9-0.pdf` (project root); feature gap analysis [[mvphd-comparison]].
- Architecture: [[signal-flow]] (composite terminal + present-geometry), [[dev-roadmap]] (Phase G).
- RF path: [[rf-modulator-subsystem]] (apply §10 correction).
- Profile system precedent: NovaTool per-tile JSON profiles.
