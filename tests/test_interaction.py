"""Bounded natural-language interaction planning."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from attune.interaction import InteractionIntent, plan_interaction


class _Client:
    def __init__(self, reply: str | None = None, error: Exception | None = None):
        self.reply = reply
        self.error = error

    def chat_completions_create(self, **kwargs):
        if self.error:
            raise self.error

        class _Message:
            content = self.reply

        class _Choice:
            message = _Message()

        class _Response:
            choices = [_Choice()]

        return _Response()


def test_planner_builds_gmail_query():
    client = _Client(
        "INTENT: MAIL\n"
        "GMAIL_QUERY: is:unread from:sarah@example.com newer_than:14d\n"
        "START: NONE\nEND: NONE"
    )

    plan = plan_interaction(client, "Did Sarah reply?", timezone_name="UTC")

    assert plan.intent == InteractionIntent.MAIL
    assert plan.gmail_query == "is:unread from:sarah@example.com newer_than:14d"


def test_planner_resolves_calendar_window():
    client = _Client(
        "INTENT: CALENDAR\nGMAIL_QUERY: NONE\n"
        "START: 2026-07-15T05:00:00-07:00\n"
        "END: 2026-07-15T12:00:00-07:00"
    )

    plan = plan_interaction(
        client,
        "What is on tomorrow morning?",
        timezone_name="America/Vancouver",
        now=datetime(2026, 7, 14, 9, tzinfo=timezone(timedelta(hours=-7))),
    )

    assert plan.intent == InteractionIntent.CALENDAR
    assert plan.start.isoformat() == "2026-07-15T05:00:00-07:00"
    assert plan.end.isoformat() == "2026-07-15T12:00:00-07:00"


def test_calendar_window_is_capped_at_31_days():
    client = _Client(
        "INTENT: CALENDAR\nGMAIL_QUERY: NONE\n"
        "START: 2026-07-01T00:00:00Z\nEND: 2027-07-01T00:00:00Z"
    )

    plan = plan_interaction(client, "Show the year", timezone_name="UTC")

    assert plan.end - plan.start == timedelta(days=31)


def test_malformed_response_falls_back_to_natural_overview_phrase():
    plan = plan_interaction(
        _Client("not a plan"),
        "Anything new to report?",
        timezone_name="UTC",
    )

    assert plan.intent == InteractionIntent.BRIEF


def test_obvious_live_read_overrides_model_general_classification():
    plan = plan_interaction(
        _Client(
            "INTENT: GENERAL\nGMAIL_QUERY: NONE\nSTART: NONE\nEND: NONE"
        ),
        "Anything new to report?",
        timezone_name="UTC",
    )

    assert plan.intent == InteractionIntent.BRIEF


def test_malformed_response_still_routes_tomorrow_morning_to_calendar():
    plan = plan_interaction(
        _Client("not a plan"),
        "What do I have tomorrow morning?",
        timezone_name="America/Vancouver",
        now=datetime(2026, 7, 14, 9, tzinfo=timezone(timedelta(hours=-7))),
    )

    assert plan.intent == InteractionIntent.CALENDAR
    assert plan.start.hour == 5
    assert plan.end.hour == 12


def test_planner_failure_falls_back_to_live_mail_read():
    plan = plan_interaction(
        _Client(error=RuntimeError("offline")),
        "Any unread email?",
        timezone_name="UTC",
    )

    assert plan.intent == InteractionIntent.MAIL
    assert plan.gmail_query == "is:unread newer_than:7d"


def test_imperative_mutation_fallback_is_write_not_read():
    plan = plan_interaction(
        _Client("malformed"),
        "Move tomorrow's meeting to 3pm",
        timezone_name="UTC",
    )

    assert plan.intent == InteractionIntent.WRITE


def test_imperative_mutation_cannot_be_downgraded_to_read_by_model():
    plan = plan_interaction(
        _Client(
            "INTENT: CALENDAR\nGMAIL_QUERY: NONE\n"
            "START: 2026-07-15T00:00:00Z\nEND: 2026-07-16T00:00:00Z"
        ),
        "Move tomorrow's meeting to 3pm",
        timezone_name="UTC",
    )

    assert plan.intent == InteractionIntent.WRITE
