# Schindler 2.0

A modern FPGA-based replacement for the Cal Media **Schindler MVPHD-24** — a 24fps video frame rate converter used to drive CRT monitors that appear in film shots. Roughly 75 MVPHD-24 units remain in service worldwide; this project is a from-scratch alternative scoped to modern workflows.

## Scope

- **Input:** HDMI + DisplayPort + Composite + Component + SDI reference (with optional broadcast-tier SDI video IN/OUT/loop-through)
- **Output:** Composite + Component (YPbPr) + S-Video, driving 1970s consumer CRTs and broadcast monitors (Sony PVM/BVM); HDMI loop-through for confidence monitoring
- **Genlock:** to film camera reference (LTC, tri-level, black burst); SDI ref with VITC extraction
- **Frame rates:** 23.976, 24.000, 25.000, 29.97, 30.000 fps (with 60 Hz → 50 Hz cadence conversion for cross-region content)
- **Color pipeline:** ported from the Screenie/NovaTool codebase
- **Control:** dual-band WiFi (concurrent AP + STA) + BLE setup pairing + GbE; web UI hosted on the Zynq PS under PetaLinux
- **Front panel:** 2.8-3.5" color TFT + rotary encoders + hardware buttons + status LEDs (no touchscreen)

## Why

The Schindler is unobtainable, expensive when found, and lacks modern color/EDID/web workflows. The market is small but underserved: rental houses, DPs shooting on CRTs, and music-video / period productions.

## Status

Early prototype phase, hardware ordered. See [`docs/01-spec.md`](docs/01-spec.md) for current spec & backlog and [`docs/schindler-playbook.md`](docs/schindler-playbook.md) for the development narrative.

## Hardware

### Development
- Digilent Zybo Z7-20 — FPGA bring-up (Zynq-7020 silicon, matches production target)
- STM32H735G-DK — UI MCU + TFT bench development
- Oscilloscope — signal analysis

### Production architecture
- Trenz TE0720 SOM — Zynq-7020 industrial (-40 to +85 °C), on custom carrier
- STM32H735IGT6 — dedicated front-panel UI MCU
- RP2040 + Si5351 — genlock PLL subsystem
- ADV7393 — composite/component/S-Video output DAC
- ADV7280 — composite/component input decoder
- Semtech GS3470 — SDI receiver (ref + optional broadcast video input)
- Semtech GS2962 — SDI transmitter (broadcast tier)
- Laird Sterling LWB5+ — pre-certified dual-band WiFi/BT module
- Custom 6-8 layer carrier PCB
- 1RU rack chassis

## License

TBD