# sdi_tx — in-house SMPTE SDI transmitter

Vendor-neutral Verilog-2005 for an SDI transmit datapath feeding an FPGA serial transceiver (AMD GTH
on Artix UltraScale+). No paid IP. Plan, stages and status: [`../../docs/12-sdi-tx-plan.md`](../../docs/12-sdi-tx-plan.md).

**Stages 1–2 (current): HD-SDI + 3G-SDI Level A**, with the **ST 352 payload ID**. `sdi_hd_tx_top`
produces 20-bit scrambled/NRZI words (C first on the wire): word clock 74.25 MHz → 1.485 Gb/s (HD,
1080p23.98–30) or 148.5 MHz → 2.97 Gb/s (3G-A, 1080p50–60). Format = raster parameters + clock +
payload-ID bytes. Test source: 75% color bars.

| Module | Role |
|---|---|
| `sdi_hd_timing.v` | Raster counter (h, line) |
| `sdi_bars_hd.v` | 75% bars test source |
| `sdi_hd_framer.v` | TRS, line numbers, CRC-18, blanking, ST 352 payload ID |
| `sdi_crc18.v` | CRC-18 per 10-bit word |
| `sdi_scrambler.v` | Scrambler + NRZI (parameterized width) |
| `sdi_hd_tx_top.v` | Top level |

Simulation: `../../sim/sdi_tx/run_iverilog.sh` (Icarus Verilog; `QUICK=1` skips the full-frame run).

Self-contained on purpose (no Crossover or Schindler dependencies) so other products can vendor it.
