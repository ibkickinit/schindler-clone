# Schindler 2.0 — RF Modulator Daughter Board (COMMITTED)

**Status:** **COMMITTED — 2026-06-11.** The RF modulator is built as a standalone, shielded, panel-mounted daughter board, connected to the main carrier by one u.FL coax (baseband composite in) + a 6-pin header (power / ground / I²C). This supersedes the 2026-05-11 "bake RF into every carrier" decision (see [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md) → "Why on every carrier, not a daughter card"). The RF *chain* architecture and parts (ADL5391, Si5351, ERA-3, MLP, bandpass, combiner) are unchanged — they relocate from the carrier onto this board. This doc is the authoritative partition + physical-build spec; the chain spec stays in [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md).

**Distinct from:** [`rf-modulator-daughter-card.md`](rf-modulator-daughter-card.md) — that stub was the *old* "Period SKU tier" daughter-card framing (customer-segment based), rejected on segmentation grounds. This is a different rationale: modularity, RF isolation, clean interconnect, and a physically optional fit — not a customer-segment play.

---

## Why this won (the 2026-06-11 commit)

The interconnect turned out clean enough that the engineering was never the blocker — the only real question was product/assembly strategy, and the daughter board wins on every technical axis that matters for an RF section trying to pass FCC Part 15:

- **Best possible EMI/FCC partition.** The whole VHF chain (RF Si5351 + 25 MHz crystal → modulator → combiner → bandpass → ERA-3 → MLP) lives under one shield can on its own ground plane. *No intentional RF crosses the interconnect* — the carrier hands the board a DC–~4.5 MHz baseband composite signal and some DC/I²C, nothing else. That's the cleanest Part 15 story available: all RF emissions contained in one Faraday box with a single coax and a filtered DC/control header entering.
- **Self-contained ground + Faraday cage.** A standalone board gets its own continuous ground plane plus the can — a proper cage. The baked-in version forced the modulator to share the main-carrier ground plane with the FPGA, DDR3, switching regulators, and everything else.
- **Modular.** The RF section can be revised or respun without touching the main carrier, and vice versa.
- **Physically optional fit.** Populate or omit the board with zero carrier respin — the carrier just carries an unused u.FL pad + 6-pin header footprint when RF isn't fitted.
- **F-connector is self-contained** on the daughter board's own panel edge.

The cost is one extra small board + an interconnect + panel-mount hardware — accepted.

---

## The partition

A self-contained, shielded RF module that panel-mounts to the rear of the chassis. The F-connector is on the daughter board's own panel edge. **Everything RF lives on the daughter board;** the main carrier hands it baseband composite, control, and power.

