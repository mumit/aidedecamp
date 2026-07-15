from __future__ import annotations

import pytest

pytest.importorskip("flask")

from attune.hosted.control_plane_service import create_app

HOST = "dev.attune.mumit.org"


def test_locked_shell_exposes_only_health_and_unavailable_root():
    client = create_app(HOST).test_client()
    headers = {"Host": HOST}
    health = client.get("/healthz", headers=headers)
    assert health.status_code == 200
    assert health.get_json() == {"status": "ok", "mode": "not_activated"}
    root = client.get("/", headers=headers)
    assert root.status_code == 503
    assert root.get_json() == {"status": "not_activated"}
    assert client.get("/oauth/google/callback", headers=headers).status_code == 404
    assert client.post("/", headers=headers).status_code == 405


def test_every_response_sets_strict_non_caching_browser_headers():
    response = create_app(HOST).test_client().get("/", headers={"Host": HOST})
    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["Referrer-Policy"] == "no-referrer"
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["X-Frame-Options"] == "DENY"
    assert response.headers["Strict-Transport-Security"] == "max-age=31536000"
    assert response.headers["Content-Security-Policy"] == (
        "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
    )


def test_host_confusion_and_invalid_configuration_fail_closed():
    client = create_app(HOST).test_client()
    assert client.get("/healthz", headers={"Host": "evil.example"}).status_code == 400
    for value in ("https://dev.attune.mumit.org", "localhost", "DEV.example.com"):
        with pytest.raises(ValueError):
            create_app(value)
