#!/usr/bin/env python3
"""schindlerd — V0a host-side bridge daemon for Schindler 2.0 control plane.

Bridges:
  - Bare-metal firmware over /dev/ttyUSB1 (JSON-RPC via the 'J' UART command)
  - Web UI / future remote surfaces over WebSocket on :8080

Single-file v0.1 skeleton. Refactor into a package when it grows past ~600 LOC.

Dependencies: pyserial, websockets. Install:
    pip install pyserial websockets

Run:
    python schindlerd.py --port /dev/ttyUSB1 --catalog ../catalog-v0.1.0.json

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

    @classmethod
    def load(cls, path: Path) -> "Catalog":
        raw = json.loads(path.read_text())
        controls = {}
        for c in raw.get("controls", []):
            controls[c["id"]] = CatalogControl.from_json(c)
        return cls(version=raw.get("schema_version", "0.0.0"), controls=controls, raw=raw)


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
                    # Mirror firmware human-readable text to our own log.
                    log.debug("uart-log: %s", line.decode("utf-8", "replace"))

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


# ---------------------------------------------------------------------------
# Profile store — JSON files in ~/.schindler/profiles/
# ---------------------------------------------------------------------------

class ProfileStore:
    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)

    def list(self) -> List[str]:
        return sorted(p.stem for p in self.root.glob("*.json"))

    def load(self, name: str) -> Dict[str, Any]:
        return json.loads((self.root / f"{name}.json").read_text())

    def save(self, name: str, profile: Dict[str, Any]) -> None:
        (self.root / f"{name}.json").write_text(json.dumps(profile, indent=2))


# ---------------------------------------------------------------------------
# JSON-RPC dispatcher — handles methods coming from WebSocket clients
# ---------------------------------------------------------------------------

class Dispatcher:
    def __init__(self, catalog: Catalog, uart: UartBridge, profiles: ProfileStore):
        self.catalog = catalog
        self.uart = uart
        self.profiles = profiles
        self.methods: Dict[str, Callable[[Dict[str, Any]], Awaitable[Any]]] = {
            "system.identify":      self._m_identify,
            "system.catalog":       self._m_catalog,
            "system.list_controls": self._m_list_controls,
            "control.get":          self._m_control_get,
            "control.set":          self._m_control_set,
            "profile.list":         self._m_profile_list,
            "profile.load":         self._m_profile_load,
            "profile.save":         self._m_profile_save,
        }

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
        return self.catalog.raw

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
        return {"id": cid, "value": ctl.coerce_from_firmware(raw_val)}

    async def _m_profile_list(self, params: Dict[str, Any]) -> List[str]:
        return self.profiles.list()

    async def _m_profile_load(self, params: Dict[str, Any]) -> Dict[str, Any]:
        name = params["name"]
        prof = self.profiles.load(name)
        applied = []
        for cid, value in prof.get("controls", {}).items():
            try:
                await self._m_control_set({"id": cid, "value": value})
                applied.append(cid)
            except Exception as e:
                log.warning("profile '%s': %s failed: %s", name, cid, e)
        return {"name": name, "applied": applied}

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


def _error(rid: Any, code: int, message: str) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


# ---------------------------------------------------------------------------
# WebSocket server
# ---------------------------------------------------------------------------

async def ws_handler(ws: "WebSocketServerProtocol", dispatcher: Dispatcher) -> None:
    log.info("ws: client connected from %s", getattr(ws, "remote_address", "?"))
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
        log.info("ws: client disconnected")


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

    profiles = ProfileStore(Path(args.profiles).expanduser())
    dispatcher = Dispatcher(catalog, uart, profiles)

    web_root = Path(args.web).resolve() if args.web else None
    if web_root and not web_root.is_dir():
        log.warning("web root not found, HTTP disabled: %s", web_root)
        web_root = None

    ws_server = await websockets.serve(
        lambda ws: ws_handler(ws, dispatcher),
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
                                                       "..", "catalog-v0.1.0.json"))
    p.add_argument("--profiles",  default="~/.schindler/profiles")
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
