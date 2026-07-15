from __future__ import annotations

from uuid import UUID

from attune.hosted.dispatch_audit import DispatchBrokerAudit

DISPATCH = UUID("10000000-0000-4000-8000-000000000611")
AUDIT = UUID("10000000-0000-4000-8000-000000000612")


class Intents:
    def __init__(self, result=AUDIT):
        self.result = result
        self.calls = []

    def request(self, intent_id, **event):
        self.calls.append((intent_id, event))
        return self.result


class Writer:
    def __init__(self, result=True):
        self.result = result
        self.calls = []

    def write(self, intent_id):
        self.calls.append(intent_id)
        return self.result


def test_dispatch_audit_writes_only_canonical_derived_intent():
    intents, writer = Intents(), Writer()
    audit = DispatchBrokerAudit(intents, writer)
    assert audit.record(DISPATCH, outcome="failed", error_code="route_not_registered")
    assert intents.calls == [
        (
            DISPATCH,
            {"outcome": "failed", "error_code": "route_not_registered"},
        )
    ]
    assert writer.calls == [AUDIT]


def test_dispatch_audit_fails_when_no_canonical_intent_exists():
    writer = Writer()
    assert not DispatchBrokerAudit(Intents(None), writer).record(
        DISPATCH, outcome="allowed"
    )
    assert writer.calls == []
