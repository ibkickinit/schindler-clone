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

## Q2 — Does the target laptop give 4-lane DP Alt Mode? *(blocks max resolution)*
Dual-4K60 needs 4 DP lanes. Many USB-C ports drop to **2-lane** DP when
simultaneous USB 3 SuperSpeed is required. We sacrifice host USB 3 (keep only
USB 2 sideband) to claim 4 lanes — but **does each target host actually grant 4
lanes in that config?** Needs measurement across MacBook / Dell / Lenovo / HP.
Fallback if only 2 lanes: cap at dual-1080p60 or single-4K, or require DSC.

## Q3 — Bus power vs auxiliary power-in *(blocks mechanical + UX)*
Dual 12G + FPGA is ~5–8 W; a host USB-C port without PD may give less. Options:
- Negotiate **USB PD** and rely on the host. Cleanest UX, not always available.
- Add a **second USB-C power-in**. Robust, but it's "another cable" — hurts the
  "just one cable" story.
- **Tiered behavior**: dual-1080p on bus power, dual-4K requires aux. Honest but
  needs clear UX signaling.
Decision waits on **measured** silicon current draw (Phase 0).

## Q4 — Fractional-rate EDID reliability per OS *(blocks Tier-2 scope)*
How reliably do Win / macOS / Linux honor an EDID that advertises **only**
23.98 / 59.94? If reliable, Tier-1 EDID management suffices for v1 and Tier-2
active FRC can stay deferred. If flaky (likely for 23.98/24), the value case for
**Tier-2 active FRC** rises — possibly into v1. Measured in Phase 4.

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
