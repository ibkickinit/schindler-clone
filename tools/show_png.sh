#!/bin/bash
# show_png.sh — display any PNG on the Schindler HDMI output via DDR image-playback.
#   1) convert PNG -> raw DDR bytes (TSG byte order)
#   2) freeze the S2MM writer (UART 'O z 1' via daemon) so the ring stops updating
#   3) JTAG-write the image into all 7 DDR slots
#   4) warp identity -> the image shows 1:1
# Usage: tools/show_png.sh <image.png> [byte-order gbr|rgb|bgr]
set -e
PNG="$1"; ORDER="${2:-gbr}"
BIN="/tmp/schindler_ddr_img.bin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VPY=/home/justin/.local/share/schindlerd-venv/bin/python
python3 "$ROOT/tools/png_to_ddr.py" "$PNG" "$BIN" --order "$ORDER"
echo "freezing S2MM..."
"$VPY" -c "
import asyncio,json,websockets
async def m():
  async with websockets.connect('ws://127.0.0.1:8081') as ws:
    try: await asyncio.wait_for(ws.recv(),1.0)
    except: pass
    for meth,par in [('operator.set',{'freeze':True}),('warp.set',{'reset':True})]:
      await ws.send(json.dumps({'jsonrpc':'2.0','id':1,'method':meth,'params':par}))
      try: await asyncio.wait_for(ws.recv(),3.0)
      except: pass
asyncio.run(m())"
source /tools/Xilinx/2025.2/Vitis/settings64.sh 2>/dev/null
echo "loading image into DDR (7 slots, ~90s over JTAG)..."
xsct "$ROOT/tools/load_ddr_image.tcl" "$BIN" 7
echo "done — image should be on the HDMI output. Un-freeze: UART 'O z 0'."
