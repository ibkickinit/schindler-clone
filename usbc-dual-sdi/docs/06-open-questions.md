# 06 — Open Questions (design-gating)

Ordered by how much they constrain the rest of the design.

## Q-MAC — MST vs USB4 front end (Mac independent-dual) *(DEFINING product decision)*
**Verified (HIGH confidence, 2026):** macOS does **not** support DP MST extended
desktop — it **mirrors** (hardware-locked on Apple Silicon, no fix coming). So:
- **MST front end** (current baseline) → two-independent on **Windows/Linux**,
  **mirror-only on Mac**. For a Mac-heavy broadcast/production market this is a
  **dealbreaker** for the "two independent" promise (dual-mirror still serves
  one-source→two-destinations, our twin-output mode).
- Macs do independent dual via **Thunderbolt/USB4 DP tunneling**, not MST. A
  **USB4 hub (Realtek RTS5490** — non-Intel, **not** TB-cert-gated, fixed-
  function, **no FPGA)** can replace the MST hub → same GS12170 chain → Mac
  *and* Windows independent dual, still "dumb."

**The decision is "who's the customer?"** Windows live-events/AV → MST (cheapest).
Mac broadcast/production → USB4. **Open / to verify:**
- ⚠️ **Does macOS actually extend across RTS5490's two tunneled DP streams?**
  UNVERIFIED — **test on a real M4/M5 Mac** before committing.
- Does a USB4 hub still work on a **plain DP-Alt-only PC** host, or does USB4
  *narrow* cheap-PC support?
- **Apple Silicon caps:** base **M1/M2/M3 = 1 external** (no dual by any method);
  **M4/M5 base + Pro/Max = 2+**. A real support-matrix caveat either way.
- RTS5490 sourcing (low-volume) and cost vs an MST hub.

**Does not block the prototype:** the GS12170 conversion chain is identical for
either front end, so Phase 1 proceeds on MST; this is a *production front-end*
decision (`02` §2, `04` Block 2, `05` Phase 3).

## Q0 — GS12170 EOL *(CONFIRMED EOL Feb 2025 — the no-FPGA design has lost its keystone)*
**CONFIRMED: the GS12170 is End-of-Life as of Feb 2025** (Semtech PCN
**EOL-000308**). The dumb/no-FPGA architecture rested entirely on this one chip,
and **there is NO single-chip replacement from any vendor** — Semtech's was "the
industry's first" and stayed the only HDMI↔12G-SDI bridge ASIC (the rest of the
catalog is SDI-PHY-only; no TI/Macnica/etc. equivalent exists). So this is a
**keystone failure, not a part swap.**

**Implication — the dumb-vs-smart distinction has largely collapsed:**
- 12G-SDI needs **12G-class transceivers**, so the "small-FPGA fallback" is *not*
  small — it's **PolarFire-class** (12.7G SERDES; its 12G-SDI IP is **free**) or
  UltraScale+. Conversion now genuinely **requires a real FPGA** for a sustainable
  12G product.
- Once a PolarFire is on the board for conversion, the *same chip* can also do the
  MST split (Parretto IP) and the smart features — so the shelved FPGA design is
  now the realistic V1 path, not a V2.

**Three paths (user decision pending):**
1. **Last-time-buy gen-1 on remaining GS12170 stock** — viable *only if enough
   stock exists* (EOL was 16 mo ago; LTB window likely closed → depends on
   distributor/broker stock + quality risk). Ships a fixed-function gen-1 to
   validate market while building the FPGA gen-2.
2. **FPGA (PolarFire) conversion now** — sustainable; more HDL, but PolarFire
   SDI IP is free.
3. **Full smart product** — since the FPGA is needed anyway, fold in frame
   conversion / color / genlock (the "V2 we'd be game for" becomes V1).
2b. **OEM converter module** (e.g. Digital Forecast HDMI→12G-SDI) — keeps *our*
   design FPGA-free at BOM/size cost; only if the module isn't itself GS12170-based.

**Next checks:** (a) current GS12170 stock for an LTB-size estimate; (b) whether
a non-GS12170 OEM module exists. Then re-baseline `01/02/04/05`.
**Action:** Semtech lifecycle inquiry + get the GS12170 eval board (Phase 0).

## Q1 — MST hub: still required, sourcing per `07` *(dumb design uses a discrete hub, not FPGA-MST)*
Going FPGA-less does **not** remove the MST hub — you still need it to get two
displays from one USB-C. In the dumb design the hub feeds the two GS12170 bridges
(HDMI 2.0). Sourcing playbook + decision in **`07-sourcing-playbook.md`**:
- **Prototype:** a **$40 off-the-shelf USB-C→dual-HDMI MST adapter** (Plugable
  USBC-MSTH2) — offloads the hub to a commodity part; build the conversion now.
- **Production:** a discrete hub — **Parade PS8650** (Avnet quote pending),
  **Synaptics VMM6210** (datasheet in hand), or **Realtek RTD2186**. All are
  design-win-channel parts; chase quotes in parallel with the build.
- *(MST-in-FPGA — Parretto/AMD/Intel — is only relevant to the Pro/smart variant,
  which has no separate bridge chip. See `04` Block 2 Family B.)*

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

## Q10 — FPGA IP-licensing NRE *(MOOT for v1 — Pro/smart variant only)*
**Not a v1 concern** — the dumb design has no FPGA and no IP licensing. This only
matters if the **Pro/smart variant** is built. For reference: AMD MST-in-FPGA
carries ~$11k AV + ~$5k DP IP; **Intel** first-party or **Parretto/Bitec on
PolarFire** are cheaper Pro routes (`04` Block 3). **HDCP entitlement is never
needed** (non-HDCP sink, Q11).

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
