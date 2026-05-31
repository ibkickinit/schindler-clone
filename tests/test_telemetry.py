"""TelemetryParser: regex match against real captured firmware lines.

These tests are the safety net against firmware print-format drift.
When the firmware DIAG layout changes, one of these will break and we
can update the parser at the same PR.
"""
import asyncio
from collections import defaultdict
from typing import Any, Dict, List

import pytest

from schindlerd import StatusBus, TelemetryParser


class CapturingBus:
    """Test-only StatusBus replacement that records publish() calls."""
    def __init__(self):
        self.events: List[Dict[str, Any]] = []

    def publish(self, payload: Dict[str, Any]) -> None:
        self.events.append(payload["params"])


@pytest.fixture
def parser():
    bus = CapturingBus()
    return TelemetryParser(bus), bus


def test_diag_line_extracts_sr_registers(parser):
    p, bus = parser
    line = ("DIAG: h_in=1080 v_in=1080 v_emit=720 v_out_tlast=720  "
            "S2MM_SR=0x00011810[FrmCnt  frmcnt=1] MM2S_SR=0x00011000[FrmCnt  frmcnt=1]  "
            "RDSTORE=1 WRSTORE=0  src=61 out=60")
    p.feed(line)
    by_id = {e["id"]: e["value"] for e in bus.events}
    assert by_id["status.s2mm_sr"] == 0x00011810
    assert by_id["status.mm2s_sr"] == 0x00011000
    assert by_id["status.source_lock"] is True
    assert by_id["status.source_rate_hz"] == 61
    assert by_id["status.output_rate_hz"] == 60


def test_telemetry_line_extracts_rate_and_regime(parser):
    p, bus = parser
    line = "TELEMETRY: src=60.895 Hz -> regime 0 [60p->60p (1:1 pass-through)]"
    p.feed(line)
    by_id = {e["id"]: e["value"] for e in bus.events}
    assert by_id["status.source_rate_hz"] == 60.895
    assert by_id["status.regime"] == "60p->60p (1:1 pass-through)"


def test_vtc_rx_line_extracts_source_format(parser):
    p, bus = parser
    line = "VTC_RX: HACTIVE=1920 VACTIVE=1080 HTOTAL=2200 VTOTAL=1125 DPOL=0x1F"
    p.feed(line)
    by_id = {e["id"]: e["value"] for e in bus.events}
    assert by_id["status.source_format"] == "1920x1080"
    assert by_id["status.source_lock"] is True


def test_dedup_does_not_republish_same_value(parser):
    p, bus = parser
    line = ("DIAG: h_in=1080 v_in=1080 v_emit=720 v_out_tlast=720  "
            "S2MM_SR=0x00011810[FrmCnt  frmcnt=1] MM2S_SR=0x00011000[FrmCnt  frmcnt=1]  "
            "RDSTORE=1 WRSTORE=0  src=60 out=60")
    p.feed(line)
    n1 = len(bus.events)
    p.feed(line)
    p.feed(line)
    n3 = len(bus.events)
    # Repeated identical DIAG lines should produce zero new publishes.
    assert n1 == n3


def test_dedup_republishes_when_value_changes(parser):
    p, bus = parser
    base = ("DIAG: h_in=1080 v_in=1080 v_emit=720 v_out_tlast=720  "
            "S2MM_SR=0x{sr:08x}[FrmCnt  frmcnt=1] MM2S_SR=0x00011000[FrmCnt  frmcnt=1]  "
            "RDSTORE=1 WRSTORE=0  src=60 out=60")
    p.feed(base.format(sr=0x11810))
    n1 = len(bus.events)
    p.feed(base.format(sr=0x19810))  # different S2MM_SR
    n2 = len(bus.events)
    assert n2 > n1
    # Exactly one new s2mm_sr event
    sr_events = [e for e in bus.events if e["id"] == "status.s2mm_sr"]
    assert len(sr_events) == 2
    assert sr_events[-1]["value"] == 0x19810


def test_unknown_line_tolerated(parser):
    p, bus = parser
    p.feed("VDMA running — S2MM + MM2S enabled, 5-frame ring")
    p.feed("Pipeline live — entering diag loop (1 sec/dump)")
    p.feed("")  # empty line
    # No publishes, no exception.
    assert bus.events == []


def test_output_format_detected_from_boot_line(parser):
    p, bus = parser
    p.feed("VTC: configuring 720p60 (HTOTAL=1650 VTOTAL=750)")
    by_id = {e["id"]: e["value"] for e in bus.events}
    assert by_id["status.output_format"] == "720p60"


def test_locked_line_marks_source_lock(parser):
    p, bus = parser
    p.feed("VTC_RX: dvi2rgb pLocked stable, enabling detector")
    by_id = {e["id"]: e["value"] for e in bus.events}
    assert by_id["status.source_lock"] is True
