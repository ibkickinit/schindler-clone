#!/usr/bin/env python3
"""G1 reframe calibration tool — set scaler geometry + grab a thumbnail PNG.

Drives the firmware hdmi.out_w/out_h/pos_x/pos_y/matte_rgb controls over raw
UART (no daemon/catalog needed), then debug.dump's a thumbnail and saves it as
a PPM/PNG so we can eyeball where the picture lands and calibrate the +STRIDE
vertical offset (POS_Y_FUDGE in firmware).

Stop the daemon first (it owns /dev/ttyUSB1):
    pkill -f schindlerd.py

Usage:
    python reframe_cal.py --out-w 960 --out-h 540 --pos-x 160 --pos-y 90
    # writes /tmp/reframe_cal.ppm  (open in any image viewer)
"""
import argparse, base64, json, re, sys, time
import serial

JSON_LINE = re.compile(rb"^\s*\{.*\}\s*$")


def jsend(ser, method, params=None, timeout=14.0):
    req = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        req["params"] = params
    ser.reset_input_buffer()
    ser.write(("J " + json.dumps(req, separators=(",", ":")) + "\r\n").encode())
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        chunk = ser.read(4096)
        if not chunk:
            continue
        buf += chunk
        for ln in buf.split(b"\n"):
            ln = ln.strip()
            if JSON_LINE.match(ln):
                try:
                    m = json.loads(ln)
                    if m.get("id") == 1:
                        return m
                except json.JSONDecodeError:
                    pass
    raise TimeoutError(f"no response to {method}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyUSB1")
    p.add_argument("--out-w", type=int)
    p.add_argument("--out-h", type=int)
    p.add_argument("--pos-x", type=int)
    p.add_argument("--pos-y", type=int)
    p.add_argument("--matte", type=lambda s: int(s, 0))
    p.add_argument("--tw", type=int, default=160)
    p.add_argument("--th", type=int, default=90)
    p.add_argument("--ppm", default="/tmp/reframe_cal.ppm")
    args = p.parse_args()

    ser = serial.Serial(args.port, 115200, timeout=0.5)
    time.sleep(0.2)

    sets = [("hdmi.out_w", args.out_w), ("hdmi.out_h", args.out_h),
            ("hdmi.pos_x", args.pos_x), ("hdmi.pos_y", args.pos_y),
            ("hdmi.matte_rgb", args.matte)]
    for cid, val in sets:
        if val is None:
            continue
        r = jsend(ser, "control.set", {"id": cid, "value": val})
        print(f"set {cid}={val} -> {r.get('result') or r.get('error')}", flush=True)
        time.sleep(0.3)  # let reframe settle

    # Grab a thumbnail and save as PPM (gbr → RGB).
    r = jsend(ser, "debug.dump", {"mode": "thumbnail", "slot": 0, "tw": args.tw, "th": args.th})
    ser.close()
    if "error" in r:
        print("dump error:", r["error"], file=sys.stderr); return 1
    res = r["result"]; w, h, fmt = res["w"], res["h"], res["fmt"]
    raw = base64.b64decode(res["data"])
    # fmt gbr → R=b2,G=b0,B=b1
    out = bytearray()
    for i in range(0, len(raw) - 2, 3):
        g, b, rr = raw[i], raw[i+1], raw[i+2]
        out += bytes((rr, g, b)) if fmt == "gbr" else bytes((raw[i], raw[i+1], raw[i+2]))
    with open(args.ppm, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode()); f.write(bytes(out))
    print(f"wrote {args.ppm}  ({w}x{h}, fmt={fmt})  — open to inspect framing", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
