# tests/

Pytest suite for the V0a daemon. Runs without bench hardware via a FakeSerial drop-in.

Audit context: Test Methodology re-audit (2026-05-31) flagged that the V0a stack shipped with zero automated tests on top of a daemon with no mock UART. This suite is the FakeSerial + pytest harness recommended as the single highest-leverage test investment.

## Install + run

```bash
python3 -m venv /tmp/schindlerd-venv
/tmp/schindlerd-venv/bin/pip install -r tests/requirements.txt
/tmp/schindlerd-venv/bin/pytest -c tests/pytest.ini
```

Or with the existing daemon venv:

```bash
/tmp/schindlerd-venv/bin/pip install pytest pytest-asyncio
/tmp/schindlerd-venv/bin/pytest -c tests/pytest.ini
```

## What's covered

| File | What it tests |
|---|---|
| `test_catalog.py` | Catalog load, enum/number/boolean coercion both directions, `annotated_raw` availability + placeholder gating + status-always-available |
| `test_telemetry.py` | TelemetryParser regex against captured DIAG/TELEMETRY/VTC_RX lines, dedup behavior, unknown-line tolerance, boot-only output_format detection |
| `test_profiles.py` | ProfileStore multi-root listing, user-shadows-factory load + list semantics, save-only-to-user, missing-name FileNotFoundError |
| `test_dispatcher.py` | JSON-RPC dispatch, enum string↔int translation across the boundary, read-only rejection, `control.changed` broadcast on set, profile.save round-trip |
| `test_uart_bridge.py` | End-to-end request/response over FakeSerial including the worker thread, text-log handler hook, concurrent request serialization, timeout behavior |

~25 tests across 5 files.

## FakeSerial

`tests/conftest.py` ships a pyserial-compatible drop-in. It accepts a per-line "request handler" callback that simulates the firmware:

```python
def my_firmware(line: bytes) -> bytes:
    req = json.loads(line[1:])  # strip 'J ' prefix
    return (json.dumps({"jsonrpc": "2.0", "id": req["id"],
                        "result": {"value": 42}}) + "\r\n").encode()

fake_serial.set_handler(my_firmware)
```

Plus `inject(data)` for spontaneous firmware prints (DIAG, TELEMETRY).

The `patch_pyserial` fixture monkeypatches `serial.Serial` so `UartBridge("/dev/fake")` transparently gets the FakeSerial. End-to-end tests use this; unit tests that don't need the wire layer use the `MockUart` shim in `test_dispatcher.py`.

## When this catches a bug

The most likely real-world catch: **firmware DIAG/TELEMETRY/VTC_RX print format drift**. The regexes in `TelemetryParser` are fragile against whitespace changes, field order, or bracket-content tweaks. `test_telemetry.py` exercises the exact captured strings — if firmware changes a print, the test fails at PR time instead of silently degrading the live status panel.

The next most likely: **catalog schema additions that the daemon doesn't handle**. The `test_catalog.py` enum/boolean coercion suite catches type-system mistakes (new enum value missing from a setter, etc.).

## Run a single test

```bash
/tmp/schindlerd-venv/bin/pytest -c tests/pytest.ini tests/test_telemetry.py::test_diag_line_extracts_sr_registers -v
```

## Future work

- Catalog schema JSON Schema validator + a `test_schema.py` that asserts every shipped catalog passes.
- Web UI smoke (Playwright headless against a FakeSerial-backed daemon).
- HDL sim wrappers under `make sim` that diff against golden artifacts — see Test Methodology re-audit verdict.
