# Schindler 2.0 — FCC Strategy & Pre-Cert Playbook

**Status:** Working strategy doc — 2026-06-12. Scopes the US FCC equipment-authorization path for Schindler 2.0 (Pro + Mini) and what's permissible before certification is granted. **Not legal advice** — the two items flagged under "Confirm before the campaign" should go to the test lab / FCC counsel before money is committed. Regulatory basis: 47 CFR Parts 2 and 15.

---

## Headline

**The FCC gate is on *delivering/selling finished units to end users*, not on building, operating, or demoing them.** Essentially all prototyping, characterization, customer validation, trade-show demoing, and even advertising + conditional pre-orders can happen *before* any certification. The only hard stop is handing a paying customer a box before the authorization for that box is in hand.

This means the cert campaign does **not** block the dev arc, the bench work, customer trials, or pre-revenue marketing. It blocks shipment.

---

## What we can do right now, pre-cert

| Activity | Allowed? | Condition |
|---|---|---|
| Build, bench-test, characterize, iterate at the shop | ✅ Unrestricted | R&D use isn't "marketing"; operating during development is explicitly fine. |
| Evaluate at customer sites / on shoots | ✅ | Performance evaluation + customer-acceptability during developmental/design/pre-production stages is permitted (47 CFR §2.803(c)(2)). If run anywhere other than our facility, the unit must carry the "not authorized" label. |
| Trade-show / demo display | ✅ | Post the conspicuous disclaimer (exact wording below), or advise all prospective buyers in writing. |
| Advertise + take conditional pre-orders | ✅ (since 2022) | §2.803 was relaxed 2022-04-12 to permit conditional sales contracts + advertising to the general public pre-authorization. Disclose that delivery is contingent on completing authorization; keep conditional-sale records for 60 months. |
| Manufacture / import a limited run for the above | ✅ | For demo loading, staging, eval units, pre-sale activity. |
| **Deliver / sell units to end users** | ❌ **Hard stop** | Prohibited until the authorization for that configuration is granted — residential end users especially. |
| Put an FCC ID on the product | ❌ | Not until certification is granted. |

### Required trade-show / advertising disclaimer (verbatim)

The notice must contain this language, displayed conspicuously on or adjacent to the device (per 47 CFR §2.803(c)(2)(iii)(A)):

> This device has not been authorized as required by the rules of the Federal Communications Commission. This device is not, and may not be, offered for sale or lease, or sold or leased, until authorization is obtained.

(If the thing being shown is an unauthorized *prototype* of a product whose production version is later authorized, §2.803(c)(2)(iii)(B) provides alternate prototype wording.)

### Conditional pre-order requirements

- Tell the buyer at time of marketing that the equipment is subject to FCC rules and **delivery is conditional on completing the authorization process**.
- Maintain records of each conditional sale for **60 months** (device name + product ID, quantity, date authorization was sought, expected FCC ID, buyer identity/contact). Produce on FCC request.

---

## Schindler's authorization map — three separate buckets

The product is not one monolithic cert. It splits into three independently-treated pieces with very different burdens:

### 1. Digital device / unintentional radiator → SDoC
The carrier, FPGA, SDI/HDMI/analog chains, switching supplies. Path: **Supplier's Declaration of Conformity** (the merged Verification + DoC process, effective 2017-11-02). Test at an accredited lab, self-declare conformity, **no FCC filing, no FCC ID**.
- A rack box marketed to broadcast/commercial/industrial users can likely qualify as a **Class A digital device** (looser radiated/conducted limits than Class B). Confirm the intended-market classification — Class A vs B changes the emission limits the bucks/FPGA edges must meet.

### 2. WiFi/BT radio (Laird Sterling LWB5+) → already certified module
The intentional radiator (2.4/5 GHz Wi-Fi + BT5.0) is a **pre-certified module with its own FCC ID**. This is the big shortcut: **we do not certify the radio.**
- Stay within the module's grant conditions (approved antenna types/gains, integration/separation rules). The host bears a **"Contains FCC ID: …"** label.
- If we stay within the module's modular-approval envelope, the radio work is near-zero formal filing. Deviating (different antenna, co-location issues) can trigger a Class II Permissive Change — avoid by following the module integration guide.

### 3. RF modulator (TV interface device, 47 CFR §15.115) → Certification
The one element that genuinely needs its **own Certification (FCC ID)** — it's an intentional radiator putting a signal on a TV channel (Ch3/Ch4). This is where the bench → pre-compliance scan → formal cert campaign actually applies (shielding, the MS643 can, feedthrough filtering, the bandpass + MLP all exist to pass these limits).

---

## The strategic kicker — the daughter board decouples the cert critical path

Because RF is now a **self-contained, separable, shielded daughter board** (committed 2026-06-11), the only certification-bearing intentional radiator is isolated on that board. Consequences:

- A unit shipped **without** the RF daughter board — **every Mini, and any Pro with RF omitted** — has no TV-band intentional radiator at all. Those units can potentially go to market on **SDoC + the LWB5+ module grant alone**, with **no modulator certification**.
- Only the **RF-equipped Pro** units gate on the §15.115 cert.
- Net: we can ship the bulk of the line early and **decouple revenue from the longest pole in the cert tent**. The partition didn't just clean up EMC — it cleaved the certification critical path.

**Sequencing implication for the dev roadmap:** treat "non-RF units shippable" (SDoC + module grant) as an earlier, separate milestone from "RF Pro shippable" (adds §15.115 grant). Don't let the modulator campaign hold the rest of the product hostage.

---

## Confirm before the campaign (cheap insurance, do early)

1. **Modulator cert classification** — confirm the RF modulator falls under §15.115 (TV interface device / TVID) vs another intentional-radiator path, and the **exact subsection** for its conducted/radiated limits. The internal docs have cited both §15.115 and §15.119 in spots — standardize this. The test lab triages this daily.
2. **Digital-device class** — confirm Class A (commercial/industrial marketing) vs Class B for the SDoC, since it sets the emission limits the carrier layout must hit.
3. **Module integration conditions** — verify the LWB5+ grant's antenna list + host-integration requirements so the "Contains FCC ID" path stays valid without a permissive change.

If we ever need to *operate* (not just develop/demo) at a scale beyond the §2.803 evaluation provisions — e.g. a large field trial — that's a **Part 5 experimental license**, not a §2.803 activity. Probably not needed at our scale.

---

## Cross-references

- AC-entry / pre-certified-module strategy: [`01-spec.md`](01-spec.md) §1.3
- RF modulator (the §15.115 element): [`rf-modulator-subsystem.md`](rf-modulator-subsystem.md) + [`rf-modulator-daughter-board-option.md`](rf-modulator-daughter-board-option.md)
- SKU stuffing (which units carry RF): [`packaging-skus.md`](packaging-skus.md)
- Dev sequencing: [`dev-roadmap.md`](dev-roadmap.md) — add the two-tier "non-RF shippable" vs "RF Pro shippable" cert milestones
