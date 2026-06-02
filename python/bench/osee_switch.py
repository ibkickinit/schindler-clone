#!/usr/bin/env python3
"""osee_switch.py — set the Osee GoStream Duet program (PGM) input over TCP.

The Osee GoStream at 192.168.0.10:19010 selects which physical source the Zybo
sees on its HDMI input. Reverse-engineered from the Bitfocus
companion-module-osee-gostream-series (installed at
~/.config/companion/modules/osee-gostream-series-2.0.0/main.js).

Protocol: a JSON command, UTF-8, wrapped in a framed packet:
    [0xEB, 0xA6, 0x00, len_lo, len_hi, <json payload>, crc_lo, crc_hi]
  len = len(payload) + 2  (covers payload + the 2 CRC bytes)
  crc = CRC-16/MODBUS over the whole frame EXCEPT the trailing 2 CRC bytes.
Command: {"id":"pgmIndex","type":"set","value":[<src>]}
  src is 0-indexed: input 1 → 0, input 2 → 1, input 3 → 2.

Bench source map (per memory schindler-osee-switcher-topology):
  input 1 (src 0) = ImagePro 1080p60 static SMPTE bars (only known-static)
  input 2 (src 1) = motion
  input 3 (src 2) = laptop

Usage:  python3 osee_switch.py [INPUT]   # INPUT = 1..3 (default 1)
"""
import json
import socket
import struct
import sys

HOST = "192.168.0.10"
PORT = 19010
HEAD1, HEAD2, PROTYPE = 0xEB, 0xA6, 0x00


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if (crc & 1) else (crc >> 1)
    return crc & 0xFFFF


def frame(payload: bytes) -> bytes:
    total = len(payload) + 7
    buf = bytearray(total)
    buf[0] = HEAD1
    buf[1] = HEAD2
    buf[2] = PROTYPE
    length = len(payload) + 2          # payload + 2 CRC bytes
    buf[3] = length & 0xFF
    buf[4] = (length >> 8) & 0xFF
    buf[5:5 + len(payload)] = payload
    crc = crc16_modbus(bytes(buf[:total - 2]))
    buf[total - 2] = crc & 0xFF
    buf[total - 1] = (crc >> 8) & 0xFF
    return bytes(buf)


def set_pgm_input(input_no: int) -> None:
    src = input_no - 1                 # input 1 → protocol value 0
    payload = json.dumps({"id": "pgmIndex", "type": "set", "value": [src]},
                         separators=(",", ":")).encode("utf-8")
    pkt = frame(payload)
    with socket.create_connection((HOST, PORT), timeout=4) as s:
        s.sendall(pkt)
        try:
            s.settimeout(1.0)
            resp = s.recv(256)
        except socket.timeout:
            resp = b""
    print(f"Osee: PGM input -> {input_no} (src={src})  sent {len(pkt)} B"
          f"  resp={resp[:32].hex() or '(none)'}")


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    if not 1 <= n <= 3:
        sys.exit("INPUT must be 1..3")
    set_pgm_input(n)
