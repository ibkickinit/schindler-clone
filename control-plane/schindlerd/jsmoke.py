#!/usr/bin/env python3
"""J UART smoke test — direct serial JSON-RPC, no daemon, no asyncio.

Confirms the firmware J command works in isolation before we add the daemon's
asyncio/WebSocket complexity on top.

Usage:
    python jsmoke.py [--port /dev/ttyUSB1] [--quiet]
"""

import argparse
import json
import re
import sys
import time

import serial

JSON_LINE = re.compile(rb"^\s*\{.*\}\s*$")


def send_recv(ser: serial.Serial, req: dict, timeout: float = 1.5) -> dict:
    line = "J " + json.dumps(req, separators=(",", ":")) + "\r\n"
    ser.reset_input_buffer()
    ser.write(line.encode("ascii"))
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        chunk = ser.read(256)
        if not chunk:
            continue
        buf += chunk
        # Pick the first '{'-prefixed line we get.
        for raw in buf.split(b"\n"):
            raw = raw.rstrip(b"\r")
            if JSON_LINE.match(raw):
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    pass
    raise TimeoutError(f"no JSON response in {timeout}s. raw buf: {buf!r}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyUSB1")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()
    ser = serial.Serial(args.port, args.baud, timeout=0.1)
    time.sleep(0.1)
    ser.reset_input_buffer()

    def step(req: dict, expect: callable) -> dict:
        if not args.quiet:
            print(f"→ {json.dumps(req)}", flush=True)
        resp = send_recv(ser, req)
        if not args.quiet:
            print(f"← {json.dumps(resp)}", flush=True)
        if "error" in resp:
            print(f"  ERROR: {resp['error']}", file=sys.stderr)
            return resp
        if expect and not expect(resp.get("result")):
            print(f"  FAIL: response didn't match expectation", file=sys.stderr)
            return resp
        return resp

    fails = 0
    # 1. identify
    r = step({"jsonrpc": "2.0", "id": 1, "method": "system.identify"},
             lambda r: r and "model" in r and "catalog" in r)
    if "error" in r or not (r.get("result") and "catalog" in r["result"]): fails += 1

    # 2. list_controls
    r = step({"jsonrpc": "2.0", "id": 2, "method": "system.list_controls"},
             lambda r: r and "ids" in r and "color.saturation" in r["ids"])
    if "error" in r or "color.saturation" not in r.get("result", {}).get("ids", []): fails += 1

    # 3. get sat
    r = step({"jsonrpc": "2.0", "id": 3, "method": "control.get",
              "params": {"id": "color.saturation"}},
             lambda r: r and "value" in r)
    if "error" in r: fails += 1
    initial_sat = r.get("result", {}).get("value", None)

    # 4. set sat to 150
    r = step({"jsonrpc": "2.0", "id": 4, "method": "control.set",
              "params": {"id": "color.saturation", "value": 150}},
             lambda r: r and r.get("value") == 150)
    if "error" in r or r.get("result", {}).get("value") != 150: fails += 1

    # 5. get sat again — should still be 150
    r = step({"jsonrpc": "2.0", "id": 5, "method": "control.get",
              "params": {"id": "color.saturation"}},
             lambda r: r and r.get("value") == 150)
    if r.get("result", {}).get("value") != 150: fails += 1

    # 6. set black_r to 32
    r = step({"jsonrpc": "2.0", "id": 6, "method": "control.set",
              "params": {"id": "color.correct.black_r", "value": 32}},
             lambda r: r and r.get("value") == 32)
    if r.get("result", {}).get("value") != 32: fails += 1

    # 7. kernel_h NN (0)
    r = step({"jsonrpc": "2.0", "id": 7, "method": "control.set",
              "params": {"id": "scaler.kernel_h", "value": 0}},
             lambda r: r and r.get("value") == 0)
    if r.get("result", {}).get("value") != 0: fails += 1

    # 8. error path: bogus id
    r = step({"jsonrpc": "2.0", "id": 8, "method": "control.set",
              "params": {"id": "no.such.control", "value": 0}},
             None)
    if "error" not in r: fails += 1

    # 9. error path: out of range
    r = step({"jsonrpc": "2.0", "id": 9, "method": "control.set",
              "params": {"id": "color.saturation", "value": 500}},
             None)
    if "error" not in r: fails += 1

    # 10. Reset: sat → 100, kernel_h → 1 (production), black_r → 0
    step({"jsonrpc": "2.0", "id": 10, "method": "control.set",
          "params": {"id": "color.saturation", "value": (initial_sat or 100)}}, None)
    step({"jsonrpc": "2.0", "id": 11, "method": "control.set",
          "params": {"id": "color.correct.black_r", "value": 0}}, None)
    step({"jsonrpc": "2.0", "id": 12, "method": "control.set",
          "params": {"id": "scaler.kernel_h", "value": 1}}, None)

    print(f"\nSMOKE TEST: {'PASS' if fails == 0 else f'FAIL ({fails} steps)'}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
