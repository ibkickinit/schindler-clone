# 06 — Open Questions (design-gating)

Ordered by how much they constrain the rest of the design.

## Q1 — MST hub chip vs FPGA DP-RX for the "two displays" split *(blocks topology)*
Two ways to present two displays from one DP link:
- **(a) Discrete DP1.4 MST hub** outputting two HDMI/DP streams into the FPGA.
  Pro: offloads DP/MST complexity. Con: **MST-hub silicon is hard to source in
  low volume** (NDA / dock-ODM channels).
- **(b) DP1.4 RX directly into the FPGA**, MST handled in FPGA IP. Pro: no scarce
  hub chip, fewer parts. Con: heavier FPGA, more IP licensing, harder bring-up.

**Need:** a sourcing answer on (a) and an IP/resource estimate on (b) before
committing. This decision cascades into FPGA size, BOM, and schedule.

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

## Q10 — HD-class sibling on Zynq-7020? *(parallel thought, not planned)*
The Zynq-7020 / TE0720 **cannot** do dual-4K 12G-SDI — even pure passthrough,
no FRC — because its **GTP transceivers cap at ~6.25 Gb/s** vs 12G-SDI's
~11.88 Gb/s (a PHY ceiling, unrelated to FRC compute). It *could* plausibly do
**dual 3G/HD-SDI** or a **single 6G**. Parked as a possible cheaper **HD-class
sibling** product, not on the 4K design path. Dual-4K needs UltraScale+
GTH/GTY — see `04` Q-block 3.

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
</content>
