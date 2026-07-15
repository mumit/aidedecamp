from __future__ import annotations

from uuid import UUID

import pytest

flask = pytest.importorskip("flask")

from attune.hosted.audit_service import create_app

INTENT_ID = UUID("a0000000-0000-4000-8000-000000000091")
EVENT_ID = UUID("b0000000-0000-4000-8000-000000000092")


class Writer:
    def __init__(self, result=EVENT_ID, error=None):
        self.result = result
        self.error = error
        self.calls = []

    def write(self, intent_id):
        self.calls.append(intent_id)
        if self.error:
            raise self.error
        return self.result


def test_writer_accepts_only_exact_canonical_intent_envelope():
    writer = Writer()
    client = create_app(writer).test_client()

    response = client.post(
        "/v1/audit-intents/write",
        json={"audit_intent_id": str(INTENT_ID)},
    )
    assert response.status_code == 200
    assert response.get_json() == {
        "status": "written",
        "audit_event_id": str(EVENT_ID),
    }
    assert writer.calls == [INTENT_ID]

    for body in (
        {},
        {"audit_intent_id": str(INTENT_ID), "tenant_id": str(INTENT_ID)},
        {"audit_intent_id": str(INTENT_ID).upper()},
        {"audit_intent_id": "not-a-uuid"},
    ):
        assert client.post("/v1/audit-intents/write", json=body).status_code == 400
    assert writer.calls == [INTENT_ID]


def test_writer_fails_closed_without_leaking_exception_details():
    missing = create_app(Writer(result=None)).test_client().post(
        "/v1/audit-intents/write", json={"audit_intent_id": str(INTENT_ID)}
    )
    assert missing.status_code == 404

    unavailable = create_app(Writer(error=RuntimeError("secret detail"))).test_client()
    response = unavailable.post(
        "/v1/audit-intents/write", json={"audit_intent_id": str(INTENT_ID)}
    )
    assert response.status_code == 503
    assert b"secret detail" not in response.data
