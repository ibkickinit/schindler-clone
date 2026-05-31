# Format-Support Matrix — v1 Scope Cut (ACCEPTED)

**Status:** ACCEPTED 2026-05-31 by Justin.

**Decision summary:**
- Inputs: 1080p and 720p @ 24/30/60 fps each (6 input formats).
- HDMI outputs: 1080p and 720p @ 24/30/60 fps.
- Analog outputs: NTSC composite @ 24 cadence and 30 cadence.
- **No upscaling** — architectural commitment. Downscale OK; matched-rate is fine; upscale forbidden.
- **PAL family out of v1** (50Hz inputs/outputs).
- 1080p60 HDMI OUT row blocked on production silicon (TE0720 or external HDMI PHY chip).
- All NTSC outputs blocked on Phase G ADV7393 chip arrival.

**Applied to `format-support-matrix.md`** in the same commit — see "v1 Ship List" section at top of that doc for the canonical 6×6 HDMI grid + 15-row composite (CVBS) table + Phase 2 verification batch plan.

**Purpose:** stop the verification-debt growth flagged by the Risk Auditor (~40 hours of bench time to re-validate ~20 ⚠️ rows post-iter6/12/13). Commit explicit scope so every row is either v1-ship, v2-deferred, or out-of-scope. No row sits unresolved consuming attention.

---

## Original draft framing (preserved for context)


## Framing question

If you had to ship Schindler 2.0 in 3 months for an MVPHD-24 replacement customer (rental house, music-video DP, period DP), what is the minimum product they'd pay for?

My read of the project goal (from `01-spec.md` + `mvphd-comparison.md`):

- **Input:** modern HDMI feed from camera or playback (1080p60 is the workhorse rate).
- **Output:** what the on-set CRT consumes — historically **NTSC composite at 480i59.94**, sometimes component HD or progressive SD.
- **FRC value:** the original MVPHD-24's distinguishing feature was 24fps cadence handling for film-shoot reference. **1080p60 → 1080p24** matters.
- **Operator preview:** HDMI out at some intermediate rate (720p60 or 1080p30) for the operator's own monitor, distinct from the on-set CRT chain.

That points to a small, defensible v1.

## Proposed v1 ship rows (5)

| Row | Input | Output | Method | Why it's in v1 |
|---|---|---|---|---|
| **2** | 1080p60 | 720p60 HDMI | — (downscale) | Operator preview monitor. Already ✅ formally promoted 2026-05-31 (3-boot rule satisfied on iter5+iter13b). The production reference. |
| **4** | 1080p60 | 1080p24 HDMI | D (5:2 drop/repeat) | **THE MVPHD-24 marquee feature** — 24fps reference for film shoots. Currently ⚠️ MS2109-tainted; one bench session to re-verify. |
| **7** | 1080p60 | 1080p30 HDMI | D (2:1) | Alternate preview rate; trivial 2:1 cadence (clean drop-every-other). Currently ⚠️ MS2109-tainted; one bench session. |
| **V1** | (test pattern) | NTSC composite color bars | — | **Phase G first-light** when chip arrives. Validates the analog chain end-to-end without input pipeline. The pre-req gate for V2. |
| **V2** | 1080p60 | NTSC composite 480i59.94 | D + downscale + re-interlace | **THE actual MVPHD-24 product** — modern HDMI → on-set CRT. v1 is incomplete without this. Requires Phase G chip + re-interlace HDL. |

Defensible product story: "Plug your camera HDMI in, watch on a 720p HDMI monitor, send NTSC composite to the talent's CRT, and play back at 24fps cadence on a reference monitor."

## Proposed v2 strong follow-on (4)

These ship next, after v1 lands and the bench rhythm is repeatable.

| Row | Input | Output | Why v2 |
|---|---|---|---|
| **1** | 1080p60 | 1080p60 HDMI | Passthrough. Hardware-blocked on Zybo (-1 BUFIO), trivially works on TE0720 production carrier. Defer until carrier hardware. |
| **5** | 1080p59.94 | 1080p23.976 | NTSC variant of Row 4. Requires Phase E1 MMCM tracking (drift absorption) — partly shipped on `phase-e1-pll-spike`; needs Phase E2 Si5351 actuator for full pull range. |
| **C2** | 1080p60 | 720p60 component (YPbPr) | HD component for prosumer CRTs. Same scaler as Row 2 + Phase G analog chain. |
| **C3** | 1080p60 | 480p60 component | SD progressive — simpler than V2 (no interlace). Phase G follow-on. |

