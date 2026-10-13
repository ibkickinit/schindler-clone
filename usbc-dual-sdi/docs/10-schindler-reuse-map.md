# 10 — Schindler 2.0 Reuse Map

> **Status: analysis, banked 2026-10-13.** Built from Schindler module headers
> and the commit / bench-manifest history — **not** a line-by-line RTL review.
> "Validated" below means "the Schindler commit log or build manifest says so".

## Why this doc exists

Schindler 2.0 (same repo, separate product — CRT 24 fps converter on Zynq-7020 /
Zybo Z7-20) already has a **Vivado video-processing pipeline**: frame buffer,
polyphase scaler, FRC cadence engine, genlock frame-follow, compositor, warp,
color, test-signal generator, OSD. Several things the Crossover docs called
"future" or "months of HDL" are **ports, not new designs**. This changes the
FPGA-vendor question (`06` Q12) and the Pro-variant effort (`02`).

> The sequestering rule in the README still holds: Crossover must not *depend*
> on the Schindler tree. Reuse means **copying modules into Crossover's own
> tree** (with provenance noted), not cross-referencing build files.

## Which Schindler branch is canonical? *(unresolved)*

No single branch holds everything:

| Branch | Last commit | Holds |
|---|---|---|
| `v1-tsg` | 2026-07-05 | **Newest HDL**: TSG, OSD-3, projective/pincushion, Path-B DMA, decimate-on-write; contains `iter5-1080p-clean` |
| `orient-integration` | 2026-06-18 | Carrier KiCad work (ADV7511 etc.) — **27 commits not in `v1-tsg`** |
| `main` | 2026-06-24 | Crossover docs (`usbc-dual-sdi/`) + older Schindler docs |
| `iter5-1080p-clean` | 2026-06-04 | Repo **default** branch; a subset of `v1-tsg` |

**Working assumption:** port HDL from **`v1-tsg`**. Confirm with Justin; a
Schindler branch reconciliation is its own task (`docs/branch-resync-plan.md`
exists on the Schindler branches).

## Module reuse map

Schindler baseline: **1080p, ~1 pixel/clock, 8-bit RGB (24-bit AXIS)**, AXI VDMA
into **Zynq PS DDR**, control from the Zynq ARM. Crossover needs **2160p60 →
~4 px/clk @ 148.5 MHz, 10-bit YCbCr 4:2:2**, two channels.

