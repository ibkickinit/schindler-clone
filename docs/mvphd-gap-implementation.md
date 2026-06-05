# Schindler 2.0 vs MVPHD-24 — **Implementation** Gap & Action Plan

**Status:** created 2026-06-04. Companion to [`mvphd-comparison.md`](mvphd-comparison.md).
**Scope note:** analog **input** is intentionally out of scope (HDMI/SDI sources only). See the
hypothetical in Appendix A for what re-adding composite input *would* cost.

## Why this doc exists (read this first)

`mvphd-comparison.md` is a **spec-level** comparison (2026-05-13) and concludes "Schindler matches
or exceeds the MVPHD-24." That is true of the **planned V1 spec**. It is **not** true of what is
**built on silicon today.** This doc is the reality check, grounded in
[`build-manifest.md`](build-manifest.md) (the source of truth for what actually runs), and turns the
gap into a sequenced action plan weighted by **lift × usefulness**.

The MVPHD-24's identity (per its own flyer): a **frame-rate converter for filming CRTs at film
cadences (23.98–30 fps).** Its job is three things together: (1) convert frame rate, (2) drive an
**analog** display, (3) **genlock** to the camera/house. Everything else is operator polish.

---

## 1. What is actually built today (production substrate `iter5-1080p-clean`)

