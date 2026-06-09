# Schindler 2.0 — RF Modulator as Panel-Mount Daughter Board (Option)

**Status:** OPTION / under consideration as of 2026-06-07. **Not committed.** This reopens the 2026-05-11 decision to bake RF into every carrier (see [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md) → "Why on every carrier, not a daughter card"). Captured here so the trade is decided deliberately, not by drift.

**Purpose:** Document what the carrier↔daughter-board interconnect looks like if the RF modulator is built as a standalone board that panel-mounts to the rear of the chassis, and weigh it against the baked-in approach.

**Distinct from:** [`rf-modulator-daughter-card.md`](rf-modulator-daughter-card.md) — that stub was the *old* "Period SKU tier" daughter-card framing (segment-based), rejected on segmentation grounds. This option is a different rationale: modularity, RF isolation, optional-fit, with a clean interconnect — not a customer-segment play.

---

## The partition

A self-contained, shielded RF module that panel-mounts to the rear. The F-connector is on the daughter board's own panel edge. Everything RF lives on the daughter board; the main carrier hands it a baseband signal, control, and power.

**Key layout move that makes the interconnect clean:** put the dedicated RF Si5351 *on the daughter board*. Then the 61.25/67.25 MHz carrier is generated and consumed entirely on the daughter board — no VHF ever crosses the connector. (The RF Si5351 doesn't need genlock — it's a free-running stable clock, per the carrier-coherence note in the RF doc — so nothing references back to the carrier; it just needs its own 25 MHz crystal locally.)

---

## What crosses the interconnect

### Over coax (one line)

- **Composite video** — ~1 Vpp, DC–~4.5 MHz baseband, from the main carrier's LMH6643 buffer to the ADL5391 Y input. This is the one signal that wants coax, and the reason is **shielding + a defined ground return**, not impedance matching: at 4–5 MHz over a ~10–20 cm intra-chassis run the line is electrically tiny, so reflections aren't the concern — noise pickup is. A ribbon conductor here would invite hum bars, digital hash, and sync-edge ringing into the picture. A short 75 Ω micro-coax (50 Ω is also fine at this frequency) kills that.

### Over ribbon / board-to-board header (low-speed + DC)

| Signal | Notes |
|---|---|
| **I²C (SDA + SCL)** | Programs the RF Si5351 channel. Ch3/Ch4 select is just a register reload — no dedicated GPIO needed. 100 kHz–1 MHz. |
| **12 V** | ERA-3 amp bias (via 240 Ω) + modulator/op-amp rails. |
| **3.3 V** | Si5351 logic. |
| **Ground** | Several interleaved ground pins + coax shield + chassis bond through the panel mount. Solid low-impedance tie required. |
| **(optional) amp enable** | Only if the amp isn't simply left powered. Since the composite/RF mode-mux was dropped (both outputs live full-time), there's no gating to control, so this is optional. |

Total daughter-board draw is ~150–200 mA — trivial for ribbon pins.

---

## What stays entirely on the daughter board (never crosses)

- The **61.25/67.25 MHz carrier** (RF Si5351 + its 25 MHz crystal, local).
- The **modulated RF output**, **bandpass filter**, **ERA-3 amp**, **MLP** — straight to the F-connector on the daughter board's panel edge.
- The **shield can** over the whole RF section.

This is the whole win: the hardest signal in the system (the VHF carrier) becomes a non-issue because it's born and consumed inside the shield can on the daughter board. Nothing radiates VHF down a ribbon.

---

## Connector specifics

- **Composite:** U.FL / MMCX / MCX coax jumper, or a soldered micro-coax pigtail, board-to-board.
- **Everything else:** a small 2.54 mm header or FFC for I²C + power + grounds.
- Keep the analog coax **physically separate** from the digital/power ribbon.

---

## EMI / FCC benefit

A self-contained shielded RF module with only baseband composite + DC + I²C entering is about the cleanest possible Part 15 partition — all RF emissions contained in one shielded box with no RF on the interconnect. Arguably *better* for the cert than the baked-in design, where the carrier and modulator share the main-carrier ground plane with everything else.

---

## The alternative partition (and why not)

If you wanted **zero analog across the connector**, move the whole analog-encode section (ADV7393 + composite buffer) onto the daughter board and send it the **digital video bus** instead — composite gets encoded right at the outputs. But that trades one well-behaved baseband coax for a wide parallel pixel bus (or a serializer) running at the pixel clock: more pins, more layout care, more cost, and it drags the composite BNC (and possibly component) onto the daughter board too. Not worth it to eliminate a single clean coax. **Stick with the one coax + ribbon.**

---

## Trade vs. the baked-in decision (2026-05-11)

**Daughter-board pros:**
- Cleanest EMI/FCC partition (all RF in one shielded, panel-mounted box; no RF on the interconnect).
- Modular — RF section can be revised/respun without touching the main carrier.
- Optional-fit becomes physically real (populate or omit the board) without a carrier respin.
- F-connector placement is self-contained on the daughter board's panel edge.

**Daughter-board cons (these are what drove the 2026-05-11 bake-in):**
- Re-introduces a **SKU/assembly axis** (with-RF vs without) — the exact bifurcation the bake-in collapsed. Note: the original rejection was about *customer segmentation*; "always populate the daughter board" keeps it universal while still getting the modularity/EMI benefits, so the SKU objection only bites if RF becomes optional-fit.
- Adds an **interconnect** (coax + header) and a **second board** — more parts, more assembly steps, more connectors to fail vs. traces on one carrier.
- A duplicate **RF Si5351 + crystal** on the daughter board (the baked-in design already had a dedicated RF Si5351, so this is a relocation, not a true add).
- Mechanical: a panel-mount board needs its own standoffs/bracket and panel cutout coordination.

**Net:** the interconnect is clean enough (one coax + one header) that the daughter board is genuinely viable — the engineering isn't the blocker. The decision is really product/assembly strategy: is the modularity + EMI isolation worth a second board and an interconnect, and does RF stay universal (populate-always) or become optional-fit? If universal, this is mostly an EMI/modularity win at the cost of assembly complexity. If optional-fit, it re-opens the segmentation question the bake-in deliberately closed.

---

## Open decision

- [ ] **Daughter board vs baked-in** — defer until carrier layout time. The RF doc flags a pre-layout decision window anyway (second GbE jack, etc.); fold this into the same review.
- [ ] If daughter board: **universal (always populated) or optional-fit?** This is the real strategic fork.

---

## Cross-references

- Baked-in design + parts spec: [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md)
- Superseded Period-SKU framing: [`rf-modulator-daughter-card.md`](rf-modulator-daughter-card.md)
- Carrier-coherence note (why the RF Si5351 is free-running): [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md) → "Si5351 dedicated to RF subsystem"
- Rear-panel slack: [`panel-layout.md`](panel-layout.md)
