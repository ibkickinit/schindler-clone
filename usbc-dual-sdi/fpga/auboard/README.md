# AUBoard 15P — bench projects (Crossover)

Vivado projects for the Avnet/Tria **AUBoard 15P** (XCAU15P-2FFVB676E). Same conventions as Schindler:
Vivado **2025.2** at `/tools/Xilinx/2025.2`, batch Tcl builds, no GUI needed. Board facts and the full
bring-up order: [`../../docs/11-auboard-bench-guide.md`](../../docs/11-auboard-bench-guide.md).

## 1. First light — `auboard_blinky`

**What it proves:** toolchain, JTAG, the 300 MHz clock, LEDs / DIP / buttons, USB-UART.

| Behaviour | Expect |
|---|---|
| LED1–4 (D31–D34) | binary count, LED1 ≈ 1 Hz |
| Hold any push button (PB4–PB7) | LEDs show the DIP switch (SW2) instead |
| RGB LED 1 | cycles R → G → B, ~1 s each |
| RGB LED 2 | green; goes dark while the PL reset button is held |
| UART 115200 8N1 | `AUBoard 15P alive #00`, `#01`, … once a second; typed characters echo back |

### One-time setup on the Linux bench machine

```bash
# JTAG cable driver (once per machine; skip if the Schindler Zybo already programs fine)
cd /tools/Xilinx/2025.2/Vivado/data/xicom/cable_drivers/lin64/install_script/install_drivers
sudo ./install_drivers
# serial port access
sudo usermod -aG dialout $USER     # log out/in afterwards
```

### Board

1. Jumpers at defaults: boot mode = Master SPI, **J11 = 1-2**, J17 fitted. FMC empty. Heatsink on if supplied.
2. 12 V brick → **J51**, **SW1** on → **D18 green**.
3. micro-USB → **J9**. `ls /dev/ttyUSB*` should show the UART (it may be the second of two ports).

### Build + program

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh
cd <repo>/usbc-dual-sdi/fpga/auboard
vivado -mode batch -nojournal -log build/build_blinky.log -source tcl/build_blinky.tcl    # ~3-6 min
vivado -mode batch -nojournal -log build/program.log      -source tcl/program_blinky.tcl
picocom -b 115200 /dev/ttyUSB1      # or ttyUSB0; Ctrl-A Ctrl-X to quit
```

Look for `BUILD_OK ... WNS=<positive>` and `STAGE_OK` in the logs, then **D19 blue** (DONE).

### If something's off

| Symptom | Likely cause |
|---|---|
| Build: `ERROR: <port> ... bank <n> (VADJ or unknown)` | a pin is in a bank the script doesn't map — send me the line; check the schematic |
| Build: IOSTANDARD/DRC error on `sys_clk_*` | the 1.2 V-bank clock standard (`DIFF_SSTL12`) is wrong for this board — send me `build/drc.rpt` |
| `no JTAG target` | cable driver not installed, or the J9 cable is charge-only |
| `xcau15p not found` | J11 not on 1-2, or the board isn't powered (D18) |
| LEDs count but no UART text | try the other `/dev/ttyUSB*`; check `dialout` group |
| Buttons/DIP act inverted | polarity assumption (active high) is wrong — easy fix, tell me |

Simulation (no hardware): `iverilog -g2005 -DSIM -o /tmp/b.vvp hdl/*.v sim/tb_blinky_uart.v && vvp -n /tmp/b.vvp`
→ decodes the UART banner, checks the echo and the DIP mirror → `PASS`.

**Not verified yet:** this design has been simulated, not built in Vivado (no Vivado in the design
session). The pin numbers come from the UG tables; bank-voltage mapping is applied by the build script.

## Next projects (planned)
2. **Clock chips** — drive U56 `RST_N` (G22) high, program **U56 (8T49N241) → 148.5 MHz** on Quad 226 REFCLK0 over the HDMI_CTL I²C bus (R23/R22); read back U57 at 0x7C.
3. **IBERT** on Quad 226 lane 3 (SFP+) at 1.485 / 2.97 Gb/s.
4. **HD-SDI / 3G-SDI out on the SFP** — `../../hdl/sdi_tx/` + a GTH wrapper from the Transceiver Wizard.