| Function | Schindler modules | Schindler status | Crossover use | Port effort |
|---|---|---|---|---|
| Frame buffer write/read | AXI VDMA, `pg_raster_to_tile`, `pg_tile_dma`, `pg_tile_pack64`, `pg_tile_s2mm_cmd` | Tiled DDR sim-validated; Path-B dedicated DMA bench-validated | Pro FRC, multiview | **Medium** — widen to 4 ppc / 10-bit; retarget DDR from Zynq PS to MIG DDR4 |
| **FRC cadence** | `pg_cadence` (superset of `pg_genlock` v2), Mackin blend | **Full matrix 60/59.94/50/30/29.97/24 → 60 bench-validated**, 3-cold-boot clean | Pro "active FRC" (`02`, `03` Tier 2) | **Low–medium** — control logic is resolution-agnostic; data paths widen |
| Genlock frame-follow | `pg_genlock` v2 (VDMA frame-pointer follow, CDC-hardened) | Bench-validated | Pro genlock | Low |
| Polyphase scaler | `scaler_h`, `scaler_v`, `scaler_top`, coeff ROMs | 8-tap, bench-validated incl. clean 50% dest-res | Multiview tiles, format conversion, degradation ladder | **Medium** — downscale-only today; 4 ppc rework |
| Compositor / placement | `pg_compose`, `pg_place_affine`, `pg_addrgen`, `pg_linefetch` | Window translation + scale anchor "bench: perfect" (build #30) | **Multiview** (N windows over the frame buffer) | Medium — multi-source + layout control |
| Geometry warp | `pg_affine`, `pg_projective`, `pg_pincushion`, `pg_warp_engine`, tile cache | Affine on bench; projective/pincushion implemented | Not needed for Crossover v1/Pro | Skip (option for LED/projection SKUs) |
| Color | `color_correct`, `color_matrix`, `color_saturation`, `gamma_lut` | Gamma bench-validated (build #38) | Range (full/limited), colorimetry, trims (`03` Color) | Low — 10-bit + YCbCr variants |
| Test signal generator | `pg_tsg` (16 patterns, SMPTE EG-1) | Built (`v1-tsg`) | **Bench source for 12G-TX bring-up** without a 4K60 input; product feature | Low–medium — 4 ppc / 2160p |
| OSD | `pg_osd`, `pg_font8x16.mem` | OSD-3 built | Format/lock overlay, multiview labels/tally | Low |
| Timing | `vid_timing`, `vtc_gen_gate`, `engb_timing` | In use | Output timing | Low |
| Sim infrastructure | `sim/` golden files, self-checking TBs, runner | In use | Regression harness for the port | Copy as-is |

## What Schindler does **not** cover (new work for Crossover)

1. **12G-SDI TX** — Schindler uses an external **GS2962** (3G) chip, no in-FPGA
   SDI framing. Crossover needs ST 2082 framing + ST 352 + ST 299 audio + GTH
   setup: AMD SMPTE UHD-SDI IP (licensed) or in-house.
2. **4K throughput** — 4 px/clk, 10-bit 4:2:2 datapath; DDR bandwidth for two
   2160p60 channels through a frame buffer ≈ **40 Gb/s** (tight on 32-bit DDR4 —
   verify).
3. **No hard ARM on Artix US+** — Zynq PS duties (VDMA control, firmware, UART
   cmds) move to **MicroBlaze / MicroBlaze-V** or the external MCU; DDR via **MIG
   DDR4**.
4. **DP-RX** (laptop Crossover) or an external **HDMI 2.0 RX chip** (GSV2011-class,
   `09`) — Schindler's HDMI-in (`dvi2rgb`, 7-series SERDES, ≤1080p) does not carry
   to 4K60.

## Consequences

- **FPGA vendor (`06` Q12):** reuse strongly favors **AMD Artix UltraScale+**
  (same Vivado flow, same AXI IP family) over **PolarFire** (Libero; every
  Schindler module re-ported). PolarFire's free SDI IP is the main counterweight.
- **Pro variant (`02`):** active FRC + genlock + color are an **adaptation of
  bench-validated RTL**, not a new design.
- **Multiview:** compositor + scaler + frame buffer = the multiview building
  blocks. Likely the origin of the "advanced model with genlock + multiview"
  recollection.
- **Recommended sequencing:** a **1080p / 3G-SDI** stepping stone first (Schindler
  pipeline nearly as-is), then widen to 4K / 12G.

## v1 vs Pro — what each actually reuses

**V1 is source-locked conversion with no frame buffer** (`02` Clocking) — the same
class of design as the SC1221-12G (`09`). Most of the table above is **Pro**.

| | **V1 (conversion)** | **Pro (smart)** |
|---|---|---|
| Datapath | RX → RGB→YCbCr, 4:4:4→4:2:2 10-bit, range → SDI TX | + frame buffer, FRC, genlock, scaler, compositor/multiview, color trims |
| DDR / MIG / MicroBlaze | **Not needed** | Required (Artix US+) |
| Schindler reuse | Small: `color_matrix` / `color_correct` (→10-bit YCbCr), `pg_tsg`, timing, maybe `pg_osd`, sim harness | **Large**: `pg_cadence`, `pg_genlock`, scaler, `pg_compose`/`pg_place_affine`, tiled DMA, color, OSD |
| Hard parts | **12G-SDI TX** (framing + GTH), **clocking** (TX clock locked to the source pixel clock *through a jitter cleaner*, incl. 1.001 rates — why the SC1221 carries a Si5392), 4 px/clk at 2160p, 12G layout to BNC, RX front end (HDMI chip or DP-RX) | 4K-widening + DDR bandwidth (~40 Gb/s for 2× 2160p60) + porting control from Zynq PS to MicroBlaze |
| MCU | STM32-class: EDID, control (as SC1221) | same, or MicroBlaze |

**Consequence for `06` Q12:** judged on **v1 alone**, the Schindler-reuse argument is
weak and **PolarFire's free SDI IP** pulls even (Artix US+ still wins on chip price
and has the SC1221 as proof). Artix US+ wins decisively **only if Pro is a
committed follow-on on the same board/silicon** → that commitment is the gating
input to Q12.

## Stepping-stone product: "smart SC1221"

SC1221-12G hardware recipe (`09`: HDMI 2.0 RX chip + Artix US+ + Si5392 + MCU)
**plus** the Schindler pipeline = HDMI → 12G-SDI with **real FRC, scaling, color,
TSG, OSD** — features the ~$200 commodity unit lacks. Same output stage as
Crossover; swap the HDMI RX for the USB-C hub + DP-RX later.

## Follow-ups

- [ ] Confirm canonical Schindler HDL branch (`v1-tsg`?).
- [ ] Pull Schindler Vivado utilization (LUT/BRAM/DSP) per module → size AU10P vs AU15P.
- [ ] DDR4 bandwidth budget for 2× 2160p60 4:2:2 10-bit through VDMA.
- [ ] Decide SDI TX: AMD UHD-SDI license quote vs in-house.
- [ ] Decide control CPU: MicroBlaze-V in fabric vs STM32.
