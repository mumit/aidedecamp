"""Scheduling conflict detection (design doc 1.2, 1.4, 4.2).

Design 4.2 calls out "a scheduling graph" as one of the small, single-purpose
graphs. What's built here is deliberately narrower than that name implies —
same reasoning as `triage.py`/`brief.py`: this is read-only, rung-1
"communicate" behavior (design 1.4's own example: "a heads-up that two
meetings just collided"), with no human-in-the-loop interrupt to checkpoint
around, so a plain function is the simplest thing that satisfies it.

What's NOT built: an action layer that actually creates holds, or responds to
invites (accept/decline/propose-new-time). The connector interface only
exposes `create_hold` (create a NEW tentative event) — there's no
accept/decline-an-existing-invite verb, and no well-defined trigger yet for
"draft a scheduling proposal" the way an incoming email is the trigger for
draft-and-approve. Building that out is real, but separate, design work: it
needs its own decision about what triggers it and how it fits the autonomy
ladder (rule 3) — not something to fold in unreviewed alongside conflict
detection. See `docs/decisions.md`.
"""

from __future__ import annotations

from dataclasses import dataclass

from ..connectors.base import CalendarEvent, WorkspaceConnector


@dataclass
class ConflictResult:
    event: CalendarEvent
    conflicting_with: CalendarEvent


def detect_conflict(
    connector: WorkspaceConnector, event: CalendarEvent
) -> ConflictResult | None:
    """Check whether ``event`` overlaps in time with any other event on the
    same calendar.

    ``list_events`` is scoped to the deployment's own calendar, so any two
    overlapping events returned by it are inherently a conflict for that
    person — no cross-calendar reasoning needed. Returns ``None`` when no
    conflict is found (including when ``event`` itself is the only thing in
    the window).
    """
    nearby = connector.list_events(time_min=event.start, time_max=event.end)
    for other in nearby:
        if other.event_id == event.event_id:
            continue
        if _overlaps(event, other):
            return ConflictResult(event=event, conflicting_with=other)
    return None


def _overlaps(a: CalendarEvent, b: CalendarEvent) -> bool:
    return a.start < b.end and b.start < a.end
