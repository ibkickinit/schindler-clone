"""Shared pytest fixtures for the schindlerd test suite.

Key piece: FakeSerial. A pyserial-compatible drop-in that lets tests script
firmware responses without /dev/ttyUSB1. Used by test_uart_bridge.py and
test_dispatcher.py end-to-end paths.
"""
from __future__ import annotations

import json
import queue
import sys
import threading
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional

import pytest

# Make the daemon module importable from anywhere under tests/.
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "control-plane" / "schindlerd"))


class FakeSerial:
    """pyserial-compatible scriptable replacement.

    A 'request handler' callback receives each line of bytes written to the
    fake port and may push response bytes back for subsequent reads. This
    lets tests model the firmware: receive JSON-RPC requests, dispatch by
    method, produce JSON-RPC responses. Notification-style writes (e.g.
    spontaneous DIAG lines from a simulated firmware) can be queued before
    or during the test via inject().
    """

    def __init__(self, port: str = "/dev/fake", baudrate: int = 115200,
                 timeout: float = 0.1):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self._tx_buffer: bytearray = bytearray()    # bytes written by test sub.
        self._rx_queue: queue.Queue[bytes] = queue.Queue()
        self._rx_pending: bytes = b""
        self._handler: Optional[Callable[[bytes], Optional[bytes]]] = None
        self._open = True
        self._lock = threading.Lock()

    # ---- pyserial-compatible API ----
    def write(self, data: bytes) -> int:
        if not self._open:
            raise RuntimeError("port closed")
        with self._lock:
            self._tx_buffer.extend(data)
            # Split on newline; each complete line goes to the handler.
            while b"\n" in self._tx_buffer:
                line, _, rest = self._tx_buffer.partition(b"\n")
                self._tx_buffer = bytearray(rest)
                if self._handler:
                    resp = self._handler(bytes(line))
                    if resp:
                        self._rx_queue.put(resp)
        return len(data)

    def read(self, size: int) -> bytes:
        if not self._open:
            raise RuntimeError("port closed")
        deadline = time.monotonic() + self.timeout
        while not self._rx_pending and time.monotonic() < deadline:
            try:
                self._rx_pending = self._rx_queue.get(timeout=0.01)
            except queue.Empty:
                pass
        if not self._rx_pending:
            return b""
        out = self._rx_pending[:size]
        self._rx_pending = self._rx_pending[size:]
        return out

    def reset_input_buffer(self) -> None:
        self._rx_pending = b""
        while True:
            try:
                self._rx_queue.get_nowait()
            except queue.Empty:
                break

    def close(self) -> None:
        self._open = False

    # ---- test-facing helpers ----
    def set_handler(self, handler: Callable[[bytes], Optional[bytes]]) -> None:
        """Install the per-line response producer."""
        self._handler = handler

    def inject(self, data: bytes) -> None:
        """Spontaneously enqueue bytes for the next read — simulates an
        unsolicited firmware print like a DIAG/TELEMETRY line."""
        self._rx_queue.put(data)


# ---------------------------------------------------------------------------
# Standard test fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def fake_serial() -> FakeSerial:
    """Bare FakeSerial. Tests install a handler if they need request/response."""
    return FakeSerial()


@pytest.fixture
def patch_pyserial(monkeypatch, fake_serial):
    """Replace `serial.Serial(...)` with a constructor that returns our fake.
    Use in tests that construct a UartBridge — the bridge's serial.Serial(...)
    call will get the fake."""
    import serial

    def fake_ctor(port: str, baudrate: int = 115200, timeout: float = 0.1):
        fake_serial.port = port
        fake_serial.baudrate = baudrate
        fake_serial.timeout = timeout
        return fake_serial

    monkeypatch.setattr(serial, "Serial", fake_ctor)
    return fake_serial


@pytest.fixture
def catalog_path() -> Path:
    """Path to the live catalog file. Most tests use this; if you need a
    smaller catalog, create one inline via tmp_path."""
    p = REPO_ROOT / "control-plane" / "catalog-v0.2.0.json"
    if not p.is_file():
        pytest.skip(f"catalog not found at {p}")
    return p


@pytest.fixture
def firmware_responder():
    """A simple scripted firmware-mock for the FakeSerial handler. Returns
    a dict-keyed dispatch table; tests register handlers by method name
    and the responder turns each JSON-RPC line into the right response.
    """
    handlers: Dict[str, Callable[[dict], dict]] = {}

    def handler(line: bytes) -> Optional[bytes]:
        text = line.decode("ascii", "replace").strip()
        # 'J ' command brackets the JSON
        if not text.startswith("J"):
            return None
        payload = text[1:].strip()
        try:
            req = json.loads(payload)
        except json.JSONDecodeError:
            return None
        method = req.get("method")
        rid = req.get("id")
        if method not in handlers:
            err = {"jsonrpc": "2.0", "id": rid,
                   "error": {"code": -32601, "message": "unknown method"}}
            return (json.dumps(err) + "\r\n").encode()
        result = handlers[method](req)
        if "error" in result:
            return (json.dumps({"jsonrpc": "2.0", "id": rid, **result}) + "\r\n").encode()
        return (json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\r\n").encode()

    class Responder:
        def __init__(self):
            self.handler = handler
            self.handlers = handlers
        def register(self, method: str, fn: Callable[[dict], dict]) -> None:
            handlers[method] = fn

    return Responder()
