from __future__ import annotations

import time
from types import SimpleNamespace

import pytest

pytest.importorskip("flask")

from attune.hosted.oauth_exchange_service import create_app

AUDIENCE = "https://oauth-exchange.attune.internal"
CALLBACK = "oauth-callback@example.iam.gserviceaccount.com"


class Exchange:
    def __init__(self):
        self.calls = []

    def exchange(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(status_code=204)


def claims(token, audience):
    assert token == "valid" and audience == AUDIENCE
    now = int(time.time())
    return {
        "iss": "https://accounts.google.com",
        "aud": AUDIENCE,
        "email": CALLBACK,
        "email_verified": True,
        "sub": "123",
        "iat": now - 10,
        "exp": now + 300,
    }


def test_exchange_requires_callback_identity_and_exact_body():
    exchange = Exchange()
    client = create_app(
        exchange,
        expected_audience=AUDIENCE,
        expected_callback=CALLBACK,
        token_verifier=claims,
    ).test_client()
    body = {"code": "code", "state": "s" * 43, "binding": "b" * 43}
    assert client.post("/v1/oauth/google/exchange", json=body).status_code == 403
    headers = {"Authorization": "Bearer valid"}
    assert (
        client.post("/v1/oauth/google/exchange", headers=headers, json=body).status_code
        == 204
    )
    assert exchange.calls == [
        {
            "authorization_code": "code",
            "state": "s" * 43,
            "binding": "b" * 43,
        }
    ]
    assert (
        client.post(
            "/v1/oauth/google/exchange",
            headers=headers,
            json={**body, "tenant_id": "untrusted"},
        ).status_code
        == 400
    )


def test_health_is_content_free():
    client = create_app(
        Exchange(),
        expected_audience=AUDIENCE,
        expected_callback=CALLBACK,
        token_verifier=claims,
    ).test_client()
    assert client.get("/healthz").get_json() == {"status": "ok"}
