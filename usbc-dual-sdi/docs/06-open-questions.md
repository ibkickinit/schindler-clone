# 06 — Open Questions (design-gating)

Ordered by how much they constrain the rest of the design.

## Q1 — How to split one DP link into two displays *(REOPENED — two live paths, gated on VMM procurability)*
The first pass concluded "MST silicon unobtainable → must do MST in an AMD
FPGA." **Follow-up research corrected that:** Synaptics **VMM6210 / VMM5330**
are *real, datasheet-published* DP1.4 MST hubs (dual-4K60) — so there are now
**two live paths** (detail in `04` Block 2):
- **Path A — discrete MST hub chip → cheaper FPGA (PolarFire, free 12G-SDI IP).
  Avoids the AMD IP NRE.** Two hub sources: **Synaptics VMM6210/5330**
  (integrates USB-C input) or **Parade PS8650** (Taiwan; true DP2.1a→DP1.4 MST
  hub, but needs a separate USB-C DP-Alt front stage). Gating unknown:
  **low-volume procurability of either hub** (datasheets public/gated; live
  stock 403-blocked, *unverified*; both sell via disti/FAE). A Thunderbolt/USB4
  front end was evaluated — **no Asian single-chip does the dual-DP breakout**
  (only Intel Goshen Ridge JHL8440, which is TB-cert-gated); not pursued for v1
  unless Thunderbolt-only host support is required (`04` Block 2).
- **Path B — DP MST RX inside an AMD FPGA** (DP1.4 RX Subsystem, PG300). Always
  available; pins vendor to AMD; **paid IP** (~$11k AV + ~$5k DP, see Q10).
**Decision rule:** if a Synaptics quote + lead time at our quantity is workable
→ **Path A** (materially cheaper). Otherwise → **Path B** (fallback, costs ~$16k
IP). ⚠️ The buyable Parade/ITE/Algoltek/Realtek parts are single-stream, **not**
MST splitters. **This is the top architecture decision to close.**

## Q2 — Does the target laptop give 4-lane DP Alt Mode? *(measurement, not a fork)*
Dual-4K60 needs 4 DP lanes. Many USB-C ports drop to **2-lane** DP when
simultaneous USB 3 SuperSpeed is required. We sacrifice host USB 3 (keep only
USB 2 sideband) to claim 4 lanes — but **does each target host actually grant 4
lanes in that config?** Needs measurement across MacBook / Dell / Lenovo / HP.
**Resolved behavior (decided):** when only 2 lanes (or insufficient bandwidth)
are available, **degrade down the ladder** in `02` (dual-4K → single-4K twin →
dual-HD → single-HD twin) rather than failing. The measurement still matters for
knowing how often each host lands on which rung.

## Q3 — External power form *(DECIDED — wattage thresholds still open)*
Dual 12G + FPGA is ~5–8 W; a host USB-C port without PD may give less.
**Decision:** a **secondary USB-C power-in port** (PD sink only, no data/Alt
Mode) that accepts **either another USB-C port or a standard USB-C PD wall PSU**;
prefer host PD when sufficient, fall back to aux, and **degrade** (per ladder)
when neither sustains the requested format. **Still open:** the measured wattage
per ladder rung (which rungs are bus-powerable vs aux-only) — pending real
silicon current draw from the sourcing research.

## Q4 — Fractional-rate EDID reliability per OS *(DECIDED to hedge — measurement still informs Tier-2)*
How reliably do Win / macOS / Linux honor an EDID that advertises **only**
23.98 / 59.94? **Decision:** accept an **optional host-side helper** (`03`) that
programmatically pins the custom mode where pure-EDID coaxing is unreliable —
video stays driverless, the helper only improves determinism. This de-risks v1
without needing active FRC. The per-OS reliability measurement (Phase 4) still
decides whether full **Tier-2 active FRC** is ever warranted.

