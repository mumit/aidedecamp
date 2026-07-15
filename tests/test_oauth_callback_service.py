from __future__ import annotations

import pytest

from attune.hosted.oauth_callback_service import MAX_CALLBACK_QUERY_BYTES, create_app


def test_callback_is_inert_and_strips_the_credential_bearing_url():
    client = create_app("dev.attune.example").test_client()

    response = client.get(
        "/oauth/google/callback?code=secret-code&state=secret-state",
        base_url="https://dev.attune.example",
    )

    assert response.status_code == 303
    assert response.headers["Location"] == "/"
    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["Referrer-Policy"] == "no-referrer"
    assert b"secret-code" not in response.data
    assert b"secret-state" not in response.data


def test_callback_refuses_oversized_query_without_reflecting_it():
    client = create_app("dev.attune.example").test_client()
    secret = "x" * (MAX_CALLBACK_QUERY_BYTES + 1)

    response = client.get(
        f"/oauth/google/callback?code={secret}",
        base_url="https://dev.attune.example",
    )

    assert response.status_code == 400
    assert secret.encode() not in response.data


@pytest.mark.parametrize("method", ["post", "put", "patch", "delete"])
def test_callback_accepts_only_get(method: str):
    client = create_app("dev.attune.example").test_client()

    response = getattr(client, method)(
        "/oauth/google/callback", base_url="https://dev.attune.example"
    )

    assert response.status_code == 405


def test_callback_rejects_host_confusion():
    response = (
        create_app("dev.attune.example")
        .test_client()
        .get("/oauth/google/callback", base_url="https://attacker.example")
    )
    assert response.status_code == 400


def test_callback_health_is_content_free():
    response = (
        create_app("dev.attune.example")
        .test_client()
        .get("/healthz", base_url="https://dev.attune.example")
    )
    assert response.status_code == 200
    assert response.get_json() == {
        "status": "ok",
        "mode": "oauth_not_activated",
    }


@pytest.mark.parametrize(
    "host", ["", "LOCALHOST", "https://dev.attune.example", "dev_attune.example"]
)
def test_callback_requires_an_exact_dns_hostname(host: str):
    with pytest.raises(ValueError):
        create_app(host)
