#!/usr/bin/env python3
"""uart_cmd.py — send a Phase-B firmware UART command and capture the reply.

The Phase-B firmware exposes runtime tuning on /dev/ttyUSB1 @ 115200 (see memory
schindler_uart_commands). This sends one command line, then drains telemetry for
a short window so you can see the firmware's acknowledgement / state echo.

Read-engine geometry command (full-master build):
    G <w> <h> <x> <y>   set output window size + position; firmware computes the
                        DDA steps from FRAME_W/H (1920x1080) into <w>x<h>.
    G 0                 disengage read-engine (MM2S passthrough)
Other useful: '?' help, 'i' info, 'g'/'s'/'m'/'b'/'w'/'a' color, 'r' reset.

Usage:
    python3 uart_cmd.py "G 960 540 0 0"      # send a command, show reply
    python3 uart_cmd.py "?"                   # help
    python3 uart_cmd.py --listen 3            # just listen 3 s, send nothing
"""
import argparse
import sys
import time

import serial  # pyserial

PORT = "/dev/ttyUSB1"
BAUD = 115200


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", nargs="?", default="", help="command line to send")
    ap.add_argument("--listen", type=float, default=1.5,
                    help="seconds to capture output after sending (default 1.5)")
    ap.add_argument("--port", default=PORT)
    args = ap.parse_args()

    with serial.Serial(args.port, BAUD, timeout=0.2) as ser:
        time.sleep(0.1)
        ser.reset_input_buffer()
        if args.cmd:
            ser.write((args.cmd + "\r\n").encode())
            ser.flush()
            print(f">>> {args.cmd!r}", file=sys.stderr)
        deadline = time.time() + args.listen
        buf = bytearray()
        while time.time() < deadline:
            chunk = ser.read(256)
            if chunk:
                buf += chunk
                deadline = time.time() + 0.6  # extend while data flows
        sys.stdout.write(buf.decode(errors="replace"))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
