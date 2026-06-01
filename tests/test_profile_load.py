"""Profile load: major-version mismatch reject; minor tolerated."""
import asyncio
import json
from pathlib import Path

import pytest

from schindlerd import Catalog, Dispatcher, ProfileStore, StatusBus


class MockUart:
    async def request(self, method, params=None, timeout=1.5):
        if method == "control.set":
            return {"jsonrpc": "2.0", "id": 1,
                    "result": {"value": params["value"]}}
        return {"jsonrpc": "2.0", "id": 1, "result": {"ids": []}}


@pytest.fixture
def dispatcher(catalog_path, tmp_path):
    cat = Catalog.load(catalog_path)
    bus = StatusBus()
    profiles = ProfileStore(tmp_path / "user")
    return Dispatcher(cat, MockUart(), profiles, bus)


def run(coro):
    return asyncio.run(coro)


def _write(path: Path, name: str, catalog_version: str, controls: dict):
    path.write_text(json.dumps({
        "schema": "schindler-profile",
        "schema_version": "0.1.0",
        "catalog_version": catalog_version,
        "name": name,
        "controls": controls,
    }))


def test_minor_mismatch_tolerated(dispatcher, tmp_path):
    """v0.1.0 profile against v0.2.0 catalog applies best-effort."""
    _write(tmp_path / "user" / "old.json", "old", "0.1.0",
           {"color.saturation": 100})
    resp = run(dispatcher.handle({
        "jsonrpc": "2.0", "id": 1, "method": "profile.load",
        "params": {"name": "old"}
    }))
    assert "error" not in resp
    assert "color.saturation" in resp["result"]["applied"]


def test_major_mismatch_rejected(dispatcher, tmp_path):
    """A v1.0.0 profile against the v0.2.0 catalog is refused."""
    _write(tmp_path / "user" / "future.json", "future", "1.0.0",
           {"color.saturation": 100})
    resp = run(dispatcher.handle({
        "jsonrpc": "2.0", "id": 1, "method": "profile.load",
        "params": {"name": "future"}
    }))
    assert resp["error"]["code"] == -32602
    assert "major-version mismatch" in resp["error"]["message"]


def test_load_reports_skipped_controls(dispatcher, tmp_path):
    """Unknown control ids in a v0.x profile are reported in 'skipped'."""
    _write(tmp_path / "user" / "stale.json", "stale", "0.2.0",
           {"color.saturation": 100, "not.a.real.control": 42})
    resp = run(dispatcher.handle({
        "jsonrpc": "2.0", "id": 1, "method": "profile.load",
        "params": {"name": "stale"}
    }))
    assert "color.saturation" in resp["result"]["applied"]
    skipped_ids = [s["id"] for s in resp["result"]["skipped"]]
    assert "not.a.real.control" in skipped_ids
