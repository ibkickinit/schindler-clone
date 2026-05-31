"""UartBridge end-to-end via FakeSerial.

Exercises the worker thread + line parsing + JSON-RPC round-trip without
needing /dev/ttyUSB1.
"""
import asyncio
import json
import threading
import time

import pytest

from schindlerd import UartBridge


@pytest.mark.asyncio
async def test_request_response_roundtrip(patch_pyserial, firmware_responder):
    firmware_responder.register(
        "system.identify",
        lambda req: {"model": "Schindler 2.0 Phase B",
                     "fw": "iter5-1080p-clean",
                     "catalog": "0.2.0"})
    patch_pyserial.set_handler(firmware_responder.handler)

    bridge = UartBridge("/dev/fake", baud=115200)
    bridge.start(asyncio.get_event_loop())
    try:
        resp = await bridge.request("system.identify", timeout=2.0)
    finally:
        bridge.stop()
    assert resp["result"]["catalog"] == "0.2.0"


@pytest.mark.asyncio
async def test_text_log_handler_receives_diag(patch_pyserial):
    captured = []
    bridge = UartBridge("/dev/fake", baud=115200)
    bridge.text_log_handler = captured.append
    bridge.start(asyncio.get_event_loop())
    try:
        # Inject an unsolicited DIAG line — should land in the text handler
        patch_pyserial.inject(b"DIAG: hello world\r\n")
        # Give the reader thread a chance + asyncio scheduler time
        await asyncio.sleep(0.3)
    finally:
        bridge.stop()
    assert any("DIAG: hello world" in line for line in captured)


@pytest.mark.asyncio
async def test_concurrent_requests_serialize_correctly(patch_pyserial,
                                                       firmware_responder):
    counter = {"n": 0}
    def handler(req):
        counter["n"] += 1
        return {"value": counter["n"]}
    firmware_responder.register("control.get", handler)
    patch_pyserial.set_handler(firmware_responder.handler)

    bridge = UartBridge("/dev/fake", baud=115200)
    bridge.start(asyncio.get_event_loop())
    try:
        # Fire 5 requests in parallel
        tasks = [bridge.request("control.get", {"id": f"x{i}"}, timeout=2.0)
                 for i in range(5)]
        responses = await asyncio.gather(*tasks)
    finally:
        bridge.stop()
    values = sorted(r["result"]["value"] for r in responses)
    assert values == [1, 2, 3, 4, 5]


@pytest.mark.asyncio
async def test_request_timeout_when_no_response(patch_pyserial):
    # No handler registered → firmware mock won't respond
    bridge = UartBridge("/dev/fake", baud=115200)
    bridge.start(asyncio.get_event_loop())
    try:
        with pytest.raises(asyncio.TimeoutError):
            await bridge.request("system.identify", timeout=0.3)
    finally:
        bridge.stop()
