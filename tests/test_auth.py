"""WS auth handshake — token-based, off by default."""
import asyncio
import json

import pytest
import websockets

from schindlerd import (
    Catalog, Dispatcher, ProfileStore, StatusBus, ws_handler
)


class FakeUart:
    async def request(self, method, params=None, timeout=1.5):
        return {"jsonrpc": "2.0", "id": 1, "result": {"ids": []}}


async def _setup_server(tmp_path, catalog_path, auth_token=None):
    cat = Catalog.load(catalog_path)
    bus = StatusBus()
    uart = FakeUart()
    profiles = ProfileStore(tmp_path / "user")
    d = Dispatcher(cat, uart, profiles, bus)

    class _FakeTel:
        last = {}
    d.telemetry = _FakeTel()

    server = await websockets.serve(
        lambda ws: ws_handler(ws, d, auth_token=auth_token),
        host="127.0.0.1", port=0,
    )
    port = server.sockets[0].getsockname()[1]
    return server, port


@pytest.mark.asyncio
async def test_no_auth_is_default(tmp_path, catalog_path):
    """Default behavior: no token = no handshake required."""
    server, port = await _setup_server(tmp_path, catalog_path, auth_token=None)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 1,
                                       "method": "system.identify"}))
            # Snapshot replay may come first; loop until our response
            for _ in range(10):
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=2.0))
                if msg.get("id") == 1:
                    assert "result" in msg
                    return
    finally:
        server.close()
        await server.wait_closed()


@pytest.mark.asyncio
async def test_correct_token_authorizes(tmp_path, catalog_path):
    server, port = await _setup_server(tmp_path, catalog_path,
                                        auth_token="hunter2")
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            # First frame must be system.auth
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 1,
                                       "method": "system.auth",
                                       "params": {"token": "hunter2"}}))
            resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=2.0))
            assert resp["result"]["authorized"] is True
            # Subsequent requests work
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 2,
                                       "method": "system.list_controls"}))
            for _ in range(10):
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=2.0))
                if msg.get("id") == 2:
                    return
            assert False, "no response to system.list_controls"
    finally:
        server.close()
        await server.wait_closed()


@pytest.mark.asyncio
async def test_wrong_token_rejected(tmp_path, catalog_path):
    server, port = await _setup_server(tmp_path, catalog_path,
                                        auth_token="hunter2")
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 1,
                                       "method": "system.auth",
                                       "params": {"token": "wrong"}}))
            resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=2.0))
            assert resp["error"]["code"] == -32001
            assert "unauthorized" in resp["error"]["message"]
    finally:
        server.close()
        await server.wait_closed()


@pytest.mark.asyncio
async def test_non_auth_first_frame_rejected(tmp_path, catalog_path):
    """A normal RPC as the first frame (skipping system.auth) is rejected."""
    server, port = await _setup_server(tmp_path, catalog_path,
                                        auth_token="hunter2")
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": 1,
                                       "method": "system.identify"}))
            resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=2.0))
            assert resp["error"]["code"] == -32001
    finally:
        server.close()
        await server.wait_closed()
