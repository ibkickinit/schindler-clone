# Warp engine edge/limit sweep — 2026-06-27

Automated telemetry sweep (no eyes needed): drove `W`/`K`/`I`/`C` combinations over UART, read the
firmware `OUT: opix/frame=N (exp M) … starved=S` counter after each. **PASS = opix==exp AND eol==exp**
(full frame). FAIL = short frame (starve). Each point read 2–3 settled samples; 720p readings were
rock-stable (identical across samples). Method gives each geometry its best shot (canonical command
order `[W, I, K/C]` so the corner command's deep quad-derived lead wins) — so a FAIL here is a **real
wall**, not a lead-tuning artifact (lead-independence proven separately, see §0).

## 0. The headline: 1080p geometry is a hard wall; 720p is the working regime
The board was found running the **1080p30** warp build. At 1080p, **only identity passes** —
- rot30 → thrashes 13–90% (bimodal cache-eviction wedge)
- keystone H400 → **rock-stable 30.8% across every lead 4096…98304** = a hard bandwidth wall, NOT lead.
- pincushion 400 → 99.9% (marginal).

Switched to **720p** at runtime (`R 720`, no rebuild) → everything below. This matches the standing
record (warp is proven at 720p; 1080p30 is the unfinished bandwidth frontier — the 143 MHz DataMover /
option-b is the 1080p fix, not yet on this bitstream). **All results below are 720p.** Left the engine
at 720p identity.

## 1. Rotation — usable range
Rotation is hard-snapped to the **10° grid** (firmware clamp `((deg+5)/10)*10`; sub-10° just snaps, so
fine rotation is not a thing on this build by design — the cache-thrash clamp).

- **Usable: every 10° step EXCEPT a dead-band at {40°, 50°} and its 180° mirror {220°, 230°}.**
  - 0,10,20,30 ✅ · **40,50 ❌** · 60,70,80,90,…,210 ✅ · **220,230 ❌** · 240,250,… ✅
  - Sharp edges, fully reproducible (30✅ 40❌ 50❌ 60✅ ; 210✅ 220❌ 230❌ 240✅).
- **45° is UNUSABLE** — it snaps to 50° → dead-band. (90°/180°/270° are all clean.)
- ⚠️ This **contradicts the `[[schindler_warp_rotation_clamp]]` memory's "10° grid + (1,33) hash is
  bench-clean" claim** — 40/50/220/230 still overflow the 4-way at 720p. The clamp reduced the dead
  zones to these four angles but did not eliminate them.

## 2. Keystone (symmetric `K h v`) — alone
- **H keystone: clean to 700** (0.70). 720–850 = resonance dropout zone (all FAIL), 900 recovers.
- **V keystone: clean to 900** (0.90, the firmware clamp) — no failures found. V is cheap.
- **HV diagonal: clean to 500.** Then a **resonance zone 550–800**: 550 marginal, 600❌, **650✅**,
  700❌, 750❌, 800❌, 850✅, 900✅. Non-monotonic = cache-set hash resonance, not a clean threshold.
- Negative (−400 H and V) clean.
- **Reliable monotonic envelope: H≤700, V≤900, HV-diagonal≤500.** Far beyond the ±10% (=100) target.

## 3. Pincushion (`I amt`) — alone
- **Full range ±1000 clean** (every step −1000…+1000 PASS). Pincushion is effectively free (radial
  address-gen, no fetch fan-out that breaks bandwidth). No edge found.

## 4. Keystone × Pincushion
- ksHV **≤400 + ANY pincushion (±600)** → all clean.
- ksHV **600 + pincushion** → mostly breaks (pin−600 passes; −300/+300/+600 FAIL 42–49%). ksHV600 is
  already near its standalone edge; pincushion tips it over.
- **Safe combined rule: keystone-diagonal ≤400 with pincushion anywhere in ±1000.**

## 5. Rotation × geometry — friction
The friction is rotation-angle-specific. **rot30 is the sensitive one**; rot10/rot90 are robust.
- rot10 + ksHV: clean to **550+** (rot10 barely costs).
- rot30 + ksHV: clean to **300**, breaks at 350. (Standalone ksHV is good to 500 — a passing rotation
  eats ~200 of the keystone budget.)
- rot90 + ksHV300 ✅.
- rot10 + pin300 ✅ ; rot30 + pin300 marginal ; rot30 + pin600 ❌ ; rot90 + pin300 ✅.
- (rot40 + anything ❌ — but rot40 is already a dead-band angle.)
- **Takeaway:** on a *passing* rotation, budget shrinks. rot10/rot90 ≈ free; rot30 ≈ half the keystone
  budget and pincushion-sensitive. Stay on 10/20/60/70/80/90/… for combined warps; avoid 30 if also
  keystoning hard.

## 6. Independent 4-corner (`C`) — opposing-corner mismatch
- Opposing corners (TL+BR both pulled diagonally inward by δ on a 1280×720 sheet) **clean to δ=400**
  (a severe shear) — no break found. The mismatch limit is **beyond δ=400**; independent corner-pin is
  the most robust control tested.

## Practical "safe envelope" (720p, single engine)
| Control | Solid limit | Notes |
|---|---|---|
| Rotation | 10° grid minus {40,50,220,230} | 45° dead (snaps to 50). 90/180/270 fine. |
| Keystone H | ±700 | 720–850 resonant dropout, 900 ok |
| Keystone V | ±900 | cheap, no fails |
| Keystone HV-diag | ±500 | 550–800 resonance minefield above |
| Pincushion | ±1000 (full) | free |
| Keystone + Pincushion | ksHV≤400 + pin any | |
| Rotation + Keystone | rot10/90 + ksHV≤500; rot30 + ksHV≤300 | avoid rot30 for big keystone |
| Opposing 4-corner | δ≥400 | no break found |

## Nature of the failures
All FAILs are tile-cache **set-hash resonance + fetch-bandwidth**, not lead (proven lead-independent),
not timing. The non-monotonic dropouts (e.g. ksHV 650✅ between 600❌ and 700❌) are the fingerprint of
specific geometries hash-colliding into a >4-way set. Same root family as the rotation dead-band.

## 1080p fine low-end sweep (2026-06-27, follow-up) — the HD target zone
Re-ran strictly at 1080p, fine steps in 0–~25%, 5–6 samples/point (1080p readings are bistable, so
multi-sample is mandatory: the first frame after a soft-reset is often a clean transient that then
degrades — judge by STEADY state). **STABLE-PASS = all steady samples full; METASTABLE/flicker = bounces
full↔collapsed = unusable.**

### Rotation IS different at 1080p (answer: yes)
- 720p dead-band on 0–180: **{40, 50}**. → **1080p dead-band: {30, 40, 50, 170}** (+180° mirrors).
- rot30 is **clean at 720p but broken at 1080p** (steady 13%). rot170 likewise flickers.
- Cause: 1080p packs ~2.25× the tiles in flight, eroding the 4-way cache margin — angles that sat right
  at the edge (metric≈4) at 720p tip over at 1080p. Same hash, less headroom.
- Clean 1080p rotations: 0,10,20,60,70,80,90,100,110,120,130,140,150,160,180 (and mirrors).

### Corner-pin (the HD target) — GOOD at 1080p
- **Symmetric H+V diagonal: STABLE-PASS to 30%** (cpHV 25…300 all clean).
- **Independent 4-corner `C` (opposing), 5/10/15/20%: STABLE-PASS** (5-sample confirmed). ✅ meets target.
- **Pure-HORIZONTAL corner-pin: resonance dead-zone 5–25%** (cpH 50–250 broken, 300 recovers). Pure-V
  clean to 20%. → moot once keystone handle is dropped for true 4-corner (task #42), but don't expose a
  pure-H pin knob.

### Pincushion — the one shortfall at 1080p
- **Standalone: STABLE-PASS only to ~5%** (pin50). **pin75–200 (7.5–20%) METASTABLE flicker** (bounces
  99.9%↔13%) = unusable standalone. Negative (barrel) −200/−300 clean.
- **BUT combined with corner-pin it clears:** **cp+pin at 10/10, 15/15, 20/20 all STABLE-PASS** (5-sample).
  The corner-pin geometry shifts the tile pattern off the pincushion-alone resonance.
- So the **actual HD use case (corner-pin + pincushion, 10–20%) works rock-solid**; only *pincushion by
  itself* above ~5% flickers at 1080p.

### 1080p verdict
The fine envelope is a **resonance lottery**: isolated single-control settings hit sharp dead-zones
(standalone pincushion ≥7.5%, pure-H pin, rot 30/170), but the combined HD geometries land clean to 20%.
This fragility is what the **option-b 143 MHz DataMover** build is meant to remove (bandwidth headroom →
margin). On THIS (apparently pre-option-b) bitstream, validate any specific 1080p production preset
individually. Target met for corner-pin (to 20–30%) and for corner-pin+pincushion combos (to 20%);
standalone pincushion at 1080p is the gap.

## Reproduce
`/tmp/warp_full_sweep.py` (full matrix), `/tmp/warp_refine.py` (boundary refinement),
`/tmp/warp_lead.py` (lead-independence proof). Stop the daemon first (it owns /dev/ttyUSB1), run, then
restart the daemon. Switch res with `R 720` / `R 1080`.
