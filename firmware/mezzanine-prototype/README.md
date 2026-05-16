# Schindler 2.0 — Mezzanine UI Prototype Firmware

**Target:** RP2040-Zero (Waveshare) on a perfboard test rig.
**Purpose:** Validate encoder + button + OLED firmware against the actual production silicon and physical components before the Pro mezzanine PCB exists.

This firmware is the **production firmware brick** for the Pro mezzanine RP2040, just running on a Pico-class dev board instead of a custom mezzanine PCB. PIO programs, encoder decode logic, debounce parameters, and OLED rendering all port 1:1 to the production board when it's fabbed — pin reassignment is the only change.

## What it does

- Reads two EC11 encoders at 2 kHz (polling-based, software quadrature decode with state-transition LUT)
- Debounces all 9 switches/buttons at 5 ms (5-way nav + Set + BTN_B + two encoder shaft presses)
- Renders status to both 0.91" OLEDs at ~30 fps (independent I²C buses)
- Streams telemetry over USB-CDC for log analysis
- Encodes operational state via the on-board WS2812 RGB LED

## Hardware pin map

```
GP0     5-way nav: UP
GP1     5-way nav: DOWN
GP2     5-way nav: LEFT
GP3     5-way nav: RIGHT
GP4     5-way nav: CENTER (press)
GP5     Set button
GP6     BTN_B  (perfboard "Reset" — NOT hardware reset)
GP8     ENC A  quadrature A
GP9     ENC A  quadrature B
GP10    ENC A  push-switch (shaft press)
GP11    ENC B  quadrature A
GP12    ENC B  quadrature B
GP13    ENC B  push-switch (shaft press)
GP16    WS2812 RGB status LED (on-board RP2040-Zero)
GP26    I²C1 SDA -> OLED B
GP27    I²C1 SCL -> OLED B
GP28    I²C0 SDA -> OLED A
GP29    I²C0 SCL -> OLED A
```

