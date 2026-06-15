# Schindler 2.0 — Session Handoff (2026-06-13)

**Purpose:** continuity doc for a fresh chat (prior chat hit the artifact limit). Read this after `_PROJECTS/_index.md` and `Schindler-2.0/docs/00-index.md`.

---

## Operating model (important)

- A separate **code agent** owns ALL edits to the KiCad project (`Schindler-2.0/KiCad/...`) and to `_KiCad/JustinLibrary.kicad_sym`. Claude does **not** touch those — Claude **guides** and writes **prompts** for the code agent.
- Claude MAY edit the **spec/decision docs**: `01-spec.md`, `01-spec-changelog.md`, `panel-layout.md`, and the subsystem/design docs. "Bank it" = record the decision in those docs (+ changelog entry).
- Justin's approval gate is the **git push**. Stage, explain, don't push.
- Style: exhaustive honest analysis, push back once then drop, propose before deciding, flag big rebuilds, don't fabricate part numbers/values — flag for verification.

## Capture status

- KiCad 10 project: `Schindler-2.0/KiCad/SchindlerCarrierBoard_V1/SchindlerCarrierBoard_V1/`. 12-sheet hierarchy built; Sheet 3 (power) placed as the pilot. **Mode = placement only ("BOM onto sheets, wire later").**
- Code agent was cleared to run **Phase 3** placement of the remaining sheets (2, 4–12), SoM backbone first, ERC each, log to `docs/kicad-capture-log.md`, stage-only. **Triage its results when they come back.**
- Library = `JustinLibrary.kicad_sym` (current format, 26 symbols, all verified). `Schindler.kicad_sym` retired/redundant. TPS26600 OUT pins already fixed (pin15 `power_out` / pin16 `passive`).
- `docs/power-tree-design.md` = locked power-tree decisions + pin-level netlist; it's the input for the eventual **wiring** pass (not placement).

## Decisions already banked (done)

- **SDI IN Loop — ADDED.** Reclocked loop via GS3470, Pro-only, +1 BNC, rear Row 1 (carrier). In `01-spec.md` §3.6 + §16.2, `panel-layout.md`, changelog. (HDMI IN loop evaluated + **rejected** — recorded, don't resurface.)

## TO BANK as soon as Justin is back at the laptop (he said "have you bank it")

1. **SDI OUT mirror.** GS2962 confirmed to have two SDO output pins (**C10 / D10**) → a second (mirrored) SDI OUT is one free BNC: buffered duplicate of the same processed SDI stream, active (drops on power loss), SI-critical 3G → **Row 1 (carrier)** next to the GS2962. Bank like the IN loop: `01-spec.md` §3.6 + §16.2, `panel-layout.md`, changelog. Pro rear BNC count → **16**.
2. **New backplane left-to-right order:** `PWR → WiFi/Net/USB → Display → INPUTS → OUTPUTS → REF (all 4 sync BNCs) → RF`. RF moved to the **far-right, isolated** (good — keeps the one VHF-radiating connector away from the genlock REF front-end). NOTE this changes the documented "sync follows IN/OUT direction" principle in `panel-layout.md` — REF is now a single grouped right-side zone. Confirm/overwrite the principle text when banking.
3. **Vertical row rule:** **Row 2 (top) = analog** (composite + component, in & out) → **riser**; **Row 1 (bottom) = SDI + HDMI** → **carrier**. Within the REF zone: REF IN/LOOP on top row, both SYNC OUT on bottom row.
4. **Stale changelog correction:** the 2026-06-12 "second composite output" entry is superseded by "we will tap, no second composite." Append a correction so it doesn't read as live.

## OPEN — needs Justin's decision before banking

- **REF-on-riser SI tension.** Justin's row rule puts REF IN/LOOP on the top row (= riser), but REF is genlock-phase-critical and a board-to-board hop is undesirable there. **Resolution direction Justin is exploring:** panel-mounted BNCs with short **coax pigtails → u.FL/MMCX on the carrier**, so the sync signal never crosses the riser mezzanine — position decoupled from electrical home. This also **killed the "separate sync daughter board" idea** (a sync board can't cleanly amputate because the Si5351 ch0 = FPGA master clock + the digital PLL lives in the FPGA on the carrier — the genlock loop is closed through the carrier, unlike the one-way RF chain).
- **Riser partition + A4 stub** not yet written. Riser = new 4th PCB ("A4"). When banking: riser carries the SI-tolerant analog video BNCs only; one TLC59116 relocates to the riser for its connector LEDs; REF/RF/Display zones stay carrier-rooted.

