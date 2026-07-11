"""Tests for the Calendar webhook republisher.

No live Flask server, no live GCP — Flask's test client plus an injected fake
publisher (mirroring the aidedecamp package's own convention of injecting
every collaborator so nothing here needs live credentials to test).

Run with: pip install -r requirements.txt pytest && pytest test_main.py
(Not part of the main `pytest` run at the repo root — this service has its
own dependency set, independent of the aidedecamp package.)
"""

from __future__ import annotations

import json

import pytest

from main import app, decode_headers, publish


class _FakeFuture:
    def __init__(self, raise_exc: Exception | None = None):
        self._raise_exc = raise_exc

    def result(self, timeout=None):
        if self._raise_exc:
            raise self._raise_exc
        return "message-id-123"


class _FakePublisher:
    def __init__(self, raise_exc: Exception | None = None):
        self.calls: list[tuple] = []
        self._raise_exc = raise_exc

    def publish(self, topic, data):
        self.calls.append((topic, data))
        return _FakeFuture(self._raise_exc)


@pytest.fixture()
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


# ---------------------------------------------------------------------------
# decode_headers
# ---------------------------------------------------------------------------


def test_decode_headers_extracts_all_fields():
    headers = {
        "X-Goog-Channel-ID": "chan-1",
        "X-Goog-Resource-ID": "res-1",
        "X-Goog-Resource-State": "exists",
        "X-Goog-Message-Number": "42",
        "Content-Type": "application/json",
    }
    decoded = decode_headers(headers)
    assert decoded == {
        "channel_id": "chan-1",
        "resource_id": "res-1",
        "resource_state": "exists",
        "message_number": "42",
    }


def test_decode_headers_missing_fields_default_empty():
    assert decode_headers({}) == {
        "channel_id": "",
        "resource_id": "",
        "resource_state": "",
        "message_number": "",
    }


# ---------------------------------------------------------------------------
# publish
# ---------------------------------------------------------------------------


def test_publish_sends_json_payload():
    fake = _FakePublisher()
    publish(fake, "projects/p/topics/t", {"channel_id": "c1"})

    assert len(fake.calls) == 1
    topic, data = fake.calls[0]
    assert topic == "projects/p/topics/t"
    assert json.loads(data) == {"channel_id": "c1"}


def test_publish_waits_for_result_and_propagates_failure():
    fake = _FakePublisher(raise_exc=RuntimeError("pubsub down"))
    with pytest.raises(RuntimeError, match="pubsub down"):
        publish(fake, "projects/p/topics/t", {"channel_id": "c1"})


# ---------------------------------------------------------------------------
# /calendar-webhook endpoint
# ---------------------------------------------------------------------------


def test_webhook_returns_200(client):
    fake = _FakePublisher()
    app.config["PUBLISHER"] = fake
    app.config["TOPIC"] = "projects/p/topics/calendar"

    resp = client.post(
        "/calendar-webhook",
        headers={
            "X-Goog-Channel-ID": "chan-1",
            "X-Goog-Resource-ID": "res-1",
            "X-Goog-Resource-State": "exists",
            "X-Goog-Message-Number": "1",
        },
    )

    assert resp.status_code == 200


def test_webhook_publishes_decoded_headers(client):
    fake = _FakePublisher()
    app.config["PUBLISHER"] = fake
    app.config["TOPIC"] = "projects/p/topics/calendar"

    client.post(
        "/calendar-webhook",
        headers={
            "X-Goog-Channel-ID": "chan-1",
            "X-Goog-Resource-ID": "res-1",
            "X-Goog-Resource-State": "sync",
            "X-Goog-Message-Number": "1",
        },
    )

    assert len(fake.calls) == 1
    topic, data = fake.calls[0]
    assert topic == "projects/p/topics/calendar"
    payload = json.loads(data)
    assert payload["channel_id"] == "chan-1"
    assert payload["resource_state"] == "sync"


def test_webhook_uses_configured_topic(client):
    fake = _FakePublisher()
    app.config["PUBLISHER"] = fake
    app.config["TOPIC"] = "projects/other/topics/other-calendar"

    client.post("/calendar-webhook", headers={"X-Goog-Channel-ID": "c1"})

    topic, _ = fake.calls[0]
    assert topic == "projects/other/topics/other-calendar"


def test_webhook_get_not_allowed(client):
    resp = client.get("/calendar-webhook")
    assert resp.status_code == 405
