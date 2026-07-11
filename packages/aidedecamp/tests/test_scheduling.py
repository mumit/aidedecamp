"""Tests for orchestrator/scheduling.py — no live connector, a FakeConnector
stands in.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from aidedecamp.connectors.base import CalendarEvent
from aidedecamp.orchestrator.scheduling import ConflictResult, detect_conflict


class _FakeConnector:
    def __init__(self, events: list[CalendarEvent]):
        self._events = events

    def list_events(self, *, time_min, time_max):
        return self._events


def _event(event_id, start_offset_min, duration_min=30, summary="Meeting"):
    base = datetime(2026, 7, 10, 9, 0, tzinfo=timezone.utc)
    start = base + timedelta(minutes=start_offset_min)
    end = start + timedelta(minutes=duration_min)
    return CalendarEvent(event_id=event_id, summary=summary, start=start, end=end)


# ---------------------------------------------------------------------------
# detect_conflict — no conflict
# ---------------------------------------------------------------------------


def test_no_conflict_when_alone():
    event = _event("e1", 0)
    conn = _FakeConnector([event])
    assert detect_conflict(conn, event) is None


def test_no_conflict_when_adjacent_not_overlapping():
    event = _event("e1", 0, duration_min=30)  # 09:00-09:30
    other = _event("e2", 30, duration_min=30)  # 09:30-10:00, back-to-back
    conn = _FakeConnector([event, other])
    assert detect_conflict(conn, event) is None


def test_excludes_itself_from_conflict_check():
    event = _event("e1", 0)
    conn = _FakeConnector([event])  # only itself in the window
    assert detect_conflict(conn, event) is None


# ---------------------------------------------------------------------------
# detect_conflict — conflict found
# ---------------------------------------------------------------------------


def test_conflict_detected_on_full_overlap():
    event = _event("e1", 0, duration_min=60, summary="Client call")
    other = _event("e2", 15, duration_min=30, summary="Standup")
    conn = _FakeConnector([event, other])

    result = detect_conflict(conn, event)

    assert isinstance(result, ConflictResult)
    assert result.event.event_id == "e1"
    assert result.conflicting_with.event_id == "e2"


def test_conflict_detected_on_partial_overlap():
    event = _event("e1", 0, duration_min=30)   # 09:00-09:30
    other = _event("e2", 15, duration_min=30)  # 09:15-09:45
    conn = _FakeConnector([event, other])

    result = detect_conflict(conn, event)

    assert result is not None
    assert result.conflicting_with.event_id == "e2"


def test_conflict_result_carries_both_events():
    event = _event("e1", 0, summary="1:1 with Priya")
    other = _event("e2", 0, summary="All-hands")
    conn = _FakeConnector([event, other])

    result = detect_conflict(conn, event)

    assert result.event.summary == "1:1 with Priya"
    assert result.conflicting_with.summary == "All-hands"


def test_returns_first_conflict_when_multiple_overlaps():
    event = _event("e1", 0, duration_min=60)
    other1 = _event("e2", 10, duration_min=10)
    other2 = _event("e3", 20, duration_min=10)
    conn = _FakeConnector([event, other1, other2])

    result = detect_conflict(conn, event)

    assert result.conflicting_with.event_id == "e2"


# ---------------------------------------------------------------------------
# detect_conflict — window passed to list_events
# ---------------------------------------------------------------------------


def test_uses_event_start_and_end_as_window():
    calls = []

    class _RecordingConnector:
        def list_events(self, *, time_min, time_max):
            calls.append((time_min, time_max))
            return []

    event = _event("e1", 0, duration_min=45)
    detect_conflict(_RecordingConnector(), event)

    assert calls == [(event.start, event.end)]