## Interconnect vocabulary (the working framework for "connector here, silicon there")

1. **Carrier-edge R/A BNC** — board-edge digital (SDI, HDMI). On Row 1 already.
2. **Panel BNC → short coax pigtail → u.FL/MMCX on carrier** — phase-critical sync (REF), positioned anywhere, continuous 75 Ω, no mezzanine hop. u.FL ~30 mating cycles (effectively permanent); MMCX if serviceable wanted.
3. **Mezzanine pin header riser** — SI-tolerant analog video (composite/component), bulk count where pigtails would be too much labor.
4. **Blind-mate coax (SMP / SMPM / BMA + float bullet)** — riser/daughter carries the BNC and the coax mates as the boards seat; use when an SI-sensitive line must be on a riser AND mate on assembly without pigtails. **Caveat: these are overwhelmingly 50 Ω; 75 Ω variants are a thinner, pricier catalog.** 50 Ω on 75 Ω video is negligible at composite/component freqs, real at 3G-SDI/sync edges.

## OPEN TASK rolled into scope — REF interconnect: pigtail vs blind-mate (needs web/catalog access)

Compare the two REF-interconnect options and return **confirmed current MPNs + prices**:

- **Option A — panel BNC → short coax pigtail → u.FL/MMCX on carrier.** Best SI (continuous 75 Ω), manual assembly per line, low part cost. Look up: Hirose **U.FL-R-SMT-1** (carrier-side, 50 Ω nominal — fine for short internal runs) vs a true **75 Ω MMCX** if impedance-exact wanted; plus the panel BNC (see below) and the pigtail cable assembly.
- **Option B — blind-mate coax (riser carries BNC, mates to carrier on seat).** Clean assembly, no loose cable; needs **75 Ω** to be SI-clean on sync. Look up **Amphenol RF / Amphenol SV Microwave** 75 Ω **SMP / Mini-SMP (SMPM)** board-mount jacks (carrier + riser) + **float bullet**, with the float/misalignment spec and stack-height vs the ~16–20 mm row gap. Also check **Samtec** RF board-to-board 75 Ω at that stack height.

**Decision heuristic to apply:** count the SI-sensitive lines crossing to the riser. **≤ ~3 → pigtail (Option A)**; **many → blind-mate (Option B).** With current plan REF = 2 lines and SDI/HDMI stay on the carrier, so the preliminary lean is **Option A (pigtail)** — but confirm with real MPNs/prices, then finalize.

Also confirm and finalize the **rear-panel BNC connector** itself (separate from the interconnect): primary candidate **Amphenol RF 031-70352** (R/A bulkhead PCB jack, through-hole, 75 Ω); second source **Molex 73101-0120**; reconcile against the BOM's current locked BNC. Avoid 50 Ω lookalikes.

## Reference facts

- Rear LCD (NHD-1.5-240240AF-CSXP) cutout: **28 × 28 mm** window, ~33 × 36 × 3 mm recessed pocket.
- BNC panel hole ø10 mm; SMA ø6.35 mm + flats. BNC pitch chosen for mockup = **0.75" (19 mm)**; hard floor ~0.6" for hand patching.
- GS2962 datasheet in vault: `Schindler-2.0/KiCad/Reference Files/BOM Docs/GS2962_DS.pdf` (+ EB design guide, GS2962-vs-GS2972 app note). GS3470 docs there too.
- Justin is mocking the backplane in SketchUp.

## Other still-open housekeeping (capture-log gaps)

- #7 reconcile `bom-v1.md` doc-names → real MPNs.
- #9 banner `carrier-schematic-capture-plan.md` as superseded.
- The SDI IN Loop + SDI OUT mirror need KiCad implementation on the SDI sheet (loop + mirror BNCs) — fold into the agent's SDI-sheet prompt so it captures all 3 SDI BNCs from the start.

## Immediate next actions for the new chat

1. Bank items 1–4 above (SDI OUT mirror, backplane order, row rule, stale-composite correction).
2. Pull catalogs (web) and return MPNs/prices for the REF pigtail-vs-blind-mate comparison; finalize the rear BNC part.
3. On Justin's go: bank the riser partition + open the A4 stub.
4. Triage the code agent's Phase 3 placement results.