| Capability | State |
|---|---|
| HDMI 1080p60 in → HDMI 720p60 out, scaled + anti-aliased | ✅ built, 3-boot clean |
| Runtime geometry (zoom / signed-window pan / 200% scale) | ✅ built, bench "perfect" (route-B build #30) |
| Color pipeline (saturation / correct / 3×3 matrix), runtime-tunable | ✅ built |
| Control plane + web UI (schindlerd + browser) | ✅ shipped (V0a) |
| FRC cadence controller (`pg_cadence`, drop/repeat) | ✅ **integrated + 3-boot bench-verified** (build #31, 2026-06-04) |
| Mackin blend (smooth FRC) | ✅ **shipped** (7 framestores; `BLEND 60/60` on 3 boots, build #31) |
| 1080p24↔720p60 FRC (digital, HDMI) | ✅ **3-boot clean** (FRC 5/12 cadence, `delta_px=0`, no EOLLate) |
| Film-cadence FRC to the **analog** CRT (60i / 3:2) | 🟡 engine ready; the *output* is hardware-gated (ADV7393) |
| Analog output (composite NTSC / component) | ❌ **hardware-blocked** — ADV7393 dead, replacement on order |
| Sync/genlock reference out (black burst / tri-level / LTC) | ❌ **hardware-blocked** — Si5351 I²C unreliable |
| SDI in/out | ❌ silicon spec'd (GS3470), not built |
| All operator features (EFX, stills, TSG, color-temp, ARC, …) | ❌ **spec-only, not implemented** |

**One-line truth:** today the device is a clean **HDMI→HDMI scaler with an emerging frame-rate
converter and a strong geometry/color core**. The three things that make it an MVPHD *replacement*
— analog output, verified film-cadence FRC, sync outputs — are not done, and two of the three are
gated on chips coming up, not on code.

---

## 2. The gap, in tiers

### Tier 1 — Core-function blockers (no replacement without these)
1. **Analog video OUTPUT** (composite NTSC, component). The CRT's only input. **Hardware-blocked**
   (ADV7393). Highest-stakes gap.
2. **Verified frame-rate conversion to 24/30** (the product's name). In flight: integrate
   `pg_cadence` + Mackin blend, then bench-verify the 24/30 rows. *Not hardware-blocked.*
3. **Sync / genlock reference outputs** for on-set locking. **Hardware-blocked** (Si5351).

### Tier 2 — Output breadth (MVPHD has; v1 scopes out)
- SDI in/out (broadcast tier, GS3470 — not built). Component output (deferred v2).
- PAL family 25/50 Hz (out of v1 scope; MVPHD does NTSC **and** PAL).

### Tier 3 — Operator features (spec'd, **not built**) — *the focus of this plan*
Still buffers, EFX, full TSG + user patterns, color-temp presets + YUV circle, ARC modes, proc-amp
bypass, BLACK/MONO quick actions, 3:2 auto-detect, motion-filter select, hours counter.

### Tier 4 — Deliberately dropped (not gaps)
Analog **input**, VGA in/out, multi-format BNC sharing, Pi co-processor, Dashboard-only control.

---

## 3. The strategic insight that makes Tier 3 cheap *now*

This session built the expensive infrastructure. Most Tier-3 operator features are no longer "new
datapaths" — they are **exposing silicon that already exists**:

| Operator feature | Already-built thing it rides on |
|---|---|
| **MONO** | `color_matrix` (3×3, runtime coeffs) → luma-replication preset |
| **BLACK** | compositor matte / window-collapse |
| **Freeze** | read engine slot-hold (= cadence "repeat" forced) |
| **Fade-to-black** | Mackin blender → blend toward a black slot (alpha ramp) |
| **Color-temp presets** | `color_matrix` / `color_correct` coefficient sets |
| **Proc-amp bypass** | color pipeline identity (already a UART `i` command) |
| **ARC modes** | signed-window geometry engine (build #30) → preset window+matte+scale |
| **Still image buffers** | read engine reads DDR slots → a still = a pre-loaded slot |
| **Custom test signals** | same DDR-preload path as stills |
| **Motion-filter select** | Mackin blend mode parameter |

So Tier 3 is a **firmware/UI harvest of work already done**, not a second hardware program. That
reframes it from "big backlog" to "quick wins while the analog/sync chips are blocked."

---

## 4. Action plan — sequenced by lift × usefulness (no hardware block)

Lift: **XS** (hours, preset/firmware) · **S** (light HDL+fw) · **M** (new infra) · **L** (heavy).
Usefulness: ★★★ MVPHD headline / direct DP tool · ★★ useful · ★ niche.

### Phase 1 — Front-panel quick-wins (XS, all preset/firmware on existing silicon) — **do first**
| Feature | Lift | Use | Notes |
|---|---|---|---|
| **MONO** | XS | ★★★ | `color_matrix` luma-replication preset + UI/quick button |
| **BLACK** | XS | ★★★ | matte-black + window-collapse (or 1 blank GPIO) |
| **Proc-amp bypass** | XS | ★★ | identity preset already exists (`i`); expose as toggle |
| **Color-temp presets (3200/4800/5600)** | XS–S | ★★ | three matrix coeff sets |
| **Hours-of-operation counter** | XS | ★ | PS persistent counter in System Info |

*Outcome:* closes 4 of the MVPHD's dedicated front-panel buttons in ~days, zero HDL risk.

### Phase 2 — Light HDL/firmware on the existing engine — **next**
| Feature | Lift | Use | Notes |
|---|---|---|---|
| **Freeze (EFX)** | S | ★★★ | force read-engine repeat / slot-hold; one mode bit |
| **ARC modes** (Letterbox/Pillar/Anamorphic/14:9/Crop) | S–M | ★★★ | preset geometry+matte configs on build-#30 engine |
| **Test-pattern expansion + Shutter-Phase Reference (F1/F2)** | S–M | ★★★/★★ | HDL pattern gen; shutter-phase = field-alternating color pair (direct DP tool) |
| **Motion-filter select (Quad/Linear/Off)** | S | ★★ | blend-mode parameter (pair with blend integration) |

### Phase 3 — Rides on the Mackin-blend integration (do alongside the N=7 build)
| Feature | Lift | Use | Notes |
|---|---|---|---|
| **Fade-to-black (EFX)** + EFX transition-time | M | ★★★ | blend toward black slot, alpha ramp 0–240 frames |
| **EFX mixer transparency** | S | ★★ | reuse blend alpha control |

### Phase 4 — New infra, but high-value (the MVPHD's "major feature")
| Feature | Lift | Use | Notes |
|---|---|---|---|
| **Still image buffers (4)** | M | ★★★ | reserve DDR region(s); web→eMMC→DDR DMA; read-engine source-select; splash/QC/signal-loss fallback |
| **Custom user test signals (8 slots)** | M | ★★ | shares the still-buffer upload/DDR path |
| **Capture current frame → buffer** | S–M | ★★ | DMA a live slot to a still buffer (reuses the `F` framebuffer-dump path) |

### Phase 5 — Heavier / deferrable (schedule when justified)
| Feature | Lift | Use | Notes |
|---|---|---|---|
| **Snow/noise + MPEG-blocks EFX** | M | ★★/★ | LFSR + blocky decimation pattern gens |
| **3:2 cadence auto-detect** | L | ★★ | input cadence detection; less fundamental than explicit 24/30 convert |
| **YUV color-circle temp adjust** | M | ★★ | brightness/sat-preserving temp (new YUV stage or matrix trick) |
| **openGear / Ross Dashboard compat** | L | ★(customer-dependent) | PS-side protocol; only if a meaningful fraction of buyers are Ross-equipped |

### Recommended ordering rationale
1. **Phase 1 first** — maximum visible "MVPHD parity" per hour, zero HDL risk, all on the verified
   substrate; safe to do while chips are blocked.
2. **Phase 2** next — light HDL that reuses the geometry/read engine; ARC + shutter-phase are real
   DP-facing tools.
3. **Phase 3** is *free if you're already integrating blend* — fold fade/transition in then.
4. **Phase 4** is the one genuine new-infra lift, but it's the MVPHD's headline "stills" feature and
   the upload path is reused by custom test signals — good ROI.
5. **Phase 5** only when a customer or scope calls for it.

**What this plan deliberately does NOT touch:** the two hardware blockers (ADV7393 analog out,
Si5351 sync) and the FRC verify — those are tracked in Tier 1 and gated on chips/bench, not on the
firmware sprint above.

---

## 5. Confirmed plan + cost refinements (2026-06-04, parity-first approved)

North star **confirmed: credible MVPHD replacement ASAP (parity-first)**. Differentiators
(geometry warp / Tier-2 pincushion-rotate) wait behind parity unless hardware-blocked. Merged
execution order (geometry-effects track folds into the parity track at ARC):

1. **Tier-1a flips** (H/V/180°) — build #32, in flight → bench. *(differentiation, but already built)*
2. **Operator-harvest batch — ONE firmware/UI build** (not five): MONO, BLACK, proc-amp bypass,
   color-temp presets, hours counter, **+ fade-to-black**. Highest ROI on the board, zero HDL risk,
   on the verified substrate.
3. **ARC modes** (geometry preset — the convergence of our geometry track + doc Phase 2) **+ Freeze**
   (sim the genlock interaction first).
4. **Core color polish** (gamma / RGB→YCbCr) — also enables better color-temp presets + is an
   analog-out dependency, so it serves parity too.
5. **Reassess:** Stills (Phase 4, MVPHD headline) vs warp/Tier-2 (differentiation). Parity-first ⇒
   stills leads.

**Cost refinements to the tables above (corrections):**
- **Fade-to-black is XS, not M.** Don't route it through Mackin (needs a black DDR slot + blend-mux
  rewire). Ramp a **global gain in the color pipeline to zero** — the pipeline already has per-channel
  white-point/gain. No black slot, no blend rewire. → moves into the Phase-1 batch.
- **MONO gotcha:** the AXIS pipeline carries pixels **R-B-G**, not RGB (`schindler_pipeline_rbg_byte_order`).
  The luma-replication `color_matrix` preset must use that channel order or MONO comes out tinted.
- **Freeze:** one-bit slot-hold, but must not fight the genlock servo (cadence picks
  `slot = frame_ptr − lag`; freeze latches the base + stops following `frame_ptr`). Sim before trusting.
- **Batch Phase 1:** all firmware+UI on the verified substrate ⇒ one build+bench, not per-feature.

---

## Appendix A — Hypothetical: adding **composite analog INPUT**

(You're intentionally not doing this for v1. Recorded for completeness — and it's less work than it
looks, because a decoder chip does the hard part.)

**The chip does the analog + deinterlace; the FPGA stays digital-progressive.** Use a dedicated SD
video decoder — the **Analog Devices ADV7280** (you already keep `ADV7280 Datasheet.pdf` in BOM
Docs; the comparison doc notes it as "silicon-capable"). It is exactly the MVPHD flyer's "3D COMB
filter for composite input" + "motion-compensated de-interlacer" in one part.

**Signal path:** CVBS (1 Vpp, 75 Ω) → ADV7280 (clamp → anti-alias → 3D comb Y/C separation →
motion-adaptive deinterlace) → **BT.656** 8-bit/27 MHz YCbCr 4:2:2 (progressive 480p) → FPGA.

**Hardware to add (a self-contained ~$10 BOM module):**
- **ADV7280A** decoder (~$5–8). Variants: `-M` adds on-chip MIPI; for a parallel BT.656 link to the
  Zynq PL use the plain ADV7280.
- **Analog front end:** BNC (75 Ω) → AC-coupling cap → ESD/clamp diode. The ADV7280 integrates the
  anti-alias filter + DC clamp, so external parts are minimal (cap + termination + ESD).
- **Crystal:** 28.63636 MHz (4× NTSC subcarrier) reference for the decoder.
- **I²C control:** configure over the **same I²C bus** infra already used for ADV7393/Si5351.
- **Power:** 1.8 V core + 3.3 V I/O + a cleanly-filtered analog rail (video decoders are
  noise-sensitive — give it its own LC-filtered AVDD).
- **FPGA pins:** ~9–11 — BT.656 is 8 data + LLC clock (+ optional HS/VS/FIELD if not using embedded
  SAV/EAV sync codes).

**FPGA/HDL to add (small, and then it's free downstream):**
- A **BT.656 receiver** block: parse SAV/EAV timing codes, recover active video + field/line flags,
  emit 720×480 YCbCr 4:2:2.
- A **YCbCr 4:2:2 → AXIS** bridge into the existing pipeline. **Once it's in the AXIS pixel domain it
  flows through S2MM → scaler → FRC → output exactly like the HDMI path** — no new processing.

**Scope implication (the real reason it was dropped):** it re-admits **480i/576i** inputs, which v1
explicitly scoped out — *but the deinterlace happens in the ADV7280, not the FPGA,* so it does **not**
reintroduce the "no FPGA deinterlacing" problem. The cost is: one more analog subsystem (chip +
clean analog layout + I²C bring-up — the same class of bench effort that's currently blocking
ADV7393/Si5351), plus supporting the SD input formats end-to-end. Architecturally easy; it's a
hardware-bring-up and market-scope decision, not an HDL-hard one.

**If you ever do want it:** the cheapest path is to bring it up on the **same I²C + analog-rail
infrastructure** you're already debugging for the analog *output* — do both analog subsystems in one
hardware/bench pass rather than two.
