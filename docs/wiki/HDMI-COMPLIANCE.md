# HDMI Compliance Rule

**HDMI output must be spec-compliant. No out-of-spec MMCM operation, no non-standard TMDS encodings, no vendor IP patches that produce non-compliant signaling.**

Established as a project rule 2026-05-31 after the 1080p60 investigation revealed that the Zybo Z7-20 -1 silicon physically cannot produce a compliant 1080p60 HDMI TMDS stream. Codified to prevent future "it works on the MS2109 capture stick" answers to genuinely non-shippable timing.

## What "out of spec" means here

- **Pixel clock above the silicon BUFIO limit** — Zybo's -1 grade caps BUFIO at 600 MHz, requiring `pclk × 5 ≤ 600 MHz` (since OSERDESE2 serializes at 5× pixel clock for TMDS). 1080p60 needs 148.5 MHz × 5 = 742.5 MHz — out.
- **MMCM VCO above silicon limit** — rgb2dvi's MMCM at `kClkRange=2` runs VCO at `pclk × 10 = 1485 MHz` on -1 (max 1200 MHz). `kClkRange=1` halves VCO to 742.5 MHz but pushes OSERDESE2 past BUFIO. Both forms are out.
- **Custom TMDS encoding** — even if the silicon could run, we don't ship pixel/blanking codes outside the CEA-861 list.
- **Patched vendor IP for margin tricks** — investigative only; never a shipping path.

## What's acceptable

- **Different IP**: there exist Xilinx IP variants that target higher pixel clocks via different OSERDES topologies. Worth evaluating if 1080p60 OUT becomes critical.
- **External silicon**: production carrier (TE0720 module + mezzanine PCB) carries an external HDMI PHY chip that handles 1080p60 natively. **This is the planned production path** for any 1080p60 output cell.
- **Lower rates**: 1080p30, 720p60, 480p60 are all comfortably in-spec on Zybo. v1 ship is 720p60 OUT only on Zybo; production carrier opens up the rest.
- **Different silicon**: TE0720 is -2 speed grade. Some Zybo limits relax on -2 (BUFIO cap, MMCM VCO max). Production-target verification owed on actual TE0720 silicon.
- **Bench-test margin tricks**: investigative only, not a shipping path. Useful for "is this an FPGA limit or a downstream chip limit?" — never the answer to "does this ship?"

## Concrete impact

| Cell | Status | Why |
|---|---|---|
| 1080p60 HDMI OUT (any input) | ❌ on Zybo / ✅ planned on TE0720 | BUFIO + MMCM VCO limits combine; no in-spec config possible |
| 1080p30 HDMI OUT | ✅ on Zybo | 74.25 MHz pclk = same as 720p60 |
| 720p60 HDMI OUT | ✅ on Zybo | Production substrate |
| 480p60 HDMI OUT | ⚠️ v1 (test owed) | In-spec by margin; not bench-verified |

See [`../format-support-matrix.md`](../format-support-matrix.md) for the full v1 ship list.

## Why this rule exists

The 2026-05-31 investigation built `1080p60 + scaler_bypass + COLOR_PIPELINE=bypass + kClkRange=1`, closed Vivado timing (WNS +0.13 ns), and saw the bench monitor say "signal out of spec." The temptation in the moment was to push further or chase a different MMCM config until the monitor accepted it. The right answer was: **the silicon can't do this in spec; stop trying.**

A different bench monitor (or the MS2109 capture stick, per the [MS2109 verification trap](DEBUGGING-PLAYBOOK.md#ms2109-verification-trap) rule) would accept a marginal signal. That's not shipping — it's chasing a single sample.

## Bench protocol implication

When a build outputs HDMI and the bench monitor rejects the signal:

1. **First check**: is this build architecturally capable of being in-spec? Use the table above or the formal arithmetic (`pclk * 5 vs BUFIO max`, `MMCM VCO range`).
2. **If no**: the build is non-shippable. Don't bench-test for cosmetic correctness; reroute to a different output mode or a different carrier.
3. **If yes**: continue debug.

Skipping step 1 is how the 2026-05-31 morning consumed ~3 hours on three sequential builds before the formal limit was acknowledged.

## Memory cross-link

- [[hdmi_compliance_rule]] — the durable rule entry
- [[zynq7020_rgb2dvi_1080p60_limit]] — the specific Zybo -1 finding with arithmetic

## Cross-links

- [BENCH-WORKFLOW](BENCH-WORKFLOW.md)
- [DEBUGGING-PLAYBOOK](DEBUGGING-PLAYBOOK.md) — MS2109 trap, bench equipment confounder, this rule
- [KNOWN-BUGS](KNOWN-BUGS.md) — 1080p60 entry references this rule
- [`../format-support-matrix.md`](../format-support-matrix.md) — what's affected
- [`../build-manifest.md`](../build-manifest.md) — 1080p60 investigation session at the 2026-05-31 heading
