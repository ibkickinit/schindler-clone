# 04 — Candidate Silicon & BOM Concept

> **Verify every part against its current datasheet and lifecycle status before
> committing.** Part numbers below are *candidates* chosen for capability fit,
> not a validated BOM. SDI and DP-Alt-Mode silicon both have notable
> end-of-life churn and supply constraints.

## Block → candidate parts

### USB-C PD / Alt-Mode controller
- Role: CC negotiation, request 4-lane DP Alt Mode, optional PD power contract.
- Candidates: **TI TPS65988 / TPS65987** (USB-C PD + Alt-Mode), **Cypress/Infineon
  CCG** family (CCG3PA / CCG6) DP-capable PD controllers.
- Selection driver: must support **DP Alt Mode 4-lane** config and (for power
  fallback) PD sink with adequate current.

### DP 1.4 MST hub / sink (1 DP in → 2 streams)
- Role: expose two display endpoints to the host; per-endpoint DDC for EDID.
- Candidates: **Synaptics VMM6000 / VMM5320** class MST hub, **Parade PS** MST
  hub silicon (e.g. PS186/PS-series). These are the chips inside USB-C→dual-HDMI
  MST docks.
- **Risk:** MST hub silicon is often sold under NDA / through dock ODMs and may
  be hard to source in low volume. *This is the single biggest sourcing risk.*
  Alternative path: a **DP1.4 RX directly into the FPGA** with MST handled in
  FPGA IP (AMD/Xilinx DisplayPort RX supports MST) — heavier FPGA but avoids the
  hub-sourcing problem. Decide in `06`.

### FPGA (conversion core, both channels)
- Role: HDMI/DP RX ×2, SMPTE mapping, audio embed, payload ID, serialize ×2.
- Needs **≥4 GTx transceivers** rated to ~12 Gb/s line rate and HDMI/DP +
  SDI-capable I/O.
- Candidates:
  - **AMD/Xilinx Artix UltraScale+** (GTH/GTYP at 12G+, has DP & native SDI
    support story) — strong fit.
  - **AMD/Xilinx Zynq UltraScale+** (adds a hard PS for the management plane —
    could absorb the MCU role) if a Linux/HID control plane is wanted on-chip.
  - **Lattice CertusPro-NX** for cost-down *if* its SERDES reach 12G with margin
    (verify — likely marginal for 12G; may cap at 6G).
- SDI + DP/HDMI **subsystem IP** (the SMPTE/DP MAC layers) is licensed IP; budget
  for it.

### 12G-SDI cable drivers (×2)
- Role: drive 75Ω BNC at 12G/6G/3G/HD/SD with rate-adaptive slew.
- Candidates: **Semtech GS12241** (12G-SDI cable driver), **TI LMH1219** (12G
  UHD-SDI equalizer/driver), **TI LMH0318/LMH1297** family for retime+drive.
- Optional **reclocker** ahead of the driver: **Semtech GS12170** / TI LMH1239
  if serial jitter from the FPGA TX needs cleanup for 12G compliance.

### Management MCU
- Role: EDID emulation (×2 endpoints), USB HID, OLED/LED, FPGA config bus.
- Candidates: **STM32H7** (USB FS/HS, plenty of I2C/SPI for DDC + control) — or
  fold this into a **Zynq UltraScale+ PS** if that FPGA is chosen.
- If discrete: EDID is presented to the MST hub's DDC lines as **emulated I2C
  EEPROM** banks the MCU can rewrite + HPD-toggle.

### Display / status
- Per-output **status LEDs** (bicolor: lock / format-tier).
- Optional small **OLED** (I2C 128×64) for standalone profile/status.

### Power
- USB-C PD sink front end (in the Alt-Mode controller) + buck regulators for FPGA
  rails (multiple voltages), SDI driver rails, 3V3/1V8 housekeeping.
- **Secondary USB-C power-in** path (open question — see `06` / power budget in
  `02`).

## Indicative bill-of-materials skeleton

| Block | Qty | Candidate | Notes / risk |
|---|---:|---|---|
| USB-C PD/Alt-Mode ctrl | 1 | TI TPS6598x / Infineon CCG | must do 4-lane DP |
| DP1.4 MST hub | 1 | Synaptics/Parade MST | **sourcing risk** or fold into FPGA |
| FPGA | 1 | Artix UltraScale+ (or Zynq US+) | needs 12G SERDES ×4 |
| SDI cable driver | 2 | Semtech GS12241 / TI LMH1219 | 12G rate-adaptive |
| SDI reclocker (opt) | 0–2 | Semtech GS12170 | only if jitter needs it |
| Mgmt MCU | 1 | STM32H7 (or PS) | EDID emu + HID |
| OLED (opt) | 1 | I2C 128×64 | standalone status |
| Power | — | PD sink + bucks | dual-4K may need aux in |
| Connectors | — | USB-C, 2× BNC 75Ω | true 75Ω BNC required |

## Make-vs-buy note
The conversion **could** in principle be done with fixed-function HDMI→SDI bridge
chips (single-channel converter ASICs exist), which would be cheaper and
simpler. We deliberately choose an **FPGA** because the whole product thesis —
managed EDID, frame-rate locking, color/range control, and a Tier-2 FRC upgrade
path — requires runtime control that fixed-function bridges don't expose. If a
future cost-down v1.5 drops Tier-2 ambitions entirely, revisit bridge-chip
silicon for a 3G/6G-only budget variant.
</content>