**The layout move that makes the interconnect clean:** the dedicated RF Si5351 lives *on the daughter board*. The 61.25/67.25 MHz carrier is generated and consumed entirely inside the shield can — no VHF ever crosses the connector. (The RF Si5351 is free-running — it doesn't reference genlock, per the carrier-coherence note in the RF doc — so it just needs its own 25 MHz crystal locally.)

---

## Interconnect — what crosses

### 1× u.FL coax — baseband composite video

- **Composite video**, ~1 Vpp, DC–~4.5 MHz, from the carrier's LMH6643 composite buffer to the daughter-board ADL5391 Y input.
- Coax is for **shielding + a defined ground return**, not impedance matching: at 4–5 MHz over a ~10–20 cm intra-chassis run the line is electrically tiny, so reflections aren't the concern — noise pickup is. A ribbon conductor here would inject hum bars, digital hash, and sync-edge ringing into the picture. A short u.FL micro-coax kills that.
- **u.FL** chosen over MMCX/MCX: smallest, cheapest, and this is an assemble-once internal jumper, not a field-mated connector. u.FL jack on the carrier, u.FL jack on the daughter board, u.FL-to-u.FL cable between.

### 6-pin header — DC + I²C

| Pin | Signal | Notes |
|---|---|---|
| 1 | **+12 V** | ERA-3 bias (via 240 Ω) + modulator / op-amp rails. Post-eFuse, fused tap on the carrier. |
| 2 | **GND** | |
| 3 | **+3.3 V** | Si5351 logic + low-level analog. Off the carrier 3.3 V rail. |
| 4 | **GND** | Interleaved return. |
| 5 | **SDA** | Programs the RF Si5351 (channel select = register reload). 100 kHz–1 MHz. |
| 6 | **SCL** | |

- Total daughter-board draw ~150–200 mA — trivial for header pins.
- **No amp-enable pin.** The mode-mux/amp-gate was dropped; the amp is simply powered whenever the board is. **RF mute** (when the operator wants composite/component only) = disable the Si5351 output over I²C (OEB / clock power-down) — no carrier appears, nothing to gate, no dedicated pin. This is the cleanest mute and it's free.
- Keep the u.FL coax physically separate from the DC/I²C header routing.

---

## What stays entirely on the daughter board (never crosses)

- The **61.25/67.25 MHz carrier** (RF Si5351 + 25 MHz crystal, local).
- The **modulated RF**, **combiner**, **bandpass filter**, **ERA-3 amp**, **MLP** — straight to the F-connector on the board's panel edge.
- The **shield can** over the whole RF section.

The hardest signal in the system (the VHF carrier) becomes a non-issue because it's born and consumed inside the can. Nothing radiates VHF down a ribbon.

---

## Physical build spec

### Board stackup — 4-layer

**4-layer is required**, driven by how DC/I²C lines enter the shield can (below). Stackup:

| Layer | Use |
|---|---|
| **Top** | RF components + ground pour; the shield can solders to a **continuous** top-layer ground ring. |
| **L2** | Solid ground plane — RF reference + cavity floor under the can. |
| **L3** | Buried signal — DC/I²C routed here to pass *under* the can wall as stripline. |
| **L4 (bottom)** | Ground plane. |

Small board, ~65 × 30 mm (suits the long-narrow can below).

### Shield can — Masach MS643, two-piece nickel-silver

- **Frame:** `MS643-10F-NS` + **Cover:** `MS643-10C-NS` — nickel-silver, 64.3 × 20.3 × 6.7 mm.
- **Two-piece** (frame soldered down, removable cover) chosen over one-piece so the cover comes off for RF tuning/rework on the bench. NS over bare CRS for solderability + corrosion.
- The long-narrow footprint suits the linear RF chain: low-level Si5351/ADL5391 at one end, ERA-3 output at the other → natural input/output isolation along the can's length.
- **6.7 mm internal height clears all parts.** Cavity resonance (~2.3 GHz for the 64 mm long dimension) is far above the 56–73 MHz band — no internal walls or absorber needed.
- Continuous PCB ground ring under the frame perimeter + a via fence (~5 mm pitch) tying the ring through to L2/L4.

### Line entry through the can wall — do NOT break the ring

The continuous top-layer ground ring **is** the Faraday seal. A gap in it is a slot in the cavity wall, which radiates worst at exactly the band being contained. So DC/I²C lines do **not** pass through a break in the ring on the top layer — they dive under it:

```
external trace ─► [feedthrough cap at the wall] ─► via down to L3
                  (ground tabs land on the ring)        │
                                                         ▼
                              run under the can wall as stripline (L2/L4 grounds)
                                                         │
                                                         ▼
                                          via back up to top, inside the can
```

- Top ground ring stays continuous; the line is referenced to ground the whole crossing.
- The feedthrough cap shunts VHF to the ring **before** the via; the buried L3 trace is shielded by the planes as it passes under the wall.
- Ring each signal via with 2–3 ground stitch vias, tight antipad, so the top↔inner transition stays coaxial-ish and isn't itself a leak.

### Feedthrough caps (at the can wall)

3-terminal SMD feedthrough caps, mounted straddling the wall position, ground tabs to the ring:

- **DC lines (+12 V, +3.3 V):** Murata `NFM21PC104R1E3D` — 0.1 µF 25 V 0805 — ~$0.10 ea.
- **I²C (SDA, SCL):** Murata `NFM21CC102R1H3D` — 1 nF 50 V 0805 — ~$0.17 ea (small enough not to slow the bus).
- **Optional series ferrite** for an L/π section on each line: Murata `BLM21PG600SN1D` (~600 Ω @ 100 MHz) — ~$0.10 ea.

### Trim pots — outside the can

The two production trims are **DC bias, not RF-path**, so they live *outside* the shield can (cover-on calibration; filtered DC through the wall):

- **Output level** — ADL5391 GADJ bias.
- **Modulation depth** — ADL5391 Z-input bias (sync-tip → max carrier, peak-white → min carrier).

There is **no RF-path trim** — level is set by DC GADJ/Z-bias + the fixed ERA-3 gain + fixed MLP. Use a short SMD multiturn trimmer in production (Bourns `3224W` 4 mm, or `3314` 3 mm) — **not** the tall bench `3296W`, which is a breadboard part only.

---

## Carrier-side requirements (minimal)

The main carrier only needs:

- **1× u.FL jack** at the composite-buffer output (tap off the existing LMH6643 composite channel).
- **1× 6-pin header** (the pinout above): a fused +12 V tap (post-eFuse), +3.3 V off the carrier rail, 2× GND, SDA/SCL off the existing I²C bus.
- That's it — ~$1 of carrier-side parts. When RF is omitted, the u.FL pad + header footprint sit unpopulated; no respin.

---

## Daughter-board BOM (delta vs. the chain parts in `rf-modulator-subsystem.md` §parts)

The RF chain parts (ADL5391 $18, Si5351+xtal $2, ERA-3 $3.50, MLP $0.10, bandpass $1.50, combiner $0.50, F-conn+ESD+DC-block $1.80, bypass $1 ≈ **$28.40**) are unchanged. The partition adds:

| Item | Per board |
|---|---:|
| MS643-10F-NS frame + MS643-10C-NS cover (NS) | ~$3.50 |
| Feedthrough caps — 2× 0.1 µF (`NFM21PC104R1E3D`) + 2× 1 nF (`NFM21CC102R1H3D`) | ~$0.55 |
| Series ferrites — 2× `BLM21PG600SN1D` (optional) | ~$0.20 |
| u.FL jack (daughter board) | ~$0.40 |
| 6-pin header (board side) | ~$0.30 |
| 4-layer daughter PCB (~65×30 mm, qty 100) | ~$2.50 |
| Panel-mount hardware / standoffs / bracket | ~$1.50 |
| Production SMD trims (2× Bourns 3224W) | ~$1.50 |
| *(drop mode-mux bias FET — amp always powered)* | −$0.30 |
| **Partition adder** | **~$10** |
| **RF daughter-board assembly total** | **~$38** |

Carrier side: u.FL jack (~$0.40) + 6-pin header (~$0.30) + u.FL-to-u.FL cable (~$1) ≈ **~$1.70**, on **every** carrier — the footprints are always present so RF stays an option on any build (unpopulated when RF isn't fitted; ~$1 of that is just the cable, only bought when RF is).

---

## Alternative: COTS certified modulator (instead of the custom chain)

Flagged 2026-06-12 while weighing FCC cert cost. Because the carrier already produces a clean genlocked, cadence-correct composite at the buffer, a **turnkey analog NTSC Ch3/4 composite-to-RF modulator fed from that tap** would up-convert it as-is (analog modulators are cadence-agnostic) and arrive **already FCC-certified** — sidestepping the ~$8–15K intentional-radiator Certification the custom ADL5391 chain would trigger. Candidates: CIMPLE CO RCA→Ch3/4 modulator (~$33, US seller, verify FCC ID), RFM-1C (~$14). The daughter-board slot could carry a COTS module instead of the custom chain.

Tradeoffs: commodity DSB units have fixed output level, modest filtering, and possible spurs — fine into a CRT at 2 m but below the custom chain's quality; integration is less elegant (gutting a consumer box); and embedding a finished certified device in our chassis is *better footing than uncertified custom silicon but not a guaranteed host-authorization pass-through*. Also confirm the unit emits the 4.5 MHz aural carrier with no audio (period-set intercarrier AGC needs it) — feed a silent/tone audio line if not. **Decision: custom ADL5391 chain stays the default (quality play); COTS kept as the budget / cert-sidestep / prototype option.**

---

## Open decisions

- [x] **Daughter board vs baked-in** — **RESOLVED 2026-06-11: daughter board.**
- [x] **Tier — truly optional fitted module (decided 2026-06-12).** Never standard, never default-populated; a unit gets RF only when ordered. Clean populate/omit, no carrier respin — the carrier always carries the u.FL + 6-pin footprints (~$1.70), unpopulated when RF is absent. Positioned as a Pro-tier option; **Mini-eligibility is an open product call** (technically fittable on any carrier — the carrier and its composite buffer are common to both SKUs). The older "universal / every unit" framing is dead.

---

## Cross-references

- RF chain architecture + parts spec: [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md)
- BOM line items: [`bom-v1.md`](bom-v1.md) §7
- Carrier-coherence note (why the RF Si5351 is free-running): [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md) → "Si5351 dedicated to RF subsystem"
- Rear-panel slack: [`panel-layout.md`](panel-layout.md)
- Superseded Period-SKU framing: [`rf-modulator-daughter-card.md`](rf-modulator-daughter-card.md)