## Proposed v3 expansion (deferred but tracked)

- **S1-S4**: All S-Video. NTSC/PAL variants of V2. S-Video market is small; defer until customer asks.
- **All PAL rows** (#9-12, V3, S2): non-US market. Defer until customer asks; not technically hard, just untested.
- **C1**: 1080p60 component — same Zybo BUFIO issue as Row 1. Production-silicon only.
- **C4-C7**: Component interlaced + edge cases.
- **All upscaling** (#17, #20-22): requires Phase E4 (scaler reposition to output side). Bigger HDL effort.
- **All 720p source** (#16, 18, 19): some defensible (Row 16 passthrough); none critical for MVPHD-24 use.

## Proposed ❌ explicitly out of scope (v1, v2, v3)

These are unambiguously NOT shipping — clarifies what tests we'll never write:

- **All interlaced INPUTs** (#23-25): no deinterlacer in plan. If a customer needs SD-interlaced input handling, that's a different product.
- **4K input** (#26): Zynq-7020 bandwidth + LE budget insufficient. Production silicon would help but isn't on the roadmap.
- **VRR / Freesync source** (#27): dvi2rgb assumes fixed timing.
- **Mackin temporal blend (Method E)** as an explicit v1 feature: the algorithm is shipped (sim 100% bit-exact), but real bench validation requires the dual-VDMA wiring that's still placeholder. **v1 doesn't promise Method E.** It's there if/when the wiring lands.

## What this scope cut delivers operationally

| Status today (all rows) | Cuts to |
|---|---|
| ~20 ⚠️ rows demanding ~40 hours of bench re-validation | **5 v1 rows** demanding 3 bench sessions to formally promote (Rows 2/4/7 reverify, Rows V1/V2 wait for chip) |
| Verification debt growing per iter | Verification debt **bounded**: only v1 rows get formal ✅; v2/v3 deferred-explicit |
| Risk Auditor #4 (MS2109 catch-up tax) | **Closed by scope reduction**; tax is now ~6 bench hours, not 40 |
| PM Agent #3 (matrix re-validation planned-sprint vs opportunistic) | Answer is **planned sprint of 3 sessions**, not 40 hours of opportunistic |

## What this scope cut doesn't prejudge

- **TE0720 migration timing:** Row 1 enters v2 when production carrier exists. Doesn't constrain when that is.
- **Phase G ordering:** V1+V2 are critical to v1; they're hardware-blocked. Whether Si5351 or ADV7393 comes first is the **Phase G/E2 priority decision** still open (PM Agent #1).
- **Mackin dual-VDMA:** unblocking Method E adds 4-5 rows (5, 9, 10, 19) to potentially-v2. Doesn't change v1.
- **Phase E4 scaler-at-output:** unblocks all upscale rows. Big-ticket future work; not v1.

## How to react to this draft

- **"Looks right"** → I update `docs/format-support-matrix.md` to mark v1 rows + demote the rest to 🔲-v2 / 🔲-v3 / ❌-v1-out-of-scope, push, and we're done. Phase 3 of Direction A closes.
- **"Wrong target customer"** → tell me who the customer actually is in your head; I redraft.
- **"V1 is too small — must include X"** → tell me which row and I'll defend or update.
- **"V1 is too ambitious — V2 is risky if Phase G slips"** → fair, we trim V2 to operator-preview only and the analog out shifts to v2.
- **"I want strategic-mind on this myself"** → no problem, this draft is reactive material not a decision.

## Related

- `format-support-matrix.md` — the canonical matrix this proposal edits
- `build-manifest.md` — current state of what's actually shipped
- `dev-roadmap.md` — Phase A→G plan
- `01-spec.md` — product spec the customer-framing is derived from
- `mvphd-comparison.md` — the device we're replacing

<!-- AGENT_TASK[docs-16]: When Justin reacts to this draft, edit format-support-matrix.md row statuses accordingly (v1 ✅ / v2 🔲-v2 / v3 🔲-v3 / out-of-scope ❌). Then archive this scope-cut doc to MIGRATION-NOTES.md so the historical context is preserved but the live matrix is the source of truth. -->