## Q10 — AMD IP-licensing NRE *(Path B only — avoided entirely on Path A)*
Pinning to AMD + FPGA-side MST (Path B) drags in a real, partly-opaque NRE:
**~$11k AMD AV IP bundle (HDMI/SDI) + ~$5k DP1.4 RX IP** (figures
order-of-magnitude, "contact sales", *unverified*). Amortizes only at volume.
**Path A (VMM + PolarFire, free 12G-SDI IP) avoids this NRE entirely** — which is
the main reason to chase VMM procurability in Q1. If Path B is chosen:
- Exact license SKUs, real quotes, and whether eval/timeout licenses suffice
  through Phase 1–4 bring-up before paying full freight.
- **HDCP entitlement is NOT needed** — see Q11 (we ship as a non-HDCP sink), so
  drop it from the NRE on either path.

## Q5 — DSC: in or out for v1?
Dual-4K60 **4:4:4** needs DP DSC; dual-4K60 **4:2:2 10-bit** (what SDI carries)
fits 4-lane HBR3 without DSC. Since SDI is 4:2:2 anyway, **v1 can likely skip
DSC** and still hit the headline spec. Confirm the blanking/TU overhead margin
on real hardware (Phase 3) before declaring DSC unnecessary.

## Q6 — Audio scope
How many embedded audio channels in v1? DP/HDMI commonly carries 2ch/8ch LPCM;
SDI supports up to 16. Default proposal: **carry whatever the DP stream provides
(2–8ch) into ST 299 groups**, don't synthesize. Confirm.

## Q7 — Genlock connector reservation
Even though active FRC/genlock is Tier-2, do we reserve a **REF-IN BNC** + FPGA
DDR bank on the v1 PCB so Pro is a stuffing upgrade, not a respin? Proposed:
**yes, reserve footprints; don't stuff.** Confirm against board-area/cost.

## Q8 — Product name
"Crossover" is a placeholder. Pick a real name before any external material.

## Q9 — Capture sibling?
A v2 sibling doing **SDI→USB capture (UVC)** is an obvious adjacent product but a
different data path. Out of scope here — flag only so we don't accidentally
design v1 in a way that forecloses it.

## Q11 — HDCP posture *(DECIDED — non-HDCP-sink, like the incumbents)*
Research-confirmed (legal-quote verbatim *unverified*, conclusions **high
confidence**; get IP-counsel sign-off on datasheet language before shipping).

**The answer to "can the user override HDCP passthrough to SDI like Schindler
does?" is NO.** SDI carries no HDCP, so passing protected content to SDI is
**decrypt-to-clear = a circumvention device**, illegal to sell/import under
**DMCA §1201 (trafficking)** *and* barred by the **DCP LLC HDCP license** (you
can't get device keys without being an adopter, who is then contractually
forbidden from emitting cleartext to a non-HDCP receiver). A user "I own the
rights" checkbox is **liability framing only — it does not legalize stripping.**
Schindler's override is a different case: it targets an **HDMI OUT** that *can*
re-carry HDCP; SDI cannot, so the same UX here would enable an illegal strip.

**Decision — match Blackmagic / AJA / Decimator: be a NON-HDCP SINK.**
- The input **never advertises as an HDCP receiver** (no device keys, never runs
  the AKE handshake). Unprotected sources (laptop desktop, cameras, production
  playback — i.e. essentially all real input) convert normally; a rare protected
  source **blanks at the source**, not in our box.
- This **avoids needing an HDCP IP license entirely** — removes that line from
  the Path-B NRE (Q10) and is moot on Path A.
- **Silicon caveat:** the **Synaptics VMM6210 includes HDCP 2.3** and many
  DP/HDMI RX bridges ship HDCP; we must ensure HDCP is **provably
  unprovisioned / never authenticated** so we are not a sink. Verify per chosen
  part (`04`).
- **Do NOT** ship or market any HDCP-defeating capability or "override" toggle.
- UX: document plainly **"not HDCP-compliant; converts unprotected sources
  only"** + a generic user-responsibility notice. No strip toggle.
- Also confirm HDMI/DP/USB-C **trademark/adopter** obligations (separate from
  HDCP).
