#!/usr/bin/env python3
"""Capture UART output for N seconds and exit. Used to verify the boot banner
after JTAG programming — non-destructive, no interactive console."""
import argparse, sys, time
import serial

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyUSB1")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--seconds", type=float, default=3.0)
    args = p.parse_args()
    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    deadline = time.time() + args.seconds
    while time.time() < deadline:
        chunk = ser.read(512)
        if chunk:
            sys.stdout.buffer.write(chunk); sys.stdout.flush()
    return 0

if __name__ == "__main__":
    sys.exit(main())
