# Code-agent prompt — Schindler 2.0 carrier schematic capture (first pass)

*Paste the section below into the code agent. It assumes the agent runs on Justin's Mac with filesystem + shell access and KiCad 10 (`kicad-cli`) installed.*

---

## Task

You are populating the **Schindler 2.0 carrier-board** KiCad schematic with components, building the hierarchical sheet structure and instantiating parts against an existing single-source-of-truth (SSOT) spec. This is real hardware capture — **accuracy over speed, and never invent data.** When the SSOT is silent or ambiguous, stop and flag it; do not guess pin assignments, values, footprints, or nets.

## Environment

- **Vault root:** `/Users/jedgerly/Library/CloudStorage/Dropbox-Personal/_PROJECTS` (call it `$VAULT`)
- **Carrier project (THIS task — KiCad 10, sch format `version 20260306`):**
  `$VAULT/Schindler-2.0/KiCad/SchindlerCarrierBoard_V1/SchindlerCarrierBoard_V1/SchindlerCarrierBoard_V1.kicad_sch`
  (currently one A4 sheet, starter symbol cache only — the 12-sheet hierarchy is NOT built yet)
- **Symbol libraries:**
  - `$VAULT/_KiCad/JustinLibrary.kicad_sym` (most ICs)
  - `$VAULT/_KiCad/Schindler.kicad_sym` (4 custom: NHD-2.9-376960AF-ASXP, NHD-1.5-240240AF-CSXP, FN9260B-6-06, NFM21_Feedthrough)
  - Plus KiCad stock libs for generic passives/connectors.
- **Scope:** carrier (PCB **A1**) ONLY. The front mezzanine (A2) and RF daughter board (A3 — `SchindlerRFBoard_V1`) are separate projects/refdes namespaces — do not touch them.

## Read first (SSOT — in this order)

All under `$VAULT/Schindler-2.0/docs/`:
1. **`refdes-map.md`** — THE authority for which component (with its assigned refdes) lives on which sheet, the per-sheet hundreds-block numbering, the shared inter-sheet bus maps, and FPGA-bank anchoring. This drives everything.
2. **`bom-v1.md`** — locked MPNs, values, packages, and the `[Pro]/[Mini]/[All]` stuffing tags. Source of the Value field.
3. **`kicad-symbol-sourcing.md`** — which library each symbol lives in, plus the recorded footprint assignments.
4. **`sheet3-te0720-som-backbone.md`** §5 — authoritative TE0720 SoM pin map (use for any FPGA-bank/SoM net).
5. **`01-spec.md`**, **`signal-flow.md`**, **`pin-budget.md`** — subsystem detail and net intent where the refdes map needs context.

Also read the existing root `.kicad_sch`, both symbol libraries (to get **exact** symbol names), and the project's `sym-lib-table` (to get the **exact** library nicknames used in `lib_id`).

## Sheet hierarchy (confirm against `refdes-map.md`)

Root + 11 children, refdes in per-sheet hundreds blocks:

| Sheet | Name | refdes block |
|---|---|---|
| 1 | Root | 100s |
| 2 | TE0720 SoM backbone | 200s |
| 3 | Power tree | 300s |
| 4 | HDMI in/out | 400s |
| 5 | Analog in | 500s |
| 6 | Analog out | 600s |
| 7 | SDI | 700s |
| 8 | Genlock | 800s |
| 9 | Clock / Sync | 900s |
| 10 | Control / Net | 1000s |
| 11 | Panel / LED | 1100s |
| 12 | RF interface / Debug | 1200s |

## Do it in stages — stop at the checkpoint

**Phase 0 — Recon (no writes).** Read the SSOT + existing project + both libraries + sym-lib-table. Confirm `kicad-cli version` (expect 10.x). Produce a short plan: confirmed sheet list, the exact library nicknames you'll use in `lib_id`, and any SSOT gaps you already see. 

**Phase 1 — Skeleton.** Build the 12-sheet hierarchy: root sheet with 11 hierarchical sheet symbols (titles + filenames per the table), child `.kicad_sch` files, and ensure both symbol libraries are in the project `sym-lib-table`. No components yet beyond what the hierarchy needs. **Validate it loads** (`kicad-cli sch erc` and/or `kicad-cli sch export netlist` as a smoke test — must run without parse errors). 

**Phase 2 — Pilot ONE sheet, then STOP for review.** Recommend **Sheet 3 (Power tree)** — self-contained and fully specced (TPS26600 eFuse, LTC2954-1 soft-power, LMR33640 ×2, TLV62568, the per-chip LDOs, INA226, TPS61040). Fully populate it: instantiate every Sheet-3 component from `refdes-map.md` with its **explicit refdes** (the map's number, not auto-annotation), **Value** (from `bom-v1.md`), and **Footprint** (from `kicad-symbol-sourcing.md` where recorded; leave blank + list if TBD). Wire the sheet-local nets and bring the power rails out as power symbols / global labels per the power tree. Validate (ERC). **Then halt and present a summary + diff for Justin to review before any rollout.**

**Phase 3 — Rollout (only after Justin approves the pilot).** Repeat Phase-2 method sheet by sheet, validating each (`kicad-cli sch erc`) before moving on. Inter-sheet buses via hierarchical labels + sheet pins per the refdes-map shared-bus maps; FPGA-bank nets per `sheet3-…md` §5.

## Hard constraints

- **KiCad 10 format only** (`version 20260306`, `generator_version "10.0"`). Match the existing file's structure.
- **`lib_id` nicknames must exactly match the project `sym-lib-table`** (e.g. `Schindler:NHD-2.9-376960AF-ASXP`, `JustinLibrary:ADV7393BCPZ`). **Every used symbol must be embedded in that sheet's `(lib_symbols …)` cache block** — not just referenced. Copy the full symbol definition in.
- **Pull refdes / value / footprint / sheet-assignment ONLY from the SSOT.** `refdes-map.md` is primary for refdes + sheet; `bom-v1.md` for value; `kicad-symbol-sourcing.md` for library + footprint. **Do not invent.** Footprint TBD → leave blank and add to the gap list.
- **Connectivity from the docs only.** Use the refdes-map bus maps and `sheet3-…md` §5 pin map for nets. Where a connection isn't specified, leave the pin unconnected and flag it — do **not** fabricate nets, and do **not** wire FPGA-bank pins by guesswork.
- **Placement can be rough.** A clean grid is fine; Justin arranges visually later. Correct instances + properties + connectivity scaffolding is the deliverable, not aesthetics. Do not attempt PCB layout/routing.
- **Validate by loading.** KiCad's own loader/ERC is the final word — run it after each sheet and report results. (The custom symbols in `Schindler.kicad_sym` were parse-validated but not yet opened in the KiCad GUI; if any fails to load, flag it, don't patch around it.)
- **Stage only — do NOT `git commit` or `git push`.** Justin's approval gate is the push. Edit the files, then report.

## Deliverables for the first pass

1. The 12-sheet hierarchical skeleton, ERC-clean (or ERC issues explained).
2. Sheet 3 (Power) fully populated and validated.
3. A **capture log** (`$VAULT/Schindler-2.0/docs/kicad-capture-log.md`): what was placed per sheet, every pin/net left unconnected and why, every footprint left TBD, and **every SSOT gap or ambiguity you hit** (the most valuable output — it tells Justin what the spec is missing).
4. A short proposed plan for Phase-3 rollout. Then stop for review.

## If anything is ambiguous

Stop and ask. Justin would rather answer a question than unwind a wrong guess across 12 sheets.
