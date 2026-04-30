# Schindler Clone

A modern FPGA-based replacement for the Cal Media **Schindler MVPHD-24** — a 24fps video frame rate converter used to drive CRT monitors that appear in film shots. Roughly 75 MVPHD-24 units remain in service worldwide; this project is a from-scratch alternative scoped to modern workflows.

## Scope

- **Input:** HDMI + DisplayPort
- **Output:** Composite + Component (YPbPr), driving 1970s consumer CRTs and broadcast monitors (Sony PVM/BVM)
- **Genlock:** to film camera reference (LTC, tri-level, black burst)
- **Frame rates:** 23.976, 24.000, 25.000, 29.97, 30.000 fps
- **Color pipeline:** ported from the Screenie/NovaTool codebase
- **Control:** Pi CM4 + web UI

## Why

The Schindler is unobtainable, expensive when found, and lacks modern color/EDID/web workflows. The market is small but underserved: rental houses, DPs shooting on CRTs, and music-video / period productions.

## Status

Planning phase. See [docs/schindler-playbook.md](docs/schindler-playbook.md) for the full development narrative.

## Hardware (planned)

- Digilent Zybo Z7-20 (Zynq-7020) — pixel pipeline + NTSC encoder
- Pi CM4 — web UI / config / EDID
- RP2040 + Si5351 — genlock PLL
- Custom carrier PCB with video DAC, op-amps, BNC outputs
- 1RU rack chassis

## License

TBD
