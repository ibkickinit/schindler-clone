# sdi_tx — in-house SMPTE SDI transmitter

Vendor-neutral Verilog-2005 for an SDI transmit datapath feeding an FPGA serial transceiver (AMD GTH
on Artix UltraScale+). No paid IP. Plan, stages and status: [`../../docs/12-sdi-tx-plan.md`](../../docs/12-sdi-tx-plan.md).

**Stage 1 (current): HD-SDI** — `sdi_hd_tx_top` produces 20-bit scrambled/NRZI words (C first on the
wire) for a GTH at 1.485 Gb/s, carrying 1080p30 75% color bars.

| Module | Role |
|---|---|
| `sdi_hd_timing.v` | Raster counter (h, line) |
| `sdi_bars_hd.v` | 75% bars test source |
| `sdi_hd_framer.v` | TRS, line numbers, CRC-18, blanking |
| `sdi_crc18.v` | CRC-18 per 10-bit word |
| `sdi_scrambler.v` | Scrambler + NRZI (parameterized width) |
| `sdi_hd_tx_top.v` | Top level |

Simulation: `../../sim/sdi_tx/run_iverilog.sh` (Icarus Verilog; `QUICK=1` skips the full-frame run).

Self-contained on purpose (no Crossover or Schindler dependencies) so other products can vendor it.