Switches: active-low, internal pull-ups enabled by firmware.
OLEDs: SSD1306, I²C address `0x3C`, 128×32 (0.91").

## Build

### Prerequisites

- **Pico SDK** installed. If you don't have it:
  ```bash
  cd ~
  git clone -b master https://github.com/raspberrypi/pico-sdk.git
  cd pico-sdk
  git submodule update --init
  export PICO_SDK_PATH=$HOME/pico-sdk
  echo 'export PICO_SDK_PATH=$HOME/pico-sdk' >> ~/.zshrc   # or ~/.bashrc
  ```
- **ARM GCC toolchain**, CMake ≥ 3.13, make. On macOS:
  ```bash
  brew install cmake gcc-arm-embedded
  ```

### Copy `pico_sdk_import.cmake`

The Pico SDK ships with `pico_sdk_import.cmake` — a CMake glue file the project needs. Copy it from the SDK:

```bash
cd firmware/mezzanine-prototype
cp $PICO_SDK_PATH/external/pico_sdk_import.cmake .
```

### Build

```bash
mkdir build && cd build
cmake ..
make -j
```

Output of interest: `build/mezzanine_prototype.uf2`

## Flash

1. Hold the **BOOT** button on the RP2040-Zero
2. Plug in the USB-C cable (or press RESET if already plugged in while holding BOOT)
3. The board mounts as a USB drive named `RPI-RP2`
4. Drag `build/mezzanine_prototype.uf2` onto the drive
5. Board auto-reboots into the new firmware

## Test procedure

### Visual checks (OLEDs)

After flash + power-on, both OLEDs should show 4 lines of text within ~2 seconds:

**OLED A (driven by I²C0 on GP28/29):**
```
ENC A +0
RPM 0
CLK 0
BTN -
```

**OLED B (driven by I²C1 on GP26/27):**
```
ENC B +0
RPM 0
CLK 0
MIS 0
```

If only one OLED lights up: check I²C wiring for the dark one. If both are blank: check that the address is actually `0x3C` and pull-up resistors are present (typically 10 kΩ to 3.3 V on each SDA/SCL line — some OLED modules have these built in).

### Functional checks

- **Rotate ENC A clockwise** — `ENC A` counter on OLED A increments by 1 per detent click, `RPM` shows rotation rate, WS2812 LED turns blue
- **Rotate ENC A counter-clockwise** — counter decrements by 1 per click
- **Push the ENC A shaft** — `CLK` count on OLED A increments
- **Same for ENC B** — independent counter on OLED B
- **Press any button or nav direction** — OLED A's bottom line shows the button name (e.g. `BTN UP`, `BTN SET`), WS2812 turns yellow while held
- **WS2812 colors:**
  - Dim green: idle
  - Blue: encoder active in last 200 ms
  - Yellow: any button held
  - Red: missed encoder counts detected (something is wrong)

### USB-CDC telemetry

Connect a serial terminal at 115200 baud to the RP2040's USB-CDC interface:

```bash
# macOS - find the device first
ls /dev/cu.usbmodem*
# Then connect:
screen /dev/cu.usbmodem14201 115200
```

You should see startup banner + event-driven log lines like:

```
t=12345  a=+24 (det +12)  rpm_a=42  b=+0 (det +0)  rpm_b=0  btn=UP  miss=0
```

Rate-limited to 20 Hz for routine rotation; button events emit immediately.

## Direction sign

If a clockwise rotation makes the count go *down* on your perfboard, the A/B encoder pins are swapped vs the LUT's assumption. Two fixes:

1. **Swap pins in firmware:** in `main.c`, swap `ENC_A_PINA` and `ENC_A_PINB` (and/or B's), rebuild, reflash
2. **Re-wire the encoder:** swap the A/B leads physically

Either works. Firmware change is faster.

## What this validates (production-portable outcomes)

- PIO-free polling quadrature decoder under real EC11 contact bounce
- 5 ms software debounce parameter tuning (measure missed-count rate, adjust if needed)
- Two-encoder simultaneous handling with no shared-resource starvation
- I²C bus utilization at 400 kHz (two OLEDs at 30 fps, 512 bytes each = ~12 KB/s per bus)
- SSD1306 init sequence + 128×32 page layout
- WS2812 timing under the standard pico-examples PIO program
- USB-CDC printf overhead under encoder event rates

When the Pro mezzanine PCB exists, this firmware ports by:

1. Updating pin defines for the mezzanine carrier layout
2. Replacing the dual OLED render with BT817Q EVE command-list generation (different drawing API; encoder/button state aggregation logic stays)
3. Adding UART to Zynq PS for state sync (one new module)

## Known limitations (V1 firmware)

- Polling-based quadrature instead of PIO. Adequate for EC11 mechanical rates (max ~1000 edges/sec at extreme manual rotation) but production firmware should move to PIO for headroom + CPU savings. Polling left for V1 to keep the firmware accessible.
- No software acceleration on long scrolls (per the changelog 2026-05-10 note that 10° click pitch warrants accel). Add to V2.
- No menu state machine — this firmware is input characterization only. Menu logic comes next.
- USB-CDC log format is human-readable. Add CSV mode for log-to-file analysis later.
- Detent count = raw_count / 2 in display only. Internal counter tracks 4× quadrature edges for full precision; production may want explicit detent state machine.

## File layout

```
firmware/mezzanine-prototype/
├── main.c                   # firmware core
├── ssd1306.h                # OLED driver + 5x7 ASCII font
├── ws2812.pio               # PIO program for WS2812 (compiled to .pio.h by build)
├── CMakeLists.txt           # build config
├── pico_sdk_import.cmake    # (copy from $PICO_SDK_PATH/external/ — see Build section)
├── README.md                # this file
└── build/                   # CMake build directory (gitignored)
```

## Spec cross-reference

- `01-spec.md` § 15.1 — Mini front panel (5-way nav + buttons subset of this rig)
- `01-spec.md` § 15.2 — Pro mezzanine (dual EC11 encoders subset of this rig)
- `01-spec.md` § 17 — UI architecture (Pro mezzanine firmware role)
- `dev-roadmap.md` § 5.2 — Pro v2 mezzanine front panel build-out
