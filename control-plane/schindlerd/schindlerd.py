#!/usr/bin/env python3
"""schindlerd — V0a host-side bridge daemon for Schindler 2.0 control plane.

Bridges:
  - Bare-metal firmware over /dev/ttyUSB1 (JSON-RPC via the 'J' UART command)
  - Web UI / future remote surfaces over WebSocket on :8080

Single-file v0.1 skeleton. Refactor into a package when it grows past ~600 LOC.

Dependencies: pyserial, websockets. Install:
    pip install pyserial websockets

Run:
    python schindlerd.py --port /dev/ttyUSB1 --catalog ../catalog-v0.2.0.json

Architecture: docs/control-plane-architecture.md §V0a.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Dict, List, Optional

try:
    import serial  # type: ignore
except ImportError:
    print("schindlerd: pyserial required (pip install pyserial)", file=sys.stderr)
    sys.exit(2)

try:
    import websockets  # type: ignore
    from websockets.server import WebSocketServerProtocol  # type: ignore
except ImportError:
    print("schindlerd: websockets required (pip install websockets)", file=sys.stderr)
    sys.exit(2)


log = logging.getLogger("schindlerd")


# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------

@dataclass
class CatalogControl:
    """One control from catalog.controls[]. Subset of the schema we need
    runtime; everything else is opaque pass-through to clients."""
    id: str
    type: str                       # "number" | "enum" | "boolean" | "trigger" | "text"
    raw: Dict[str, Any] = field(default_factory=dict)
    enum_str_to_int: Dict[str, int] = field(default_factory=dict)
    enum_int_to_str: Dict[int, str] = field(default_factory=dict)
    read_only: bool = False

    @classmethod
    def from_json(cls, j: Dict[str, Any]) -> "CatalogControl":
        c = cls(id=j["id"], type=j["type"], raw=j, read_only=bool(j.get("read_only")))
        if c.type == "enum":
            for idx, opt in enumerate(j.get("options", [])):
                v = opt["value"]
                c.enum_str_to_int[v] = idx
                c.enum_int_to_str[idx] = v
        return c

    def coerce_to_firmware(self, value: Any) -> int:
        """Translate client-side value (string for enums, number for everything
        else) into the integer the firmware J command expects."""
        if self.type == "enum":
            if isinstance(value, str):
                if value not in self.enum_str_to_int:
                    raise ValueError(f"unknown enum value '{value}' for {self.id}")
                return self.enum_str_to_int[value]
            if isinstance(value, int):
                if value not in self.enum_int_to_str:
                    raise ValueError(f"enum index {value} out of range for {self.id}")
                return value
            raise ValueError(f"{self.id}: enum value must be string or int")
        if self.type == "number":
            return int(value)
        if self.type == "boolean":
            return 1 if value else 0
        raise ValueError(f"{self.id}: type '{self.type}' is not settable via control.set")

    def coerce_from_firmware(self, value: int) -> Any:
        if self.type == "enum":
            return self.enum_int_to_str.get(value, value)
        if self.type == "boolean":
            return bool(value)
        return value


@dataclass
class Catalog:
    version: str
    controls: Dict[str, CatalogControl]
    raw: Dict[str, Any]
    available_ids: Optional[set] = None  # firmware-reported set; None = not probed yet

    @classmethod
    def load(cls, path: Path) -> "Catalog":
        raw = json.loads(path.read_text())
        controls = {}
        for c in raw.get("controls", []):
            controls[c["id"]] = CatalogControl.from_json(c)
        return cls(version=raw.get("schema_version", "0.0.0"), controls=controls, raw=raw)

    def annotated_raw(self) -> Dict[str, Any]:
        """Return the catalog with each control tagged 'available' based on
        what the firmware reported via system.list_controls. Status-type
        controls are always 'available' from the client's perspective (the
        daemon synthesizes them; firmware needn't know about them). Controls
        with requires_status == 'placeholder' are forced unavailable."""
        out = json.loads(json.dumps(self.raw))  # deep copy
        avail = self.available_ids or set()
        for c in out.get("controls", []):
            cid = c["id"]
            placeholder = c.get("requires_status") == "placeholder"
            if c.get("category") == "status" or c.get("read_only"):
                c["available"] = not placeholder
            else:
                c["available"] = (cid in avail) and not placeholder
        return out


# ---------------------------------------------------------------------------
# AUTOTUNE log tap — harvest the firmware's per-trial lead-sweep lines into a CSV
# so (geometry -> working lead) data accumulates as the operator drives the UI.
# A firmware trial line looks like:
#   AUTOTUNE: rot=0 invx=4096 invy=4096 pan=0,0 ks=0,0 pin=-10,-10 L=6144 \
#             opix=2073600/2073600 eol=1080 starved=24 FULL
# ---------------------------------------------------------------------------
_AUTOTUNE_RE = re.compile(
    r"AUTOTUNE:\s+rot=(-?\d+)\s+invx=(-?\d+)\s+invy=(-?\d+)\s+pan=(-?\d+),(-?\d+)\s+"
    r"ks=(-?\d+),(-?\d+)\s+pin=(-?\d+),(-?\d+)\s+L=(\d+)\s+opix=(\d+)/(\d+)\s+"
    r"eol=(\d+)\s+starved=(\d+)\s+(FULL|short)")
_AUTOTUNE_CSV = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "docs", "autotune-leads.csv"))
_AUTOTUNE_HDR = ("ts,rot,invx,invy,panx,pany,ks_h,ks_v,pin_x,pin_y,"
                 "lead,opix,opix_exp,eol,starved,result,"
                 "tl_x,tl_y,tr_x,tr_y,br_x,br_y,bl_x,bl_y,scale_pct\n")
# Live corner-pin offsets (output px), kept current by _m_corner_set. The firmware geometry descriptor
# can't express the corner-pin (it's solved into the homography), so the daemon supplies it for the CSV.
_LAST_CORNERS = (0, 0, 0, 0, 0, 0, 0, 0)   # tl_x,tl_y,tr_x,tr_y,br_x,br_y,bl_x,bl_y
# Live scale %, kept current by _m_scale_set. The firmware descriptor only reflects ENLARGE (>=100%, via
# invx); SHRINK (<100%) decimates write-side with invx=4096, so 90% and 100% are indistinguishable there.
# Capturing it daemon-side labels the shrink rows.
_LAST_SCALE = 100

def autotune_csv_tap(text: str) -> None:
    """If `text` is a firmware AUTOTUNE trial line, append one parsed row to docs/autotune-leads.csv.
    Append-only, called from the single UART reader thread (no lock needed). Never raises into the
    reader loop. Each row is one (geometry, lead) -> opix datapoint (firmware geom fields + the daemon's
    live corner-pin) for mining better static leads."""
    m = _AUTOTUNE_RE.search(text)
    if not m:
        return
    try:
        new = not os.path.exists(_AUTOTUNE_CSV)
        with open(_AUTOTUNE_CSV, "a") as fh:
            if new:
                fh.write(_AUTOTUNE_HDR)
            corners = ",".join(str(v) for v in _LAST_CORNERS)
            fh.write("%d,%s,%s,%d\n" % (int(time.time()), ",".join(m.groups()), corners, _LAST_SCALE))
    except Exception as e:                 # disk/path issue must never kill the UART reader
        log.debug("autotune csv tap failed: %s", e)


# ---------------------------------------------------------------------------
# UART bridge — runs in a worker thread, talks to the firmware over /dev/ttyUSBn
# ---------------------------------------------------------------------------

class UartBridge:
    """Thread-safe UART bridge. send() submits a JSON-RPC request and returns
    a Future that resolves with the firmware's response. Concurrent requests
    are serialized via a per-instance request queue + per-request id."""

    JSON_LINE_RE = re.compile(rb"^\s*\{.*\}\s*$")

    def __init__(self, port: str, baud: int = 115200):
        self.port = port
        self.baud = baud
        self.ser: Optional[serial.Serial] = None
        self._next_id = 1
        self._pending: Dict[int, asyncio.Future] = {}
        self._lock = threading.Lock()
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._stop = threading.Event()
        self._reader_thread: Optional[threading.Thread] = None
        # Non-JSON UART lines (firmware DIAG/TELEMETRY/etc) get routed to this
        # callback on the asyncio loop. Set externally by the daemon.
        self.text_log_handler: Optional[Callable[[str], None]] = None

    def start(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop
        self.ser = serial.Serial(self.port, self.baud, timeout=0.1)
        self._reader_thread = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader_thread.start()
        log.info("uart: opened %s @ %d", self.port, self.baud)

    def stop(self) -> None:
        self._stop.set()
        if self.ser:
            self.ser.close()

    def _reader_loop(self) -> None:
        assert self.ser is not None and self._loop is not None
        buf = bytearray()
        while not self._stop.is_set():
            try:
                chunk = self.ser.read(256)
            except Exception as e:
                log.warning("uart: read error: %s", e)
                time.sleep(0.5)
                continue
            if not chunk:
                continue
            buf.extend(chunk)
            while b"\n" in buf:
                line, _, rest = buf.partition(b"\n")
                buf = bytearray(rest)
                line = line.rstrip(b"\r")
                if not line:
                    continue
                if self.JSON_LINE_RE.match(line):
                    self._on_json_line(line)
                else:
                    text = line.decode("utf-8", "replace")
                    log.debug("uart-log: %s", text)
                    if "AUTOTUNE:" in text:
                        autotune_csv_tap(text)          # harvest lead-sweep trials -> docs/autotune-leads.csv
                    if self.text_log_handler and self._loop:
                        self._loop.call_soon_threadsafe(self.text_log_handler, text)

    def _on_json_line(self, line: bytes) -> None:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            log.warning("uart: malformed JSON: %s", line)
            return
        rid = obj.get("id")
        if not isinstance(rid, int):
            log.debug("uart: notification or null-id frame: %s", obj)
            return
        with self._lock:
            fut = self._pending.pop(rid, None)
        if fut is None:
            log.warning("uart: response for unknown id %d: %s", rid, obj)
            return
        assert self._loop is not None
        self._loop.call_soon_threadsafe(fut.set_result, obj)

    async def request(self, method: str, params: Optional[Dict[str, Any]] = None,
                       timeout: float = 1.5) -> Dict[str, Any]:
        assert self._loop is not None and self.ser is not None
        with self._lock:
            rid = self._next_id
            self._next_id += 1
        req = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            req["params"] = params
        fut = self._loop.create_future()
        with self._lock:
            self._pending[rid] = fut
        line = "J " + json.dumps(req, separators=(",", ":")) + "\r\n"
        try:
            self.ser.write(line.encode("ascii"))
        except Exception as e:
            with self._lock:
                self._pending.pop(rid, None)
            raise RuntimeError(f"uart write failed: {e}") from e
        try:
            return await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            with self._lock:
                self._pending.pop(rid, None)
            raise

    def send_raw(self, line: str) -> None:
        """Send a RAW (non-JSON-RPC) firmware command line, fire-and-forget.
        For commands outside the catalog/JSON-RPC path — e.g. the read-engine
        geometry 'G w h x y'. The firmware echoes a non-JSON 'GEO:' line which the
        reader logs; there is no response correlation (so this returns nothing)."""
        if self.ser is None:
            raise RuntimeError("uart not open")
        try:
            self.ser.write((line.rstrip() + "\r\n").encode("ascii"))
        except Exception as e:
            raise RuntimeError(f"uart raw write failed: {e}") from e


# ---------------------------------------------------------------------------
# Profile store — JSON files in ~/.schindler/profiles/
# ---------------------------------------------------------------------------

class ProfileStore:
    """Multi-source profile store. The first root is the writable user dir;
    additional roots (e.g. factory presets shipped with the daemon) are
    read-only. Name collisions resolve to the first matching root, so a
    user profile shadows a factory profile of the same name."""

    def __init__(self, user_root: Path, readonly_roots: Optional[List[Path]] = None):
        self.user_root = user_root
        self.user_root.mkdir(parents=True, exist_ok=True)
        self.readonly_roots = [p for p in (readonly_roots or []) if p.is_dir()]

    def list(self) -> List[Dict[str, Any]]:
        """List visible profiles. Each entry: {name, factory: bool, source}."""
        seen: Dict[str, Dict[str, Any]] = {}
        for p in self.user_root.glob("*.json"):
            seen[p.stem] = {"name": p.stem, "factory": False, "source": "user"}
        for root in self.readonly_roots:
            for p in root.glob("*.json"):
                if p.stem in seen:
                    continue
                seen[p.stem] = {"name": p.stem, "factory": True, "source": root.name}
        return sorted(seen.values(), key=lambda r: (not r["factory"], r["name"]))

    def load(self, name: str) -> Dict[str, Any]:
        user_path = self.user_root / f"{name}.json"
        if user_path.is_file():
            return json.loads(user_path.read_text())
        for root in self.readonly_roots:
            p = root / f"{name}.json"
            if p.is_file():
                return json.loads(p.read_text())
        raise FileNotFoundError(f"no profile '{name}'")

    def save(self, name: str, profile: Dict[str, Any]) -> None:
        # Saving always writes to the user dir; never touches factory dirs.
        (self.user_root / f"{name}.json").write_text(json.dumps(profile, indent=2))


# ---------------------------------------------------------------------------
# Status cache + telemetry parser — converts firmware text lines into typed
# status fields broadcast as JSON-RPC notifications to all connected WS clients.
# ---------------------------------------------------------------------------

class Subscriber:
    """One bus subscriber: queue + per-client stats. Stats are exposed via
    system.metrics so an operator can see whether a client is keeping up."""
    __slots__ = ("q", "label", "published", "dropped", "consecutive_drops",
                 "last_drop_warned")

    def __init__(self, label: str, maxsize: int = 64):
        self.q: asyncio.Queue = asyncio.Queue(maxsize=maxsize)
        self.label = label
        self.published = 0
        self.dropped = 0
        self.consecutive_drops = 0
        self.last_drop_warned = 0


class StatusBus:
    """In-process pub-sub for status fields. Clients subscribe() and receive a
    Subscriber wrapping an asyncio.Queue. WS handler drains the queue and
    forwards as JSON-RPC notifications.

    Drops are tracked per-client. If a single client misses 10 events in a
    row we log a warning (probable backpressure or runaway client). Total
    counters survive across subscribers and feed system.metrics."""

    DROP_WARN_THRESHOLD = 10  # consecutive drops before logging

    def __init__(self):
        self._subs: List[Subscriber] = []
        self._lock = asyncio.Lock()
        self.total_published = 0
        self.total_dropped = 0
        self._next_id = 1

    async def subscribe(self, label: Optional[str] = None) -> Subscriber:
        async with self._lock:
            sub_id = self._next_id
            self._next_id += 1
        sub = Subscriber(label or f"client-{sub_id}")
        async with self._lock:
            self._subs.append(sub)
        return sub

    async def unsubscribe(self, sub: Subscriber) -> None:
        async with self._lock:
            if sub in self._subs:
                self._subs.remove(sub)

    def publish(self, payload: Dict[str, Any]) -> None:
        # Synchronous publish — called from the asyncio loop. Drops events
        # to slow subscribers rather than blocking the pipeline.
        self.total_published += 1
        for sub in list(self._subs):
            try:
                sub.q.put_nowait(payload)
                sub.published += 1
                sub.consecutive_drops = 0
            except asyncio.QueueFull:
                sub.dropped += 1
                sub.consecutive_drops += 1
                self.total_dropped += 1
                if (sub.consecutive_drops == self.DROP_WARN_THRESHOLD
                        and sub.consecutive_drops != sub.last_drop_warned):
                    log.warning("status: client '%s' dropped %d events in a row "
                                "(queue full — slow consumer?)",
                                sub.label, sub.consecutive_drops)
                    sub.last_drop_warned = sub.consecutive_drops

    def metrics(self) -> Dict[str, Any]:
        return {
            "total_published": self.total_published,
            "total_dropped": self.total_dropped,
            "subscribers": [
                {
                    "label": s.label,
                    "published": s.published,
                    "dropped": s.dropped,
                    "queue_depth": s.q.qsize(),
                }
                for s in self._subs
            ],
        }


class TelemetryParser:
    """Regex-based parser for the firmware's existing DIAG/TELEMETRY/VTC_RX
    lines. Maps captured fields to catalog status.* ids and publishes deltas.

    The parser keeps the last value per id and only republishes on change —
    no point sending the same S2MM_SR every second."""

    # The firmware DIAG line wraps each SR with a bracketed bitfield decode,
    # e.g. S2MM_SR=0x00011810[FrmCnt  frmcnt=1]. The bracket content contains
    # spaces, so match it with [^\]]* rather than \S*.
    RE_DIAG = re.compile(
        r"DIAG:\s*h_in=(\d+)\s+v_in=(\d+)\s+v_emit=(\d+)\s+v_out_tlast=(\d+)\s+"
        r"S2MM_SR=(0x[0-9a-fA-F]+)(?:\[[^\]]*\])?\s+"
        r"MM2S_SR=(0x[0-9a-fA-F]+)(?:\[[^\]]*\])?\s+"
        r"RDSTORE=(\d+)\s+WRSTORE=(\d+)\s+src=(\d+)\s+out=(\d+)")
    RE_TELEMETRY = re.compile(
        r"TELEMETRY:\s+src=([\d.]+)\s+Hz\s+->\s+regime\s+(\d+)\s+\[(.+?)\]")
    RE_VTCRX = re.compile(
        r"VTC_RX:\s+HACTIVE=(\d+)\s+VACTIVE=(\d+)\s+HTOTAL=(\d+)\s+VTOTAL=(\d+)")
    RE_LOCKED = re.compile(r"dvi2rgb pLocked stable")
    # The warp OUT line fires EVERY telemetry cycle; its eol-exp = output height (720/1080) -> robust
    # output-res detection even after a daemon restart (the "VTC: configuring" line only fires on a change).
    RE_OUTEXP = re.compile(r"OUT: opix/frame=\d+ \(exp \d+\) eol/frame=\d+ \(exp (\d+)\)")

    def __init__(self, bus: StatusBus):
        self.bus = bus
        self.last: Dict[str, Any] = {}
        # Output format is a build-time constant for v0.1 — bag it from the
        # banner line and reuse.
        self._output_format = "720p60"  # default until banner says otherwise

    def feed(self, line: str) -> None:
        try:
            self._feed(line)
        except Exception as e:
            log.warning("telemetry parser error: %s on line %r", e, line)

    def _feed(self, line: str) -> None:
        if m := self.RE_DIAG.search(line):
            self._update("status.s2mm_sr", int(m.group(5), 16))
            self._update("status.mm2s_sr", int(m.group(6), 16))
            # DIAG only fires once the pipeline is locked, so its presence
            # implies source_lock=true. src/out are integer-Hz approximations
            # adequate for the operator status bar.
            self._update("status.source_lock", True)
            self._update("status.source_rate_hz", int(m.group(9)))
            self._update("status.output_rate_hz", int(m.group(10)))
            return
        if m := self.RE_TELEMETRY.search(line):
            hz = float(m.group(1))
            regime_lbl = m.group(3)
            self._update("status.source_rate_hz", round(hz, 3))
            self._update("status.regime", regime_lbl)
            return
        if m := self.RE_VTCRX.search(line):
            hactive = int(m.group(1)); vactive = int(m.group(2))
            self._update("status.source_format", f"{hactive}x{vactive}")
            self._update("status.source_lock", True)
            return
        if self.RE_LOCKED.search(line):
            self._update("status.source_lock", True)
            return
        if m := self.RE_OUTEXP.search(line):
            fmt = "1080p30" if int(m.group(1)) >= 1000 else "720p60"   # eol-exp = output height
            self._output_format = fmt
            self._update("status.output_format", fmt)
            return
        if "VTC: configuring 720p60" in line:
            self._output_format = "720p60"
            self._update("status.output_format", "720p60")
        elif "VTC: configuring 1080p30" in line:
            self._output_format = "1080p30"
            self._update("status.output_format", "1080p30")
        elif "VTC: configuring 1080p60" in line:
            self._output_format = "1080p60"
            self._update("status.output_format", "1080p60")

    def _update(self, cid: str, value: Any) -> None:
        if self.last.get(cid) == value:
            return
        self.last[cid] = value
        # Publish as a JSON-RPC notification (no id). Web UI handler routes
        # status.update notifications into the per-row value cells.
        self.bus.publish({
            "jsonrpc": "2.0",
            "method": "status.update",
            "params": {"id": cid, "value": value},
        })


# ---------------------------------------------------------------------------
# JSON-RPC dispatcher — handles methods coming from WebSocket clients
# ---------------------------------------------------------------------------

class Dispatcher:
    def __init__(self, catalog: Catalog, uart: UartBridge, profiles: ProfileStore,
                 bus: "StatusBus"):
        self.catalog = catalog
        self.uart = uart
        self.profiles = profiles
        self.bus = bus
        self.uart.text_log_handler = self._on_uart_text   # firmware AUTOTUNE lines -> OSD banner events
        self.methods: Dict[str, Callable[[Dict[str, Any]], Awaitable[Any]]] = {
            "system.identify":      self._m_identify,
            "system.catalog":       self._m_catalog,
            "system.list_controls": self._m_list_controls,
            "control.get":          self._m_control_get,
            "control.set":          self._m_control_set,
            "profile.list":         self._m_profile_list,
            "profile.load":         self._m_profile_load,
            "profile.save":         self._m_profile_save,
            "status.snapshot":      self._m_status_snapshot,
            "system.metrics":       self._m_system_metrics,
            "debug.dump":           self._m_debug_dump,
            "geom.set":             self._m_geom_set,
            "warp.set":             self._m_warp_set,
            "sheet.set":            self._m_sheet_set,        # keystone (legacy; superseded by corner.set)
            "corner.set":           self._m_corner_set,       # independent 4-corner pin (raw 'C')
            "pincushion.set":       self._m_pincushion_set,   # radial warp (now COEXISTS with corner-pin)
            "lead.autotune":        self._m_lead_autotune,    # force prefetch-lead sweep ('U') / toggle on-break
            "matte.set":            self._m_matte_set,        # runtime matte fill colour
            "scale.set":            self._m_scale_set,        # CANON scale: shrink=write-side, enlarge=read-side warp zoom (Z)
            "output.set":           self._m_output_set,       # live resolution / framerate (74.25 family)
            "blend.set":            self._m_blend_set,
            "operator.set":         self._m_operator_set,
            "arc.set":              self._m_arc_set,
            "gamma.set":            self._m_gamma_set,
            "colorspace.set":       self._m_colorspace_set,
        }
        self.telemetry: Optional[TelemetryParser] = None  # set by daemon main

    async def handle(self, req: Dict[str, Any]) -> Dict[str, Any]:
        rid = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if method not in self.methods:
            return _error(rid, -32601, f"unknown method '{method}'")
        try:
            result = await self.methods[method](params)
            return {"jsonrpc": "2.0", "id": rid, "result": result}
        except ValueError as e:
            return _error(rid, -32602, str(e))
        except KeyError as e:
            return _error(rid, -32602, f"missing param: {e}")
        except Exception as e:
            log.exception("dispatcher: %s failed", method)
            return _error(rid, -32603, str(e))

    async def _m_identify(self, params: Dict[str, Any]) -> Dict[str, Any]:
        try:
            fw = await self.uart.request("system.identify")
            fw_result = fw.get("result", {})
        except Exception as e:
            fw_result = {"error": str(e)}
        return {
            "daemon": "schindlerd",
            "daemon_version": "0.1.0",
            "catalog": self.catalog.version,
            "firmware": fw_result,
        }

    async def _m_catalog(self, params: Dict[str, Any]) -> Dict[str, Any]:
        if self.catalog.available_ids is None:
            await self.probe_firmware_controls()
        return self.catalog.annotated_raw()

    async def probe_firmware_controls(self) -> None:
        """Ask the firmware which controls it actually implements. Used to
        annotate the catalog so the UI can hide gated controls."""
        try:
            fw = await self.uart.request("system.list_controls")
            ids = fw.get("result", {}).get("ids", [])
            self.catalog.available_ids = set(ids)
            log.info("firmware reports %d available controls", len(ids))
        except Exception as e:
            log.warning("firmware probe failed: %s", e)
            self.catalog.available_ids = set()

    async def _m_list_controls(self, params: Dict[str, Any]) -> List[str]:
        return list(self.catalog.controls.keys())

    async def _m_control_get(self, params: Dict[str, Any]) -> Dict[str, Any]:
        cid = params["id"]
        ctl = self.catalog.controls.get(cid)
        if ctl is None:
            raise ValueError(f"unknown control id '{cid}'")
        fw = await self.uart.request("control.get", {"id": cid})
        if "error" in fw:
            raise RuntimeError(f"firmware: {fw['error'].get('message', '?')}")
        raw_val = fw["result"]["value"]
        return {"id": cid, "value": ctl.coerce_from_firmware(raw_val)}

    async def _m_control_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        cid = params["id"]
        ctl = self.catalog.controls.get(cid)
        if ctl is None:
            raise ValueError(f"unknown control id '{cid}'")
        if ctl.read_only:
            raise ValueError(f"'{cid}' is read-only")
        fw_val = ctl.coerce_to_firmware(params["value"])
        fw = await self.uart.request("control.set", {"id": cid, "value": fw_val})
        if "error" in fw:
            raise RuntimeError(f"firmware: {fw['error'].get('message', '?')}")
        raw_val = fw["result"]["value"]
        out_val = ctl.coerce_from_firmware(raw_val)
        # Multi-client coordination: every connected client receives a
        # control.changed notification so all open browsers stay in sync.
        # The originating client filters its own echo via inflight/pending
        # state in the UI handler.
        self.bus.publish({
            "jsonrpc": "2.0",
            "method": "control.changed",
            "params": {"id": cid, "value": out_val},
        })
        return {"id": cid, "value": out_val}

    async def _m_warp_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Warp read-engine geometry: rotation + zoom, sent COHERENTLY as one raw
        'W <deg> <invx> <invy>' (WARP build only; not a catalog control). The daemon holds the
        current (deg, invx, invy) so changing zoom preserves rotation and vice-versa — unlike the
        route-B 'G' command, which writes the same GPIOs as the warp coeffs and would clobber them.
          deg          : -180..180 (firmware wraps mod 360, auto per-geometry LEAD)
          invx/invy    : inverse scale, Q12 (4096 = 1:1; >4096 = zoom OUT/downscale; <4096 = zoom IN)
          panx/pany    : SIGNED placement shift, OUTPUT px (+right/+down). Applied through the affine,
                         so the image slides under the matte and matte fills the vacated edge (canon
                         signed-window). This is the CANON "Position" control (Shift X/Y handle); the
                         route-B 'G' shift is inert in the warp build.
          zoom         : convenience % (100 = 1:1; 200 = 2x zoom-in); maps to invx=invy=4096*100/zoom"""
        if not hasattr(self, "_warp_deg"):
            self._warp_deg, self._warp_invx, self._warp_invy = 0, 4096, 4096
            self._warp_panx, self._warp_pany = 0, 0
        if "deg" in params:
            d = int(round(float(params["deg"])))
            while d > 180:  d -= 360
            while d < -180: d += 360
            self._warp_deg = d
        def cl(v): return 256 if v < 256 else 0xFFFFF if v > 0xFFFFF else v
        if "invx" in params: self._warp_invx = cl(int(round(float(params["invx"]))))
        if "invy" in params: self._warp_invy = cl(int(round(float(params["invy"]))))
        def clp(v, lim): iv = int(round(float(v))); return -lim if iv < -lim else lim if iv > lim else iv
        if "panx" in params: self._warp_panx = clp(params["panx"], 2560)  # OUTPUT px, off-screen ok
        if "pany" in params: self._warp_pany = clp(params["pany"], 1440)
        if "zoom" in params:
            # Legacy convenience: prefer scale.set ('Z') which routes per axis. zoom>=100 is a legit
            # read-side warp zoom (the canon ENLARGE path); zoom<100 would be a read-side DOWNSCALE-fetch
            # (the bandwidth footgun — shrink belongs on the write side via Z). UI scale uses scale.set.
            z = max(25.0, min(400.0, float(params["zoom"])))
            iv = cl(int(round(4096.0 * 100.0 / z)))
            self._warp_invx = self._warp_invy = iv
        # 5-arg W (firmware: W <deg> <invx> <invy> <panx> <pany>); pan applied through the affine.
        self.uart.send_raw(f"W {self._warp_deg} {self._warp_invx} {self._warp_invy} "
                           f"{self._warp_panx} {self._warp_pany}")
        out = {"deg": self._warp_deg, "invx": self._warp_invx, "invy": self._warp_invy,
               "panx": self._warp_panx, "pany": self._warp_pany}
        self.bus.publish({"jsonrpc": "2.0", "method": "warp.changed", "params": out})
        return out

    # ---- Two-stage SHEET WARP (Bite 1/2). Keystone/corner-pin and pincushion are MUTUALLY EXCLUSIVE
    # (#49: pincushion is applied AFTER the corner-pin, so combining them leaves the black border
    # un-bowed — clamped to one-or-the-other). The daemon holds _sheet_mode and zeroes the other family
    # on switch. CLAMPS are the conservative single-engine 1080p envelope (720p has more headroom); the
    # UI 'override' box unlocks the fragile/may-break zone toward the firmware's own clamp. These will be
    # tightened once the two-engine DDR-bandwidth build measures the real derate (task #41). ----
    async def _m_sheet_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Keystone sheet warp (Bite 1). XOR with pincushion. Raw 'K <h> <v>' — h,v 1/1000 signed
        (far-edge shrink; the simple corner-pin driver). Switching INTO keystone zeroes any active
        pincushion. Conservative clamp +/-150 (0.15); {override:true} unlocks to +/-900 (fw clamps 0.9)."""
        ov = bool(params.get("override"))
        lim = 900 if ov else 150
        def clk(v): iv = int(round(float(v))); return -lim if iv < -lim else lim if iv > lim else iv
        if not hasattr(self, "_sheet_h"): self._sheet_h, self._sheet_v = 0, 0
        if "h" in params: self._sheet_h = clk(params["h"])
        if "v" in params: self._sheet_v = clk(params["v"])
        self.uart.send_raw(f"K {self._sheet_h} {self._sheet_v}")   # XOR removed (coexists with pincushion)
        out = {"h": self._sheet_h, "v": self._sheet_v, "override": ov}
        self.bus.publish({"jsonrpc": "2.0", "method": "sheet.changed", "params": out})
        return out

    async def _m_pincushion_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Radial pincushion/barrel warp (Bite 2), INDEPENDENT X/Y (2026-06-28). Coexists with corner-pin.
        Raw 'I <x> <y>' — 1/1000 signed per-axis (+barrel out / -pincushion in; corners stay PINNED).
        Params: {x, y} per-axis, or {amt} symmetric (legacy; sets both). Conservative clamp +/-200 (0.20);
        {override:true} unlocks to +/-1000 (1.0)."""
        ov = bool(params.get("override"))
        # ASYMMETRIC clamp (2026-06-28, docs/warp-geometry-envelope.md): +barrel pincushion minifies the
        # source -> WALLS at +75 even with no corner-pin, so cap positive TIGHT; -pincushion magnifies ->
        # clean to -200, so negative is generous. Override loosens both slightly.
        pos_lim = 50 if ov else 40
        neg_lim = 200 if ov else 150
        if not hasattr(self, "_pin_x"): self._pin_x = 0
        if not hasattr(self, "_pin_y"): self._pin_y = 0
        def _clamp(v):
            iv = int(round(float(v)))
            return -neg_lim if iv < -neg_lim else pos_lim if iv > pos_lim else iv
        if "amt" in params:                       # legacy symmetric
            self._pin_x = self._pin_y = _clamp(params["amt"])
        if "x" in params: self._pin_x = _clamp(params["x"])
        if "y" in params: self._pin_y = _clamp(params["y"])
        # 2026-06-27: pincushion COEXISTS with corner-pin (separate firmware stages) — XOR removed.
        self.uart.send_raw(f"I {self._pin_x} {self._pin_y}")
        out = {"x": self._pin_x, "y": self._pin_y, "amt": self._pin_x, "override": ov}
        self.bus.publish({"jsonrpc": "2.0", "method": "pincushion.changed", "params": out})
        return out

    async def _m_lead_autotune(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Prefetch-lead auto-tune (firmware 'U'). No params -> force a sweep on the CURRENT geometry NOW
        (the firmware tries a lead ladder, applies the lowest FULL one, and logs AUTOTUNE: lines on the
        UART for harvesting). {enable: bool} -> toggle the automatic on-break tuner ('U 0'/'U 1', default
        ON). The sweep takes ~3s and soft-resets the cache each step (brief on-screen flicker)."""
        if "enable" in params:
            en = 1 if params["enable"] else 0
            self.uart.send_raw(f"U {en}")
            return {"enable": bool(en)}
        if params.get("scan"):
            self.uart.send_raw("U 2")          # scan-all: log every lead's result for this geometry
            return {"swept": True, "scan": True}
        self.uart.send_raw("U")
        return {"swept": True}

    def _on_uart_text(self, text: str) -> None:
        """Route firmware AUTOTUNE log lines to the UI as an OSD banner: a 'tuning' event when a sweep
        starts (carrying the old/auto lead) and a 'done' event when it finishes (the chosen lead + whether
        it reached a full frame). Runs on the event-loop thread (call_soon_threadsafe from the UART reader)."""
        try:
            m = re.search(r"AUTOTUNE start:.*\(auto lead was (\d+)\)", text)
            if m:
                self.bus.publish({"jsonrpc": "2.0", "method": "autotune.changed",
                                  "params": {"state": "tuning", "old": int(m.group(1))}})
                return
            m = re.search(r"AUTOTUNE done:.*CHOSE L=(\d+) \(opix=(\d+)/(\d+)\)", text)
            if m:
                self.bus.publish({"jsonrpc": "2.0", "method": "autotune.changed",
                                  "params": {"state": "done", "new": int(m.group(1)),
                                             "full": int(m.group(2)) >= int(m.group(3))}})
        except Exception as e:                 # never let an OSD parse error disturb the UART path
            log.debug("autotune osd parse failed: %s", e)

    def _out_wh(self):
        """Current output raster (W,H). Prefer the LIVE board res from telemetry (the build BOOTS 1080p30,
        so the board can be 1080p while the daemon's set-mode still says 720p) -> fall back to _output_format."""
        fmt = (self.telemetry.last.get("status.output_format") if self.telemetry else None) \
              or getattr(self, "_output_format", "720p60")
        return (1920, 1080) if "1080" in str(fmt) else (1280, 720)

    async def _m_corner_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Independent 4-corner pin, IMAGE-CORNER (forward) model so each corner is ABSOLUTE/decoupled.
        Each corner has an (x,y) handle: **+ = OUT (away from frame center), − = IN (toward center)** —
        consistent for all four corners and both axes. We place each image corner at its output position,
        solve the output->source homography, and emit 'C' = that homography at the 4 fixed raster corners.
        (The old source-offset model coupled the corners — moving one shifted the whole map.) Coexists
        with pincushion. Clamp 1/3 raster (safe) / full under {override:true}. Res from the live mode."""
        W, H = self._out_wh()
        ov = bool(params.get("override"))
        lim = 200 if ov else 100   # default ±100 px (safe); {override:true} unlocks to ±200 for exploration
        def cl(v, m):
            iv = int(round(float(v))); return -m if iv < -m else m if iv > m else iv
        keys = ["tl", "tr", "br", "bl"]
        rect = [(0, 0), (W - 1, 0), (W - 1, H - 1), (0, H - 1)]   # source content corners + fixed output corners
        sgnx = {"tl": -1, "tr": +1, "br": +1, "bl": -1}          # +handle X -> OUT: screen-x sign per corner
        sgny = {"tl": -1, "tr": -1, "br": +1, "bl": +1}          # +handle Y -> OUT: screen-y sign per corner
        if not hasattr(self, "_corners"):
            self._corners = {k: {"x": 0, "y": 0} for k in keys}
        for k in keys:
            c = params.get(k)
            if isinstance(c, dict):
                if "x" in c: self._corners[k]["x"] = cl(c["x"], lim)
                if "y" in c: self._corners[k]["y"] = cl(c["y"], lim)
        # keep the module-level corner snapshot current for the AUTOTUNE CSV tap (firmware can't log it)
        global _LAST_CORNERS
        _LAST_CORNERS = tuple(self._corners[k][ax] for k in keys for ax in ("x", "y"))
        # output position where each IMAGE corner should land (absolute), per the OUT=+ convention
        outp = []
        for (bx, by), k in zip(rect, keys):
            outp.append((bx + sgnx[k] * self._corners[k]["x"], by + sgny[k] * self._corners[k]["y"]))
        # solve homography mapping output-positions -> source-rect-corners, then sample at the fixed corners
        Hm = _solve_homography(outp, rect)
        if Hm is None:                                            # degenerate -> identity (no-op send)
            pts = [v for c in rect for v in c]
        else:
            pts = []
            for (fx, fy) in rect:
                sx, sy = _apply_homography(Hm, fx, fy)
                pts += [int(round(sx)), int(round(sy))]
        self.uart.send_raw("C " + " ".join(str(p) for p in pts))
        out = {"corners": self._corners, "src": pts, "w": W, "h": H, "override": ov}
        self.bus.publish({"jsonrpc": "2.0", "method": "corner.changed", "params": out})
        return out

    async def _m_matte_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Runtime matte fill colour (on-sheet/off-content fill; off-sheet is always black).
        Raw 'T <r> <g> <b>', each 0..255. Default 16/16/16 (dim gray, the firmware boot default)."""
        def c8(v): iv = int(round(float(v))); return 0 if iv < 0 else 255 if iv > 255 else iv
        r = c8(params.get("r", 0)); g = c8(params.get("g", 0)); b = c8(params.get("b", 0))  # default black
        self.uart.send_raw(f"T {r} {g} {b}")
        out = {"r": r, "g": g, "b": b}
        self.bus.publish({"jsonrpc": "2.0", "method": "matte.changed", "params": out})
        return out

    async def _m_scale_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """CANON image scale via raw 'Z <x> [y]' (per axis; #59). Each axis: <100% = scaler DECIMATES
        write-side (shrink, bandwidth-safe); >=100% = warp ZOOMS read-side (enlarge, cheap). Canon =
        "shrink write-side, enlarge read-side; the warp never DOWNSCALES." Independent ('x','y' in %) or
        uniform ('pct'). 10..200%."""
        def cl(v):
            iv = int(round(float(v)))
            return 10 if iv < 10 else 200 if iv > 200 else iv
        try:
            if "x" in params or "y" in params:
                xp = cl(params.get("x", params.get("y", 100)))
                yp = cl(params.get("y", params.get("x", 100)))
            else:
                xp = yp = cl(params.get("pct", 100))
        except (TypeError, ValueError):
            raise ValueError("scale.set needs numeric 'pct' or 'x'/'y'")
        self.uart.send_raw(f"Z {xp} {yp}")
        self._scale_pct = xp
        global _LAST_SCALE
        _LAST_SCALE = xp                       # label autotune CSV rows with the live scale (esp. shrink)
        # Mirror the firmware: UPSCALE (>=100%) lives in the warp invx/invy; DOWNSCALE (<100%) decimates
        # write-side so the warp reads 1:1 (invx=4096). Record it so a later warp.set (rotation/pan) sends
        # the CURRENT zoom and doesn't reset it to 1:1 (fixes "nudging rotation zeroes my zoom").
        if not hasattr(self, "_warp_deg"):
            self._warp_deg, self._warp_panx, self._warp_pany = 0, 0, 0
        self._warp_invx = max(256, (4096 * 100) // xp) if xp >= 100 else 4096
        self._warp_invy = max(256, (4096 * 100) // yp) if yp >= 100 else 4096
        out = {"x": xp, "y": yp, "pct": xp}
        self.bus.publish({"jsonrpc": "2.0", "method": "scale.changed", "params": out})
        return out

    async def _m_output_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Live output resolution / framerate. Raw 'R <720|1080>'. v1 firmware wires the two 74.25 MHz
        modes 720p60 / 1080p30; 720p50 / 1080p24 / 1080p25 are the SAME clock but need firmware VTC
        tables (follow-up). 1080p60 (148.5 MHz) is BLOCKED on the Zybo rgb2dvi serializer -> rejected."""
        m = str(params.get("mode", "720p60"))
        R = {"720p60": 720, "1080p30": 1080}
        if m not in R:
            raise ValueError(f"output mode '{m}' not available on this build (have: {', '.join(R)})")
        self.uart.send_raw(f"R {R[m]}")
        self._output_format = m
        self.bus.publish({"jsonrpc": "2.0", "method": "output.changed", "params": {"mode": m}})
        return {"mode": m}

    async def _m_geom_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """⚠️ NEUTRALIZED in the WARP build (2026-06-27). The raw 'G'/'P' (route-B read-engine geometry)
        writes GEO_A/B/C — the SAME GPIOs the warp's projective corner-pin (warp_apply_homography) uses —
        so ANY geom.set CLOBBERS the warp's matrix and breaks/blacks the picture (this was the "anchor
        crushed it on the left" bug). Route-B is legacy/dead in the warp product. So we DO NOT send G/P;
        we only echo the requested values for multi-client sync. Scale=Z (scale.set), shift=warp pan
        (warp.set panx/pany), rotation=warp.set deg. If a real route-B build is ever revived, re-enable."""
        def clampi(v: Any, lo: int, hi: int) -> int:
            iv = int(round(float(v)))
            return lo if iv < lo else hi if iv > hi else iv
        w = clampi(params.get("w", 1280), 1, 3840)
        h = clampi(params.get("h", 720), 1, 2160)
        x = clampi(params.get("x", 0), -2560, 2560)
        y = clampi(params.get("y", 0), -1440, 1440)
        anchor = 1 if params.get("anchor", 0) else 0
        filt = clampi(params.get("filt", 0), 0, 3)
        hflip = 1 if params.get("hflip", 0) else 0
        vflip = 1 if params.get("vflip", 0) else 0
        # *** NO 'G'/'P' SENT — see docstring (clobbers the warp). Echo only. ***
        applied = {"w": w, "h": h, "x": x, "y": y, "anchor": anchor, "filt": filt,
                   "hflip": hflip, "vflip": vflip}
        self.bus.publish({"jsonrpc": "2.0", "method": "geom.changed", "params": applied})
        return applied

    async def _m_blend_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Mackin blend mode (read-engine). Raw 'M 0|1|2': 0=off (drop/repeat),
        1=intelligent (blend mid-phase), 2=force (blend every interframe). Accepts
        {"mode":0|1|2} or legacy {"enabled":bool}. Not a catalog control."""
        if "mode" in params:
            m = int(params["mode"]); m = 0 if m < 0 else 2 if m > 2 else m
        else:
            m = 1 if params.get("enabled") else 0
        self.uart.send_raw(f"M {m}")
        self.bus.publish({"jsonrpc": "2.0", "method": "blend.changed", "params": {"mode": m}})
        return {"mode": m}

    async def _m_operator_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Operator quick-actions (parity Phase 1) — raw 'O ...' firmware commands. Any of:
        {"mono":0|1} {"bypass":0|1} {"black":0|1} {"temp":<K>} {"fade":<0-255>,"step":<n>}."""
        out: Dict[str, Any] = {}
        if "mono" in params:
            m = 1 if params["mono"] else 0; self.uart.send_raw(f"O m {m}"); out["mono"] = m
        if "bypass" in params:
            y = 1 if params["bypass"] else 0; self.uart.send_raw(f"O y {y}"); out["bypass"] = y
        if "black" in params:
            k = 1 if params["black"] else 0; self.uart.send_raw(f"O k {k}"); out["black"] = k
        if "freeze" in params:
            z = 1 if params["freeze"] else 0; self.uart.send_raw(f"O z {z}"); out["freeze"] = z
        if "gamma" in params:
            g = int(params["gamma"]); self.uart.send_raw(f"O g {g}"); out["gamma"] = g  # 0=off,18,22,24
        if "temp" in params:
            t = int(params["temp"]); self.uart.send_raw(f"O t {t}"); out["temp"] = t
        if "fade" in params:
            tgt = int(params["fade"]); tgt = 0 if tgt < 0 else 255 if tgt > 255 else tgt
            step = int(params.get("step", 6)); step = 1 if step < 1 else step
            self.uart.send_raw(f"O f {tgt} {step}"); out["fade"] = tgt
        self.bus.publish({"jsonrpc": "2.0", "method": "operator.changed", "params": out})
        return out

    # ARC (aspect) modes — preset window sizes on the signed-window geometry engine; the
    # engine centers (anchor=0) and mattes the rest. Pure geometry preset, no firmware/HDL.
    # NOTE: scales the full source into the window, so the cross-aspect modes (4:3/letterbox)
    # change the picture's aspect (anamorphic) for a 16:9 source — the operator framing tool.
    _ARC_TABLE = {
        "fill":      (1280, 720),   # 16:9 fill (default)
        "zoom":      (1408, 792),   # ~110% overscan, undistorted (crops edges)
        "4:3":       (960,  720),   # pillarbox (bars L/R)
        "14:9":      (1120, 720),   # 14:9 compromise
        "letterbox": (1280, 545),   # 2.35:1 letterbox (bars T/B)
    }

    async def _m_arc_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Aspect-ratio preset: fill / zoom / 4:3 / 14:9 / letterbox. Sets a centered window
        of the preset size on the geometry engine (preserves the current flip state)."""
        mode = str(params.get("mode", "fill"))
        w, h = self._ARC_TABLE.get(mode, self._ARC_TABLE["fill"])
        lf = getattr(self, "_last_flip", (0, 0))
        res = await self._m_geom_set({"w": w, "h": h, "x": 0, "y": 0, "anchor": 0,
                                      "hflip": lf[0], "vflip": lf[1]})
        self.bus.publish({"jsonrpc": "2.0", "method": "arc.changed", "params": {"mode": mode}})
        return {"mode": mode, **res}

    async def _m_gamma_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Continuous gamma (0.1 steps). The firmware computes the curve on-device from
        gamma*10 (fixed-point, verified ≤1 LSB vs pow), so we send only the short value
        'O g <gamma*10>' — no bulk LUT transport. g<=0 or 1.0 → off/linear."""
        g = float(params.get("gamma", 1.0))
        gx10 = int(round(g * 10.0))
        if gx10 < 0:
            gx10 = 0
        self.uart.send_raw(f"O g {gx10}")
        self.bus.publish({"jsonrpc": "2.0", "method": "gamma.changed", "params": {"gamma": g}})
        return {"gamma": g}

    async def _m_colorspace_set(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Input colorspace override (parity 3.5). {range: 'full'|'limited'} via color_correct
        black/white preset ('C r 0|1'). YCbCr→RGB matrix decode is deferred (needs a YCbCr
        source to validate the TMDS lane order before shipping the coefficients)."""
        out: Dict[str, Any] = {}
        if "range" in params:
            r = 1 if str(params["range"]).lower().startswith("lim") else 0
            self.uart.send_raw(f"C r {r}")
            out["range"] = "limited" if r else "full"
        self.bus.publish({"jsonrpc": "2.0", "method": "colorspace.changed", "params": out})
        return out

    async def _m_profile_list(self, params: Dict[str, Any]) -> List[str]:
        return self.profiles.list()

    async def _m_profile_load(self, params: Dict[str, Any]) -> Dict[str, Any]:
        name = params["name"]
        prof = self.profiles.load(name)
        # Reject profiles whose catalog_version major differs from ours.
        # Minor mismatches still apply best-effort. See CATALOG-EVOLUTION.md.
        prof_v = prof.get("catalog_version", "0.0.0")
        try:
            prof_major = int(prof_v.split(".")[0])
            live_major = int(self.catalog.version.split(".")[0])
        except (ValueError, IndexError):
            prof_major = live_major = 0
        if prof_major != live_major:
            raise ValueError(
                f"catalog major-version mismatch: profile '{name}' authored "
                f"against catalog {prof_v}, daemon serving {self.catalog.version}")
        applied = []
        skipped = []
        for cid, value in prof.get("controls", {}).items():
            try:
                await self._m_control_set({"id": cid, "value": value})
                applied.append(cid)
            except Exception as e:
                log.warning("profile '%s': %s failed: %s", name, cid, e)
                skipped.append({"id": cid, "reason": str(e)})
        return {"name": name, "applied": applied, "skipped": skipped}

    async def _m_profile_save(self, params: Dict[str, Any]) -> Dict[str, Any]:
        name = params["name"]
        # If caller passed an explicit controls dict, save that. Otherwise read
        # back the current state of every settable control.
        if "controls" in params:
            controls = params["controls"]
        else:
            controls = {}
            for cid, ctl in self.catalog.controls.items():
                if ctl.read_only or ctl.type == "trigger":
                    continue
                try:
                    r = await self._m_control_get({"id": cid})
                    controls[cid] = r["value"]
                except Exception as e:
                    log.warning("profile.save: skipping %s (%s)", cid, e)
        profile = {
            "schema": "schindler-profile",
            "schema_version": "0.1.0",
            "catalog_version": self.catalog.version,
            "name": name,
            "controls": controls,
        }
        self.profiles.save(name, profile)
        return {"name": name, "saved": len(controls)}

    async def _m_system_metrics(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Daemon health: bus pub/drop counts + per-client queue depths.
        Useful when diagnosing whether a slow client is causing event drops."""
        return self.bus.metrics()

    async def _m_debug_dump(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """DDR framebuffer dump (scaler-testing instrument). Forwards to the
        firmware debug.dump J method with a long timeout — dumps stream ~10-20 KB
        of base64 over UART (1-4 s). Pass-through of {mode,slot,w,h,fmt,data}."""
        fw = await self.uart.request("debug.dump", params or {}, timeout=12.0)
        if "error" in fw:
            raise RuntimeError(f"firmware: {fw['error'].get('message', '?')}")
        return fw["result"]

    async def _m_status_snapshot(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Return the current value of every status field the daemon has seen.
        Clients call this after their UI has rendered so they can populate the
        status panel from cached state — works around the race between the WS
        connect-time snapshot replay (sent immediately) and the browser's
        catalog-render path (which takes ~100ms to populate its row table)."""
        if self.telemetry is None:
            return {}
        return dict(self.telemetry.last)


def _solve_homography(src, dst):
    """4-point DLT: 3x3 homography (i=1) mapping src[i]->dst[i] (each a 2-tuple). Returns [a..h] or None.
    Plain Gaussian elimination on the 8x8 system (no numpy)."""
    A, b = [], []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -x * u, -y * u]); b.append(float(u))
        A.append([0, 0, 0, x, y, 1, -x * v, -y * v]); b.append(float(v))
    n = 8
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(A[r][col]))
        if abs(A[piv][col]) < 1e-9:
            return None
        A[col], A[piv] = A[piv], A[col]; b[col], b[piv] = b[piv], b[col]
        pv = A[col][col]
        for j in range(col, n): A[col][j] /= pv
        b[col] /= pv
        for r in range(n):
            if r != col and A[r][col] != 0.0:
                f = A[r][col]
                for j in range(col, n): A[r][j] -= f * A[col][j]
                b[r] -= f * b[col]
    return b  # [a,b,c,d,e,f,g,h]


def _apply_homography(H, x, y):
    a, b, c, d, e, f, g, h = H
    w = g * x + h * y + 1.0
    if abs(w) < 1e-9:
        w = 1e-9
    return (a * x + b * y + c) / w, (d * x + e * y + f) / w


def _error(rid: Any, code: int, message: str) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


# ---------------------------------------------------------------------------
# WebSocket server
# ---------------------------------------------------------------------------

async def ws_handler(ws: "WebSocketServerProtocol", dispatcher: Dispatcher,
                     auth_token: Optional[str] = None) -> None:
    log.info("ws: client connected from %s", getattr(ws, "remote_address", "?"))

    # Auth handshake (Risk N1 prep). When auth_token is set, the first frame
    # MUST be a system.auth request with the matching token. Anything else
    # gets a -32001 "unauthorized" and the connection closes. Default is
    # None (disabled) — preserves today's localhost-only convenience.
    if auth_token is not None:
        try:
            first = await asyncio.wait_for(ws.recv(), timeout=5.0)
            req = json.loads(first)
            if (req.get("method") != "system.auth"
                    or req.get("params", {}).get("token") != auth_token):
                await ws.send(json.dumps(_error(req.get("id"), -32001,
                                                "unauthorized")))
                await ws.close()
                log.warning("ws: client failed auth from %s",
                            getattr(ws, "remote_address", "?"))
                return
            await ws.send(json.dumps({
                "jsonrpc": "2.0", "id": req.get("id"),
                "result": {"authorized": True},
            }))
        except (asyncio.TimeoutError, json.JSONDecodeError):
            await ws.close()
            return

    # Subscribe this client to the status bus. A background task drains the
    # queue and forwards each event as a JSON notification.
    addr = getattr(ws, "remote_address", None)
    label = f"{addr[0]}:{addr[1]}" if addr else "ws-client"
    sub = await dispatcher.bus.subscribe(label=label)
    push_task = asyncio.create_task(_drain_status_to_ws(sub.q, ws))
    # Replay last-known status snapshot so a fresh client doesn't have to
    # wait up to ~1s for the next DIAG line.
    try:
        for cid, val in list(dispatcher.telemetry.last.items()):
            await ws.send(json.dumps({
                "jsonrpc": "2.0",
                "method": "status.update",
                "params": {"id": cid, "value": val},
            }))
    except Exception:
        pass
    try:
        async for raw in ws:
            try:
                req = json.loads(raw)
            except json.JSONDecodeError:
                await ws.send(json.dumps(_error(None, -32700, "parse error")))
                continue
            resp = await dispatcher.handle(req)
            await ws.send(json.dumps(resp))
    except websockets.ConnectionClosed:
        pass
    finally:
        push_task.cancel()
        await dispatcher.bus.unsubscribe(sub)
        log.info("ws: client disconnected")


async def _drain_status_to_ws(q: asyncio.Queue, ws) -> None:
    try:
        while True:
            payload = await q.get()
            try:
                await ws.send(json.dumps(payload))
            except websockets.ConnectionClosed:
                return
    except asyncio.CancelledError:
        return


# ---------------------------------------------------------------------------
# Minimal HTTP static server (serves the web UI from ../web/)
# ---------------------------------------------------------------------------

async def http_handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
                       web_root: Path) -> None:
    try:
        request_line = await reader.readline()
        if not request_line:
            writer.close(); return
        parts = request_line.decode("ascii", "replace").split()
        if len(parts) < 2 or parts[0] != "GET":
            writer.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length:0\r\n\r\n")
            await writer.drain(); writer.close(); return
        path = parts[1]
        # Drain headers
        while True:
            line = await reader.readline()
            if line in (b"\r\n", b"\n", b""):
                break
        if path == "/" or path == "":
            path = "/index.html"
        # Strip leading slash, prevent traversal
        safe = path.lstrip("/").replace("..", "")
        f = web_root / safe
        if not f.is_file():
            body = b"<h1>404</h1>schindlerd: not found"
            writer.write(b"HTTP/1.1 404 Not Found\r\nContent-Type:text/html\r\n"
                         + f"Content-Length:{len(body)}\r\n\r\n".encode() + body)
        else:
            body = f.read_bytes()
            ctype = {
                ".html": "text/html",
                ".js":   "application/javascript",
                ".css":  "text/css",
                ".json": "application/json",
            }.get(f.suffix, "application/octet-stream")
            writer.write(b"HTTP/1.1 200 OK\r\n"
                         + f"Content-Type:{ctype}\r\nContent-Length:{len(body)}\r\n\r\n".encode()
                         + body)
        await writer.drain()
    except Exception as e:
        log.warning("http: %s", e)
    finally:
        try: writer.close()
        except Exception: pass


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def amain(args: argparse.Namespace) -> int:
    catalog_path = Path(args.catalog).resolve()
    if not catalog_path.is_file():
        log.error("catalog not found: %s", catalog_path)
        return 2
    catalog = Catalog.load(catalog_path)
    log.info("catalog: v%s with %d controls", catalog.version, len(catalog.controls))

    uart = UartBridge(args.port, args.baud)
    uart.start(asyncio.get_running_loop())

    bus = StatusBus()
    telemetry = TelemetryParser(bus)
    uart.text_log_handler = telemetry.feed

    profiles = ProfileStore(
        Path(args.profiles).expanduser(),
        readonly_roots=[Path(args.factory_profiles).resolve()] if args.factory_profiles else None,
    )
    dispatcher = Dispatcher(catalog, uart, profiles, bus)
    dispatcher.telemetry = telemetry  # exposed to ws_handler for snapshot replay

    web_root = Path(args.web).resolve() if args.web else None
    if web_root and not web_root.is_dir():
        log.warning("web root not found, HTTP disabled: %s", web_root)
        web_root = None

    auth_token = os.environ.get("SCHINDLERD_AUTH_TOKEN") or None
    if auth_token:
        log.info("ws: auth ENABLED (SCHINDLERD_AUTH_TOKEN set)")
    elif args.host != "127.0.0.1" and args.host != "localhost":
        log.warning("ws: binding non-loopback (%s) without auth — "
                    "Risk N1 release-gate. Set SCHINDLERD_AUTH_TOKEN.",
                    args.host)
    ws_server = await websockets.serve(
        lambda ws: ws_handler(ws, dispatcher, auth_token=auth_token),
        host=args.host, port=args.ws_port,
    )
    log.info("ws: serving on ws://%s:%d", args.host, args.ws_port)

    http_server = None
    if web_root:
        http_server = await asyncio.start_server(
            lambda r, w: http_handler(r, w, web_root),
            host=args.host, port=args.http_port,
        )
        log.info("http: serving %s on http://%s:%d", web_root, args.host, args.http_port)

    try:
        await asyncio.Future()  # run forever
    except (asyncio.CancelledError, KeyboardInterrupt):
        pass
    finally:
        uart.stop()
        ws_server.close()
        await ws_server.wait_closed()
        if http_server:
            http_server.close()
            await http_server.wait_closed()
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="schindlerd")
    p.add_argument("--port",      default="/dev/ttyUSB1", help="serial device")
    p.add_argument("--baud",      type=int, default=115200)
    p.add_argument("--catalog",   default=os.path.join(os.path.dirname(__file__),
                                                       "..", "catalog-v0.2.0.json"))
    p.add_argument("--profiles",  default="~/.schindler/profiles")
    p.add_argument("--factory-profiles",
                   default=os.path.join(os.path.dirname(__file__),
                                        "..", "profiles", "factory"),
                   help="read-only profile dir shipped with the daemon")
    p.add_argument("--host",      default="127.0.0.1")
    p.add_argument("--ws-port",   type=int, default=8081)
    p.add_argument("--http-port", type=int, default=8080)
    p.add_argument("--web",       default=os.path.join(os.path.dirname(__file__), "..", "web"))
    p.add_argument("-v", "--verbose", action="count", default=0)
    args = p.parse_args()
    level = logging.WARNING - 10 * args.verbose
    logging.basicConfig(level=max(level, logging.DEBUG),
                        format="%(asctime)s %(name)s %(levelname)s: %(message)s")
    try:
        return asyncio.run(amain(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
