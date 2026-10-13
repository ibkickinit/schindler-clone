# 12 — SDI Transmitter Plan (in-house, AMD, no IP license)

> **Decided 2026-10-13 (Justin):** no paid AMD IP. Crossover stays on **AMD Artix
> UltraScale+** (Schindler reuse, AUBoard bench) and we write our **own SDI transmitter**.
> Status: **stage 1 (HD-SDI datapath) written and passing simulation** — see bottom.

## What we use (all free)

| Source | Used for | Notes |
|---|---|---|
| Vivado **Transceiver Wizard** (GTH), **IBERT**, **ILA** | GTH TX at 1.485 / 2.97 / 5.94 / 11.88 Gb/s (and /1.001), link checks, debug | Included with Vivado |
| **XAPP1248** (SDI on UltraScale GTH, v1.6) | Guide for GTH control: rate switching, refclk select, TX setup | Free download (registration). Wraps the licensed UHD-SDI core → reuse only GTH-control ideas; *check download license terms* |
| **XAPP1249** + legacy **Triple-Rate SDI** reference | Readable SD/HD/3G framing reference | Unencrypted source; Xilinx-device-only license is fine for us (*verify*) |
| **UHD-SDI GT** (PG380) | Possible GTH wrapper | Use only if Vivado's License column says *Included* |
| SMPTE ST 292-1, 424, 425-1/-5, 2081-1/-10, **2082-1/-10**, 352, 299-1/-2, RP 168 | The spec | **Buy** (SMPTE digital library) — ST 2082-10 (4K mapping) is essential |
| Skyworks **AN1035** | 12G-SDI refclk / jitter requirements | Free |
| photonSDI (open source) | — | Skipped: empty (2017, "Features: None") |

## Architecture

```
video (4 px/clk YCbCr 4:2:2 10-bit, from color stage or pg_tsg)
 -> [12G only] 2SI split: 2160p -> four 1080p sub-images (ST 2082-10 / 425-5)
 -> per stream: TRS (EAV/SAV), line numbers, CRC-18, ST 352 payload ID, [ST 299 audio]
 -> [3G/6G/12G] interleave data streams per ST 424 / 2081-1 / 2082-1
 -> scrambler x^9+x^4+1 + NRZI
 -> GTH TX (refclk 148.5 or 148.5/1.001 MHz: U56 on AUBoard, Si5392 on product)
 -> cable driver -> 75-ohm BNC
```

## Stages (each provable on the analyzer, SC1221-12G as reference)

| # | Stage | Status |
|---|---|---|
| 1 | **HD-SDI 1.485 Gb/s**, 1080p30 75% bars: framing, CRC, scrambler/NRZI, 20-bit GTH word | **RTL + sim PASS** (2026-10-13) — needs GTH wrapper + bench |
| 2 | 3G-SDI Level A (1080p60), 40-bit GTH word | — |
| 3 | 6G (ST 2081) | — |
| 4 | **12G** (2SI quad split, ST 2082) | — |
| 5 | ST 352 payload ID on every rate; ST 299 embedded audio | — |
| 6 | Interlaced 1080i, 720p, fractional-rate checks | — |

Effort estimate: **~2–4 months part-time** to analyzer-clean 12G; HD in the first weeks.
Main risks: GTH clocking/jitter compliance, 2SI mapping details — not the logic.

## Stage 1 — what exists (`hdl/sdi_tx/`, `sim/sdi_tx/`)

| File | Role |
|---|---|
| `sdi_hd_timing.v` | Raster counter (1080p30 default; 1080p25/24, 720p by parameter) |
| `sdi_bars_hd.v` | 75% bars, Rec.709 10-bit (stand-in until `pg_tsg` is ported to YCbCr) |
| `sdi_hd_framer.v` | EAV/SAV + XYZ protection bits, LN0/LN1, CRC-18 per stream, blanking, clipping |
| `sdi_crc18.v` | CRC-18 (x^18+x^5+x^4+1), 10 bits/word, LSB first |
| `sdi_scrambler.v` | x^9+x^4+1 scrambler + NRZI, parameterized width (20 now; 40/80 later) |
| `sdi_hd_tx_top.v` | Top: `txdata[19:0]` = {Y, C}, C first on the wire |
| `sim/sdi_tx/tb_sdi_hd_tx.v` | **Independent** receiver-style checker (descramble, TRS, LN sequence, V bits, CRC via MSB-first division, video content) |
| `sim/sdi_tx/run_iverilog.sh` | Small raster PASS · error-injection must FAIL · full 1080p30 frame PASS |

**Sim result:** full 1080p30 frame — 1,125 lines, 2.48 M words, **0 errors**; injected 1-bit wire
error → caught (video + CRC mismatches). Icarus Verilog 12; full frame ≈ 8 min (`QUICK=1` skips it).

**Still to confirm on real equipment (sim can't prove convention):**
- CRC bit order / word packing (CR0 = C0..C8) — both the DUT and checker assume C0 = first CRC bit.
- Line convention: LN after EAV labels the preceding active line; SAV carries the next line's V.

**GTH settings for stage 1 (starting point — let the wizard compute):** 1.485 Gb/s line rate,
refclk 148.5 MHz (AUBoard **U56 → Quad 226 REFCLK0**, `11`), CPLL (≈2.97 GHz VCO, TX divider 4),
**20-bit external / 20-bit internal**, 8b10b off, TXUSRCLK2 = 74.25 MHz, SFP lane = Quad 226 ch 3.
Bench: SFP 12G-SDI module → analyzer; IBERT first.

## Reuse in Schindler 2.0

- **Current Schindler (TE0720 / Zynq-7020): cannot use it.** The 7020 has **no multi-gigabit
  transceivers** (noted in Schindler's own changelog), and its HR I/O SERDES tops out below HD-SDI's
  1.485 Gb/s. The external SDI chips (GS2962 TX, GS3470 RX) stay on that platform.
- **A transceiver-equipped Schindler** (Artix US+ / Zynq US+ with GTH, e.g. a "Schindler 4K/Pro"
  platform) **could drop the SDI serializer chip (GS2962)** and use this core.
  - Still needs a small **cable driver/reclocker per output** (GTH can't meet SMPTE launch amplitude,
    return loss and jitter into 75 Ω on its own — the SC1221-12G carries one too).
  - **SDI input / reference** (GS3470: broadcast input, SDI ref, VITC) is a **receiver** — a separate,
    harder core (CDR, rate detect, word align). Not covered here.
  - A 4K Schindler also needs a 4K input path, a 4-px/clk pipeline and DDR bandwidth (`10`); the
    SDI TX is one piece of that.
- **Code placement:** the core is self-contained (no Crossover/Schindler dependencies). Per the
  README's sequestering rule, Schindler would **vendor a copy**; if both products adopt it, move it to a
  shared library repo.
