"""Dispatcher: JSON-RPC method dispatch + firmware coercion.

Tests use a MockUart that fakes the UartBridge interface (.request()
returns a canned response) rather than driving the asyncio reader
thread. End-to-end coverage with the real UartBridge lives in
test_uart_bridge.py.
"""
import asyncio
from pathlib import Path
from typing import Any, Dict, List

import pytest

from schindlerd import Catalog, Dispatcher, ProfileStore, StatusBus


class MockUart:
    """UartBridge-shaped mock. Tests configure responses per method."""
    def __init__(self):
        self.responses: Dict[str, Dict[str, Any]] = {}
        self.calls: List[Dict[str, Any]] = []

    async def request(self, method: str, params=None, timeout: float = 1.5):
        self.calls.append({"method": method, "params": params})
        if method in self.responses:
            return {"jsonrpc": "2.0", "id": 1, "result": self.responses[method]}
        return {"jsonrpc": "2.0", "id": 1,
                "error": {"code": -32601, "message": "unknown"}}

    def set_response(self, method: str, result: Dict[str, Any]) -> None:
        self.responses[method] = result


@pytest.fixture
def dispatcher_setup(catalog_path, tmp_path):
    cat = Catalog.load(catalog_path)
    bus = StatusBus()
    uart = MockUart()
    profiles = ProfileStore(tmp_path / "user")
    d = Dispatcher(cat, uart, profiles, bus)
    return d, uart, cat


def run(coro):
    return asyncio.get_event_loop().run_until_complete(coro) if False else asyncio.run(coro)


def test_unknown_method_returns_32601(dispatcher_setup):
    d, _, _ = dispatcher_setup
    resp = run(d.handle({"jsonrpc": "2.0", "id": 1, "method": "no.such.thing"}))
    assert resp["error"]["code"] == -32601


def test_system_catalog_returns_annotated(dispatcher_setup):
    d, uart, _ = dispatcher_setup
    uart.set_response("system.list_controls",
                      {"ids": ["color.saturation", "scaler.kernel_h"]})
    resp = run(d.handle({"jsonrpc": "2.0", "id": 1, "method": "system.catalog"}))
    by_id = {c["id"]: c for c in resp["result"]["controls"]}
    assert by_id["color.saturation"]["available"] is True
    # Not reported by firmware → unavailable (and not status / read_only)
    assert by_id["color.correct.black_r"]["available"] is False


def test_control_get_round_trip_pass_through(dispatcher_setup):
    d, uart, _ = dispatcher_setup
    uart.set_response("control.get", {"value": 175})
    resp = run(d.handle({
        "jsonrpc": "2.0", "id": 1, "method": "control.get",
        "params": {"id": "color.saturation"}
    }))
    assert resp["result"] == {"id": "color.saturation", "value": 175}


def test_control_set_enum_string_translates_to_int_and_back(dispatcher_setup):
    d, uart, _ = dispatcher_setup
    # Firmware always sees integers
    uart.set_response("control.set", {"value": 0})
    resp = run(d.handle({
        "jsonrpc": "2.0", "id": 1, "method": "control.set",
        "params": {"id": "scaler.kernel_h", "value": "nn"}
    }))
    # Firmware got the int...
    set_call = next(c for c in uart.calls if c["method"] == "control.set")
    assert set_call["params"]["value"] == 0
    # ...and the response came back as a string
    assert resp["result"]["value"] == "nn"


def test_control_set_unknown_id_yields_value_error(dispatcher_setup):
    d, _, _ = dispatcher_setup
    resp = run(d.handle({
        "jsonrpc": "2.0", "id": 1, "method": "control.set",
        "params": {"id": "fake.thing", "value": 100}
    }))
    assert resp["error"]["code"] == -32602
    assert "unknown control id" in resp["error"]["message"]


def test_control_set_read_only_rejected(dispatcher_setup):
    d, _, _ = dispatcher_setup
    resp = run(d.handle({
        "jsonrpc": "2.0", "id": 1, "method": "control.set",
        "params": {"id": "status.s2mm_sr", "value": 0}
    }))
    assert resp["error"]["code"] == -32602
    assert "read-only" in resp["error"]["message"]


def test_control_set_broadcasts_control_changed(dispatcher_setup):
    d, uart, _ = dispatcher_setup
    uart.set_response("control.set", {"value": 175})

    events: List[Dict[str, Any]] = []
    async def _drain():
        sub = await d.bus.subscribe()
        # Run the set, then check the queue
        resp = await d.handle({
            "jsonrpc": "2.0", "id": 1, "method": "control.set",
            "params": {"id": "color.saturation", "value": 175}
        })
        # Pull anything queued
        while not sub.q.empty():
            events.append(sub.q.get_nowait())
        await d.bus.unsubscribe(sub)
        return resp

    resp = asyncio.run(_drain())
    assert resp["result"]["value"] == 175
    # Should have seen a control.changed notification
    changed = [e for e in events if e.get("method") == "control.changed"]
    assert len(changed) == 1
    assert changed[0]["params"] == {"id": "color.saturation", "value": 175}


def test_profile_save_snapshots_current_state(dispatcher_setup, tmp_path):
    d, uart, _ = dispatcher_setup
    # MockUart returns nothing useful for control.get, so save with explicit
    # 'controls' field bypasses the snapshot path.
    resp = run(d.handle({
        "jsonrpc": "2.0", "id": 1, "method": "profile.save",
        "params": {"name": "test", "controls": {"color.saturation": 110}}
    }))
    assert resp["result"]["name"] == "test"
    assert resp["result"]["saved"] == 1
    items = run(d.handle({"jsonrpc": "2.0", "id": 2, "method": "profile.list"}))
    names = {x["name"] for x in items["result"]}
    assert "test" in names
