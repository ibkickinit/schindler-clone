"""StatusBus: pub/sub semantics + drop tracking + metrics."""
import asyncio
import pytest

from schindlerd import StatusBus, Subscriber


@pytest.mark.asyncio
async def test_publish_reaches_all_subscribers():
    bus = StatusBus()
    a = await bus.subscribe("a")
    b = await bus.subscribe("b")
    bus.publish({"jsonrpc": "2.0", "method": "status.update", "params": {"id": "x", "value": 1}})
    assert a.q.qsize() == 1
    assert b.q.qsize() == 1


@pytest.mark.asyncio
async def test_unsubscribe_stops_delivery():
    bus = StatusBus()
    a = await bus.subscribe()
    await bus.unsubscribe(a)
    bus.publish({"method": "status.update"})
    assert a.q.qsize() == 0


@pytest.mark.asyncio
async def test_full_queue_drops_event_and_counts():
    bus = StatusBus()
    sub = await bus.subscribe()
    # Fill the queue
    for i in range(70):  # > maxsize=64
        bus.publish({"i": i})
    assert sub.dropped > 0
    assert sub.published == 64
    assert bus.total_dropped == sub.dropped
    assert bus.total_published == 70


@pytest.mark.asyncio
async def test_consecutive_drop_resets_after_successful_publish():
    bus = StatusBus()
    sub = await bus.subscribe()
    for _ in range(70):
        bus.publish({})
    assert sub.consecutive_drops > 0
    # Drain one slot
    sub.q.get_nowait()
    bus.publish({})
    assert sub.consecutive_drops == 0


@pytest.mark.asyncio
async def test_metrics_reports_per_client_state():
    bus = StatusBus()
    a = await bus.subscribe("aaa")
    b = await bus.subscribe("bbb")
    bus.publish({})
    bus.publish({})
    m = bus.metrics()
    assert m["total_published"] == 2
    assert m["total_dropped"] == 0
    labels = {s["label"] for s in m["subscribers"]}
    assert labels == {"aaa", "bbb"}


@pytest.mark.asyncio
async def test_drop_warning_threshold_uses_consecutive_count(caplog):
    """The DROP_WARN_THRESHOLD warning should fire exactly once per streak."""
    import logging
    caplog.set_level(logging.WARNING)
    bus = StatusBus()
    sub = await bus.subscribe("slow-client")
    # Push enough to trigger the threshold (64 fill + threshold drops)
    for _ in range(64 + StatusBus.DROP_WARN_THRESHOLD + 5):
        bus.publish({})
    warns = [r for r in caplog.records if "dropped" in r.message]
    assert len(warns) == 1
    assert "slow-client" in warns[0].message
