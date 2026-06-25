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
  **USB4 hub (Realtek RTS5490** — non-Intel, **not** TB-cert-gated) can replace
  the MST hub; its DP-tunneled outputs feed the **same PolarFire DP-RX** → Mac
  *and* Windows independent dual.

**The decision is "who's the customer?"** Windows live-events/AV → MST (cheapest).
Mac broadcast/production → USB4. **Open / to verify:**
- ⚠️ **Does macOS actually extend across RTS5490's two tunneled DP streams?**
  UNVERIFIED — **test on a real M4/M5 Mac** before committing.
- Does a USB4 hub still work on a **plain DP-Alt-only PC** host, or does USB4
  *narrow* cheap-PC support?
- **Apple Silicon caps:** base **M1/M2/M3 = 1 external** (no dual by any method);
  **M4/M5 base + Pro/Max = 2+**. A real support-matrix caveat either way.
- RTS5490 sourcing (low-volume) and cost vs an MST hub.

**Does not block the prototype:** the PolarFire conversion is identical for either
front end (both deliver DP to the DP-RX), so bring-up proceeds regardless; this is
a *production front-end* decision (`02` §2, `04` Block 2, `05` Phase 3).

## Q0 — Conversion approach *(DECIDED 2026-06 → PolarFire FPGA; GS12170 dead)*
**DECISION: do conversion in a Microchip PolarFire FPGA** (free 12G-SDI IP). The
GS12170 fixed-function path is dead (CONFIRMED EOL Feb 2025, PCN **EOL-000308**,
no replacement). User chose the FPGA path. New architecture in `02`/`04`. The
fixed-function gen-1 last-buy option was left open pending a live stock check (see
below), but the **durable design is PolarFire**.

**New diligence items the FPGA path created (verify on the bench / with Microchip):**
- **Q0a — HDMI-RX 4K30 cap → use DP-RX for 4K60.** Microchip HDMI RX IP tops out
  at 4K30; the **DisplayPort RX IP** does HBR3/SST → **4K60**. So the hub must
  output **DP** (PS8650/VMM5330), and we validate 4K60 over DP-RX. *Confirmed from
  Microchip IP docs; bench-verify.*
  - **Clarification (the 12G output is NOT the issue):** PolarFire's transceivers
    (12.7G) + free SDI TX IP do **single AND dual 12G-SDI out** fine. The 4K30 cap
    is purely on the **HDMI input** (limits a HDMI source to 6G out); it says
    nothing about SDI output. And the video kit's on-board **3G** SDI is an
    **eval-board** limit — 12G needs the `VIDEO-DC-SDI` FMC; the chip is unaffected.
- **Q0b — 2-channel resource/timing fit + DP-RX IP cost + package transceivers.**
  The DG0889 12G-SDI demo is single-channel; confirm 2× DP-RX + 2× SDI-TX + Mi-V
  fit + close timing in MPF300 (300K LE), and that the chosen **package exposes
  enough transceiver lanes** (≈2× DP-RX lanes + 2× SDI-TX lanes — the kit's
  1152-ball part has plenty; smaller packages may not). SDI IP is free; **confirm
  DP-RX IP license** (Microchip CoreDP or Bitec).
- **Bench needs `VIDEO-DC-SDI` FMC** for 12G (the video kit's on-board SDI is
  HD/3G only).

## Q0c — SDI-rate scope vs cost *(DECIDED: stay dual-4K60/12G)*
**DECISION: keep dual-4K60/12G** (the full spec) — not scoped down. FPGA plan of
record **MPF200T-FCG484I ($286)**, cost-down to **MPF100T ($174)** if the design
fits its logic. Cost accepted as the price of the high-end spec; the analysis
below is retained as the rationale + the lower-rate fallback if economics force it.

The FPGA cost is driven by the **dual-4K60/12G** ambition, and it's a heavy BOM
line at any size: MPF100T **$174** (logic tight), MPF200T **$286**, MPF300T
**~$600** (qty-1; ~30–50% less at volume) — **plus** the DP-RX IP license. For a
sub-$600–900-retail product that's tough. **The biggest cost lever is the SDI
rate, not the part number:**

