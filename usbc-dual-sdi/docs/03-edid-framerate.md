# 03 — EDID & Frame-Rate Management

This is the **core differentiator**. Any HDMI→SDI converter moves pixels; the
value here is *controlling what pixels the laptop decides to send*, so the SDI
that comes out is broadcast-legal without the operator fighting the OS display
settings.

## The problem with "just plug it in"

A GPU picks resolution and frame rate from the sink's **EDID** (the descriptor
the display advertises over the DDC/I2C channel). Left to defaults, a laptop
will happily emit **2160p60.00** or **1080p60.00** — and 60.00 is *not* a
broadcast rate. Worse:

- Fractional broadcast rates (**23.976, 29.97, 59.94**) are often **absent** or
  buried in a display's EDID, so the GPU never offers them.
- The GPU may pick **RGB full-range** when downstream SDI gear expects
  **YCbCr limited (legal) range**.
- The two outputs can independently drift to different timings.

## Tier 1 — EDID-driven management (v1, no frame buffer)

We **emulate** the EDID for each sink endpoint in the management MCU (writable,
not a fixed EEPROM). By authoring the EDID we dictate the menu of modes the host
sees, and by ordering/flagging them we strongly bias what it picks.

### What we advertise
- A **curated CEA-861 mode list** per output, broadcast-first:
  - 1080p/1080i and 2160p at **23.98 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60**.
  - Fractional rates carried as proper **detailed timing descriptors / VICs**
    with the correct pixel clocks (e.g. 1080p59.94 at 148.35 MHz, not 148.5).
  - **YCbCr 4:2:2 / 4:4:4 support flags** and **limited-range** preference via
    the CEA video capability data block.
- A **"preferred timing"** set to the profile the operator selected, so the GPU
  defaults to it on hot-plug.

### EDID profiles (operator-selectable)
Profiles are stored in the MCU and chosen via the config app, OLED+button, or a
default. Each profile is essentially a tailored EDID:

| Profile | Advertises / prefers |
|---|---|
| `Auto (broadcast)` | full broadcast mode list, prefers 1080p59.94 |
| `Lock 1080p59.94` | **only** 1080p59.94 offered |
| `Lock 1080p50` | **only** 1080p50 |
| `Lock 2160p59.94` | only 2160p59.94 (4:2:2) |
| `Lock 2160p23.98` | only 2160p23.98 — film cadence |
| `Lock 1080p23.98` | only 1080p23.98 |
| `Cinema 24.00` | only 24.000 (true, not 23.98) |

"Lock" profiles work by advertising a **single** mode (plus the bare minimum the
host needs to enumerate), which is the most reliable way to force a GPU onto an
exact timing — it has nothing else to choose.

### Hot-plug discipline
Changing a profile re-asserts **HPD (hot-plug detect)** to the affected sink so
the host re-reads EDID and re-selects. This is how a profile change "takes"
without unplugging.

### Limits of the passive approach (be honest)
- The GPU still has final say; some drivers ignore or round fractional rates.
- macOS/Windows/Linux differ in how aggressively they honor custom EDIDs.
- 23.98/24 enumeration from laptop GPUs is historically the least reliable case.

These limits are exactly why Tier 2 exists — **and** why we accept an optional
host-side helper (below).

### Host-side helper (accepted, optional)
Pure-EDID coaxing isn't always enough — some GPUs/OSes round or ignore custom
fractional timings (23.98/24 is the worst case). We therefore accept that a
**small host-side software/driver component may be needed** to make frame-rate
forcing reliable, **without** requiring it for the device to function:

- Video is always **driverless** (native DP Alt Mode); the SDI works on a bare
  plug-in regardless.
- The optional helper (the same app that talks to the management MCU over the
  USB 2.0 sideband, `Tier 1`) can, where the OS allows, **create/apply a custom
  display mode** matching the device's preferred timing — programmatically
  pinning the exact resolution/frame rate instead of hoping the GPU picks it
  from the EDID. This rides existing per-OS custom-resolution mechanisms.
- This is a **reliability enhancer, not a dependency**: no helper → EDID-driven
  behavior (works, occasionally imperfect on fractional rates); helper present →
  deterministic mode locking.

Not ideal (a driverless story is cleaner), but it's the pragmatic hedge against
GPU/OS variability and is far cheaper than putting active FRC in v1.

## Tier 2 — Active frame-rate conversion (Pro / v2)

When EDID coaxing isn't enough — or when true conversion is required (e.g. host
locked at 60.00 but the facility runs 59.94, or 50↔60 cross-region) — we do real
**FRC** in the FPGA:

- **DDR frame buffer** + write(host-clocked)/read(SDI-clocked) decoupling.
- Output read side driven by either an **internal broadcast-accurate clock** or
  an **external genlock reference** (tri-level / black burst REF IN).
- Cadence handling: frame **repeat/drop** for integer-ratio cases; proper
  motion-aware conversion is a much larger effort and explicitly out of scope —
  v2 targets clean repeat/drop + genlock, not motion interpolation.
- Both outputs can be **genlocked together** and to house sync.

The v1 PCB should reserve the **FPGA DDR bank + a REF-IN footprint** so Tier 2
is a stuffing/firmware upgrade, not a respin.

## Color / range management
Independent of frame rate, the pipeline manages:
- **Colorimetry**: Rec.709 (HD) / Rec.2020 (UHD) signaling on SDI via ST 352
  payload ID + VPID.
- **Range**: force YCbCr **limited (legal)** range out, with a full-range
  override for measurement workflows. Advertised to the host through the EDID
  CEA video capability block, and enforced in the FPGA on the SDI side.

## Config app surface (Tier 1)
Minimal, per output:
- Pick EDID profile (dropdown of the table above).
- Resolution / frame-rate lock override.
- Color range (Auto / Limited / Full), colorimetry.
- Read-back: host-selected timing, SDI line rate, **lock status**, audio channel
  count.

No driver is needed for video; the app only talks to the management MCU over the
USB 2.0 sideband to change EDID/config and read status.
</content>