| Target | SDI rate | Silicon | Rel. FPGA cost |
|---|---|---|---|
| Dual **4K60** | 12G | MPF100T/200T+ | $174–286+ |
| Dual **4K30** | 6G | smaller PolarFire / **Lattice CertusPro-NX** (10.3G OK for 6G) | much less (~$30–80) |
| Dual **1080p60** | 3G | small PolarFire / cheap FPGA | least |

**3G/1080p is the most common broadcast format** (huge installed base of 1080p
switchers/monitors). **Decision needed:** is dual-4K60 essential, or does dual-
1080p (3G) / dual-4K30 (6G) serve the real use case (feeding SDI monitors/
switchers from a laptop)? A lower rate opens **much cheaper silicon** (incl.
non-PolarFire) and a viable BOM, with 4K60 as a premium model later. **This gates
the FPGA choice and the whole BOM — resolve before committing.**

*(History below retained for the decision trail.)*

**CONFIRMED EOL Feb 2025 — the no-FPGA design lost its keystone:** the GS12170 is
End-of-Life (PCN EOL-000308), and **there is NO single-chip replacement from any
vendor** — Semtech's was "the industry's first" and stayed the only HDMI↔12G-SDI
bridge ASIC (rest of the catalog is SDI-PHY-only). A **keystone failure, not a
part swap.**

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

**Check results (2026-06):**
- **Stock — not numerically resolvable remotely** (DigiKey/Mouser/Arrow/Octopart/
  Findchips all 403 the crawler). But GS12170-IBE3 is still **listed "ships
  today" at DigiKey, Mouser, Arrow 16 mo post-EOL** → residual authorized stock
  likely exists. **User must check live qty** (sum across distributors vs
  run-size ×2 chips/unit + margin) — that number decides if a last-buy gen-1 is
  viable.
- **OEM modules exist but = stopgap, not a foundation.** Finished HDMI→12G-SDI
  converters: **Digital Forecast Bridge M_HS** (dual HDMI→dual 12G-SDI micro
  module — closest to our back-end), **Blackmagic Micro Converter** (1→1, ~$149,
  **FPGA-based → survives the EOL**), AJA **HA5-12G** (1→2 DA, not independent),
  **SC&T SDI02E-12G** (likely GS12170-based → also doomed). Integrating finished
  modules is bulky/costly/vendor-margin-laden and not the clean integrated
  product. Only a cheap *board-level OEM* module would change that (needs vendor
  BD).
- **Key reframe:** the survey shows **everyone does this conversion in an FPGA**
  (Blackmagic = Spartan/Artix). The GS12170 was the *anomaly* that skipped it;
  its death just returns us to the industry-standard FPGA path. **PolarFire (free
  12G-SDI IP) is the durable answer**, not a sad fallback.
**Action:** Semtech lifecycle inquiry + get the GS12170 eval board (Phase 0).

## Q1 — Front-end hub: still required (discrete DP-output hub feeds the FPGA DP-RX)
The FPGA does **conversion**, not the MST split — you still need a hub to get two
displays from one USB-C. It should output **DP** (to feed the PolarFire DP-RX at
4K60; the HDMI-RX path caps at 4K30 — Q0a). Sourcing in **`07`**:
- **Prototype:** a **$40 off-the-shelf USB-C→dual-HDMI MST adapter** (Plugable
  USBC-MSTH2) for the HDMI-in / ≤4K30 bring-up; a DP source/hub for 4K60.
- **Production (DP output):** **Parade PS8650** (Avnet quote pending), **Synaptics
  VMM5330**, or **Realtek RTS5490** (USB4, for Mac — Q-MAC). Design-win-channel
  parts; chase quotes in parallel with the build.
- *(MST-in-FPGA — Parretto/AMD/Intel — is NOT used; the discrete hub does the
  split. It survives only as a theoretical all-in-one-chip alternative, `04`.)*

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

## Q10 — FPGA IP licensing *(V1 = just the DP-RX IP; the big MST NRE is avoided)*
V1 uses PolarFire, but because the **discrete hub does the MST split**, we **do
not** license DP-MST IP — sidestepping the ~$16k AMD AV/DP NRE entirely. V1's only
IP question is the **DP-RX IP** (Microchip CoreDP-RX or Bitec) — the **12G-SDI IP
is free** — tracked in **Q0b**. **No HDCP entitlement** (non-HDCP sink, Q11). The
~$16k AMD MST-in-FPGA route only matters for a theoretical all-in-one-chip Pro
variant (`04` Block 3) — not pursued.

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
